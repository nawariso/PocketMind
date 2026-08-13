param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('add', 'list', 'test', 'remove')] [string] $Action,
    [string] $Model,
    [string] $Alias,
    [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto',
    [string] $Prompt = 'ตอบสั้น ๆ ว่าคุณคือโมเดลอะไรและช่วยงานประเภทใดได้ดี',
    [ValidateRange(8, 2048)] [int] $MaxTokens = 128,
    [switch] $DeleteWeights,
    [switch] $LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

$liteLlmBase = 'http://localhost:4000'
$protectedAliases = @('corp-general', 'corp-ocr')

function Assert-OllamaModelTag {
    param([Parameter(Mandatory)] [string] $Value)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?$') {
        throw 'Model must be an exact Ollama name/tag containing only letters, numbers, dot, underscore, dash, slash, and one optional tag separator.'
    }
}

function Get-ProtectedPhysicalModels {
    $configPath = Join-Path $script:PocRepoRoot 'litellm/config.yaml'
    $models = foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -match '^\s+model:\s+ollama_chat/(\S+)\s*$') { $matches[1] }
    }
    return @($models | Sort-Object -Unique)
}

function Assert-LabAlias {
    param([Parameter(Mandatory)] [string] $Value)
    if ($Value -notmatch '^lab-[a-z0-9][a-z0-9._-]{0,62}$') {
        throw "Alias must start with 'lab-' and contain only lowercase letters, numbers, dot, underscore, or dash."
    }
    if ($protectedAliases -contains $Value) {
        throw "Protected production alias cannot be changed: $Value"
    }
}

function Resolve-LabAlias {
    param([string] $RequestedAlias, [string] $PhysicalModel)
    if (-not [string]::IsNullOrWhiteSpace($RequestedAlias)) { return $RequestedAlias }
    if ([string]::IsNullOrWhiteSpace($PhysicalModel)) { throw '-Model or -Alias is required.' }
    $safe = ($PhysicalModel.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
    return "lab-$safe"
}

function Invoke-Ollama {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $ResolvedProfile
    )
    if ($ResolvedProfile -eq 'native') {
        & ollama @Arguments
    }
    else {
        & docker exec pocketmind-ollama ollama @Arguments
    }
    if ($LASTEXITCODE -ne 0) { throw "Ollama command failed: ollama $($Arguments -join ' ')" }
}

function Get-LabDeployments {
    $response = Invoke-RestMethod -Uri "$liteLlmBase/model/info" -Headers (Get-PocBearerHeaders) -TimeoutSec 30
    $dataProperty = $response.PSObject.Properties['data']
    $items = if ($null -ne $dataProperty) { @($dataProperty.Value) } else { @($response) }
    return @($items | Where-Object {
        $nameProperty = $_.PSObject.Properties['model_name']
        $null -ne $nameProperty -and [string]$nameProperty.Value -like 'lab-*'
    })
}

function Find-LabDeployment {
    param([Parameter(Mandatory)] [string] $LabAlias)
    return @(Get-LabDeployments | Where-Object { $_.model_name -eq $LabAlias }) | Select-Object -First 1
}

function Assert-WeightsDeletionSafe {
    param(
        [Parameter(Mandatory)] [string] $PhysicalModel,
        [Parameter(Mandatory)] [string] $RemovingAlias,
        [object[]] $Deployments = @()
    )
    if ($PhysicalModel -in @(Get-ProtectedPhysicalModels)) {
        throw "Refusing to delete production model weights: $PhysicalModel. The alias was not removed."
    }
    $sharedAliases = @($Deployments | Where-Object {
        $_.model_name -ne $RemovingAlias -and
        ([string]$_.litellm_params.model -replace '^ollama_chat/', '') -eq $PhysicalModel
    })
    if ($sharedAliases.Count -gt 0) {
        throw "Refusing to delete shared weights used by: $($sharedAliases.model_name -join ', '). The alias was not removed."
    }
}

if ($LibraryOnly) { return }

try {
    Assert-PocSecretsConfigured
    $resolvedProfile = Resolve-PocProfile -RequestedProfile $Profile
    $headers = Get-PocBearerHeaders

    switch ($Action) {
        'add' {
            if ([string]::IsNullOrWhiteSpace($Model)) { throw 'add requires -Model with an exact Ollama model tag.' }
            Assert-OllamaModelTag -Value $Model
            $labAlias = Resolve-LabAlias -RequestedAlias $Alias -PhysicalModel $Model
            Assert-LabAlias -Value $labAlias
            if ($null -ne (Find-LabDeployment -LabAlias $labAlias)) { throw "Model Lab alias already exists: $labAlias" }

            $freeDisk = Get-PSDrive -Name ([IO.Path]::GetPathRoot($script:PocRepoRoot).TrimEnd(':', '\')) -ErrorAction SilentlyContinue
            if ($null -ne $freeDisk) { Write-Host ("Host free disk: {0:N1} GB" -f ($freeDisk.Free / 1GB)) }
            Write-Host "Pulling exact Ollama model '$Model'..." -ForegroundColor Cyan
            # The effective command is: ollama pull <exact-tag>
            Invoke-Ollama -Arguments @('pull', $Model) -ResolvedProfile $resolvedProfile
            Invoke-Ollama -Arguments @('show', $Model) -ResolvedProfile $resolvedProfile

            $deploymentId = [guid]::NewGuid().ToString()
            $body = @{
                model_name = $labAlias
                litellm_params = @{
                    model = "ollama_chat/$Model"
                    api_base = 'os.environ/OLLAMA_API_BASE'
                }
                model_info = @{
                    id = $deploymentId
                    db_model = $true
                    description = "PocketMind Model Lab: $Model"
                }
            } | ConvertTo-Json -Depth 12
            Invoke-RestMethod -Uri "$liteLlmBase/model/new" -Method Post -Headers $headers `
                -ContentType 'application/json' -Body $body -TimeoutSec 60 | Out-Null

            $modelList = Invoke-RestMethod -Uri "$liteLlmBase/v1/models" -Headers $headers -TimeoutSec 30
            if (@($modelList.data.id) -notcontains $labAlias) {
                try {
                    $rollbackBody = @{ id = $deploymentId } | ConvertTo-Json
                    Invoke-RestMethod -Uri "$liteLlmBase/model/delete" -Method Post -Headers $headers `
                        -ContentType 'application/json' -Body $rollbackBody -TimeoutSec 60 | Out-Null
                }
                catch { Write-Warning "Rollback failed for deployment $deploymentId`: $($_.Exception.Message)" }
                throw "LiteLLM did not expose $labAlias after creation; deployment rollback was attempted."
            }
            Write-Host "[ready] $labAlias -> $Model" -ForegroundColor Green
            Write-Host "Test it: pwsh ./scripts/model-lab.ps1 test -Alias $labAlias"
            Write-Host 'Open WebUI may require a browser refresh before the new alias appears.'
        }
        'list' {
            $models = @(Get-LabDeployments)
            if ($models.Count -eq 0) { Write-Host 'No Model Lab aliases are registered.'; break }
            $models | ForEach-Object {
                [pscustomobject]@{
                    Alias = $_.model_name
                    PhysicalModel = $_.litellm_params.model
                    DeploymentId = $_.model_info.id
                }
            } | Format-Table -AutoSize
        }
        'test' {
            $labAlias = Resolve-LabAlias -RequestedAlias $Alias -PhysicalModel $Model
            Assert-LabAlias -Value $labAlias
            $body = @{
                model = $labAlias
                messages = @(@{ role = 'user'; content = $Prompt })
                max_tokens = $MaxTokens
                temperature = 0
            } | ConvertTo-Json -Depth 8
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-RestMethod -Uri "$liteLlmBase/v1/chat/completions" -Method Post `
                -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 300
            $timer.Stop()
            $tokens = [int]$response.usage.completion_tokens
            $rate = if ($timer.Elapsed.TotalSeconds -gt 0) { $tokens / $timer.Elapsed.TotalSeconds } else { 0 }
            Write-Host $response.choices[0].message.content
            Write-Host ("`nAlias={0}; latency={1:N2}s; output={2} tokens; wall-rate={3:N2} tokens/s" -f `
                $labAlias, $timer.Elapsed.TotalSeconds, $tokens, $rate) -ForegroundColor Green
        }
        'remove' {
            $labAlias = Resolve-LabAlias -RequestedAlias $Alias -PhysicalModel $Model
            Assert-LabAlias -Value $labAlias
            $deployment = Find-LabDeployment -LabAlias $labAlias
            if ($null -eq $deployment) { throw "Model Lab alias not found: $labAlias" }
            $physicalModel = [string]$deployment.litellm_params.model
            $physicalModel = $physicalModel -replace '^ollama_chat/', ''
            if ($DeleteWeights) {
                Assert-WeightsDeletionSafe -PhysicalModel $physicalModel -RemovingAlias $labAlias `
                    -Deployments @(Get-LabDeployments)
            }
            $body = @{ id = [string]$deployment.model_info.id } | ConvertTo-Json
            Invoke-RestMethod -Uri "$liteLlmBase/model/delete" -Method Post -Headers $headers `
                -ContentType 'application/json' -Body $body -TimeoutSec 60 | Out-Null
            Write-Host "Removed LiteLLM alias: $labAlias" -ForegroundColor Green
            if ($DeleteWeights) {
                Invoke-Ollama -Arguments @('rm', $physicalModel) -ResolvedProfile $resolvedProfile
                Write-Host "Deleted Ollama weights: $physicalModel" -ForegroundColor Green
            }
        }
    }
}
catch {
    Write-Error "Model Lab failed: $($_.Exception.Message)"
    exit 1
}
