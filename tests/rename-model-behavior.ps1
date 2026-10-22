$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/rename-model.ps1') -LibraryOnly

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock] $Operation, [string] $Message)
    $threw = $false
    try { & $Operation | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function Copy-TestObject { param($Value) return ($Value | ConvertTo-Json -Depth 60 | ConvertFrom-Json) }

$source = [pscustomobject]@{
    model_name = 'default-general'
    litellm_params = [pscustomobject]@{ model = 'ollama_chat/test:4b'; api_base = 'os.environ/OLLAMA_API_BASE'; num_ctx = 16384 }
    model_info = [pscustomobject]@{ id = 'static-source'; db_model = $false; supports_vision = $true; max_input_tokens = 16384 }
}
$ui = [pscustomobject]@{
    id = 'default-general'; name = 'Previous display label'; base_model_id = $null
    meta = [pscustomobject]@{ capabilities = [pscustomobject]@{ builtin_tools = $false; vision = $true } }
    params = [pscustomobject]@{ system = 'Keep this system prompt'; temperature = 0.1 }
    access_grants = @([pscustomobject]@{ principal_type = 'group'; principal_id = 'private-team'; permission = 'read' })
    is_active = $false
}
$valves = [pscustomobject]@{ auto_discover_models = $false; allowed_models = 'default-general,default-ocr'; max_keys_per_user = 7 }
$plan = New-RenamePlan -Deployments @($source) -UiModels @($ui) -Valves $valves -Old 'default-general' -New 'Pocket-General'
Assert-True $plan.CreateRoute 'A new alias must be created'
Assert-True (-not $plan.CreateUi) 'An existing WebUI ID must be reused'
Assert-True ($plan.Route.model_name -ceq 'Pocket-General') 'New alias is incorrect'
Assert-True ($plan.Route.litellm_params.num_ctx -eq 16384) 'Model parameters were lost'
Assert-True ($plan.Route.model_info.id -ne 'static-source') 'Deployment IDs must not be shared'
Assert-True ($plan.Route.model_info.supports_vision) 'Capabilities were lost'
Assert-True ($plan.Updates[0].id -ceq 'default-general') 'Stable WebUI ID was changed'
Assert-True ($plan.Updates[0].access_grants[0].principal_id -eq 'private-team') 'Private grants were broadened'
Assert-True ($plan.Updates[0].params.system -eq $ui.params.system) 'System prompt was lost'
Assert-True (-not $plan.Updates[0].is_active) 'Inactive model was enabled'
Assert-True ($plan.Updates[0].meta.capabilities.builtin_tools -eq $false) 'OCR/tool metadata changed'
Assert-True ($plan.Valves.allowed_models -ceq 'default-general,default-ocr,Pocket-General') 'Manual allowlist must retain old scopes and add the new name'
Assert-True ($plan.Valves.max_keys_per_user -eq 7) 'Unrelated Valves were changed'
Assert-True ($valves.allowed_models -ceq 'default-general,default-ocr') 'Planning mutated the original Valves'
Assert-True ($ui.name -ceq 'Previous display label') 'Planning mutated WebUI input'

# Retry after creation or a partial cross-service update is safe, including reordered API fields.
$target = Copy-TestObject $plan.Route
$target.litellm_params = [pscustomobject]@{ num_ctx = 16384; api_base = 'os.environ/OLLAMA_API_BASE'; model = 'ollama_chat/test:4b' }
$renamedUi = Copy-TestObject $ui
$renamedUi.name = 'Pocket-General'
$retry = New-RenamePlan -Deployments @($source, $target) -UiModels @($renamedUi) -Old 'default-general' -New 'Pocket-General'
Assert-True (-not $retry.CreateRoute -and $retry.Updates.Count -eq 0) 'Repeat operation should not duplicate routes or UI updates'

$chained = New-RenamePlan -Deployments @($source, $target) -UiModels @($renamedUi) -Old 'Pocket-General' -New 'Final-General'
Assert-True (-not $chained.CreateUi -and $chained.Updates.Count -eq 1 -and $chained.Updates[0].id -ceq 'default-general' -and $chained.Updates[0].name -ceq 'Final-General') 'Chained renames must keep and update the original workspace ID'

$conflict = Copy-TestObject $target
$conflict.model_info.PSObject.Properties.Remove('pocketmind_rename_from')
Assert-Throws { New-RenamePlan -Deployments @($source, $conflict) -UiModels @($ui) -Old 'default-general' -New 'Pocket-General' } 'Unrelated destination alias was adopted'
$drift = Copy-TestObject $target
$drift.litellm_params.num_ctx = 8192
Assert-Throws { New-RenamePlan -Deployments @($source, $drift) -UiModels @($ui) -Old 'default-general' -New 'Pocket-General' } 'Routing drift was ignored on retry'
Assert-Throws { New-RenamePlan -Deployments @($source, $source) -UiModels @($ui) -Old 'default-general' -New 'Pocket-General' } 'Load-balanced source was accepted'
Assert-Throws { New-RenamePlan -Deployments @($source) -UiModels @($ui) -Old 'default-general' -New 'DEFAULT-GENERAL' } 'Case-only rename was accepted'
foreach ($invalid in @('with spaces', 'wild*', '--option', ('x' * 129))) {
    Assert-Throws { Assert-RenameAlias $invalid } "Invalid alias accepted: $invalid"
}
Assert-RenameAlias 'โมเดลภาษาไทย'
Assert-RenameAlias 'team/model:tag'
$remote = Copy-TestObject $source
$remote.litellm_params.model = 'openai/remote'
Assert-Throws { New-RenamePlan -Deployments @($remote) -UiModels @() -Old 'default-general' -New 'Pocket-General' } 'Nonlocal provider accepted'
$remote = Copy-TestObject $source
$remote.litellm_params.api_base = 'https://external.invalid'
Assert-Throws { New-RenamePlan -Deployments @($remote) -UiModels @() -Old 'default-general' -New 'Pocket-General' } 'External API base accepted'

$workspaceConflict = Copy-TestObject $ui
$workspaceConflict.id = 'Pocket-General'
Assert-Throws { New-RenamePlan -Deployments @($source) -UiModels @($ui, $workspaceConflict) -Old 'default-general' -New 'Pocket-General' } 'Workspace ID collision accepted'
$curated = Copy-TestObject $ui
$curated.id = 'curated-id'; $curated.name = 'Reviewed preset'; $curated.base_model_id = 'default-general'
$presetPlan = New-RenamePlan -Deployments @($source) -UiModels @($ui, $curated) -Old 'default-general' -New 'Pocket-General'
Assert-True ($presetPlan.Updates.Count -eq 1) 'Curated preset names must be preserved'
$privatePlan = New-RenamePlan -Deployments @($source) -UiModels @() -Old 'default-general' -New 'Pocket-General'
Assert-True ($privatePlan.CreateUi -and $privatePlan.NewUi.access_grants.Count -eq 0) 'Missing WebUI record must default to private'
$discovery = [pscustomobject]@{ auto_discover_models = $true; allowed_models = 'default-general' }
$autoPlan = New-RenamePlan -Deployments @($source) -UiModels @($ui) -Valves $discovery -Old 'default-general' -New 'Pocket-General'
Assert-True ($null -eq $autoPlan.Valves) 'Automatic discovery must not require changing Valves'

# Missing functions are discovered through the admin list; authentication failures must not be ignored.
$script:installed = $false
$script:denyFunctionList = $false
function Invoke-RenameApi {
    param([string] $Path, [switch] $WebUI)
    if ($script:denyFunctionList) { throw 'simulated unauthorized' }
    if ($Path -eq '/api/v1/functions/list') {
        if ($script:installed) { return @([pscustomobject]@{ id = 'api_key_manager' }) }
        return @()
    }
    if ($Path -eq '/api/v1/functions/id/api_key_manager/valves') { return $valves }
    throw 'Unexpected function lookup'
}
Assert-True ($null -eq (Get-RenameOptionalValves)) 'Missing Function must be skipped without probing its 401 endpoint'
$script:installed = $true
Assert-True ((Get-RenameOptionalValves).max_keys_per_user -eq 7) 'Installed Function settings must be read'
$script:denyFunctionList = $true
Assert-Throws { Get-RenameOptionalValves } 'Function-list authentication failure was silently skipped'

# Orchestration uses only additive route creation and name updates: no key/team/history changes.
$script:calls = @()
$script:failUpdate = $false
$script:missingAlias = $false
function Invoke-RenameApi {
    param([string] $Path, [string] $Method = 'GET', $Body, [switch] $WebUI)
    $script:calls += [pscustomobject]@{ Path = $Path; Method = $Method; Body = $Body }
    switch ($Path) {
        '/model/new' { return $null }
        '/v1/models' {
            $ids = @('default-general'); if (-not $script:missingAlias) { $ids += 'Pocket-General' }
            return [pscustomobject]@{ data = @($ids | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
        }
        '/api/v1/models/create' { return $null }
        '/api/v1/models/model/update' { if ($script:failUpdate) { throw 'simulated UI failure' }; return $null }
        '/api/v1/functions/id/api_key_manager/valves/update' { return $null }
        '/api/v1/models/model?id=default-general' { return [pscustomobject]@{ id = 'default-general'; name = 'Pocket-General' } }
        default { throw "Unexpected endpoint: $Path" }
    }
}
Invoke-RenamePlan $plan
Assert-True (@($script:calls | Where-Object { $_.Path -eq '/model/new' }).Count -eq 1) 'Expected one additive route creation'
Assert-True (@($script:calls | Where-Object { $_.Path -match '/key|/team|/delete|/tasks|/chats' }).Count -eq 0) 'Legacy access/history was mutated'
$script:calls = @()
Invoke-RenamePlan $privatePlan
$created = @($script:calls | Where-Object { $_.Path -eq '/api/v1/models/create' })
Assert-True ($created.Count -eq 1 -and $created[0].Body.access_grants.Count -eq 0) 'Private creation must preserve an empty access list'
$script:calls = @(); $script:failUpdate = $true
Assert-Throws { Invoke-RenamePlan $plan } 'Partial failure was hidden'
Assert-True (@($script:calls | Where-Object { $_.Path -match '/delete|/key|/team' }).Count -eq 0) 'Failure deleted compatibility routes or modified scopes'
$script:calls = @(); $script:missingAlias = $true
Assert-Throws { Invoke-RenamePlan $plan } 'Missing route discovery was ignored'
Assert-True (@($script:calls | Where-Object { $_.Path -like '/api/v1/*' }).Count -eq 0) 'UI changed before compatibility was verified'
Write-Host 'Model rename behavior tests passed.' -ForegroundColor Green

# Exercise the real CLI -WhatIf with synthetic credentials/endpoints and no disk/server mutations.
$script:restCalls = @()
function Test-Path {
    param([string] $LiteralPath, $PathType)
    if ($LiteralPath -like '*/.env' -or $LiteralPath -like '*\.env') { return $true }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Content {
    param([string] $LiteralPath, [switch] $Raw)
    if ($LiteralPath -like '*/.env' -or $LiteralPath -like '*\.env') {
        return @('WEBUI_ADMIN_EMAIL=operator@example.invalid', 'WEBUI_ADMIN_PASSWORD=synthetic-only-password', 'LITELLM_MASTER_KEY=synthetic-only-key')
    }
    Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
function Invoke-RestMethod {
    param($Uri, $Method = 'GET', $Headers, $TimeoutSec, $ContentType, $Body)
    $script:restCalls += [pscustomobject]@{ Uri = $Uri; Method = $Method }
    switch -Wildcard ($Uri) {
        '*/api/v1/auths/signin' { return [pscustomobject]@{ role = 'admin'; token = 'synthetic-token' } }
        '*/model/info' { return [pscustomobject]@{ data = @($source) } }
        '*/api/v1/models/all' { return @($ui) }
        '*/api/v1/functions/list' { return @([pscustomobject]@{ id = 'api_key_manager' }) }
        '*/api/v1/functions/id/api_key_manager/valves' { return $valves }
        default { throw 'WhatIf attempted an unexpected endpoint/mutation' }
    }
}
. (Join-Path $repoRoot 'scripts/rename-model.ps1') -OldAlias default-general -NewAlias Pocket-General -AdminEmail operator@example.invalid -WhatIf
Assert-True (@($script:restCalls | Where-Object { $_.Method -ne 'GET' -and $_.Uri -notlike '*/auths/signin' }).Count -eq 0) 'WhatIf mutated resources'
Write-Host 'Model rename CLI WhatIf test passed.' -ForegroundColor Green
