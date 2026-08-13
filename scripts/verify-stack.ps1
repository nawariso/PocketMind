param(
    [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto',
    [switch] $NativeOllama
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

try {
    $resolvedProfile = Resolve-PocProfile -RequestedProfile $Profile -NativeOllama:$NativeOllama
    $envValues = Get-PocEnv
    $requiredContainers = @(
        'pocketmind-postgres',
        'pocketmind-litellm',
        'pocketmind-open-webui',
        'pocketmind-prometheus',
        'pocketmind-grafana'
    )
    if ($resolvedProfile -eq 'cpu' -or $resolvedProfile -eq 'nvidia') {
        $requiredContainers = @('pocketmind-ollama') + $requiredContainers
    }
    if ($resolvedProfile -eq 'nvidia') { $requiredContainers = @('pocketmind-nvidia-exporter') + $requiredContainers }
    foreach ($container in $requiredContainers) {
        $state = Get-PocContainerState -ContainerName $container
        if ($null -eq $state -or $state.Status -ne 'running' -or ($state.Health -ne 'healthy' -and $state.Health -ne 'none')) {
            throw "$container is not healthy."
        }
        Write-Host "[ok] $container"
    }

    $databaseClient = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $databaseClient.BeginConnect('127.0.0.1', 5432, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(5000) -or -not $databaseClient.Connected) {
            throw 'PostgreSQL TCP port 127.0.0.1:5432 is not reachable.'
        }
        $databaseClient.EndConnect($connect)
    }
    finally {
        $databaseClient.Dispose()
    }
    $databaseSqlCheck = & docker exec pocketmind-postgres sh -c `
        'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -h 127.0.0.1 -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -tA -c select/**/1'
    if ($LASTEXITCODE -ne 0 -or ($databaseSqlCheck -join '').Trim() -ne '1') {
        throw 'PostgreSQL authentication failed inside the database service.'
    }
    Write-Host '[ok] PostgreSQL DBeaver path 127.0.0.1:5432'

    & (Join-Path $PSScriptRoot 'smoke-test.ps1') -Profile $resolvedProfile
    if ($LASTEXITCODE -ne 0) { throw 'Smoke test failed.' }

    Write-Host '[check] Open WebUI and service UIs'
    Wait-PocHttp -Uri 'http://localhost:3000/health' -TimeoutSeconds 60 | Out-Null
    Wait-PocHttp -Uri 'http://localhost:4000/ui/' -TimeoutSeconds 60 | Out-Null
    Wait-PocHttp -Uri 'http://localhost:9090/-/ready' -TimeoutSeconds 60 | Out-Null

    Write-Host '[check] Grafana health and provisioning APIs'
    $grafanaHealth = (Wait-PocHttp -Uri 'http://localhost:3001/api/health' -TimeoutSeconds 60).Content | ConvertFrom-Json
    if ($grafanaHealth.database -ne 'ok') { throw 'Grafana database health is not ok.' }

    $envValues = Get-PocEnv
    $grafanaPair = '{0}:{1}' -f $envValues['GRAFANA_ADMIN_USER'], $envValues['GRAFANA_ADMIN_PASSWORD']
    $grafanaToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($grafanaPair))
    $grafanaHeaders = @{ Authorization = "Basic $grafanaToken" }
    $datasource = (Wait-PocHttp -Uri 'http://localhost:3001/api/datasources/uid/prometheus' -Headers $grafanaHeaders -TimeoutSeconds 60).Content | ConvertFrom-Json
    if ($datasource.url -ne 'http://prometheus:9090') { throw 'Grafana Prometheus datasource is not provisioned correctly.' }
    $dashboard = (Wait-PocHttp -Uri 'http://localhost:3001/api/dashboards/uid/pocketmind-litellm' -Headers $grafanaHeaders -TimeoutSeconds 60).Content | ConvertFrom-Json
    if ($dashboard.dashboard.title -ne 'PocketMind - LiteLLM') { throw 'Grafana LiteLLM dashboard is not provisioned.' }
    $gpuDashboard = (Wait-PocHttp -Uri 'http://localhost:3001/api/dashboards/uid/pocketmind-gpu-engine' -Headers $grafanaHeaders -TimeoutSeconds 60).Content | ConvertFrom-Json
    if ($gpuDashboard.dashboard.title -ne 'Local LLM - GPU & Engine') {
        throw 'Grafana GPU and engine dashboard is not provisioned.'
    }
    $gpuDashboardRows = @($gpuDashboard.dashboard.panels | Where-Object { $_.type -eq 'row' })
    $gpuDashboardPanels = @($gpuDashboard.dashboard.panels | Where-Object { $_.type -ne 'row' })
    if ($gpuDashboardRows.Count -ne 2 -or $gpuDashboardPanels.Count -ne 12) {
        throw 'Grafana GPU and engine dashboard must contain two rows and twelve content panels.'
    }

    Write-Host '[check] Prometheus target and LiteLLM metrics APIs'
    $targets = (Wait-PocHttp -Uri 'http://localhost:9090/api/v1/targets' -TimeoutSeconds 60).Content | ConvertFrom-Json
    $liteLlmTargets = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq 'litellm' })
    if ($liteLlmTargets.Count -ne 1 -or $liteLlmTargets[0].health -ne 'up') {
        throw 'Prometheus LiteLLM target is not UP.'
    }
    if ($resolvedProfile -eq 'nvidia') {
        $nvidiaTargets = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq 'nvidia_gpu' })
        if ($nvidiaTargets.Count -ne 1 -or $nvidiaTargets[0].health -ne 'up') {
            throw 'Prometheus NVIDIA GPU target is not UP.'
        }

        $requiredGpuMetrics = @(
            'nvidia_smi_utilization_gpu_ratio',
            'nvidia_smi_memory_used_bytes',
            'nvidia_smi_memory_total_bytes',
            'nvidia_smi_power_draw_watts',
            'nvidia_smi_temperature_gpu',
            'nvidia_smi_clocks_current_graphics_clock_hz'
        )
        foreach ($metric in $requiredGpuMetrics) {
            $encodedMetric = [Uri]::EscapeDataString($metric)
            $queryUri = "http://localhost:9090/api/v1/query?query=$encodedMetric"
            $queryResult = (Wait-PocHttp -Uri $queryUri -TimeoutSeconds 60).Content | ConvertFrom-Json
            if ($queryResult.status -ne 'success' -or @($queryResult.data.result).Count -lt 1) {
                throw "NVIDIA GPU metric has no Prometheus samples: $metric"
            }
        }
    }
    else {
        $unexpectedNvidiaTargets = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq 'nvidia_gpu' })
        if ($unexpectedNvidiaTargets.Count -ne 0) {
            throw "Profile '$resolvedProfile' must not configure a Prometheus NVIDIA target."
        }
    }

    $metricsText = (Wait-PocHttp -Uri 'http://localhost:4000/metrics/' `
        -Headers (Get-PocBearerHeaders) -TimeoutSeconds 15).Content
    foreach ($metric in @(
        'litellm_proxy_total_requests_metric',
        'litellm_input_tokens_metric',
        'litellm_output_tokens_metric',
        'litellm_request_total_latency_metric'
    )) {
        if (-not $metricsText.Contains($metric)) { throw "LiteLLM metric is missing: $metric" }
    }

    $ollamaContainer = if ($resolvedProfile -eq 'native') { $null } else { 'pocketmind-ollama' }
    if ($resolvedProfile -eq 'native') {
        $modelList = & ollama list
        $processorList = & ollama ps
    }
    else {
        $modelList = & docker exec $ollamaContainer ollama list
        $processorList = & docker exec $ollamaContainer ollama ps
    }
    $expectedModel = $envValues['OLLAMA_MODEL']
    if ([string]::IsNullOrWhiteSpace($expectedModel)) { throw 'OLLAMA_MODEL is missing from .env.' }
    if (($modelList -join "`n") -notmatch [regex]::Escape($expectedModel)) {
        throw "Ollama model $expectedModel is not installed."
    }
    if ($resolvedProfile -eq 'nvidia' -and ($processorList -join "`n") -notmatch 'GPU') {
        throw 'Ollama does not report GPU placement after inference.'
    }

    Write-Host '[ok] Open WebUI health' -ForegroundColor Green
    Write-Host '[ok] Prometheus targets and monitoring metrics' -ForegroundColor Green
    Write-Host '[ok] Grafana datasource and dashboards' -ForegroundColor Green
    Write-Host "[ok] Ollama processor: $((($processorList | Select-Object -Skip 1) -join ' ').Trim())" -ForegroundColor Green
    Write-Host "Full stack verification passed for profile '$resolvedProfile'." -ForegroundColor Green
}
catch {
    Write-Error "Stack verification failed: $($_.Exception.Message)"
    exit 1
}
