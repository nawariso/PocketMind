$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/common.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if (($Actual -join '|') -ne ($Expected -join '|')) {
        $script:failures.Add("$Message (expected '$($Expected -join '|')', got '$($Actual -join '|')')")
    }
}

try {
    Assert-Equal -Actual (Resolve-PocProfile -RequestedProfile auto -HostOs macos -Architecture arm64 -DockerNvidiaAvailable $false) `
        -Expected 'native' -Message 'macOS auto profile must use native Ollama'
    Assert-Equal -Actual (Resolve-PocProfile -RequestedProfile auto -HostOs windows -Architecture amd64 -DockerNvidiaAvailable $true) `
        -Expected 'nvidia' -Message 'Windows auto profile must use a working NVIDIA runtime'
    Assert-Equal -Actual (Resolve-PocProfile -RequestedProfile auto -HostOs linux -Architecture arm64 -DockerNvidiaAvailable $false) `
        -Expected 'cpu' -Message 'Linux without NVIDIA must use CPU profile'
    Assert-Equal -Actual (Resolve-PocProfile -RequestedProfile cpu -HostOs windows -Architecture amd64 -DockerNvidiaAvailable $true) `
        -Expected 'cpu' -Message 'Explicit CPU profile must override NVIDIA detection'
    Assert-Equal -Actual (Resolve-PocProfile -RequestedProfile auto -NativeOllama -HostOs windows -Architecture amd64 -DockerNvidiaAvailable $true) `
        -Expected 'native' -Message 'NativeOllama compatibility switch must select native profile'

    $nvidiaRejected = $false
    try {
        Resolve-PocProfile -RequestedProfile nvidia -HostOs macos -Architecture arm64 -DockerNvidiaAvailable $false | Out-Null
    }
    catch {
        $nvidiaRejected = $true
    }
    Assert-Equal -Actual $nvidiaRejected -Expected $true -Message 'NVIDIA profile must be rejected on macOS arm64'

    Assert-Equal -Actual ((Get-PocComposeFiles -Profile cpu) | ForEach-Object { Split-Path -Leaf $_ }) `
        -Expected @('docker-compose.yml') -Message 'CPU Compose mapping is incorrect'
    Assert-Equal -Actual ((Get-PocComposeFiles -Profile nvidia) | ForEach-Object { Split-Path -Leaf $_ }) `
        -Expected @('docker-compose.yml', 'docker-compose.nvidia.yml') -Message 'NVIDIA Compose mapping is incorrect'
    Assert-Equal -Actual ((Get-PocComposeFiles -Profile native) | ForEach-Object { Split-Path -Leaf $_ }) `
        -Expected @('docker-compose.native-ollama.yml') -Message 'Native Compose mapping is incorrect'
}
catch {
    $failures.Add("Profile contract raised an unexpected error: $($_.Exception.Message)")
}

if ($failures.Count -gt 0) {
    Write-Host "Profile contract failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'Profile contract passed.' -ForegroundColor Green
