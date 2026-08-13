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
Assert-Throws { Assert-LabAlias -Value 'corp-general' } 'Production alias was accepted'
Assert-Throws { Assert-LabAlias -Value 'not-a-lab-model' } 'Alias outside lab namespace was accepted'

$protected = @(Get-ProtectedPhysicalModels)
Assert-True -Condition ($protected -contains 'qwen3:4b-instruct-2507-q4_K_M') `
    -Message 'Current corp-general physical model is not protected'
Assert-True -Condition ($protected -contains 'scb10x/typhoon-ocr1.5-3b') `
    -Message 'Current corp-ocr physical model is not protected'
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

if ($failures.Count -gt 0) {
    Write-Host "Model Lab behavior test failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host 'Model Lab behavior test passed.' -ForegroundColor Green
