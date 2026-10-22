$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/model-lab.ps1') -Action list -LibraryOnly

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Throws {
    param([scriptblock] $Operation, [string] $Message)
    try { & $Operation; $script:failures.Add($Message) } catch { }
}
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

Assert-OllamaModelTag -Value 'qwen3:4b-instruct-2507-q4_K_M'
Assert-OllamaModelTag -Value 'namespace/model.name:tag-1'
Assert-Throws { Assert-OllamaModelTag -Value '--help' } 'Leading-dash model option was accepted'
Assert-Throws { Assert-OllamaModelTag -Value 'model:tag:extra' } 'Multiple model tag separators were accepted'
Assert-Throws { Assert-OllamaModelTag -Value 'model name:tag' } 'Whitespace in model tag was accepted'

Assert-LabAlias -Value 'lab-qwen3-8b'
Assert-LabAlias -Value 'Qwen3.6-35B'
Assert-LabAlias -Value 'my-model'
Assert-LabAlias -Value 'qwen3:8b'
Assert-LabAlias -Value 'namespace/model:tag'
Assert-LabAlias -Value 'โมเดลภาษาไทย'
Assert-Throws { Assert-LabAlias -Value 'default-general' } 'Production alias was accepted'
Assert-Throws { Assert-LabAlias -Value 'default-ocr' } 'Default OCR alias was accepted'
foreach ($invalid in @('--help', 'model name', 'model*', 'model?name', ('x' * 129))) {
    Assert-Throws { Assert-LabAlias -Value $invalid } "Invalid alias accepted: $invalid"
}
Assert-True -Condition ((Resolve-LabAlias -PhysicalModel 'qwen3:8b') -eq 'qwen3:8b') `
    -Message 'Implicit alias must preserve the physical name without adding a prefix'
Assert-True -Condition ((Resolve-LabAlias -RequestedAlias 'MyModel' -PhysicalModel 'qwen3:8b') -ceq 'MyModel') `
    -Message 'Explicit alias must preserve spelling and case'

$protected = @(Get-ProtectedPhysicalModels)
Assert-True -Condition ($protected -contains 'qwen3:4b-instruct-2507-q4_K_M') `
    -Message 'Current default-general physical model is not protected'
Assert-True -Condition ($protected -contains 'scb10x/typhoon-ocr1.5-3b') `
    -Message 'Current default-ocr physical model is not protected'
Assert-Throws {
    Assert-WeightsDeletionSafe -PhysicalModel 'qwen3:4b-instruct-2507-q4_K_M' -RemovingAlias 'lab-a'
} 'Production physical model deletion was accepted'

$shared = @(
    [pscustomobject]@{
        model_name = 'lab-b'
        litellm_params = [pscustomobject]@{ model = 'ollama_chat/example/model:tag' }
    }
)
Assert-Throws {
    Assert-WeightsDeletionSafe -PhysicalModel 'example/model:tag' -RemovingAlias 'lab-a' -Deployments $shared
} 'Shared lab physical model deletion was accepted'
Assert-WeightsDeletionSafe -PhysicalModel 'example/unshared:tag' -RemovingAlias 'lab-a' -Deployments $shared

# Registry behavior must depend on storage metadata rather than a naming prefix.
$script:catalog = @(
    [pscustomobject]@{ model_name = 'default-general'; model_info = [pscustomobject]@{ db_model = $false; id = 'static' } },
    [pscustomobject]@{ model_name = 'Chat'; model_info = [pscustomobject]@{ db_model = $true; id = 'chat-id' } },
    [pscustomobject]@{ model_name = 'namespace/model:tag'; model_info = [pscustomobject]@{ db_model = $true; id = 'tag-id' } },
    [pscustomobject]@{ model_name = 'lab-legacy'; model_info = [pscustomobject]@{ db_model = $true; id = 'legacy-id' } },
    [pscustomobject]@{ model_name = 'configured-extra'; model_info = [pscustomobject]@{ db_model = $false; id = 'extra' } },
    [pscustomobject]@{ model_name = 'missing-metadata' }
)
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    if ($Uri -notlike '*/model/info') { throw "Unexpected API call: $Uri" }
    return [pscustomobject]@{ data = $script:catalog }
}
function Get-PocBearerHeaders { return @{ Authorization = 'Bearer test-only' } }

$custom = @(Get-LabDeployments)
Assert-True -Condition ($custom.Count -eq 3) -Message 'List must include every DB-backed alias and exclude static aliases'
Assert-True -Condition ($custom.model_name -contains 'Chat') -Message 'Custom name without prefix was hidden'
Assert-True -Condition ($custom.model_name -contains 'lab-legacy') -Message 'Legacy lab aliases must remain manageable'
Assert-True -Condition ((Find-LabDeployment -LabAlias 'Chat').model_info.id -eq 'chat-id') `
    -Message 'Remove lookup must find custom aliases by deployment ID'
Assert-True -Condition ($null -eq (Find-LabDeployment -LabAlias 'configured-extra')) `
    -Message 'Static config aliases must not be removable through Model Lab'
Assert-Throws { Assert-AliasAvailable -Value 'chat' } 'Case-insensitive duplicate DB alias accepted'
Assert-Throws { Assert-AliasAvailable -Value 'configured-extra' } 'Duplicate static alias accepted'
Assert-AliasAvailable -Value 'new-name'

# Shared-weight protection must consider aliases outside Model Lab as well.
$script:catalog += [pscustomobject]@{
    model_name = 'configured-consumer'
    litellm_params = [pscustomobject]@{ model = 'ollama_chat/example/model:tag' }
    model_info = [pscustomobject]@{ db_model = $false }
}
$sharingConsumer = @(Get-AllModelDeployments | Where-Object { $_.model_name -eq 'configured-consumer' })
Assert-Throws {
    Assert-WeightsDeletionSafe -PhysicalModel 'example/model:tag' -RemovingAlias 'Chat' -Deployments $sharingConsumer
} 'Shared weights used by a static alias were accepted for deletion'

if ($failures.Count -gt 0) {
    Write-Host "Model Lab behavior test failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host 'Model Lab behavior test passed.' -ForegroundColor Green
