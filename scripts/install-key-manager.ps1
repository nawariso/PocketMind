param(
    [Parameter(Mandatory)] [string] $AdminEmail,
    [string] $OpenWebUiUrl = 'http://localhost:3000',
    # Open WebUI group IDs allowed to see the key manager. Omit to allow every signed-in user.
    [string[]] $GroupId = @(),
    # LiteLLM model aliases to make visible to every signed-in user. Open WebUI hides models from
    # non-admin users until they have an access grant. Models that already have an entry are left unchanged.
    [string[]] $PublicModels = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

# The admin password is read from OPENWEBUI_ADMIN_PASSWORD or prompted; it is never accepted as an argument.
$password = $env:OPENWEBUI_ADMIN_PASSWORD
if ([string]::IsNullOrEmpty($password)) {
    $secure = Read-Host -Prompt "Open WebUI password for $AdminEmail" -AsSecureString
    $password = [System.Net.NetworkCredential]::new('', $secure).Password
}

$functionId = 'api_key_manager'
$sourcePath = Join-Path $script:PocRepoRoot 'openwebui/functions/api_key_manager.py'
Assert-PocFile -RelativePath 'openwebui/functions/api_key_manager.py'

try {
    $session = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/auths/signin" -Method Post -ContentType 'application/json' `
        -Body (@{ email = $AdminEmail; password = $password } | ConvertTo-Json) -TimeoutSec 30
    if ($session.role -ne 'admin') { throw "$AdminEmail is not an Open WebUI administrator." }
    $headers = @{ Authorization = "Bearer $($session.token)" }

    $body = @{
        id = $functionId
        name = 'API Key Manager'
        content = Get-Content -Raw -LiteralPath $sourcePath
        meta = @{ description = 'Create, list, rotate, and revoke your own scoped LiteLLM API key.' }
    } | ConvertTo-Json -Depth 6

    $existing = $null
    try { $existing = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/functions/id/$functionId" -Headers $headers -TimeoutSec 30 }
    catch { }

    if ($null -eq $existing) {
        $function = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/functions/create" -Method Post -Headers $headers `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
        Write-Host 'Created function api_key_manager.' -ForegroundColor Green
    }
    else {
        $function = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/functions/id/$functionId/update" -Method Post -Headers $headers `
            -ContentType 'application/json' -Body $body -TimeoutSec 60
        Write-Host 'Updated function api_key_manager (valves are preserved).' -ForegroundColor Green
    }
    if (-not $function.is_active) {
        Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/functions/id/$functionId/toggle" -Method Post -Headers $headers -TimeoutSec 30 | Out-Null
        Write-Host 'Activated function api_key_manager.' -ForegroundColor Green
    }

    # Open WebUI hides models from non-admin users until the model is registered with an access grant.
    $registered = $null
    try { $registered = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/models/model?id=$functionId" -Headers $headers -TimeoutSec 30 }
    catch { }
    if ($null -eq $registered) {
        $grants = @()
        if ($GroupId.Count -eq 0) { $grants += @{ principal_type = 'user'; principal_id = '*'; permission = 'read' } }
        else { foreach ($id in $GroupId) { $grants += @{ principal_type = 'group'; principal_id = $id; permission = 'read' } } }
        $modelBody = @{
            id = $functionId
            name = 'API Key Manager'
            base_model_id = $null
            meta = @{ description = 'Type help to create and manage your own API key.' }
            params = @{}
            access_grants = $grants
            is_active = $true
        } | ConvertTo-Json -Depth 8
        Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/models/create" -Method Post -Headers $headers `
            -ContentType 'application/json' -Body $modelBody -TimeoutSec 30 | Out-Null
        $audience = if ($GroupId.Count -eq 0) { 'all signed-in users' } else { "groups: $($GroupId -join ', ')" }
        Write-Host "Registered the model for $audience." -ForegroundColor Green
    }
    else {
        Write-Host 'Model already registered; existing access grants were left unchanged.'
    }

    foreach ($modelId in $PublicModels) {
        $entry = $null
        try { $entry = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/models/model?id=$([uri]::EscapeDataString($modelId))" -Headers $headers -TimeoutSec 30 }
        catch { }
        if ($null -ne $entry) {
            Write-Host "Model $modelId already has an Open WebUI entry; its access grants were left unchanged."
            continue
        }
        $publicBody = @{
            id = $modelId
            name = $modelId
            base_model_id = $null
            meta = @{}
            params = @{}
            access_grants = @(@{ principal_type = 'user'; principal_id = '*'; permission = 'read' })
            is_active = $true
        } | ConvertTo-Json -Depth 8
        Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/models/create" -Method Post -Headers $headers `
            -ContentType 'application/json' -Body $publicBody -TimeoutSec 30 | Out-Null
        Write-Host "Made $modelId visible to every signed-in user." -ForegroundColor Green
    }
    Write-Host 'Select "API Key Manager" in the Open WebUI model picker and type "help".'
}
catch {
    Write-Error "Installing API Key Manager failed: $($_.Exception.Message)"
    exit 1
}
finally {
    $password = $null
}
