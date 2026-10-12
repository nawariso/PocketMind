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
        $modelNames = @($envValues['OLLAMA_MODEL'])
        $ocrModelName = $envValues['OLLAMA_OCR_MODEL']
        if ([string]::IsNullOrWhiteSpace($ocrModelName)) { $ocrModelName = 'scb10x/typhoon-ocr1.5-3b' }
        $modelNames += $ocrModelName
        $modelList = (& ollama list) -join "`n"
        foreach ($modelName in $modelNames) {
            if ($modelList -notmatch [regex]::Escape($modelName)) {
                if (-not $Pull) {
                    throw "Native Ollama model '$modelName' is missing. Run: ollama pull $modelName (or rerun setup with -Pull)."
                }
                & ollama pull $modelName
                if ($LASTEXITCODE -ne 0) { throw "Failed to pull native Ollama model: $modelName" }
            }
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
    if (Test-PocProxyEnabled) { $containers += 'pocketmind-nginx' }

    foreach ($container in $containers) {
        Wait-PocContainerHealthy -ContainerName $container -TimeoutSeconds 360
    }

    # Open WebUI reports onboarding while no administrator exists; whoever opens it first would become one.
    if ((Test-PocProxyEnabled) -and (Get-PocProxySettings).BindAddress -ne '127.0.0.1') {
        try {
            $webUiConfig = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/api/config' -TimeoutSec 10
            if ($webUiConfig.onboarding -eq $true) {
                Write-Warning 'Open WebUI has no administrator yet and the proxy listens beyond this host: the first visitor would become the administrator. Create the administrator account now, or set WEBUI_ADMIN_EMAIL and WEBUI_ADMIN_PASSWORD in .env before the first start.'
            }
        }
        catch { }
    }
    Write-Host "Local LLM stack is running with profile '$resolvedProfile'." -ForegroundColor Green
    Write-Host 'Open WebUI: http://localhost:3000'
    Write-Host 'LiteLLM:    http://localhost:4000/ui/'
    Write-Host 'Prometheus: http://localhost:9090'
    Write-Host 'Grafana:    http://localhost:3001'
    if (Test-PocProxyEnabled) {
        $proxy = Get-PocProxySettings
        Write-Host "Proxy:      Open WebUI http://$($proxy.BindAddress):$($proxy.WebUiPort)  API http://$($proxy.BindAddress):$($proxy.ApiPort)/v1"
        if ($proxy.BindAddress -eq '127.0.0.1') {
            Write-Host 'The proxy listens on this host only. Set PROXY_BIND_ADDRESS in .env to share it on your network.'
        }
        elseif ($proxy.BindAddress -eq '0.0.0.0') {
            Write-Host 'The proxy listens on every interface: give users this host''s own IP address, not 0.0.0.0.'
        }
    }
}
catch {
    Write-Error "Setup failed: $($_.Exception.Message)"
    exit 1
}
