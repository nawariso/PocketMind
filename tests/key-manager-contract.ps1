$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

$pipePath = Join-Path $repoRoot 'openwebui/functions/api_key_manager.py'
Assert-True -Condition (Test-Path -LiteralPath $pipePath -PathType Leaf) -Message 'openwebui/functions/api_key_manager.py is missing'
if (Test-Path -LiteralPath $pipePath) {
    $pipe = Get-Content -Raw -LiteralPath $pipePath
    foreach ($term in @(
        'if __task__:',                       # title/tag/follow-up calls must never issue keys
        'user.get("role") not in ("user", "admin")', # pending users are refused
        'user_id={urllib.parse.quote(user_id)}',     # keys are always looked up by the caller
        '.get("user_id") == user_id',                # ownership is re-checked on the response
        '"duration": self.valves.key_duration',      # every key expires
        'default=20, ge=1, le=100',                  # total key cap per user
        '"models": [model]',                         # every key is limited to exactly one model
        'self._pick_model(',                         # the model must come from discovery or the manual allowlist
        'auto_discover_models',
        'pocketmind_rename_from',
        'self._litellm("GET", "/model/info")',
        'self._litellm("GET", "/v1/models")',         # includes database-backed Model Lab aliases
        'members_with_roles',                        # the key's team comes from LiteLLM team membership
        'get_super_admin_user',                      # mirrored groups are owned by an administrator
        'litellm_team_id',                           # sync only rewrites groups it created
        'Only administrators can run `sync`.',       # sync changes keys of other users
        'No models are enabled for API keys',        # empty catalogs/allowlists must never issue unrestricted keys
        '"max_parallel_requests"',
        '"rpm_limit"',
        '"tpm_limit"',
        'key_aliases',                               # deletion is by alias after the ownership filter
        'secrets.token_hex'
    )) {
        Assert-True -Condition ($pipe.Contains($term)) -Message "API Key Manager is missing guard: $term"
    }
    Assert-True -Condition ($pipe -notmatch 'master_key\s*:\s*str') `
        -Message 'API Key Manager must not store the LiteLLM master key in a Valve'
    Assert-True -Condition ($pipe -notmatch 'sk-[A-Za-z0-9]{16,}') `
        -Message 'API Key Manager must not contain a hard-coded key'
    Assert-True -Condition ($pipe -match 'os\.environ\.get\("LITELLM_MASTER_KEY"\) or os\.environ\.get\("OPENAI_API_KEY"\)') `
        -Message 'API Key Manager must read the master key from the container environment'
}

$installPath = Join-Path $repoRoot 'scripts/install-key-manager.ps1'
Assert-True -Condition (Test-Path -LiteralPath $installPath -PathType Leaf) -Message 'scripts/install-key-manager.ps1 is missing'
if (Test-Path -LiteralPath $installPath) {
    $install = Get-Content -Raw -LiteralPath $installPath
    Assert-True -Condition ($install -notmatch '\[string\]\s*\$(Admin)?Password') `
        -Message 'Installer must not accept the admin password as a parameter'
    Assert-True -Condition ($install.Contains('$PublicModels = @($PublicModels | ForEach-Object { $_ -split '','' }')) `
        -Message 'Installer must split comma-separated -PublicModels (pwsh -File passes them as one string)'
    Assert-True -Condition ($install.Contains('$GroupId = @($GroupId | ForEach-Object { $_ -split '','' }')) `
        -Message 'Installer must split comma-separated -GroupId'
    foreach ($term in @('OPENWEBUI_ADMIN_PASSWORD', '-AsSecureString', '/api/v1/functions/create', '/api/v1/models/create', 'access_grants', '$PublicModels')) {
        Assert-True -Condition ($install.Contains($term)) -Message "Installer is missing: $term"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" }
    throw "API Key Manager contract failed with $($failures.Count) issue(s)."
}
Write-Host 'API Key Manager contract passed.'
