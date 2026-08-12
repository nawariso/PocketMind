param(
    [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto',
    [switch] $NativeOllama
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $resolvedProfile = Resolve-PocProfile -RequestedProfile $Profile -NativeOllama:$NativeOllama
    $hostOs = Get-PocHostOs
    $architecture = Get-PocArchitecture
    Assert-PocSecretsConfigured

    Assert-PocCommand -Name 'docker'
    & docker version --format '{{.Server.Version}}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop engine is not available.' }
    & docker compose version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose is not available.' }

    foreach ($file in @(
        'litellm/config.yaml',
        'prometheus/prometheus.yml',
        'grafana/provisioning/datasources/prometheus.yml',
        'grafana/provisioning/dashboards/dashboard.yml',
        'grafana/dashboards/litellm-overview.json',
        'grafana/dashboards/gpu-engine-overview.json'
    )) {
        Assert-PocFile -RelativePath $file
    }

    if ($resolvedProfile -eq 'native') {
        Assert-PocCommand -Name 'ollama'
        $ollamaStatus = Invoke-PocHttpStatus -Uri 'http://localhost:11434/api/tags' -TimeoutSeconds 5
        if ($ollamaStatus -ne 200) {
            throw 'Native Ollama is not responding at http://localhost:11434.'
        }

        $envValues = Get-PocEnv
        $litellmImage = $envValues['LITELLM_IMAGE']
        $probe = & docker run --rm --pull missing `
            --add-host 'host.docker.internal:host-gateway' `
            --entrypoint python $litellmImage `
            -c "import urllib.request; urllib.request.urlopen('http://host.docker.internal:11434/api/tags', timeout=5)" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Native Ollama is healthy on localhost but containers cannot reach host.docker.internal:11434. Configure Ollama for Docker host access without exposing it to the LAN. Probe: $($probe -join ' ')"
        }
    }
    elseif ($resolvedProfile -eq 'nvidia') {
        Assert-PocCommand -Name 'nvidia-smi'
        & nvidia-smi --query-gpu=name --format=csv,noheader | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "NVIDIA GPU is not available to $hostOs." }
        if (-not (Test-PocDockerNvidia)) {
            throw "Docker cannot access the NVIDIA GPU. $script:PocNvidiaProbeDiagnostic"
        }
    }

    Invoke-PocCompose -Profile $resolvedProfile -Arguments @('config', '--quiet')
    Write-Host "Prerequisite checks passed: os=$hostOs, arch=$architecture, profile=$resolvedProfile" -ForegroundColor Green
}
catch {
    Write-Error "Prerequisite check failed: $($_.Exception.Message)"
    exit 1
}
