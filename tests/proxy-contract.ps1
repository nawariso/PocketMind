$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/common.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

foreach ($relativePath in @('docker-compose.proxy.yml', 'nginx/nginx.conf', 'nginx/local/.gitkeep')) {
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf) -Message "$relativePath is missing"
}

# --- nginx.conf: what is exposed and how
$nginxPath = Join-Path $repoRoot 'nginx/nginx.conf'
if (Test-Path -LiteralPath $nginxPath) {
    $nginx = Get-Content -Raw -LiteralPath $nginxPath
    foreach ($term in @(
        'server_tokens off;',
        'resolver 127.0.0.11',                                 # containers are recreated; resolve at request time
        'set $webui http://open-webui:8080;',
        'set $litellm http://litellm:4000;',
        'proxy_pass $litellm$uri$is_args$args;',               # forward the path that matched, not the raw one
        'limit_req zone=api burst=60 nodelay;',
        'limit_req zone=login burst=10 nodelay;',
        '~^/api/v1/auths/ $binary_remote_addr;',
        'limit_req_status 429;',
        'client_max_body_size 50m;',
        'proxy_set_header Upgrade $http_upgrade;',             # Open WebUI socket.io
        'proxy_buffering off;',                                # streaming responses
        'proxy_read_timeout 600s;',
        'location = /nginx-health',
        'limit_except GET POST OPTIONS'
    )) {
        Assert-True -Condition $nginx.Contains($term) -Message "nginx.conf is missing: $term"
    }
    $allowRegex = 'location ~ ^/v1/(chat/completions|completions|embeddings|responses|models(/[^/]+)?)$ {'
    Assert-True -Condition $nginx.Contains($allowRegex) -Message 'nginx.conf must allow only the listed LiteLLM inference endpoints'
    Assert-True -Condition ([regex]::Matches($nginx, 'include /etc/nginx/local/\*\.conf;').Count -eq 2) `
        -Message 'nginx.conf must include local rules in both servers'
    Assert-True -Condition ([regex]::Matches($nginx, 'limit_req zone=api').Count -eq 1) `
        -Message 'The per-address API rate limit must apply to the API server only'
    Assert-True -Condition ([regex]::Matches($nginx, 'limit_req zone=login').Count -eq 1) `
        -Message 'Open WebUI may only be rate-limited on its sign-in endpoints'

    $webServer = ($nginx -split 'listen 8081 default_server;', 2)[0]
    Assert-True -Condition (-not $webServer.Contains('limit_req zone=api')) -Message 'The Open WebUI server must not use the API rate limit'
    $apiServer = ($nginx -split 'listen 8081 default_server;', 2)[1]
    Assert-True -Condition ($null -ne $apiServer -and $apiServer -match '(?s)location / \{\s*return 404;\s*\}') `
        -Message 'The API server must answer 404 for every path that is not allow-listed'
    if ($null -ne $apiServer) {
        foreach ($forbidden in @('location /ui', 'location /key', 'location /model', 'location /team', 'location /user', 'openapi', 'metrics')) {
            Assert-True -Condition (-not $apiServer.Contains($forbidden)) -Message "The API server must not route $forbidden"
        }
        Assert-True -Condition (-not $apiServer.Contains('proxy_pass http://litellm:4000;')) `
            -Message 'The API server must not proxy LiteLLM paths it did not allow-list'
    }
    Assert-True -Condition ($nginx -notmatch 'log_format') -Message 'nginx must keep the default access log format, which does not record request headers'
}

# --- compose overlay: rendered with every profile
# The project .env is read by `docker compose config` unless the process environment overrides it, so every
# render pins the proxy settings; the defaults themselves are asserted from the overlay text below.
$defaultProxyEnvironment = @{ PROXY_BIND_ADDRESS = '0.0.0.0'; PROXY_WEBUI_PORT = '8480'; PROXY_API_PORT = '8481' }
$overlayText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'docker-compose.proxy.yml')
foreach ($term in @('${PROXY_BIND_ADDRESS:-0.0.0.0}', '${PROXY_WEBUI_PORT:-8480}', '${PROXY_API_PORT:-8481}')) {
    Assert-True -Condition $overlayText.Contains($term) -Message "docker-compose.proxy.yml must default to $term"
}

function Get-RenderedCompose {
    param([string[]] $ComposeFiles, [hashtable] $Environment = @{})
    $arguments = @('compose')
    foreach ($file in $ComposeFiles) { $arguments += @('-f', (Join-Path $repoRoot $file)) }
    $arguments += @('config', '--format', 'json')
    $saved = @{}
    foreach ($name in $Environment.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $Environment[$name]) }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $rendered = & docker @arguments 2>$null; $exit = $LASTEXITCODE }
    finally {
        $ErrorActionPreference = $previous
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    if ($exit -ne 0) { $script:failures.Add("Compose rendering failed for $($ComposeFiles -join ' + ') + the proxy overlay"); return $null }
    return ($rendered -join [Environment]::NewLine) | ConvertFrom-Json
}

foreach ($base in @(@('docker-compose.yml'), @('docker-compose.yml', 'docker-compose.nvidia.yml'), @('docker-compose.native-ollama.yml'))) {
    $label = ($base + 'docker-compose.proxy.yml') -join ' + '
    $without = Get-RenderedCompose -ComposeFiles $base -Environment $defaultProxyEnvironment
    $with = Get-RenderedCompose -ComposeFiles ($base + 'docker-compose.proxy.yml') -Environment $defaultProxyEnvironment
    if ($null -eq $without -or $null -eq $with) { continue }

    $nginxProperty = $with.services.PSObject.Properties['nginx']
    Assert-True -Condition ($null -ne $nginxProperty) -Message "$label does not define the nginx service"
    if ($null -eq $nginxProperty) { continue }
    $service = $nginxProperty.Value

    $published = @($service.ports | ForEach-Object { '{0}:{1}->{2}' -f $_.host_ip, $_.published, $_.target })
    Assert-True -Condition (($published -join '|') -eq '0.0.0.0:8480->8080|0.0.0.0:8481->8081') `
        -Message "$label must publish only 8080/8081 of the proxy, listening on 0.0.0.0 by default (got $($published -join ', '))"
    Assert-True -Condition ($null -eq $without.services.PSObject.Properties['nginx']) -Message "$label base files must not define nginx"
    foreach ($other in $with.services.PSObject.Properties | Where-Object { $_.Name -ne 'nginx' }) {
        $beforeProperty = $without.services.PSObject.Properties[$other.Name]
        $beforePorts = if ($null -eq $beforeProperty -or $null -eq $beforeProperty.Value.PSObject.Properties['ports']) { 0 } else { @($beforeProperty.Value.ports).Count }
        $afterPorts = if ($null -eq $other.Value.PSObject.Properties['ports']) { 0 } else { @($other.Value.ports).Count }
        Assert-True -Condition ($beforePorts -eq $afterPorts) -Message "$label must not change the ports of service '$($other.Name)'"
    }
    # Open WebUI holds the LiteLLM master key; its passthrough route would forward arbitrary paths upstream with it.
    $passthrough = $with.services.'open-webui'.environment.PSObject.Properties['ENABLE_OPENAI_API_PASSTHROUGH']
    Assert-True -Condition ($null -ne $passthrough -and [string]$passthrough.Value -eq 'false') `
        -Message "$label must keep ENABLE_OPENAI_API_PASSTHROUGH=false on Open WebUI"
    foreach ($adminVariable in @('WEBUI_ADMIN_EMAIL', 'WEBUI_ADMIN_PASSWORD', 'WEBUI_ADMIN_NAME')) {
        Assert-True -Condition ($null -ne $with.services.'open-webui'.environment.PSObject.Properties[$adminVariable]) `
            -Message "$label must pass $adminVariable to Open WebUI (first-start administrator)"
    }
    Assert-True -Condition ($service.read_only -eq $true) -Message "$label nginx must run with a read-only root filesystem"
    Assert-True -Condition (@($service.cap_drop) -contains 'ALL') -Message "$label nginx must drop all capabilities"
    Assert-True -Condition (@($service.security_opt) -contains 'no-new-privileges:true') -Message "$label nginx must set no-new-privileges"
    Assert-True -Condition (@($service.networks.PSObject.Properties.Name) -contains 'ai-net') -Message "$label nginx must join ai-net"
    foreach ($dependency in @('open-webui', 'litellm')) {
        $property = $service.depends_on.PSObject.Properties[$dependency]
        Assert-True -Condition ($null -ne $property -and $property.Value.condition -eq 'service_healthy') `
            -Message "$label nginx must wait for $dependency to be healthy"
    }
}

# The bind address and ports are configurable: prove a single interface and a loopback-only setup are honoured.
$custom = Get-RenderedCompose -ComposeFiles @('docker-compose.native-ollama.yml', 'docker-compose.proxy.yml') -Environment @{ PROXY_BIND_ADDRESS = '10.1.2.3'; PROXY_WEBUI_PORT = '9001'; PROXY_API_PORT = '9002' }
if ($null -ne $custom) {
    $published = @($custom.services.nginx.ports | ForEach-Object { '{0}:{1}' -f $_.host_ip, $_.published })
    Assert-True -Condition (($published -join '|') -eq '10.1.2.3:9001|10.1.2.3:9002') -Message 'PROXY_BIND_ADDRESS and the proxy ports must be configurable'
}
$local = Get-RenderedCompose -ComposeFiles @('docker-compose.native-ollama.yml', 'docker-compose.proxy.yml') -Environment @{ PROXY_BIND_ADDRESS = '127.0.0.1'; PROXY_WEBUI_PORT = '8480'; PROXY_API_PORT = '8481' }
if ($null -ne $local) {
    $published = @($local.services.nginx.ports | ForEach-Object { '{0}:{1}' -f $_.host_ip, $_.published })
    Assert-True -Condition (($published -join '|') -eq '127.0.0.1:8480|127.0.0.1:8481') -Message 'PROXY_BIND_ADDRESS=127.0.0.1 must keep the proxy on this host'
}

# --- one switch for every script (a later run without the overlay would remove nginx as an orphan)
$savedProxy = $env:PROXY_ENABLED
try {
    $env:PROXY_ENABLED = 'true'
    Assert-True -Condition (Test-PocProxyEnabled) -Message 'PROXY_ENABLED=true must enable the proxy overlay'
    $env:PROXY_ENABLED = 'false'
    Assert-True -Condition (-not (Test-PocProxyEnabled)) -Message 'PROXY_ENABLED=false must disable the proxy overlay'
}
finally { $env:PROXY_ENABLED = $savedProxy }
$commonScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'scripts/common.ps1')
Assert-True -Condition ($commonScript.Contains("if (Test-PocProxyEnabled) { `$dockerArguments += @('-f', (Get-PocProxyComposeFile)) }")) `
    -Message 'Invoke-PocCompose must add the proxy overlay whenever the proxy is enabled'

$envExample = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.env.example')
foreach ($term in @('WEBUI_ADMIN_EMAIL=', 'WEBUI_ADMIN_PASSWORD=', 'PROXY_ENABLED=false', 'PROXY_BIND_ADDRESS=0.0.0.0', 'PROXY_WEBUI_PORT=8480', 'PROXY_API_PORT=8481', 'NGINX_IMAGE=nginx:1.30-alpine')) {
    Assert-True -Condition $envExample.Contains($term) -Message ".env.example is missing: $term"
}
$gitignore = Get-Content -Raw -LiteralPath (Join-Path $repoRoot '.gitignore')
Assert-True -Condition $gitignore.Contains('nginx/local/*.conf') -Message 'Local nginx rules must be git-ignored'

# --- syntax check with the real nginx binary (skipped when the image cannot be pulled)
if ($null -ne (Get-Command docker -ErrorAction SilentlyContinue)) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker run --rm -v "$($nginxPath):/etc/nginx/nginx.conf:ro" -v "$(Join-Path $repoRoot 'nginx/local'):/etc/nginx/local:ro" nginx:1.30-alpine nginx -t 2>&1
        $text = $output -join "`n"
    }
    finally { $ErrorActionPreference = $previous }
    if ($text -match 'syntax is ok') { }
    elseif ($text -match 'emerg') { $failures.Add("nginx rejected nginx.conf: $text") }
    else { Write-Warning 'Skipped the nginx -t syntax check: the nginx image could not be run.' }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host " - $_" }
    throw "Proxy contract failed with $($failures.Count) issue(s)."
}
Write-Host 'Proxy contract passed.'
