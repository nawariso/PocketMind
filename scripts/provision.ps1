param(
    [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto',
    # Email of the Open WebUI administrator that is created on the first start. Needed when .env does not exist yet.
    [string] $AdminEmail = '',
    # Address users type to reach this server (an IP or DNS name). Defaults to this host's primary IPv4 address.
    [string] $PublicHost = '',
    # Report what is missing and change nothing.
    [switch] $CheckOnly,
    [switch] $SkipNetworkCheck,
    # Open Open WebUI sign-up to everyone who can reach it. Off by default: with the new-account role `user` it means
    # anyone on the network can chat and create API keys, with no email-domain limit and no email verification.
    [switch] $EnableSignup,
    # Install what is missing and safe to install: Ollama on macOS (Homebrew, started by a LaunchAgent with the
    # context length the stack needs). With -CheckOnly it only prints what it would do. Docker is never installed.
    [switch] $InstallPrerequisites,
    # Do not ask before installing.
    [switch] $Yes,
    # Do not download images and models (they must already be present).
    [switch] $NoPull,
    [switch] $LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

# One command, in the right order, on any supported host: check the host, create .env if needed, start the stack,
# verify it, configure Open WebUI, and install the API Key Manager. Safe to run again: existing .env values and
# running services are kept, and every step reads the current state before it changes anything.

$script:Checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check {
    param([string] $Name, [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Status, [string] $Detail, [string] $Fix = '')
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Fix = $Fix })
}

# --- pure helpers (covered by tests/provision-contract.ps1) -----------------------------------------------------

function ConvertTo-VersionOrNull {
    param([string] $Text)
    $match = [regex]::Match([string]$Text, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $patch = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }
    return New-Object System.Version ([int]$match.Groups[1].Value), ([int]$match.Groups[2].Value), $patch
}

function Test-VersionAtLeast {
    param([string] $Text, [string] $Minimum)
    $actual = ConvertTo-VersionOrNull $Text
    if ($null -eq $actual) { return $false }
    return $actual -ge (ConvertTo-VersionOrNull $Minimum)
}

function Get-RandomSecret {
    param([int] $Bytes = 24)
    $buffer = New-Object byte[] $Bytes
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($buffer) } finally { $generator.Dispose() }
    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-ProvisionEnvContent {
    # Builds a private .env from .env.example: random secrets in place of the placeholders, the bootstrap administrator,
    # and the shared-pilot proxy switched on.
    param([Parameter(Mandatory)] [string] $ExampleText, [Parameter(Mandatory)] [string] $AdminEmail)
    $text = $ExampleText
    $text = $text -replace 'CHANGE_ME_POSTGRES_PASSWORD', (Get-RandomSecret)
    $text = $text -replace 'CHANGE_ME_LITELLM_MASTER_KEY', ('sk-' + (Get-RandomSecret))
    $text = $text -replace 'CHANGE_ME_LITELLM_SALT_KEY', (Get-RandomSecret)
    $text = $text -replace 'CHANGE_ME_WEBUI_SECRET_KEY', (Get-RandomSecret)
    $text = $text -replace 'CHANGE_ME_GRAFANA_PASSWORD', (Get-RandomSecret)
    $text = $text -replace '(?m)^WEBUI_ADMIN_EMAIL=.*$', ('WEBUI_ADMIN_EMAIL=' + $AdminEmail)
    $text = $text -replace '(?m)^WEBUI_ADMIN_PASSWORD=.*$', ('WEBUI_ADMIN_PASSWORD=' + (Get-RandomSecret -Bytes 16))
    $text = $text -replace '(?m)^PROXY_ENABLED=.*$', 'PROXY_ENABLED=true'
    return $text
}

function Get-ListeningPorts {
    return @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $_.Port } | Sort-Object -Unique)
}

function Get-PrimaryIPv4 {
    $candidates = foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne 'Up' -or $adapter.NetworkInterfaceType -eq 'Loopback') { continue }
        $properties = $adapter.GetIPProperties()
        $hasGateway = @($properties.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0
        foreach ($address in $properties.UnicastAddresses) {
            if ($address.Address.AddressFamily -eq 'InterNetwork' -and -not $address.Address.ToString().StartsWith('169.254.')) {
                [pscustomobject]@{ Address = $address.Address.ToString(); Gateway = $hasGateway }
            }
        }
    }
    $preferred = @($candidates | Sort-Object { -not $_.Gateway } | Select-Object -First 1)
    if ($preferred.Count -eq 0) { return '' }
    return $preferred[0].Address
}

function Get-StatusForMemory {
    param([double] $GiB)
    if ($GiB -lt 6) { return 'FAIL' }
    if ($GiB -lt 8) { return 'WARN' }
    return 'PASS'
}

function Get-StatusForDisk {
    param([double] $GiB)
    if ($GiB -lt 10) { return 'FAIL' }
    if ($GiB -lt 25) { return 'WARN' }
    return 'PASS'
}

function Get-HostAdvice {
    # Remediation text per operating system. Only the macOS Homebrew command was run on a real host; the others
    # point to the vendors' instructions.
    param([ValidateSet('windows', 'macos', 'linux')] [string] $HostOs, [Parameter(Mandatory)] [string] $Item)
    $advice = @{
        'docker' = @{
            windows = 'Install Docker Desktop with the WSL2 backend: https://docs.docker.com/desktop/setup/install/windows-install/'
            macos   = 'Install Docker Desktop for Mac: https://docs.docker.com/desktop/setup/install/mac-install/'
            linux   = 'Install Docker Engine and the Compose plugin: https://docs.docker.com/engine/install/ , then add your user to the docker group and enable the service (systemctl enable --now docker).'
        }
        'pwsh' = @{
            windows = 'winget install --id Microsoft.PowerShell (Windows PowerShell 5.1 also works for these scripts).'
            macos   = 'brew install powershell'
            linux   = 'Install PowerShell 7: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux'
        }
        'ollama' = @{
            windows = 'Not needed: the Windows profiles run Ollama in a container.'
            macos   = 'Install Ollama (https://ollama.com/download) and start it with: OLLAMA_CONTEXT_LENGTH=8192 OLLAMA_KEEP_ALIVE=10m ollama serve'
            linux   = 'Not needed: the Linux profiles run Ollama in a container.'
        }
        'firewall' = @{
            windows = 'Allow only the proxy ports (default 8480 and 8481) in Windows Defender Firewall for the user network.'
            macos   = 'Allow only the proxy ports (default 8480 and 8481) for the user network.'
            linux   = 'Docker publishes ports around ufw and similar firewalls. Restrict clients in nginx/local/*.conf (allow <cidr>; deny all;) or set PROXY_BIND_ADDRESS to one interface, then test from another machine.'
        }
    }
    return $advice[$Item][$HostOs]
}

function Invoke-ProvisionStep {
    param([string] $Title, [scriptblock] $Action)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    # A stale exit code from an earlier native command must not fail this step.
    $global:LASTEXITCODE = 0
    & $Action
    if ($global:LASTEXITCODE -ne 0) { throw "Step failed: $Title" }
}

function Test-FreshOpenWebUiExposure {
    # True when a NEW Open WebUI (no data volume yet) would be reachable beyond this host with no bootstrap
    # administrator: the first visitor would become administrator.
    param([string] $AdminEmail, [string] $AdminPassword, [bool] $VolumeExists, [bool] $ProxyEnabled, [string] $BindAddress)
    if ($VolumeExists) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($AdminEmail) -and -not [string]::IsNullOrWhiteSpace($AdminPassword)) { return $false }
    return $ProxyEnabled -and $BindAddress -ne '127.0.0.1'
}

function ConvertTo-XmlText {
    param([string] $Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-OllamaLaunchAgentPlist {
    # A launchd agent that runs `ollama serve` at login and keeps it running, with the environment the stack needs.
    # OLLAMA_HOST is not set here, so Ollama keeps its loopback default; pass it in -Environment only for tests.
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $OllamaPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Environment,
        [Parameter(Mandatory)] [string] $LogPath
    )
    $variables = ($Environment.Keys | Sort-Object | ForEach-Object {
        "        <key>$(ConvertTo-XmlText $_)</key>`n        <string>$(ConvertTo-XmlText ([string]$Environment[$_]))</string>"
    }) -join "`n"
    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(ConvertTo-XmlText $Label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(ConvertTo-XmlText $OllamaPath)</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
$variables
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(ConvertTo-XmlText $LogPath)</string>
    <key>StandardErrorPath</key>
    <string>$(ConvertTo-XmlText $LogPath)</string>
</dict>
</plist>
"@
}

function Get-OllamaSettings {
    # The values the stack expects, from .env, else .env.example, else the documented defaults.
    $values = @{}
    foreach ($name in @('.env', '.env.example')) {
        $path = Join-Path $script:PocRepoRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { $values = Get-PocEnv -Path $path; break }
    }
    $context = [string]$values['OLLAMA_CONTEXT_LENGTH']; if ([string]::IsNullOrWhiteSpace($context)) { $context = '8192' }
    $keepAlive = [string]$values['OLLAMA_KEEP_ALIVE']; if ([string]::IsNullOrWhiteSpace($keepAlive)) { $keepAlive = '10m' }
    return [pscustomobject]@{ ContextLength = $context; KeepAlive = $keepAlive }
}

function Test-HttpAnswers {
    # True only when the address answers 200; a refused or timed-out connection is simply false.
    param([Parameter(Mandatory)] [string] $Uri, [int] $TimeoutSeconds = 5)
    try { return (Invoke-PocHttpStatus -Uri $Uri -TimeoutSeconds $TimeoutSeconds) -eq 200 } catch { return $false }
}

function Confirm-ProvisionAction {
    param([Parameter(Mandatory)] [string[]] $Plan, [switch] $AssumeYes)
    Write-Host 'About to do:' -ForegroundColor Cyan
    $Plan | ForEach-Object { Write-Host "  - $_" }
    if ($AssumeYes) { return $true }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        throw 'Installing needs confirmation but there is no terminal; run again with -Yes to confirm.'
    }
    return (Read-Host -Prompt 'Proceed? (y/N)') -match '^(y|yes)$'
}

function Get-OllamaInstallPlan {
    # What -InstallPrerequisites would do for native Ollama. Homebrew is told never to update itself or to upgrade
    # something already installed: an upgrade would interrupt a running Ollama and change a version nobody tested.
    param(
        [Parameter(Mandatory)] [bool] $Installed,
        [Parameter(Mandatory)] [string] $OllamaPath,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $ContextLength,
        [Parameter(Mandatory)] [string] $KeepAlive
    )
    $plan = New-Object 'System.Collections.Generic.List[string]'
    if (-not $Installed) { $plan.Add('brew install ollama   (HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1)') }
    $plan.Add("write ~/Library/LaunchAgents/$Label.plist: run '$OllamaPath serve' at login and keep it running, with OLLAMA_CONTEXT_LENGTH=$ContextLength and OLLAMA_KEEP_ALIVE=$KeepAlive (Ollama stays on 127.0.0.1)")
    $plan.Add("launchctl bootstrap the agent, then wait for http://localhost:11434")
    return @($plan)
}

function Install-OllamaLaunchAgent {
    # Loads (or reloads) the agent. Safe to run again: an agent with the same label is unloaded first.
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $OllamaPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Environment,
        [string] $PlistDirectory = (Join-Path $HOME 'Library/LaunchAgents'),
        [string] $LogDirectory = (Join-Path $HOME 'Library/Logs/PocketMind'),
        [int] $Port = 11434
    )
    New-Item -ItemType Directory -Path $PlistDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $plistPath = Join-Path $PlistDirectory "$Label.plist"
    Set-Content -LiteralPath $plistPath -Value (New-OllamaLaunchAgentPlist -Label $Label -OllamaPath $OllamaPath -Environment $Environment -LogPath (Join-Path $LogDirectory 'ollama.log')) -Encoding UTF8
    & plutil -lint $plistPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "The generated launchd file is not valid: $plistPath" }

    $uid = (& id -u).Trim()
    # gui/<uid> exists only in a logged-in desktop session; over SSH on a headless Mac use user/<uid>.
    $domain = "gui/$uid"
    & launchctl print $domain 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $domain = "user/$uid" }
    & launchctl bootout "$domain/$Label" 2>$null | Out-Null
    $global:LASTEXITCODE = 0
    $output = & launchctl bootstrap $domain $plistPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "launchctl could not load $Label in $domain`: $($output -join ' ')" }
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-HttpAnswers -Uri "http://127.0.0.1:$Port/api/tags" -TimeoutSeconds 3) { return $plistPath }
        Start-Sleep -Seconds 2
    }
    throw "Ollama did not answer on port $Port after loading $Label; see $(Join-Path $LogDirectory 'ollama.log')."
}

if ($LibraryOnly) { return }

# --- checks ------------------------------------------------------------------------------------------------------

function Invoke-ProvisionChecks {
    $hostOs = Get-PocHostOs
    $architecture = Get-PocArchitecture
    $supported = ($hostOs -eq 'windows' -and $architecture -eq 'amd64') -or ($hostOs -eq 'macos' -and $architecture -eq 'arm64') -or ($hostOs -eq 'linux')
    Add-Check 'Operating system' $(if ($supported) { 'PASS' } else { 'FAIL' }) "$hostOs / $architecture" $(if ($supported) { '' } else { 'Supported: Windows 11 amd64, macOS Apple Silicon, Linux amd64 or arm64.' })
    Add-Check 'PowerShell' 'PASS' ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

    # Docker
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        Add-Check 'Docker CLI' 'FAIL' 'docker was not found on PATH.' (Get-HostAdvice -HostOs $hostOs -Item 'docker')
        return $null
    }
    $serverVersion = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-Check 'Docker engine' 'FAIL' 'The Docker engine does not answer (not started, or no permission).' 'Start Docker (Docker Desktop, or: systemctl start docker) and make sure your user may use it.'
        return $null
    }
    Add-Check 'Docker engine' 'PASS' "version $serverVersion"
    $osType = & docker info --format '{{.OSType}}' 2>$null
    if ($osType -and $osType -ne 'linux') { Add-Check 'Docker containers' 'FAIL' "Docker is in $osType container mode." 'Switch Docker Desktop to Linux containers (WSL2 backend).' }
    $composeVersion = & docker compose version --short 2>$null
    $composeOk = ($LASTEXITCODE -eq 0) -and (Test-VersionAtLeast -Text "$composeVersion" -Minimum '2.23.1')
    Add-Check 'Docker Compose' $(if ($composeOk) { 'PASS' } else { 'FAIL' }) "version $composeVersion (2.23.1 or newer is needed for inline configs)" $(if ($composeOk) { '' } else { 'Update Docker Desktop, or install the current Compose v2 plugin.' })

    $memoryBytes = 0.0
    [double]::TryParse([string](& docker info --format '{{.MemTotal}}' 2>$null), [ref]$memoryBytes) | Out-Null
    $memoryGiB = [math]::Round($memoryBytes / 1GB, 1)
    $memoryStatus = Get-StatusForMemory $memoryGiB
    Add-Check 'Memory available to Docker' $memoryStatus "$memoryGiB GiB" $(if ($memoryStatus -ne 'PASS') { 'At least 8 GiB is required and 16 GiB or more is recommended; raise the Docker Desktop memory limit or use a larger host.' } else { '' })

    $diskPath = $script:PocRepoRoot
    if ($hostOs -eq 'linux') {
        $root = & docker info --format '{{.DockerRootDir}}' 2>$null
        if ($root -and (Test-Path -LiteralPath $root)) { $diskPath = $root }
    }
    $drive = [System.IO.DriveInfo]::GetDrives() | Where-Object { $diskPath.StartsWith($_.RootDirectory.FullName) } |
        Sort-Object { $_.RootDirectory.FullName.Length } -Descending | Select-Object -First 1
    if ($null -ne $drive) {
        $freeGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        $diskStatus = Get-StatusForDisk $freeGiB
        Add-Check 'Free disk space' $diskStatus "$freeGiB GiB on $($drive.RootDirectory.FullName)" $(if ($diskStatus -ne 'PASS') { 'Images and models need about 15 GiB; keep at least 25 GiB free.' } else { '' })
    }

    # Profile and its runtime
    $resolved = $null
    try { $resolved = Resolve-PocProfile -RequestedProfile $Profile }
    catch { Add-Check 'Inference profile' 'FAIL' $_.Exception.Message 'Choose a profile this host supports: cpu, nvidia (NVIDIA GPU), or native (macOS).' }
    if ($null -ne $resolved) {
        Add-Check 'Inference profile' 'PASS' "$resolved (requested: $Profile)"
        if ($resolved -eq 'native') {
            $ollamaCommand = Get-Command ollama -ErrorAction SilentlyContinue
            # PROVISION_OLLAMA_URL exists only so tests can point this check at an address nothing listens on.
            $ollamaUrl = if ([string]::IsNullOrWhiteSpace($env:PROVISION_OLLAMA_URL)) { 'http://localhost:11434' } else { $env:PROVISION_OLLAMA_URL }
            $ollamaAnswers = Test-HttpAnswers -Uri "$ollamaUrl/api/tags"
            if ($ollamaAnswers) {
                Add-Check 'Ollama (native)' 'PASS' 'answers on localhost:11434'
                if ($InstallPrerequisites) {
                    Add-Check 'Ollama settings' 'WARN' 'Ollama is already running and was left alone (it may not have been started with OLLAMA_CONTEXT_LENGTH=8192).' 'Confirm the CONTEXT column of "ollama ps" shows 8192 after the first request; to let PocketMind manage Ollama, stop yours and run this script again with -InstallPrerequisites.'
                }
            }
            elseif (-not $InstallPrerequisites -or $hostOs -ne 'macos') {
                $detail = if ($null -eq $ollamaCommand) { 'ollama was not found.' } else { 'Ollama is installed but does not answer on localhost:11434.' }
                Add-Check 'Ollama (native)' 'FAIL' $detail ((Get-HostAdvice -HostOs $hostOs -Item 'ollama') + $(if ($hostOs -eq 'macos') { ' Or run this script again with -InstallPrerequisites.' } else { '' }))
            }
            else {
                $brew = Get-Command brew -ErrorAction SilentlyContinue
                $label = 'com.pocketmind.ollama'
                $ollamaSettings = Get-OllamaSettings
                # The Homebrew prefix is /opt/homebrew on Apple Silicon; the symlink survives upgrades, unlike the Cellar path.
                $brewPrefix = if ($null -ne $brew) { (& brew --prefix).Trim() } else { '/opt/homebrew' }
                $ollamaPath = Join-Path $brewPrefix 'bin/ollama'
                if ($null -eq $ollamaCommand -and $null -eq $brew) {
                    Add-Check 'Ollama (native)' 'FAIL' 'ollama is not installed and Homebrew is not available to install it.' 'Install Homebrew (https://brew.sh) or Ollama (https://ollama.com/download), then run this script again.'
                }
                else {
                    $plan = Get-OllamaInstallPlan -Installed ($null -ne $ollamaCommand) -OllamaPath $ollamaPath -Label $label -ContextLength $ollamaSettings.ContextLength -KeepAlive $ollamaSettings.KeepAlive
                    if ($CheckOnly) {
                        Add-Check 'Ollama (native)' 'WARN' 'not running; -InstallPrerequisites would set it up (nothing is installed in -CheckOnly mode).' ($plan -join ' | ')
                    }
                    elseif (-not (Confirm-ProvisionAction -Plan $plan -AssumeYes:$Yes)) {
                        Add-Check 'Ollama (native)' 'FAIL' 'installation was not confirmed.' 'Run again and answer y, or pass -Yes.'
                    }
                    else {
                        try {
                            if ($null -eq $ollamaCommand) {
                                $env:HOMEBREW_NO_AUTO_UPDATE = '1'; $env:HOMEBREW_NO_INSTALL_UPGRADE = '1'
                                & brew install ollama
                                if ($LASTEXITCODE -ne 0) { throw 'brew install ollama failed.' }
                            }
                            $ollamaEnvironment = [ordered]@{ OLLAMA_CONTEXT_LENGTH = $ollamaSettings.ContextLength; OLLAMA_KEEP_ALIVE = $ollamaSettings.KeepAlive }
                            $plist = Install-OllamaLaunchAgent -Label $label -OllamaPath $ollamaPath -Environment $ollamaEnvironment
                            $version = (& $ollamaPath --version 2>&1 | Select-Object -Last 1)
                            Add-Check 'Ollama (native)' 'PASS' "installed and started by launchd ($plist); $version" 'This stack was exercised with Homebrew Ollama 0.30.11; a newer version is untested here.'
                        }
                        catch { Add-Check 'Ollama (native)' 'FAIL' $_.Exception.Message 'Fix the error above, or install and start Ollama yourself (see the guide).' }
                    }
                }
            }
        }
        elseif ($resolved -eq 'nvidia') {
            if (Test-PocDockerNvidia) { Add-Check 'NVIDIA GPU in Docker' 'PASS' 'a container can use the GPU' }
            else { Add-Check 'NVIDIA GPU in Docker' 'FAIL' $script:PocNvidiaProbeDiagnostic 'Install the NVIDIA driver and the NVIDIA Container Toolkit, then retry (or use -Profile cpu).' }
        }
    }

    # Ports: a running installation owns its own ports, so only a fresh host is checked.
    $ownContainers = @(& docker ps --filter 'name=pocketmind-' --format '{{.Names}}' 2>$null)
    if ($ownContainers.Count -eq 0) {
        $wanted = @(3000, 3001, 4000, 5432, 9090)
        if ($resolved -eq 'cpu' -or $resolved -eq 'nvidia') { $wanted += 11434 }
        # A .env that does not exist yet is created with the proxy enabled, so its ports are needed too.
        if (-not (Test-Path -LiteralPath (Join-Path $script:PocRepoRoot '.env') -PathType Leaf) -or (Test-PocProxyEnabled)) {
            $proxy = Get-PocProxySettings
            $wanted += @($proxy.WebUiPort, $proxy.ApiPort)
        }
        $busy = @($wanted | Where-Object { (Get-ListeningPorts) -contains $_ })
        Add-Check 'Ports free' $(if ($busy.Count -eq 0) { 'PASS' } else { 'FAIL' }) $(if ($busy.Count -eq 0) { ($wanted -join ', ') } else { "in use: $($busy -join ', ')" }) $(if ($busy.Count -eq 0) { '' } else { 'Stop the program using them, or change PROXY_WEBUI_PORT and PROXY_API_PORT in .env (the service ports 3000, 3001, 4000, 5432, 9090 are fixed).' })
    }
    else { Add-Check 'Ports free' 'PASS' 'an existing PocketMind installation is running; its ports are not re-checked' }

    # An existing .env without a bootstrap administrator would start a NEW Open WebUI that any visitor could claim.
    $envFile = Join-Path $script:PocRepoRoot '.env'
    if ((Test-Path -LiteralPath $envFile -PathType Leaf) -and $null -ne $resolved) {
        $existing = Get-PocEnv
        # The exact volume of THIS compose project (another stack on the host may have its own openwebui_data).
        $volumeExists = $false
        try {
            $composeArguments = @('compose')
            foreach ($composeFile in (Get-PocComposeFiles -Profile $resolved)) { $composeArguments += @('-f', $composeFile) }
            if (Test-PocProxyEnabled) { $composeArguments += @('-f', (Get-PocProxyComposeFile)) }
            $composeArguments += @('config', '--format', 'json')
            $volumeName = [string]((((& docker @composeArguments 2>$null) -join "`n") | ConvertFrom-Json).volumes.openwebui_data.name)
            if (-not [string]::IsNullOrWhiteSpace($volumeName)) {
                $volumeExists = @(& docker volume ls --format '{{.Name}}' 2>$null | Where-Object { $_ -eq $volumeName }).Count -gt 0
            }
        }
        catch { $volumeExists = $false }
        $proxySettings = Get-PocProxySettings
        if (Test-FreshOpenWebUiExposure -AdminEmail ([string]$existing['WEBUI_ADMIN_EMAIL']) -AdminPassword ([string]$existing['WEBUI_ADMIN_PASSWORD']) `
                -VolumeExists $volumeExists -ProxyEnabled (Test-PocProxyEnabled) -BindAddress $proxySettings.BindAddress) {
            Add-Check 'First administrator' 'FAIL' 'a new Open WebUI would be reachable from the network with no administrator configured: the first visitor would become administrator.' 'Set WEBUI_ADMIN_EMAIL and WEBUI_ADMIN_PASSWORD in .env, or set PROXY_BIND_ADDRESS=127.0.0.1 until the administrator account exists.'
        }
    }

    # Host specifics
    if ($hostOs -eq 'linux') {
        if ($null -ne (Get-Command systemctl -ErrorAction SilentlyContinue)) {
            $enabled = (& systemctl is-enabled docker 2>$null)
            if ("$enabled" -ne 'enabled') { Add-Check 'Docker starts at boot' 'WARN' 'the docker service is not enabled' 'systemctl enable docker, so the stack returns after a reboot.' }
        }
        if ($null -ne (Get-Command ufw -ErrorAction SilentlyContinue) -and ("$(& ufw status 2>$null)" -match 'Status: active')) {
            Add-Check 'Host firewall' 'WARN' 'ufw is active, but Docker published ports bypass it' (Get-HostAdvice -HostOs $hostOs -Item 'firewall')
        }
        if ($null -ne (Get-Command getenforce -ErrorAction SilentlyContinue) -and ("$(& getenforce 2>$null)" -eq 'Enforcing')) {
            Add-Check 'SELinux' 'WARN' 'SELinux is enforcing; bind-mounted config files may need a :z label' 'If a container cannot read its config, add :z to the bind mounts or set a policy.'
        }
    }
    else { Add-Check 'Host firewall' 'WARN' 'allow only the proxy ports for the user network' (Get-HostAdvice -HostOs $hostOs -Item 'firewall') }

    # Network egress (host view; the Docker daemon may use its own proxy settings)
    if (-not $SkipNetworkCheck) {
        foreach ($target in @(
            @{ Name = 'Docker Hub'; Uri = 'https://registry-1.docker.io/v2/'; Ok = @(200, 401) },
            @{ Name = 'GitHub Container Registry'; Uri = 'https://ghcr.io/v2/'; Ok = @(200, 401) },
            @{ Name = 'LiteLLM registry'; Uri = 'https://docker.litellm.ai/v2/'; Ok = @(200, 401) },
            # The Ollama registry answers 404 at its root; a gateway block page answers 403, 407, or 503 instead.
            @{ Name = 'Ollama registry'; Uri = 'https://registry.ollama.ai/v2/'; Ok = @(200, 401, 404) }
        )) {
            $status = 0
            try { $status = Invoke-PocHttpStatus -Uri $target.Uri -TimeoutSeconds 10 } catch { $status = 0 }
            # A registry answers one of the expected codes; a gateway block page answers something else, and no answer means no route.
            $reachable = $target.Ok -contains $status
            Add-Check "Download: $($target.Name)" $(if ($reachable) { 'PASS' } else { 'WARN' }) "HTTP $status from $($target.Uri)" $(if ($reachable) { '' } else { 'Ask the network team to allow this registry (and, for ghcr.io, pkg-containers.githubusercontent.com), or load the images in advance.' })
        }
    }
    return $resolved
}

function Show-Checks {
    foreach ($check in $script:Checks) {
        $color = switch ($check.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
        Write-Host ('[{0}] {1}: {2}' -f $check.Status, $check.Name, $check.Detail) -ForegroundColor $color
        if ($check.Fix) { Write-Host "       -> $($check.Fix)" }
    }
}

try {
    $repo = $script:PocRepoRoot
    $envPath = Join-Path $repo '.env'

    Write-Host '=== Host and prerequisites ===' -ForegroundColor Cyan
    $resolvedProfile = Invoke-ProvisionChecks
    Show-Checks
    $failures = @($script:Checks | Where-Object { $_.Status -eq 'FAIL' })
    $warnings = @($script:Checks | Where-Object { $_.Status -eq 'WARN' })
    Write-Host ("`n{0} check(s) failed, {1} warning(s)." -f $failures.Count, $warnings.Count)
    if ($failures.Count -gt 0) { throw 'Fix the failed checks above, then run this script again.' }
    if ($CheckOnly) { Write-Host 'Check only: nothing was changed.' -ForegroundColor Green; return }

    Invoke-ProvisionStep 'Private configuration (.env)' {
        if (Test-Path -LiteralPath $envPath -PathType Leaf) {
            Write-Host '.env already exists: it is kept as it is.'
        }
        else {
            $email = $AdminEmail
            if ([string]::IsNullOrWhiteSpace($email)) { $email = Read-Host -Prompt 'Email address of the Open WebUI administrator' }
            if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'A valid administrator email is required (-AdminEmail).' }
            $content = New-ProvisionEnvContent -ExampleText (Get-Content -Raw -LiteralPath (Join-Path $repo '.env.example')) -AdminEmail $email
            Set-Content -LiteralPath $envPath -Value $content -Encoding ASCII -NoNewline
            if ((Get-PocHostOs) -ne 'windows') { & chmod 600 $envPath }
            Write-Host ".env created with random secrets, administrator $email, and the shared proxy enabled."
            Write-Host 'The administrator password and every other secret are stored only in .env. Keep it private and back it up.'
        }
        $script:EnvValues = Get-PocEnv
        if ([string]::IsNullOrWhiteSpace([string]$script:EnvValues['WEBUI_ADMIN_EMAIL'])) {
            Write-Warning 'WEBUI_ADMIN_EMAIL is empty in .env: on a new installation the first visitor would become administrator.'
        }
    }

    Invoke-ProvisionStep 'Prerequisite check for the chosen profile' { & (Join-Path $PSScriptRoot 'check-prerequisites.ps1') -Profile $resolvedProfile }
    Invoke-ProvisionStep 'Start the stack' {
        if ($NoPull) { & (Join-Path $PSScriptRoot 'setup.ps1') -Profile $resolvedProfile }
        else { & (Join-Path $PSScriptRoot 'setup.ps1') -Profile $resolvedProfile -Pull }
    }
    Invoke-ProvisionStep 'Verify the stack' { & (Join-Path $PSScriptRoot 'verify-stack.ps1') -Profile $resolvedProfile }

    $adminEmailInEnv = [string]$script:EnvValues['WEBUI_ADMIN_EMAIL']
    if ([string]::IsNullOrWhiteSpace($adminEmailInEnv)) { $adminEmailInEnv = $AdminEmail }
    if ([string]::IsNullOrWhiteSpace($adminEmailInEnv)) {
        Write-Warning 'No administrator email is known (WEBUI_ADMIN_EMAIL is empty and -AdminEmail was not given), so the Open WebUI steps were skipped. Run scripts/configure-open-webui.ps1 and scripts/install-key-manager.ps1 yourself.'
    }
    else {
        $apiPort = (Get-PocProxySettings).ApiPort
        # A host name given with -PublicHost is applied as asked; a detected address never replaces one an administrator chose.
        $hostGiven = -not [string]::IsNullOrWhiteSpace($PublicHost)
        if ([string]::IsNullOrWhiteSpace($PublicHost)) { $PublicHost = Get-PrimaryIPv4 }
        if ([string]::IsNullOrWhiteSpace($PublicHost)) { $PublicHost = 'localhost' }
        Invoke-ProvisionStep 'Configure Open WebUI (new-account role, task model, model access)' {
            if ($EnableSignup) { & (Join-Path $PSScriptRoot 'configure-open-webui.ps1') -AdminEmail $adminEmailInEnv -EnableSignup }
            else { & (Join-Path $PSScriptRoot 'configure-open-webui.ps1') -AdminEmail $adminEmailInEnv }
        }
        Invoke-ProvisionStep 'Install the API Key Manager' {
            $env:OPENWEBUI_ADMIN_PASSWORD = [string]$script:EnvValues['WEBUI_ADMIN_PASSWORD']
            try {
                if ($hostGiven) { & (Join-Path $PSScriptRoot 'install-key-manager.ps1') -AdminEmail $adminEmailInEnv -PublicBaseUrl "http://${PublicHost}:$apiPort/v1" }
                else { & (Join-Path $PSScriptRoot 'install-key-manager.ps1') -AdminEmail $adminEmailInEnv -PublicBaseUrl "http://${PublicHost}:$apiPort/v1" -KeepCustomBaseUrl }
            }
            finally { Remove-Item Env:\OPENWEBUI_ADMIN_PASSWORD -ErrorAction SilentlyContinue }
        }
    }

    $proxy = Get-PocProxySettings
    Write-Host "`n=== Ready ===" -ForegroundColor Green
    Write-Host "Chat (users, in a browser):  http://${PublicHost}:$($proxy.WebUiPort)"
    Write-Host "API for applications:        http://${PublicHost}:$($proxy.ApiPort)/v1   (users create their own key in Open WebUI with the 'API Key Manager' model)"
    Write-Host "Administrator:               $adminEmailInEnv  (password: WEBUI_ADMIN_PASSWORD in .env)"
    Write-Host 'Still yours to decide: HTTPS, client address limits in nginx/local, LiteLLM teams, backups. See docs/server-deployment-checklist.md.'
}
catch {
    Write-Error "Provisioning stopped: $($_.Exception.Message)"
    exit 1
}
