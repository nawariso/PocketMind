param(
    [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto',
    [switch] $NativeOllama,
    [switch] $Pull
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $resolvedProfile = Resolve-PocProfile -RequestedProfile $Profile -NativeOllama:$NativeOllama
    & (Join-Path $PSScriptRoot 'check-prerequisites.ps1') -Profile $resolvedProfile
    if ($LASTEXITCODE -ne 0) { throw 'Prerequisite checks failed.' }

    $envValues = Get-PocEnv

    if ($resolvedProfile -eq 'native') {
        $modelName = $envValues['OLLAMA_MODEL']
        $modelList = (& ollama list) -join "`n"
        if ($modelList -notmatch [regex]::Escape($modelName)) {
            if (-not $Pull) {
                throw "Native Ollama model '$modelName' is missing. Run: ollama pull $modelName (or rerun setup with -Pull)."
            }
            & ollama pull $modelName
            if ($LASTEXITCODE -ne 0) { throw "Failed to pull native Ollama model: $modelName" }
        }
    }

    if ($Pull) {
        Invoke-PocCompose -Profile $resolvedProfile -Arguments @('pull')
    }
    Invoke-PocCompose -Profile $resolvedProfile -Arguments @('up', '-d', '--remove-orphans')

    $containers = @(
        'pocketmind-postgres',
        'pocketmind-litellm',
        'pocketmind-open-webui',
        'pocketmind-prometheus',
        'pocketmind-grafana'
    )
    if ($resolvedProfile -eq 'cpu' -or $resolvedProfile -eq 'nvidia') {
        $containers = @('pocketmind-ollama') + $containers
    }
    if ($resolvedProfile -eq 'nvidia') { $containers = @('pocketmind-nvidia-exporter') + $containers }

    foreach ($container in $containers) {
        Wait-PocContainerHealthy -ContainerName $container -TimeoutSeconds 360
    }

    Write-Host "Local LLM stack is running with profile '$resolvedProfile'." -ForegroundColor Green
    Write-Host 'Open WebUI: http://localhost:3000'
    Write-Host 'LiteLLM:    http://localhost:4000/ui/'
    Write-Host 'Prometheus: http://localhost:9090'
    Write-Host 'Grafana:    http://localhost:3001'
}
catch {
    Write-Error "Setup failed: $($_.Exception.Message)"
    exit 1
}
