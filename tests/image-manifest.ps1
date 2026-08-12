$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/common.ps1')

Assert-PocCommand -Name 'docker'
$envValues = Get-PocEnv
$failures = New-Object 'System.Collections.Generic.List[string]'
$universalImages = @(
    'POSTGRES_IMAGE',
    'OLLAMA_IMAGE',
    'LITELLM_IMAGE',
    'OPEN_WEBUI_IMAGE',
    'PROMETHEUS_IMAGE',
    'GRAFANA_IMAGE'
)

foreach ($variableName in $universalImages) {
    $imageReference = $envValues[$variableName]
    if ([string]::IsNullOrWhiteSpace($imageReference)) {
        $failures.Add(".env is missing $variableName")
        continue
    }

    $rawManifest = & docker buildx imagetools inspect $imageReference --raw 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("Unable to inspect $variableName ($imageReference): $($rawManifest -join ' ')")
        continue
    }

    try {
        $manifest = ($rawManifest -join "`n") | ConvertFrom-Json
        $architectures = @(
            $manifest.manifests |
                Where-Object { $_.platform.os -eq 'linux' } |
                ForEach-Object { $_.platform.architecture } |
                Sort-Object -Unique
        )
        foreach ($requiredArchitecture in @('amd64', 'arm64')) {
            if ($architectures -notcontains $requiredArchitecture) {
                $failures.Add("$variableName does not publish linux/$requiredArchitecture ($imageReference)")
            }
        }
        Write-Host "[ok] $variableName -> $($architectures -join ', ')"
    }
    catch {
        $failures.Add("Invalid manifest JSON for $variableName ($imageReference): $($_.Exception.Message)")
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Image manifest contract failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'Image manifest contract passed.' -ForegroundColor Green
