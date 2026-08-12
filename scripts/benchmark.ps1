param(
    [ValidateRange(1, 100)] [int] $Runs = 5,
    [ValidateRange(8, 512)] [int] $MaxTokens = 64
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $headers = Get-PocBearerHeaders
    $body = @{
        model = 'corp-general'
        messages = @(@{ role = 'user'; content = 'Briefly explain why local AI inference is useful.' })
        max_tokens = $MaxTokens
        temperature = 0
    } | ConvertTo-Json -Depth 8

    Write-Host 'Warming the model...'
    Invoke-RestMethod -Uri 'http://localhost:4000/v1/chat/completions' -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 180 | Out-Null

    $samples = @()
    for ($run = 1; $run -le $Runs; $run++) {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Uri 'http://localhost:4000/v1/chat/completions' -Method Post `
            -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 180
        $timer.Stop()
        $tokens = [int]$response.usage.completion_tokens
        $seconds = [Math]::Max($timer.Elapsed.TotalSeconds, 0.001)
        $samples += [pscustomobject]@{
            Run = $run
            Seconds = [Math]::Round($seconds, 2)
            OutputTokens = $tokens
            TokensPerSecond = [Math]::Round($tokens / $seconds, 2)
        }
    }

    $samples | Format-Table -AutoSize
    $averageLatency = [Math]::Round(($samples | Measure-Object Seconds -Average).Average, 2)
    $averageRate = [Math]::Round(($samples | Measure-Object TokensPerSecond -Average).Average, 2)
    Write-Host "Average latency: $averageLatency s; average output rate: $averageRate tokens/s" -ForegroundColor Green
}
catch {
    Write-Error "Benchmark failed: $($_.Exception.Message)"
    exit 1
}
