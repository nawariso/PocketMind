param(
    [string] $Alias = 'local-poc-app',
    [string] $Duration = '30d'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $body = @{
        key_alias = $Alias
        duration = $Duration
        models = @('corp-general')
        metadata = @{ purpose = 'pocketmind' }
    } | ConvertTo-Json -Depth 8
    $result = Invoke-RestMethod -Uri 'http://localhost:4000/key/generate' -Method Post `
        -Headers (Get-PocBearerHeaders) -ContentType 'application/json' -Body $body -TimeoutSec 30
    if ([string]::IsNullOrWhiteSpace([string]$result.key)) {
        throw 'LiteLLM did not return a virtual key.'
    }
    Write-Host "Virtual key created for corp-general (alias=$Alias, duration=$Duration):" -ForegroundColor Green
    Write-Output $result.key
}
catch {
    Write-Error "Virtual key creation failed: $($_.Exception.Message)"
    exit 1
}
