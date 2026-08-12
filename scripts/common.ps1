$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:PocRepoRoot = Split-Path -Parent $PSScriptRoot

function Get-PocEnv {
    param([string] $Path = (Join-Path $script:PocRepoRoot '.env'))

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Environment file not found: $Path"
    }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -notmatch '^\s*([^=]+)=(.*)$') {
            throw "Malformed .env line: $line"
        }
        $values[$matches[1].Trim()] = $matches[2]
    }
    return $values
}

function Assert-PocSecretsConfigured {
    param([hashtable] $EnvValues = (Get-PocEnv))

    $requiredSecrets = @(
        'POSTGRES_PASSWORD',
        'LITELLM_MASTER_KEY',
        'LITELLM_SALT_KEY',
        'WEBUI_SECRET_KEY',
        'GRAFANA_ADMIN_PASSWORD'
    )
    foreach ($name in $requiredSecrets) {
        $value = $EnvValues[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$name is missing or empty in .env"
        }
        if ($value -match '^CHANGE_ME(?:_|$)') {
            throw "$name still contains the CHANGE_ME placeholder. Set a private value in .env before starting the stack."
        }
    }
}

function Get-PocHostOs {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)) { return 'windows' }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX)) { return 'macos' }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Linux)) { return 'linux' }
    throw 'Unsupported operating system.'
}

function Get-PocArchitecture {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    switch ($architecture) {
        'x64' { return 'amd64' }
        'arm64' { return 'arm64' }
        default { throw "Unsupported process architecture: $architecture" }
    }
}

function Test-PocDockerNvidia {
    param([int] $TimeoutSeconds = 30)

    $script:PocNvidiaProbeDiagnostic = ''
    $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $dockerCommand) {
        $script:PocNvidiaProbeDiagnostic = 'Docker command is not available.'
        return $false
    }

    $envValues = Get-PocEnv
    $probeImage = $envValues['OLLAMA_IMAGE']
    if ([string]::IsNullOrWhiteSpace($probeImage)) { $probeImage = 'ollama/ollama:0.32.6' }

    $process = $null
    try {
        $probeArguments = @(
            'run', '--rm', '--pull', 'missing', '--gpus', 'all',
            '--entrypoint', 'nvidia-smi', $probeImage,
            '--query-gpu=name', '--format=csv,noheader'
        )
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $dockerCommand.Source
        $processInfo.Arguments = ($probeArguments | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        if (-not $process.Start()) { throw 'Docker NVIDIA probe process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            $script:PocNvidiaProbeDiagnostic = "Docker NVIDIA probe timed out after $TimeoutSeconds seconds."
            return $false
        }

        $process.WaitForExit()
        $stdout = $stdoutTask.Result.Trim()
        $stderr = $stderrTask.Result.Trim()
        if ($process.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stdout)) {
            $script:PocNvidiaProbeDiagnostic = $stdout
            return $true
        }
        $script:PocNvidiaProbeDiagnostic = if ([string]::IsNullOrWhiteSpace($stderr)) {
            "Docker NVIDIA probe exited with code $($process.ExitCode)."
        }
        else { $stderr }
        return $false
    }
    catch {
        $script:PocNvidiaProbeDiagnostic = "$($_.Exception.Message) $($_.ScriptStackTrace)"
        return $false
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Resolve-PocProfile {
    param(
        [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $RequestedProfile = 'auto',
        [switch] $NativeOllama,
        [string] $HostOs = (Get-PocHostOs),
        [string] $Architecture = (Get-PocArchitecture),
        [Nullable[bool]] $DockerNvidiaAvailable = $null
    )

    if ($NativeOllama) {
        if ($RequestedProfile -ne 'auto' -and $RequestedProfile -ne 'native') {
            throw "-NativeOllama conflicts with -Profile $RequestedProfile."
        }
        return 'native'
    }
    if ($RequestedProfile -eq 'cpu' -or $RequestedProfile -eq 'native') { return $RequestedProfile }

    if ($RequestedProfile -eq 'nvidia') {
        if ($HostOs -notin @('windows', 'linux') -or $Architecture -ne 'amd64') {
            throw "NVIDIA profile requires Windows/Linux on amd64; detected $HostOs/$Architecture."
        }
        $nvidiaAvailable = if ($null -eq $DockerNvidiaAvailable) { Test-PocDockerNvidia } else { [bool]$DockerNvidiaAvailable }
        if (-not $nvidiaAvailable) {
            throw "NVIDIA profile requested but Docker GPU access failed. $script:PocNvidiaProbeDiagnostic"
        }
        return 'nvidia'
    }

    if ($HostOs -eq 'macos') { return 'native' }
    if ($HostOs -notin @('windows', 'linux')) { throw "Unsupported operating system: $HostOs" }
    if ($Architecture -eq 'amd64') {
        $nvidiaAvailable = if ($null -eq $DockerNvidiaAvailable) { Test-PocDockerNvidia } else { [bool]$DockerNvidiaAvailable }
        if ($nvidiaAvailable) { return 'nvidia' }
    }
    return 'cpu'
}

function Get-PocComposeFiles {
    param([ValidateSet('cpu', 'native', 'nvidia')] [string] $Profile)

    switch ($Profile) {
        'cpu' { return @(Join-Path $script:PocRepoRoot 'docker-compose.yml') }
        'native' { return @(Join-Path $script:PocRepoRoot 'docker-compose.native-ollama.yml') }
        'nvidia' {
            return @(
                (Join-Path $script:PocRepoRoot 'docker-compose.yml'),
                (Join-Path $script:PocRepoRoot 'docker-compose.nvidia.yml')
            )
        }
    }
}

function Invoke-PocCompose {
    param(
        [ValidateSet('cpu', 'native', 'nvidia')] [string] $Profile = 'cpu',
        [switch] $NativeOllama,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    if ($NativeOllama) { $Profile = 'native' }
    $dockerArguments = @('compose')
    foreach ($composeFile in (Get-PocComposeFiles -Profile $Profile)) {
        $dockerArguments += @('-f', $composeFile)
    }
    $dockerArguments += $Arguments
    & docker @dockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose failed with exit code $LASTEXITCODE`: docker $($dockerArguments -join ' ')"
    }
}

function Invoke-PocHttpStatus {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers = @{},
        [string] $Method = 'GET',
        [string] $Body,
        [string] $ContentType,
        [int] $TimeoutSeconds = 15
    )

    $requestParameters = @{
        Uri = $Uri
        Headers = $Headers
        Method = $Method
        TimeoutSec = $TimeoutSeconds
        UseBasicParsing = $true
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $requestParameters['Body'] = $Body }
    if ($PSBoundParameters.ContainsKey('ContentType')) { $requestParameters['ContentType'] = $ContentType }
    try {
        return [int](Invoke-WebRequest @requestParameters).StatusCode
    }
    catch {
        $response = $_.Exception.Response
        if ($null -eq $response) { throw }
        return [int]$response.StatusCode
    }
}

function Assert-PocCommand {
    param([Parameter(Mandatory)] [string] $Name)

    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is not available: $Name"
    }
}

function Assert-PocFile {
    param([Parameter(Mandatory)] [string] $RelativePath)

    $path = Join-Path $script:PocRepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file is missing or is not a file: $RelativePath"
    }
}

function Get-PocContainerState {
    param([Parameter(Mandatory)] [string] $ContainerName)

    $raw = & docker inspect $ContainerName --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $parts = ($raw -join '').Trim().Split('|')
    return [pscustomobject]@{
        Status = $parts[0]
        Health = $parts[1]
    }
}

function Wait-PocContainerHealthy {
    param(
        [Parameter(Mandatory)] [string] $ContainerName,
        [int] $TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = Get-PocContainerState -ContainerName $ContainerName
        if ($null -ne $state) {
            if ($state.Status -eq 'running' -and ($state.Health -eq 'healthy' -or $state.Health -eq 'none')) {
                Write-Host "[healthy] $ContainerName"
                return
            }
            if ($state.Status -eq 'exited' -or $state.Health -eq 'unhealthy') {
                throw "$ContainerName entered terminal state: status=$($state.Status), health=$($state.Health)"
            }
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if ($null -eq $state) {
        throw "Timed out waiting for container to appear: $ContainerName"
    }
    throw "Timed out waiting for $ContainerName`: status=$($state.Status), health=$($state.Health)"
}

function Wait-PocHttp {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers = @{},
        [int] $TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $Headers -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { return $response }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for HTTP endpoint: $Uri"
}

function Get-PocMasterKey {
    $envValues = Get-PocEnv
    $key = $envValues['LITELLM_MASTER_KEY']
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw 'LITELLM_MASTER_KEY is missing from .env'
    }
    return $key
}

function Get-PocBearerHeaders {
    return @{ Authorization = "Bearer $(Get-PocMasterKey)" }
}
