$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

$scriptPath = Join-Path $repoRoot 'scripts/model-lab.ps1'
Assert-True -Condition (Test-Path -LiteralPath $scriptPath) -Message 'scripts/model-lab.ps1 is missing'
if (Test-Path -LiteralPath $scriptPath) {
    $scriptContent = Get-Content -Raw -LiteralPath $scriptPath
    foreach ($term in @(
        "ValidateSet('add', 'list', 'test', 'remove')",
        "'lab-'",
        '/model/new',
        '/model/delete',
        "@('pull', `$Model)",
        "@('show', `$Model)",
        "'corp-general'",
        "'corp-ocr'"
    )) {
        Assert-True -Condition ($scriptContent.Contains($term)) -Message "Model Lab script is missing safety/behavior term: $term"
    }
}

$config = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'litellm/config.yaml')
Assert-True -Condition ($config.Contains('store_model_in_db: true')) `
    -Message 'LiteLLM must persist Model Lab aliases in its database'

$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
foreach ($term in @(
    '## Model Lab: try another Ollama model without editing config',
    'pwsh ./scripts/model-lab.ps1 add',
    'pwsh ./scripts/model-lab.ps1 test',
    'pwsh ./scripts/model-lab.ps1 remove',
    'lab-'
)) {
    Assert-True -Condition ($readme.Contains($term)) -Message "README is missing Model Lab guidance: $term"
}

$verifyScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/verify-stack.ps1')
Assert-True -Condition ($verifyScript.Contains("`$envValues['OLLAMA_MODEL']")) `
    -Message 'Stack verifier must read the configured OLLAMA_MODEL instead of a stale hard-coded model'
Assert-True -Condition (-not $verifyScript.Contains('llama3\.2:3b')) `
    -Message 'Stack verifier must not retain the old hard-coded Llama model'

if ($failures.Count -gt 0) {
    Write-Host "Model Lab contract failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'Model Lab contract passed.' -ForegroundColor Green
