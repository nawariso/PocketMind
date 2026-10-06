$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

$requiredDocs = @(
    'docs/README.md',
    'docs/architecture.md',
    'docs/operations-runbook.md',
    'docs/security.md',
    'docs/backup-and-restore.md',
    'docs/troubleshooting.md',
    'docs/models/catalog.md',
    'docs/models/evaluation-guide.md',
    'docs/models/benchmark-log.md',
    'docs/decisions/0001-stable-model-aliases.md',
    'docs/decisions/0002-typhoon-for-ocr.md',
    'docs/decisions/0003-database-backed-model-lab.md',
    'docs/decisions/0004-self-service-virtual-keys.md'
)
foreach ($relativePath in $requiredDocs) {
    $path = Join-Path $repoRoot $relativePath
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "Required knowledge document is missing: $relativePath"
}

$mainReadme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
Assert-True -Condition ($mainReadme.Contains('[Documentation index](docs/README.md)')) `
    -Message 'README must link to the authoritative documentation index'

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/README.md')) {
    $index = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/README.md')
    foreach ($term in @(
        'Authoritative current-state documentation',
        'Historical implementation plans',
        'operations-runbook.md',
        'models/catalog.md',
        'security.md',
        'backup-and-restore.md',
        'troubleshooting.md',
        'decisions/'
    )) {
        Assert-True -Condition ($index.Contains($term)) -Message "Documentation index is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/operations-runbook.md')) {
    $runbook = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/operations-runbook.md')
    foreach ($term in @(
        'pwsh ./scripts/setup.ps1 -Profile auto',
        'pwsh ./scripts/verify-stack.ps1 -Profile auto',
        'docker exec pocketmind-ollama ollama ps',
        'Emergency shutdown',
        'Do not delete named volumes',
        'OLLAMA_CONTEXT_LENGTH=8192',
        'node_exporter',
        'Rotate the LiteLLM master key',
        'Task Model',
        'install-key-manager.ps1',
        'usage-report.ps1'
    )) {
        Assert-True -Condition ($runbook.Contains($term)) -Message "Operations runbook is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/troubleshooting.md')) {
    $troubleshooting = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/troubleshooting.md')
    foreach ($term in @(
        'one character per line',
        'Task Model',
        'Invalid proxy server token',
        'continuous-YlOrRd',
        'Host dashboard has no data',
        'host.docker.internal:11434',
        'API Key Manager problems'
    )) {
        Assert-True -Condition ($troubleshooting.Contains($term)) -Message "Troubleshooting guide is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/architecture.md')) {
    $architecture = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/architecture.md')
    foreach ($term in @('node_exporter', 'API Key Manager', 'prometheus.native.yml', 'Local LLM - Host (macOS & CPU)')) {
        Assert-True -Condition ($architecture.Contains($term)) -Message "Architecture document is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'README.md')) {
    $readme = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
    foreach ($term in @('usage-report.ps1', 'install-key-manager.ps1', 'Task Model', 'OLLAMA_CONTEXT_LENGTH=8192')) {
        Assert-True -Condition ($readme.Contains($term)) -Message "README is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/models/catalog.md')) {
    $catalog = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/models/catalog.md')
    foreach ($term in @(
        'qwen3:4b-instruct-2507-q4_K_M',
        'scb10x/typhoon-ocr1.5-3b',
        'builtin_tools=false',
        'gemma4:12b',
        'Removed'
    )) {
        Assert-True -Condition ($catalog.Contains($term)) -Message "Model catalog is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/security.md')) {
    $security = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/security.md')
    foreach ($term in @('localhost-only', 'LITELLM_MASTER_KEY', 'Virtual Key', 'Quick Tunnel', 'Model Lab', 'OAUTH_ALLOWED_DOMAINS', 'does not verify')) {
        Assert-True -Condition ($security.Contains($term)) -Message "Security document is missing: $term"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot 'docs/backup-and-restore.md')) {
    $backup = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docs/backup-and-restore.md')
    foreach ($term in @('pg_dump', 'pg_restore', 'openwebui_data', 'Restore is destructive', '.env', 'API Key Manager')) {
        Assert-True -Condition ($backup.Contains($term)) -Message "Backup document is missing: $term"
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Documentation knowledge-base contract failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host 'Documentation knowledge-base contract passed.' -ForegroundColor Green
