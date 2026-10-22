$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/common.ps1')

$oldPrivacy = $env:PRIVACY_MODE
$oldProxy = $env:PROXY_ENABLED
try {
    $env:PRIVACY_MODE = 'true'
    $env:PROXY_ENABLED = 'true'
    if (-not (Test-PocPrivacyEnabled)) { throw 'Privacy switch was not detected.' }
    if ((Split-Path -Leaf (Get-PocPrivacyComposeFile -Profile nvidia)) -ne 'docker-compose.privacy.yml') {
        throw 'Privacy overlay was not selected.'
    }
    $rejected = $false
    try { Get-PocPrivacyComposeFile -Profile native | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Native Ollama must not claim Docker isolation.' }
    $env:PROXY_ENABLED = 'false'
    $rejected = $false
    try { Get-PocPrivacyComposeFile -Profile cpu | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Missing ingress proxy was accepted.' }
    $env:PROXY_ENABLED = 'true'
    function docker {
        $script:dockerArgs = @($args)
        $global:LASTEXITCODE = 0
    }
    Invoke-PocCompose -Profile nvidia -Arguments @('config', '--quiet')
    $privacyIndex = [Array]::IndexOf($script:dockerArgs, (Get-PocPrivacyComposeFile -Profile nvidia))
    $proxyIndex = [Array]::IndexOf($script:dockerArgs, (Get-PocProxyComposeFile))
    if ($privacyIndex -le $proxyIndex) { throw 'Privacy overlay must follow the proxy overlay.' }
    $env:PRIVACY_MODE = 'false'
    Invoke-PocCompose -Profile cpu -Arguments @('config', '--quiet')
    if (($script:dockerArgs -join ' ') -match 'docker-compose.privacy.yml') { throw 'Privacy cannot be silently enabled during bootstrap.' }
    Write-Host 'Privacy script contract passed.'
}
finally {
    $env:PRIVACY_MODE = $oldPrivacy
    $env:PROXY_ENABLED = $oldProxy
}
