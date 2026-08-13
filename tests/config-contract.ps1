$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Assert-RequiredFile {
    param([Parameter(Mandatory)] [string] $RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) `
        -Message "Required file is missing or is not a file: $RelativePath"
}

$requiredFiles = @(
    'docker-compose.nvidia.yml',
    'litellm/config.yaml',
    'prometheus/prometheus.yml',
    'prometheus/prometheus.nvidia.yml',
    'grafana/provisioning/datasources/prometheus.yml',
    'grafana/provisioning/dashboards/dashboard.yml',
    'grafana/dashboards/litellm-overview.json',
    'grafana/dashboards/gpu-engine-overview.json',
    'scripts/common.ps1',
    'scripts/check-prerequisites.ps1',
    'scripts/setup.ps1',
    'scripts/smoke-test.ps1',
    'scripts/create-virtual-key.ps1',
    'scripts/benchmark.ps1',
    'scripts/verify-stack.ps1',
    'tests/profile-contract.ps1',
    'tests/script-portability.ps1',
    'tests/image-manifest.ps1',
    '.github/workflows/portability-contract.yml'
)

foreach ($relativePath in $requiredFiles) {
    Assert-RequiredFile -RelativePath $relativePath
}

function Test-ComposeContract {
    param(
        [Parameter(Mandatory)] [string[]] $ComposeFiles,
        [Parameter(Mandatory)] [string[]] $ExpectedServices,
        [string[]] $ForbiddenServices = @(),
        [switch] $RequireNvidiaExporter,
        [switch] $RequireNvidiaPrometheusConfig,
        [switch] $RejectDeviceReservations,
        [switch] $RequireNativeOllama
    )

    $composeArguments = @('compose')
    foreach ($composeFile in $ComposeFiles) { $composeArguments += @('-f', $composeFile) }
    $composeArguments += @('config', '--format', 'json')
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rendered = & docker @composeArguments 2>&1
        $composeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($composeExitCode -ne 0) {
        $script:failures.Add("Compose rendering failed for $($ComposeFiles -join ', ')`: $($rendered -join [Environment]::NewLine)")
        return
    }

    $composeLabel = $ComposeFiles -join ' + '
    $config = ($rendered -join [Environment]::NewLine) | ConvertFrom-Json
    foreach ($serviceName in $ExpectedServices) {
        Assert-True -Condition ($null -ne $config.services.PSObject.Properties[$serviceName]) `
            -Message "$composeLabel does not define service '$serviceName'"
    }
    foreach ($serviceName in $ForbiddenServices) {
        Assert-True -Condition ($null -eq $config.services.PSObject.Properties[$serviceName]) `
            -Message "$composeLabel must not define service '$serviceName'"
    }

    foreach ($serviceProperty in $config.services.PSObject.Properties) {
        $service = $serviceProperty.Value
        if ($RejectDeviceReservations) {
            $deployProperty = $service.PSObject.Properties['deploy']
            if ($null -ne $deployProperty) {
                $deployJson = $deployProperty.Value | ConvertTo-Json -Depth 20 -Compress
                Assert-True -Condition ($deployJson -notmatch 'devices') `
                    -Message "$composeLabel service '$($serviceProperty.Name)' must not reserve GPU devices"
            }
        }
        $portsProperty = $service.PSObject.Properties['ports']
        if ($null -eq $portsProperty) { continue }
        foreach ($port in @($portsProperty.Value)) {
            if ($null -eq $port) { continue }
            $hostIpProperty = $port.PSObject.Properties['host_ip']
            $publishedProperty = $port.PSObject.Properties['published']
            $publishedPort = if ($null -eq $publishedProperty) { '<unknown>' } else { $publishedProperty.Value }
            Assert-True -Condition ($null -ne $hostIpProperty -and $hostIpProperty.Value -eq '127.0.0.1') `
                -Message "$composeLabel service '$($serviceProperty.Name)' publishes port $publishedPort outside 127.0.0.1"
        }
    }

    $postgresPortsProperty = $config.services.postgres.PSObject.Properties['ports']
    $dbeaverPort = @()
    if ($null -ne $postgresPortsProperty) {
        $dbeaverPort = @($postgresPortsProperty.Value | Where-Object {
            $_.PSObject.Properties['target'].Value -eq 5432 -and
            $_.PSObject.Properties['published'].Value -eq '5432' -and
            $_.PSObject.Properties['host_ip'].Value -eq '127.0.0.1'
        })
    }
    Assert-True -Condition ($dbeaverPort.Count -eq 1) `
        -Message "$composeLabel must publish PostgreSQL exactly as 127.0.0.1:5432:5432 for DBeaver"

    if ($RequireNvidiaExporter) {
        $exporterProperty = $config.services.PSObject.Properties['nvidia-exporter']
        $exporter = if ($null -eq $exporterProperty) { $null } else { $exporterProperty.Value }
        Assert-True -Condition ($null -ne $exporter) `
            -Message "$composeLabel does not define service 'nvidia-exporter'"
        if ($null -ne $exporter) {
            Assert-True -Condition ($null -eq $exporter.PSObject.Properties['ports']) `
                -Message "$composeLabel must not publish the NVIDIA exporter port"
            Assert-True -Condition (($exporter.command -join ' ') -match '--collect\.backend=nvml') `
                -Message "$composeLabel must use the NVIDIA exporter NVML backend"
            Assert-True -Condition (($exporter.command -join ' ') -match '--collect\.interval=5s') `
                -Message "$composeLabel must collect NVIDIA metrics every 5 seconds"
        }
    }

    if ($RequireNvidiaPrometheusConfig) {
        $prometheusVolumes = @($config.services.prometheus.volumes)
        $configMounts = @($prometheusVolumes | Where-Object {
            $_.target -eq '/etc/prometheus/prometheus.yml'
        })
        Assert-True -Condition ($configMounts.Count -eq 1) `
            -Message "$composeLabel must render exactly one Prometheus configuration mount"
        if ($configMounts.Count -eq 1) {
            Assert-True -Condition ($configMounts[0].source -match 'prometheus[\\/]prometheus\.nvidia\.yml$') `
                -Message "$composeLabel must render prometheus.nvidia.yml as the Prometheus configuration"
        }
    }

    if ($RequireNativeOllama) {
        $litellm = $config.services.litellm
        Assert-True -Condition ($litellm.environment.OLLAMA_API_BASE -eq 'http://host.docker.internal:11434') `
            -Message "$composeLabel must point LiteLLM to host.docker.internal:11434"
        $extraHostsProperty = $litellm.PSObject.Properties['extra_hosts']
        $extraHosts = if ($null -eq $extraHostsProperty) { @() } else { @($extraHostsProperty.Value) }
        Assert-True -Condition ($extraHosts -contains 'host.docker.internal=host-gateway') `
            -Message "$composeLabel must define host.docker.internal:host-gateway"
    }
}

function Test-MonitoringContract {
    $prometheusConfig = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'prometheus/prometheus.yml')
    Assert-True -Condition ($prometheusConfig -match 'job_name: litellm') `
        -Message 'Base Prometheus configuration must scrape LiteLLM'
    Assert-True -Condition ($prometheusConfig -notmatch 'nvidia_gpu|nvidia-exporter:9835') `
        -Message 'Base Prometheus configuration must not scrape NVIDIA metrics'

    $nvidiaPrometheusPath = Join-Path $repoRoot 'prometheus/prometheus.nvidia.yml'
    if (Test-Path -LiteralPath $nvidiaPrometheusPath -PathType Leaf) {
        $nvidiaPrometheus = Get-Content -Raw -LiteralPath $nvidiaPrometheusPath
        Assert-True -Condition ($nvidiaPrometheus -match 'job_name: litellm') `
            -Message 'NVIDIA Prometheus configuration must scrape LiteLLM'
        Assert-True -Condition ($nvidiaPrometheus -match '(?ms)- job_name: nvidia_gpu\s+scrape_interval: 5s\s+scrape_timeout: 4s.*?- nvidia-exporter:9835') `
            -Message 'NVIDIA Prometheus configuration must scrape nvidia-exporter:9835 every 5 seconds'
        Assert-True -Condition (([regex]::Matches($nvidiaPrometheus, 'nvidia-exporter:9835')).Count -eq 1) `
            -Message 'NVIDIA Prometheus configuration must contain exactly one exporter target'
    }

    $dashboardPath = Join-Path $repoRoot 'grafana/dashboards/gpu-engine-overview.json'
    if (-not (Test-Path -LiteralPath $dashboardPath -PathType Leaf)) { return }

    $dashboard = Get-Content -Raw -LiteralPath $dashboardPath | ConvertFrom-Json
    $rowTitles = @($dashboard.panels | Where-Object { $_.type -eq 'row' } | ForEach-Object { $_.title })
    $contentPanels = @($dashboard.panels | Where-Object { $_.type -ne 'row' })
    $panelTitles = @($contentPanels | ForEach-Object { $_.title })
    $expressions = @(
        $contentPanels |
            ForEach-Object {
                $targetsProperty = $_.PSObject.Properties['targets']
                if ($null -ne $targetsProperty) { @($targetsProperty.Value) }
            } |
            Where-Object { $null -ne $_ -and $null -ne $_.expr } |
            ForEach-Object { $_.expr }
    )

    Assert-True -Condition ($dashboard.uid -eq 'pocketmind-gpu-engine') `
        -Message 'GPU dashboard UID is incorrect'
    Assert-True -Condition ($dashboard.title -eq 'Local LLM - GPU & Engine') `
        -Message 'GPU dashboard title is incorrect'
    Assert-True -Condition ($dashboard.refresh -eq '5s') `
        -Message 'GPU dashboard refresh must be 5s'
    Assert-True -Condition (($rowTitles -join '|') -eq 'GPU Hardware (nvidia-smi)|Ollama / LiteLLM Engine') `
        -Message 'GPU dashboard rows are incorrect'
    Assert-True -Condition ($contentPanels.Count -eq 12) `
        -Message 'GPU dashboard must contain twelve content panels'

    $requiredPanelTitles = @(
        'GPU SM Utilization',
        'VRAM Used / Total',
        'Power Draw',
        'GPU Temperature',
        'Graphics Clock',
        'Fan Speed',
        'KV Cache Usage',
        'Requests Running / Waiting',
        'Throughput (tokens/s)',
        'Prefix Cache Hit Rate',
        'Time to First Token',
        'Inter-token Latency'
    )
    foreach ($panelTitle in $requiredPanelTitles) {
        Assert-True -Condition ($panelTitles -contains $panelTitle) `
            -Message "GPU dashboard panel is missing: $panelTitle"
    }

    $requiredExpressions = @(
        'nvidia_smi_utilization_gpu_ratio',
        'nvidia_smi_memory_used_bytes',
        'nvidia_smi_memory_total_bytes',
        'nvidia_smi_power_draw_watts',
        'nvidia_smi_temperature_gpu',
        'nvidia_smi_clocks_current_graphics_clock_hz',
        'nvidia_smi_fan_speed_ratio',
        'sum(litellm_in_flight_requests)',
        'sum(rate(litellm_input_tokens_metric_total[1m]))',
        'sum(rate(litellm_output_tokens_metric_total[1m]))',
        'histogram_quantile(0.50, sum by (le) (rate(litellm_llm_api_time_to_first_token_metric_bucket[5m])))',
        'histogram_quantile(0.95, sum by (le) (rate(litellm_llm_api_time_to_first_token_metric_bucket[5m])))',
        'histogram_quantile(0.50, sum by (le) (rate(litellm_deployment_latency_per_output_token_bucket[5m])))',
        'histogram_quantile(0.95, sum by (le) (rate(litellm_deployment_latency_per_output_token_bucket[5m])))'
    )
    foreach ($expression in $requiredExpressions) {
        Assert-True -Condition ($expressions -contains $expression) `
            -Message "GPU dashboard PromQL expression is missing: $expression"
    }

    $textContent = ($contentPanels | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.options.content }) -join "`n"
    Assert-True -Condition ($textContent -match 'KV-cache usage gauge') `
        -Message 'KV Cache panel must explain why the metric is unavailable'
    Assert-True -Condition ($textContent -match 'cache hit and query counters') `
        -Message 'Prefix Cache panel must explain why the metric is unavailable'
}

function Test-VerificationScriptContract {
    $verificationPath = Join-Path $repoRoot 'scripts/verify-stack.ps1'
    $verificationScript = Get-Content -Raw -LiteralPath $verificationPath
    $requiredVerificationTerms = @(
        'pocketmind-nvidia-exporter',
        'pocketmind-gpu-engine',
        'nvidia_gpu',
        'nvidia_smi_utilization_gpu_ratio',
        'nvidia_smi_memory_used_bytes',
        'nvidia_smi_memory_total_bytes',
        'nvidia_smi_power_draw_watts',
        'nvidia_smi_temperature_gpu',
        'nvidia_smi_clocks_current_graphics_clock_hz'
    )
    foreach ($term in $requiredVerificationTerms) {
        Assert-True -Condition ($verificationScript.Contains($term)) `
            -Message "Runtime verifier does not check required monitoring term: $term"
    }
}

function Test-PrometheusTokenConfigContract {
    foreach ($composePath in @('docker-compose.yml', 'docker-compose.native-ollama.yml')) {
        $composeContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $composePath)
        Assert-True -Condition ($composeContent.Contains('content: ${LITELLM_MASTER_KEY}')) `
            -Message "$composePath must create the Prometheus token from LITELLM_MASTER_KEY at runtime"
        Assert-True -Condition (-not $composeContent.Contains('./prometheus/litellm_token')) `
            -Message "$composePath must not require a host token file on a fresh clone"
    }
}

function Test-OcrModelContract {
    $litellmConfig = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'litellm/config.yaml')
    Assert-True -Condition ($litellmConfig.Contains('model_name: corp-ocr')) `
        -Message 'LiteLLM must expose the corp-ocr alias'
    Assert-True -Condition ($litellmConfig.Contains('model: ollama_chat/scb10x/typhoon-ocr1.5-3b')) `
        -Message 'corp-ocr must route to the official Typhoon OCR Ollama build'
    Assert-True -Condition ($litellmConfig.Contains('supports_vision: true')) `
        -Message 'corp-ocr must advertise vision capability'
    Assert-True -Condition (-not $litellmConfig.Contains('gemma4:12b')) `
        -Message 'LiteLLM must not retain the replaced Gemma 4 model'

    $composeContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docker-compose.yml')
    Assert-True -Condition ($composeContent.Contains('OLLAMA_OCR_MODEL: ${OLLAMA_OCR_MODEL:-scb10x/typhoon-ocr1.5-3b}')) `
        -Message 'Container Ollama setup must define the official Typhoon OCR model'
    Assert-True -Condition ($composeContent.Contains('ollama pull $${OLLAMA_OCR_MODEL}')) `
        -Message 'Container Ollama setup must pull the configured OCR model'
    Assert-True -Condition (-not $composeContent.Contains('OLLAMA_VISION_MODEL')) `
        -Message 'Container setup must not retain the replaced generic vision-model setting'

    $envExample = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.env.example')
    Assert-True -Condition ($envExample.Contains('OLLAMA_OCR_MODEL=scb10x/typhoon-ocr1.5-3b')) `
        -Message '.env.example must document the official Typhoon OCR Ollama build'
    Assert-True -Condition ($envExample.Contains('OLLAMA_CONTEXT_LENGTH=8192')) `
        -Message '.env.example must provide enough context for OCR image prompts'

    Assert-True -Condition ($composeContent.Contains('OLLAMA_CONTEXT_LENGTH: ${OLLAMA_CONTEXT_LENGTH:-8192}')) `
        -Message 'Container Ollama must default to at least 8192 context tokens for image prompts'

    $readmeContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'README.md')
    Assert-True -Condition ($readmeContent.Contains('Built-in Tools: Off')) `
        -Message 'README must require Built-in Tools to be disabled for the OCR-only model'
}

function Test-SecretPlaceholderGuardContract {
    $commonScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/common.ps1')
    $prerequisiteScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/check-prerequisites.ps1')
    Assert-True -Condition ($commonScript.Contains('function Assert-PocSecretsConfigured')) `
        -Message 'Common helpers must define the secret-placeholder guard'
    Assert-True -Condition ($commonScript.Contains("-match '^CHANGE_ME(?:_|$)'")) `
        -Message 'Secret-placeholder guard must reject CHANGE_ME values'
    Assert-True -Condition ($prerequisiteScript.Contains('Assert-PocSecretsConfigured')) `
        -Message 'Prerequisite checks must reject unchanged secret placeholders'
}

Push-Location $repoRoot
try {
    Test-ComposeContract -ComposeFiles @('docker-compose.yml') `
        -ExpectedServices @('postgres', 'ollama', 'model-init', 'litellm', 'open-webui', 'prometheus', 'grafana') `
        -ForbiddenServices @('nvidia-exporter') -RejectDeviceReservations
    Test-ComposeContract -ComposeFiles @('docker-compose.yml', 'docker-compose.nvidia.yml') `
        -ExpectedServices @('postgres', 'ollama', 'model-init', 'litellm', 'open-webui', 'nvidia-exporter', 'prometheus', 'grafana') `
        -RequireNvidiaExporter -RequireNvidiaPrometheusConfig
    Test-ComposeContract -ComposeFiles @('docker-compose.native-ollama.yml') `
        -ExpectedServices @('postgres', 'litellm', 'open-webui', 'prometheus', 'grafana') `
        -ForbiddenServices @('ollama', 'model-init', 'nvidia-exporter') -RequireNativeOllama
    Test-MonitoringContract
    Test-VerificationScriptContract
    Test-PrometheusTokenConfigContract
    Test-OcrModelContract
    Test-SecretPlaceholderGuardContract
}
finally {
    Pop-Location
}

if ($failures.Count -gt 0) {
    Write-Host "Configuration contract failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'Configuration contract passed.' -ForegroundColor Green
