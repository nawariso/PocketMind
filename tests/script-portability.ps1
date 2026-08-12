$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

$scriptFiles = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') -Filter '*.ps1'
foreach ($scriptFile in $scriptFiles) {
    $content = Get-Content -Raw -LiteralPath $scriptFile.FullName
    Assert-True -Condition ($content -notmatch '(?i)curl\.exe') `
        -Message "$($scriptFile.Name) uses Windows-only curl.exe"
    Assert-True -Condition ($content -notmatch '(?i)--output\s+NUL') `
        -Message "$($scriptFile.Name) uses the Windows-only NUL device"
    if ($scriptFile.Name -ne 'common.ps1') {
        Assert-True -Condition ($content -notmatch 'docker-compose(?:\.native-ollama|\.nvidia)?\.yml') `
            -Message "$($scriptFile.Name) selects a Compose file outside common.ps1"
    }
}

$readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
foreach ($term in @(
    'Windows 11',
    'macOS',
    'Ubuntu',
    '-Profile auto',
    '-Profile nvidia',
    '-Profile native',
    '-Profile cpu'
)) {
    Assert-True -Condition ($readme.Contains($term)) -Message "README is missing portability guidance: $term"
}

foreach ($term in @(
    '```mermaid',
    'flowchart LR',
    'pwsh ./scripts/setup.ps1 -Profile auto -Pull',
    'powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Profile auto -Pull',
    'recommended end-to-end validation; it is not required to start the stack'
)) {
    Assert-True -Condition ($readme.Contains($term)) -Message "README is missing one-command setup guidance: $term"
}
Assert-True -Condition ($readme -notmatch 'Browser -> Open WebUI') `
    -Message 'README still contains the old ASCII architecture diagram'

if ($failures.Count -gt 0) {
    Write-Host "Script portability contract failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'Script portability contract passed.' -ForegroundColor Green
