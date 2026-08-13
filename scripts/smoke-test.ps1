param(
    [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto',
    [switch] $NativeOllama
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $headers = Get-PocBearerHeaders
    Wait-PocHttp -Uri 'http://localhost:4000/health/liveliness' | Out-Null
    Wait-PocHttp -Uri 'http://localhost:4000/health/readiness' | Out-Null

    $models = Invoke-RestMethod -Uri 'http://localhost:4000/v1/models' -Headers $headers -TimeoutSec 15
    if (@($models.data.id) -notcontains 'corp-general') {
        throw "LiteLLM does not expose model alias 'corp-general'."
    }
    if (@($models.data.id) -notcontains 'corp-ocr') {
        throw "LiteLLM does not expose OCR model alias 'corp-ocr'."
    }

    $body = @{
        model = 'corp-general'
        messages = @(@{ role = 'user'; content = 'Reply with exactly: POC_OK' })
        max_tokens = 16
        temperature = 0
    } | ConvertTo-Json -Depth 8
    $completion = Invoke-RestMethod -Uri 'http://localhost:4000/v1/chat/completions' -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 120
    $text = [string]$completion.choices[0].message.content
    if ($text.Trim() -ne 'POC_OK') {
        throw "Unexpected inference response: $text"
    }

    $badStatus = Invoke-PocHttpStatus -Uri 'http://localhost:4000/v1/models' `
        -Headers @{ Authorization = 'Bearer sk-invalid-local-poc-key' } -TimeoutSeconds 15
    if ($badStatus -ne 401) {
        throw "Invalid API key was not rejected with HTTP 401 (received $badStatus)."
    }

    Write-Host "Smoke test passed: alias=corp-general, response=$($text.Trim()), invalid-key=401" -ForegroundColor Green
}
catch {
    Write-Error "Smoke test failed: $($_.Exception.Message)"
    exit 1
}
