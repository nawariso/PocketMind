param(
    [Parameter(Mandatory)] [string] $AdminEmail,
    [string] $OpenWebUiUrl = 'http://localhost:3000',
    # Role of accounts created or signing in later. `user` approves them at once; `pending` needs an administrator.
    [ValidateSet('user', 'pending')] [string] $DefaultUserRole = 'user',
    # Model that writes chat titles, tags, and follow-up suggestions (the OCR model cannot).
    [string] $TaskModel = 'default-general',
    # LiteLLM aliases made visible to every signed-in user. Open WebUI hides models from normal users until an entry exists.
    [string[]] $PublicModels = @('default-general', 'default-ocr'),
    # Open sign-up to everyone who can reach Open WebUI. Off by default; see the warning printed when it is on.
    [switch] $EnableSignup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

# `pwsh ./script.ps1 -PublicModels a,b` passes "a,b" as ONE string, so split comma lists ourselves.
$PublicModels = @($PublicModels | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Settings that Open WebUI keeps in its database (and so are not in Git). Safe to run again: every step reads the
# current value first and changes only what differs. The password is taken from OPENWEBUI_ADMIN_PASSWORD, or from
# WEBUI_ADMIN_PASSWORD in .env when the email is the bootstrap administrator's, or it is prompted for.
$password = $env:OPENWEBUI_ADMIN_PASSWORD
if ([string]::IsNullOrEmpty($password) -and (Test-Path -LiteralPath (Join-Path $script:PocRepoRoot '.env') -PathType Leaf)) {
    $fileValues = Get-PocEnv
    if ([string]$fileValues['WEBUI_ADMIN_EMAIL'] -eq $AdminEmail) { $password = [string]$fileValues['WEBUI_ADMIN_PASSWORD'] }
}
if ([string]::IsNullOrEmpty($password)) {
    $secure = Read-Host -Prompt "Open WebUI password for $AdminEmail" -AsSecureString
    $password = [System.Net.NetworkCredential]::new('', $secure).Password
}

function Invoke-OpenWebUi {
    param([string] $Method = 'GET', [string] $Path, $Body)
    $parameters = @{ Uri = "$OpenWebUiUrl$Path"; Method = $Method; Headers = $script:headers; TimeoutSec = 60 }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters['ContentType'] = 'application/json'
        $parameters['Body'] = $Body | ConvertTo-Json -Depth 20
    }
    return Invoke-RestMethod @parameters
}

try {
    $session = Invoke-RestMethod -Uri "$OpenWebUiUrl/api/v1/auths/signin" -Method Post -ContentType 'application/json' `
        -Body (@{ email = $AdminEmail; password = $password } | ConvertTo-Json) -TimeoutSec 30
    if ($session.role -ne 'admin') { throw "$AdminEmail is not an Open WebUI administrator." }
    $script:headers = @{ Authorization = "Bearer $($session.token)" }

    # 1. Role of new accounts
    $adminConfig = Invoke-OpenWebUi -Path '/api/v1/auths/admin/config'
    if ($adminConfig.DEFAULT_USER_ROLE -ne $DefaultUserRole) {
        $adminConfig.DEFAULT_USER_ROLE = $DefaultUserRole
        Invoke-OpenWebUi -Method Post -Path '/api/v1/auths/admin/config' -Body $adminConfig | Out-Null
        Write-Host "Default role for new accounts set to '$DefaultUserRole'." -ForegroundColor Green
    }
    else { Write-Host "Default role for new accounts is already '$DefaultUserRole'." }
    if ($EnableSignup -and -not $adminConfig.ENABLE_SIGNUP) {
        $adminConfig.ENABLE_SIGNUP = $true
        Invoke-OpenWebUi -Method Post -Path '/api/v1/auths/admin/config' -Body $adminConfig | Out-Null
        Write-Host 'Sign-up opened (-EnableSignup).' -ForegroundColor Yellow
    }
    $signupState = if ($adminConfig.ENABLE_SIGNUP) { 'OPEN' } else { 'closed' }
    Write-Host "Sign-up is $signupState (change it in Admin Panel -> Settings -> General)."
    if ($adminConfig.ENABLE_SIGNUP -and $DefaultUserRole -eq 'user') {
        Write-Warning 'Sign-up is open and new accounts are approved at once: anyone who can reach Open WebUI can chat and create API keys, there is no email-domain limit, email addresses are not verified, and team attribution by email can be claimed by anyone.'
    }

    # 2. Task model for titles, tags, and follow-ups
    $taskConfig = Invoke-OpenWebUi -Path '/api/v1/tasks/config'
    if ($taskConfig.TASK_MODEL_EXTERNAL -ne $TaskModel) {
        $taskConfig.TASK_MODEL_EXTERNAL = $TaskModel
        Invoke-OpenWebUi -Method Post -Path '/api/v1/tasks/config/update' -Body $taskConfig | Out-Null
        Write-Host "Task model set to '$TaskModel'." -ForegroundColor Green
    }
    else { Write-Host "Task model is already '$TaskModel'." }

    # 3. Models visible to normal users. default-ocr is vision-only and cannot take tool definitions.
    foreach ($modelId in $PublicModels) {
        $entry = $null
        try { $entry = Invoke-OpenWebUi -Path "/api/v1/models/model?id=$([uri]::EscapeDataString($modelId))" }
        catch { }
        $capabilities = if ($modelId -eq 'default-ocr') { [pscustomobject]@{ vision = $true; builtin_tools = $false } } else { $null }
        if ($null -eq $entry) {
            $body = @{
                id = $modelId; name = $modelId; base_model_id = $null
                meta = @{ capabilities = $capabilities }
                params = @{}
                access_grants = @(@{ principal_type = 'user'; principal_id = '*'; permission = 'read' })
                is_active = $true
            }
            Invoke-OpenWebUi -Method Post -Path '/api/v1/models/create' -Body $body | Out-Null
            Write-Host "Model $modelId made visible to every signed-in user." -ForegroundColor Green
            continue
        }
        if ($modelId -eq 'default-ocr') {
            $current = $null
            if ($null -ne $entry.meta.capabilities -and $null -ne $entry.meta.capabilities.PSObject.Properties['builtin_tools']) {
                $current = $entry.meta.capabilities.builtin_tools
            }
            if ($current -ne $false) {
                # Capabilities that were never set are created with vision on; ones an administrator set are kept as they are.
                if ($null -eq $entry.meta.capabilities) { $entry.meta | Add-Member -NotePropertyName capabilities -NotePropertyValue ([pscustomobject]@{ vision = $true }) -Force }
                $entry.meta.capabilities | Add-Member -NotePropertyName builtin_tools -NotePropertyValue $false -Force
                $body = @{
                    id = $entry.id; name = $entry.name; base_model_id = $entry.base_model_id
                    meta = $entry.meta; params = $entry.params
                    access_grants = @($entry.access_grants | ForEach-Object { @{ principal_type = $_.principal_type; principal_id = $_.principal_id; permission = $_.permission } })
                    is_active = $entry.is_active
                }
                Invoke-OpenWebUi -Method Post -Path '/api/v1/models/model/update' -Body $body | Out-Null
                Write-Host 'Model default-ocr: Built-in Tools turned off (it does not support tools).' -ForegroundColor Green
            }
            else { Write-Host 'Model default-ocr already has Built-in Tools off.' }
        }
        else { Write-Host "Model $modelId already has an Open WebUI entry; its access was left unchanged." }
    }
    Write-Host 'Open WebUI settings are in place.' -ForegroundColor Green
}
catch {
    Write-Error "Configuring Open WebUI failed: $($_.Exception.Message) $($_.ErrorDetails.Message)"
    exit 1
}
finally {
    $password = $null
}
