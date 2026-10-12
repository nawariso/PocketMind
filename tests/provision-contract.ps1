$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

. (Join-Path $repoRoot 'scripts/provision.ps1') -LibraryOnly
$provision = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/provision.ps1')

# --- version comparison (Docker Compose must be new enough for inline configs)
Assert-True -Condition (Test-VersionAtLeast -Text 'v5.1.4' -Minimum '2.23.1') -Message 'Compose v5.1.4 must satisfy 2.23.1'
Assert-True -Condition (Test-VersionAtLeast -Text '2.23.1' -Minimum '2.23.1') -Message 'Compose 2.23.1 must satisfy 2.23.1'
Assert-True -Condition (-not (Test-VersionAtLeast -Text '2.23.0' -Minimum '2.23.1')) -Message 'Compose 2.23.0 must not satisfy 2.23.1'
Assert-True -Condition (Test-VersionAtLeast -Text '2.40' -Minimum '2.23.1') -Message 'Compose 2.40 must satisfy 2.23.1'
Assert-True -Condition (-not (Test-VersionAtLeast -Text 'not a version' -Minimum '2.23.1')) -Message 'Unparsable versions must fail'

# --- thresholds
foreach ($case in @(@(5.9, 'FAIL'), @(6, 'WARN'), @(7.7, 'WARN'), @(8, 'PASS'), @(16, 'PASS'))) {
    Assert-True -Condition ((Get-StatusForMemory $case[0]) -eq $case[1]) -Message "Memory $($case[0]) GiB must be $($case[1])"
}
foreach ($case in @(@(9, 'FAIL'), @(10, 'WARN'), @(24.9, 'WARN'), @(25, 'PASS'))) {
    Assert-True -Condition ((Get-StatusForDisk $case[0]) -eq $case[1]) -Message "Disk $($case[0]) GiB must be $($case[1])"
}

# --- generated configuration
$first = Get-RandomSecret
Assert-True -Condition ($first -match '^[0-9a-f]{48}$') -Message 'Random secrets must be 48 hex characters'
Assert-True -Condition ($first -ne (Get-RandomSecret)) -Message 'Random secrets must differ between calls'

$example = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.env.example')
$generated = New-ProvisionEnvContent -ExampleText $example -AdminEmail 'owner@example.com'
Assert-True -Condition ($generated -notmatch 'CHANGE_ME_') -Message 'Generated .env must not keep any CHANGE_ME_ placeholder'
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("pm-provision-" + [guid]::NewGuid().ToString('N') + '.env')
try {
    Set-Content -LiteralPath $temporary -Value $generated -Encoding ASCII -NoNewline
    $values = Get-PocEnv -Path $temporary
    Assert-PocSecretsConfigured -EnvValues $values
    Assert-True -Condition ($values['WEBUI_ADMIN_EMAIL'] -eq 'owner@example.com') -Message 'Generated .env must carry the administrator email'
    Assert-True -Condition ($values['WEBUI_ADMIN_PASSWORD'].Length -ge 12 -and $values['WEBUI_ADMIN_PASSWORD'] -notmatch 'CHANGE_ME') -Message 'Generated administrator password must be strong'
    Assert-True -Condition ($values['PROXY_ENABLED'] -eq 'true') -Message 'Generated .env must enable the shared proxy'
    Assert-True -Condition ($values['LITELLM_MASTER_KEY'] -match '^sk-[0-9a-f]{48}$') -Message 'Generated master key must be sk- plus 48 hex characters'
    $secrets = @('POSTGRES_PASSWORD', 'LITELLM_MASTER_KEY', 'LITELLM_SALT_KEY', 'WEBUI_SECRET_KEY', 'GRAFANA_ADMIN_PASSWORD', 'WEBUI_ADMIN_PASSWORD') | ForEach-Object { $values[$_] }
    Assert-True -Condition (@($secrets | Sort-Object -Unique).Count -eq $secrets.Count) -Message 'Every generated secret must be different'
    foreach ($kept in @('OPEN_WEBUI_IMAGE', 'DEFAULT_USER_ROLE', 'PROXY_BIND_ADDRESS', 'OLLAMA_MODEL')) {
        Assert-True -Condition ($values[$kept] -eq (Get-PocEnv -Path (Join-Path $repoRoot '.env.example'))[$kept]) -Message "Generated .env must keep the .env.example value of $kept"
    }
}
finally { Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue }

# --- host detection helpers
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
$listener.Start()
try {
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    Assert-True -Condition ((Get-ListeningPorts) -contains $port) -Message 'Get-ListeningPorts must see a port that is open'
}
finally { $listener.Stop() }
$address = Get-PrimaryIPv4
Assert-True -Condition ($address -eq '' -or $address -match '^\d{1,3}(\.\d{1,3}){3}$') -Message 'Get-PrimaryIPv4 must return an IPv4 address or nothing'

foreach ($os in @('windows', 'macos', 'linux')) {
    foreach ($item in @('docker', 'pwsh', 'ollama', 'firewall')) {
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace((Get-HostAdvice -HostOs $os -Item $item))) -Message "Missing $item advice for $os"
    }
}
Assert-True -Condition ((Get-HostAdvice -HostOs linux -Item firewall).Contains('nginx/local')) -Message 'Linux firewall advice must point to nginx/local (Docker bypasses ufw)'

# --- a failing step stops the chain, and a stale exit code does not fail a good step
$stopped = $false
try { Invoke-ProvisionStep 'failing step' { & pwsh -NoProfile -Command 'exit 3' } 6>$null }
catch { $stopped = $_.Exception.Message -match 'Step failed: failing step' }
Assert-True -Condition $stopped -Message 'A step whose command exits non-zero must stop provisioning'
$global:LASTEXITCODE = 7
$passed = $true
try { Invoke-ProvisionStep 'quiet step' { $null = 1 } 6>$null } catch { $passed = $false }
Assert-True -Condition $passed -Message 'A stale non-zero exit code must not fail a step that did nothing wrong'

# --- a new Open WebUI reachable from the network with no bootstrap administrator is refused
foreach ($case in @(
    @{ Email = ''; Password = ''; Volume = $false; Proxy = $true; Bind = '0.0.0.0'; Expected = $true; Label = 'new install, no admin, open bind' },
    @{ Email = 'a@b.c'; Password = ''; Volume = $false; Proxy = $true; Bind = '0.0.0.0'; Expected = $true; Label = 'email without password' },
    @{ Email = 'a@b.c'; Password = 'x'; Volume = $false; Proxy = $true; Bind = '0.0.0.0'; Expected = $false; Label = 'bootstrap admin set' },
    @{ Email = ''; Password = ''; Volume = $true; Proxy = $true; Bind = '0.0.0.0'; Expected = $false; Label = 'existing data volume' },
    @{ Email = ''; Password = ''; Volume = $false; Proxy = $true; Bind = '127.0.0.1'; Expected = $false; Label = 'loopback only' },
    @{ Email = ''; Password = ''; Volume = $false; Proxy = $false; Bind = '0.0.0.0'; Expected = $false; Label = 'proxy off' },
    @{ Email = ''; Password = ''; Volume = $false; Proxy = $true; Bind = '10.1.2.3'; Expected = $true; Label = 'one LAN interface' }
)) {
    $actual = Test-FreshOpenWebUiExposure -AdminEmail $case.Email -AdminPassword $case.Password -VolumeExists $case.Volume -ProxyEnabled $case.Proxy -BindAddress $case.Bind
    Assert-True -Condition ($actual -eq $case.Expected) -Message "Fresh Open WebUI exposure: $($case.Label) must be $($case.Expected)"
}

# --- the shell wrapper forwards arguments exactly (values with spaces and empty values included)
if ($null -ne (Get-Command sh -ErrorAction SilentlyContinue) -and [System.IO.Path]::DirectorySeparatorChar -eq '/') {
    $stub = Join-Path ([System.IO.Path]::GetTempPath()) ("pm-stub-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stub | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $stub 'pwsh') -Value "#!/bin/sh`nfor a in `"`$@`"; do printf '[%s]\n' `"`$a`"; done" -Encoding ASCII
        & chmod +x (Join-Path $stub 'pwsh')
        $savedPath = $env:PATH
        $env:PATH = "$stub$([System.IO.Path]::PathSeparator)$savedPath"
        try { $forwarded = @(& sh (Join-Path $repoRoot 'scripts/provision.sh') --AdminEmail 'o@e.com' --PublicHost 'my server' --CheckOnly -Profile cpu '') }
        finally { $env:PATH = $savedPath }
        $expectedArgs = @('[-NoProfile]', '[-File]', "[$(Join-Path $repoRoot 'scripts/provision.ps1')]", '[-AdminEmail]', '[o@e.com]', '[-PublicHost]', '[my server]', '[-CheckOnly]', '[-Profile]', '[cpu]', '[]')
        Assert-True -Condition (($forwarded -join '|') -eq ($expectedArgs -join '|')) -Message "provision.sh must forward arguments exactly (got: $($forwarded -join ' '))"
    }
    finally { Remove-Item -LiteralPath $stub -Recurse -Force -ErrorAction SilentlyContinue }
}
$attributes = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.gitattributes')
Assert-True -Condition $attributes.Contains('*.sh text eol=lf') -Message '.gitattributes must keep shell scripts on LF line endings'
foreach ($term in @('[switch] $EnableSignup', 'Test-FreshOpenWebUiExposure', '-KeepCustomBaseUrl')) {
    Assert-True -Condition $provision.Contains($term) -Message "provision.ps1 is missing: $term"
}

# --- the order of the steps, and the guards, are what prevents a wrong sequence
$order = @('check-prerequisites.ps1', 'setup.ps1', 'verify-stack.ps1', 'configure-open-webui.ps1', 'install-key-manager.ps1') | ForEach-Object { $provision.IndexOf("'$_'") }
Assert-True -Condition (@($order | Where-Object { $_ -lt 0 }).Count -eq 0) -Message 'provision.ps1 must run every step script'
Assert-True -Condition (($order -join ',') -eq (($order | Sort-Object) -join ',')) -Message 'provision.ps1 must run check-prerequisites, setup, verify-stack, configure-open-webui, then install-key-manager, in that order'
foreach ($term in @('[switch] $CheckOnly', 'Test-Path -LiteralPath $envPath -PathType Leaf', 'it is kept as it is', '$global:LASTEXITCODE = 0', "Throw 'Fix the failed checks") ) {
    Assert-True -Condition ($provision.ToLowerInvariant().Contains($term.ToLowerInvariant())) -Message "provision.ps1 is missing: $term"
}
$wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/provision.sh')
foreach ($term in @('command -v pwsh', 'exec pwsh -NoProfile -File', 'provision.ps1', '--*)')) {
    Assert-True -Condition $wrapper.Contains($term) -Message "provision.sh is missing: $term"
}
$configure = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/configure-open-webui.ps1')
foreach ($term in @('DEFAULT_USER_ROLE', 'TASK_MODEL_EXTERNAL', 'builtin_tools', "-split ','")) {
    Assert-True -Condition $configure.Contains($term) -Message "configure-open-webui.ps1 is missing: $term"
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" }
    throw "Provision contract failed with $($failures.Count) issue(s)."
}
Write-Host 'Provision contract passed.'
