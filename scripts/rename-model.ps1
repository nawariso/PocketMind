[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $OldAlias,
    [string] $NewAlias,
    [string] $AdminEmail,
    [string] $OpenWebUiUrl = 'http://localhost:3000',
    [switch] $LibraryOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-RenameProperty {
    param($Object, [string] $Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Assert-RenameAlias {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 128 -or
        $Value -notmatch '^[\p{L}\p{N}][\p{L}\p{M}\p{N}._:/-]*$') {
        throw [ArgumentException]::new('Aliases must start with a letter/number, use at most 128 letters/numbers or . _ : / -, and contain no spaces/wildcards.')
    }
}

function Invoke-RenameApi {
    param([string] $Path, [string] $Method = 'GET', $Body, [switch] $WebUI)
    $base = if ($WebUI) { $script:RenameUiUrl } else { 'http://localhost:4000' }
    $headers = if ($WebUI) { $script:RenameUiHeaders } else { Get-PocBearerHeaders }
    $parameters = @{ Uri = "$base$Path"; Method = $Method; Headers = $headers; TimeoutSec = 60 }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 60
    }
    Invoke-RestMethod @parameters
}

function Get-RenameOptionalValves {
    # The pinned WebUI returns 401 for a missing function, which must not be confused with auth failure.
    $functions = @(Invoke-RenameApi -WebUI -Path '/api/v1/functions/list')
    if (@($functions | Where-Object { $_.id -ceq 'api_key_manager' }).Count -eq 0) { return $null }
    return Invoke-RenameApi -WebUI -Path '/api/v1/functions/id/api_key_manager/valves'
}

function ConvertTo-RenameCanonical {
    param($Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) { $result[$key] = ConvertTo-RenameCanonical $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-RenameCanonical $_ })
        return ,$items
    }
    $result = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        $result[$property.Name] = ConvertTo-RenameCanonical $property.Value
    }
    return $result
}

function New-RenamePlan {
    param([object[]] $Deployments, [object[]] $UiModels, $Valves, [string] $Old, [string] $New)
    Assert-RenameAlias $Old
    Assert-RenameAlias $New
    if ($Old -eq $New) { throw [ArgumentException]::new('Choose a distinct new alias; case-only renames are not supported.') }
    $sources = @($Deployments | Where-Object { $_.model_name -ceq $Old })
    if ($sources.Count -ne 1) { throw [ArgumentException]::new('Source must resolve to exactly one deployment; multi-deployment/load-balanced aliases require manual review.') }
    $source = $sources[0]
    if ([string]$source.litellm_params.model -notlike 'ollama_chat/*') { throw [ArgumentException]::new('Only local ollama_chat routes are supported.') }
    $base = [string](Get-RenameProperty $source.litellm_params 'api_base')
    if ($base -notin @('os.environ/OLLAMA_API_BASE', 'http://ollama:11434', 'http://host.docker.internal:11434') -or
        -not [string]::IsNullOrEmpty([string](Get-RenameProperty $source.litellm_params 'api_key'))) {
        throw [ArgumentException]::new('Only the repository local Ollama base without provider credentials is supported.')
    }
    $targets = @($Deployments | Where-Object { $_.model_name -eq $New })
    $createRoute = $targets.Count -eq 0
    if (-not $createRoute) {
        # Only reuse a route created by this operation; never adopt a coincidentally matching alias.
        if ($targets.Count -ne 1 -or $targets[0].model_name -cne $New -or
            (Get-RenameProperty $targets[0].model_info 'pocketmind_rename_from') -cne $Old -or
            (ConvertTo-Json (ConvertTo-RenameCanonical $targets[0].litellm_params) -Depth 60 -Compress) -cne
            (ConvertTo-Json (ConvertTo-RenameCanonical $source.litellm_params) -Depth 60 -Compress)) {
            throw [ArgumentException]::new('Destination alias already exists or its routing differs; no changes were made.')
        }
    }
    $modelInfo = $source.model_info | ConvertTo-Json -Depth 60 | ConvertFrom-Json
    foreach ($property in @('id', 'db_model', 'created_at', 'updated_at', 'created_by', 'updated_by')) {
        $modelInfo.PSObject.Properties.Remove($property)
    }
    $modelInfo | Add-Member -NotePropertyName id -NotePropertyValue ([guid]::NewGuid().ToString()) -Force
    $modelInfo | Add-Member -NotePropertyName db_model -NotePropertyValue $true -Force
    $modelInfo | Add-Member -NotePropertyName pocketmind_rename_from -NotePropertyValue $Old -Force
    $route = @{ model_name = $New; litellm_params = $source.litellm_params; model_info = $modelInfo }
    # Follow earlier compatibility renames so B -> C still renames the stable A workspace ID.
    $related = @($Old)
    $ancestor = $source
    while ($true) {
        $parent = [string](Get-RenameProperty $ancestor.model_info 'pocketmind_rename_from')
        if ([string]::IsNullOrWhiteSpace($parent) -or $related -ccontains $parent) { break }
        $parents = @($Deployments | Where-Object { $_.model_name -ceq $parent })
        if ($parents.Count -ne 1 -or
            (ConvertTo-Json (ConvertTo-RenameCanonical $parents[0].litellm_params) -Depth 60 -Compress) -cne
            (ConvertTo-Json (ConvertTo-RenameCanonical $source.litellm_params) -Depth 60 -Compress)) { break }
        $related += $parent
        $ancestor = $parents[0]
    }
    $updates = @()
    foreach ($entry in $UiModels) {
        # Keep curated preset names. Rename the base record and exact-name references only.
        if ($related -ccontains $entry.id -or
            ($related -ccontains (Get-RenameProperty $entry 'base_model_id') -and $related -ccontains $entry.name)) {
            if ($entry.name -ceq $New) { continue }
            $body = @{
                id = $entry.id; name = $New; base_model_id = $entry.base_model_id
                meta = $entry.meta; params = $entry.params; is_active = $entry.is_active
                access_grants = @(Get-RenameProperty $entry 'access_grants' @())
            }
            $updates += $body
        }
    }
    $createUi = @($UiModels | Where-Object { $related -ccontains $_.id }).Count -eq 0
    # Refuse a new alias colliding with a different workspace/preset or function model ID.
    if (@($UiModels | Where-Object { $_.id -eq $New }).Count -gt 0) { throw [ArgumentException]::new('Destination conflicts with an existing Open WebUI model ID.') }
    if (@($UiModels | Where-Object { $_.name -ceq $New -and $related -cnotcontains $_.id -and $related -cnotcontains (Get-RenameProperty $_ 'base_model_id') }).Count -gt 0) {
        throw [ArgumentException]::new('Destination display name belongs to another WebUI model.')
    }
    $newUi = @{ id = $Old; name = $New; base_model_id = $null; meta = @{}; params = @{}; access_grants = @(); is_active = $true }
    if ($Old -eq 'default-ocr') { $newUi.meta = @{ capabilities = @{ vision = $true; builtin_tools = $false } } }
    $updatedValves = $null
    if ($null -ne $Valves -and -not (Get-RenameProperty $Valves 'auto_discover_models' $true)) {
        $allowed = @(([string](Get-RenameProperty $Valves 'allowed_models' '')) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($allowed -ccontains $Old -and $allowed -cnotcontains $New) {
            $updatedValves = $Valves | ConvertTo-Json -Depth 60 | ConvertFrom-Json
            $updatedValves | Add-Member -NotePropertyName allowed_models -NotePropertyValue (($allowed + $New) -join ',') -Force
        }
    }
    [pscustomobject]@{ Old = $Old; New = $New; CreateRoute = $createRoute; Route = $route; Updates = $updates; CreateUi = $createUi; NewUi = $newUi; Valves = $updatedValves }
}

function Invoke-RenamePlan {
    param($Plan)
    # Never delete/rename the old route or edit key/team scopes. Failed steps can be retried.
    if ($Plan.CreateRoute) {
        Invoke-RenameApi -Path '/model/new' -Method Post -Body $Plan.Route | Out-Null
    }
    $catalog = Invoke-RenameApi -Path '/v1/models'
    if (@($catalog.data.id) -cnotcontains $Plan.Old -or @($catalog.data.id) -cnotcontains $Plan.New) {
        throw [ArgumentException]::new('Both aliases must be discoverable before updating WebUI. Old routes were not removed; inspect routing and rerun.')
    }
    if ($Plan.CreateUi) {
        Invoke-RenameApi -WebUI -Path '/api/v1/models/create' -Method Post -Body $Plan.NewUi | Out-Null
        Write-Warning 'The new WebUI record is private: review intended access grants before sharing.'
    }
    foreach ($body in $Plan.Updates) {
        Invoke-RenameApi -WebUI -Path '/api/v1/models/model/update' -Method Post -Body $body | Out-Null
    }
    if ($null -ne $Plan.Valves) {
        Invoke-RenameApi -WebUI -Path '/api/v1/functions/id/api_key_manager/valves/update' -Method Post -Body $Plan.Valves | Out-Null
    }
    # Verify stable IDs and the display labels after mutations.
    foreach ($id in @(@($Plan.Updates | ForEach-Object { $_.id }) + $(if ($Plan.CreateUi) { $Plan.Old }))) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $entry = Invoke-RenameApi -WebUI -Path "/api/v1/models/model?id=$([uri]::EscapeDataString($id))"
        if ($entry.id -cne $id -or $entry.name -cne $Plan.New) { throw [ArgumentException]::new('WebUI verification failed; rerun after inspecting the affected record.') }
    }
}

if ($LibraryOnly) { return }
try {
    Assert-RenameAlias $OldAlias
    Assert-RenameAlias $NewAlias
    if ([string]::IsNullOrWhiteSpace($AdminEmail)) { throw [ArgumentException]::new('-AdminEmail is required.') }
    # Admin sessions and source metadata must stay on the server's loopback management endpoints.
    $url = [uri]$OpenWebUiUrl
    if (-not $url.IsAbsoluteUri -or $url.Scheme -notin @('http', 'https') -or -not $url.IsLoopback -or
        $url.UserInfo -or $url.Query -or $url.Fragment -or $url.AbsolutePath -ne '/') {
        throw [ArgumentException]::new('OpenWebUiUrl must be an HTTP(S) loopback origin, for example http://localhost:3000.')
    }
    $script:RenameUiUrl = $OpenWebUiUrl.TrimEnd('/')
    $fileValues = Get-PocEnv
    $password = $env:OPENWEBUI_ADMIN_PASSWORD
    if ([string]::IsNullOrEmpty($password) -and [string]$fileValues['WEBUI_ADMIN_EMAIL'] -eq $AdminEmail) {
        $password = [string]$fileValues['WEBUI_ADMIN_PASSWORD']
    }
    if ([string]::IsNullOrEmpty($password)) {
        $secure = Read-Host "Open WebUI password for $AdminEmail" -AsSecureString
        $password = [System.Net.NetworkCredential]::new('', $secure).Password
    }
    $session = Invoke-RestMethod -Uri "$script:RenameUiUrl/api/v1/auths/signin" -Method Post -ContentType 'application/json' `
        -Body (@{ email = $AdminEmail; password = $password } | ConvertTo-Json) -TimeoutSec 30
    if ($session.role -ne 'admin') { throw 'Open WebUI administrator access is required.' }
    $script:RenameUiHeaders = @{ Authorization = "Bearer $($session.token)" }
    $deployments = Invoke-RenameApi -Path '/model/info'
    $models = @(Invoke-RenameApi -WebUI -Path '/api/v1/models/all')
    $valves = Get-RenameOptionalValves
    $plan = New-RenamePlan -Deployments @($deployments.data) -UiModels $models -Valves $valves -Old $OldAlias -New $NewAlias
    Write-Host "New API alias: $NewAlias; legacy API alias retained: $OldAlias"
    Write-Host "WebUI display updates: $($plan.Updates.Count); create private base record: $($plan.CreateUi)"
    Write-Host 'Model IDs, history, task/default references, key scopes and team scopes stay unchanged.'
    if ($PSCmdlet.ShouldProcess("$OldAlias -> $NewAlias (retain legacy API)", 'Add API alias and update WebUI display names')) {
        Invoke-RenamePlan $plan
        Write-Host 'Completed. Refresh WebUI and test old/new API aliases with appropriately scoped keys.' -ForegroundColor Green
        Write-Host 'Updated API Key Manager offers current names for new keys and shows legacy names only to their active-key owners. Raw API discovery retains both aliases.'
    }
}
catch {
    # Do not echo remote response bodies: routing metadata may contain credentials.
    if ($_.Exception -is [ArgumentException]) { Write-Warning $_.Exception.Message }
    Write-Error 'Model rename did not complete. No legacy alias/key was deleted. Check service health, naming conflicts and permissions, then rerun. Changes across services are not atomic.'
    exit 1
}
finally {
    $password = $null
    $script:RenameUiHeaders = $null
}
