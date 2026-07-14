param(
    [string]$Image = "litewaf/local-gateway:takeover-agent-dev",
    [string]$AdminPort = "18088",
    [string]$ApplicationPort = "18089",
    [switch]$KeepOnFailure
)

$ErrorActionPreference = "Stop"
$container = "litewaf-activation-agent-smoke"
$volume = "litewaf-activation-agent-smoke-runtime"
$runtime = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-activation-smoke-" + [guid]::NewGuid().ToString("N"))
$completed = $false

function Get-SHA256 {
    param([string]$Path)
    return "sha256:" + (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
}

function Get-Size {
    param([string]$Path)
    return (Get-Item -LiteralPath $Path).Length
}

try {
    $ErrorActionPreference = "Continue"
    docker rm -f $container 2>$null | Out-Null
    docker volume rm $volume 2>$null | Out-Null
    $ErrorActionPreference = "Stop"

    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    Set-Content -Path (Join-Path $runtime "active.json") -Encoding ascii -NoNewline -Value '{"version":"bootstrap","applications":[]}'
    New-Item -ItemType Directory -Force -Path (Join-Path $runtime "listeners") | Out-Null

    docker volume create $volume | Out-Null
    docker run -d --name $container `
        -p "${AdminPort}:8080" `
        -p "${ApplicationPort}:${ApplicationPort}" `
        --mount "source=$volume,target=/etc/litewaf" `
        -e LITEWAF_DEPLOYMENT_MODE=bridge `
        -e LITEWAF_ACTIVATION_POLL_INTERVAL=1 `
        -e LITEWAF_ACTIVATION_PROBE_TIMEOUT=5 `
        $Image | Out-Null
    Start-Sleep -Seconds 2

    $health = curl.exe -s -o NUL -w "%{http_code}" "http://127.0.0.1:$AdminPort/healthz"
    if ($health -ne "200") {
        throw "versioned bootstrap health failed with $health"
    }

    $version = "ruleset-0002"
    $candidate = Join-Path $runtime "releases\$version"
    $listeners = Join-Path $candidate "listeners"
    New-Item -ItemType Directory -Force -Path $listeners | Out-Null
    Set-Content -Path (Join-Path $candidate "active.json") -Encoding ascii -NoNewline -Value @"
{"version":"$version","applications":[{"id":1,"name":"Activation smoke","mode":"protect","enabled":true,"hosts":["app.activation.test"],"listeners":[{"port":$ApplicationPort,"protocol":"http","enabled":true}],"upstreams":[{"name":"primary","url":"http://127.0.0.1:65534","enabled":true}]}]}
"@
    Set-Content -Path (Join-Path $candidate "nginx.conf") -Encoding ascii -NoNewline -Value @'
worker_processes auto;
pid /var/run/litewaf-nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 128; }
http {
    access_log /dev/stdout;
    lua_package_path "/usr/local/openresty/nginx/lua/?.lua;;";
    lua_shared_dict litewaf_rate_limit 1m;
    lua_shared_dict litewaf_dynamic_ban 1m;
    lua_shared_dict litewaf_dynamic_ban_clear 1m;
    lua_shared_dict litewaf_dynamic_protection 1m;
    lua_shared_dict litewaf_metrics 1m;
    include /usr/local/openresty/nginx/conf/litewaf-realip.conf;
    include /usr/local/openresty/nginx/conf/litewaf-resolver.conf;
    init_by_lua_block { litewaf = require "litewaf" }
    init_worker_by_lua_block { litewaf.init_worker() }
    include /usr/local/openresty/nginx/conf/litewaf-admin.conf;
    include listeners/*.conf;
}
'@
    Set-Content -Path (Join-Path $listeners "applications.conf") -Encoding ascii -NoNewline -Value @"
server { listen $ApplicationPort default_server; server_name _; return 404; }
server {
    listen $ApplicationPort;
    server_name app.activation.test;
    location = /.litewaf/internal-ready {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        content_by_lua_block { litewaf.internal_ready() }
    }
    location / { return 204; }
}
"@
    Set-Content -Path (Join-Path $listeners "body-size.conf") -Encoding ascii -NoNewline -Value "client_max_body_size 50m;`n"

    $artifacts = @(
        @{ path = "active.json"; sha256 = Get-SHA256 (Join-Path $candidate "active.json"); size = Get-Size (Join-Path $candidate "active.json") },
        @{ path = "nginx.conf"; sha256 = Get-SHA256 (Join-Path $candidate "nginx.conf"); size = Get-Size (Join-Path $candidate "nginx.conf") },
        @{ path = "listeners/applications.conf"; sha256 = Get-SHA256 (Join-Path $listeners "applications.conf"); size = Get-Size (Join-Path $listeners "applications.conf") },
        @{ path = "listeners/body-size.conf"; sha256 = Get-SHA256 (Join-Path $listeners "body-size.conf"); size = Get-Size (Join-Path $listeners "body-size.conf") }
    )
    $manifest = [ordered]@{
        schema_version = 1
        version = $version
        generated_at = "2026-07-14T10:00:00Z"
        artifacts = $artifacts
        listeners = @(@{ port = [int]$ApplicationPort; protocol = "http"; host = "app.activation.test" })
    }
    $manifestPath = Join-Path $candidate "manifest.json"
    Set-Content -Path $manifestPath -Encoding ascii -NoNewline -Value ($manifest | ConvertTo-Json -Depth 8 -Compress)

    docker exec $container mkdir -p "/etc/litewaf/releases/$version"
    if ($LASTEXITCODE -ne 0) {
        throw "failed to create candidate directory in activation volume"
    }
    docker cp "${candidate}\." "${container}:/etc/litewaf/releases/$version"
    if ($LASTEXITCODE -ne 0) {
        throw "failed to copy candidate into activation volume"
    }

    $control = Join-Path $runtime "control"
    New-Item -ItemType Directory -Force -Path $control | Out-Null
    $request = [ordered]@{
        schema_version = 1
        version = $version
        checksum = Get-SHA256 $manifestPath
        requested_at = "2026-07-14T10:00:01Z"
        previous_version = "bootstrap"
    }
    $requestTemp = Join-Path $control "activate.json.tmp"
    Set-Content -Path $requestTemp -Encoding ascii -NoNewline -Value ($request | ConvertTo-Json -Compress)
    docker exec $container mkdir -p /etc/litewaf/control
    docker cp $requestTemp "${container}:/etc/litewaf/control/activate.json.tmp"
    docker exec $container mv -f /etc/litewaf/control/activate.json.tmp /etc/litewaf/control/activate.json
    if ($LASTEXITCODE -ne 0) {
        throw "failed to publish activation request"
    }

    $deadline = (Get-Date).AddSeconds(15)
    $status = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $ErrorActionPreference = "Continue"
            $statusJson = docker exec $container sh -c "cat /etc/litewaf/control/activation-status.json 2>/dev/null" 2>$null
            $statusExit = $LASTEXITCODE
            $ErrorActionPreference = "Stop"
            if ($statusExit -eq 0 -and $statusJson) {
                $status = ($statusJson -join "`n") | ConvertFrom-Json
                if ($status.status -in @("activated", "validation_failed", "reload_failed", "probe_failed", "rollback_failed")) {
                    break
                }
            }
        }
        catch {
            $ErrorActionPreference = "Stop"
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $status -or $status.status -ne "activated" -or $status.version -ne $version) {
        $logs = docker logs $container 2>&1
        throw "activation failed: status=$($status | ConvertTo-Json -Compress) logs=$($logs -join [Environment]::NewLine)"
    }
    $current = (docker exec $container readlink /etc/litewaf/current).Trim()
    if ($current -ne "releases/$version") {
        throw "unexpected current link: $current"
    }
    $appStatus = curl.exe -s -o NUL -w "%{http_code}" -H "Host: app.activation.test" "http://127.0.0.1:$ApplicationPort/"
    if ($appStatus -ne "204") {
        throw "activated application listener returned $appStatus"
    }

    Write-Host "activation-agent-smoke passed"
    $completed = $true
}
finally {
    if ($KeepOnFailure -and -not $completed) {
        Write-Warning "preserving $container, $volume, and $runtime for diagnosis"
    }
    else {
        $ErrorActionPreference = "Continue"
        docker rm -f $container 2>$null | Out-Null
        docker volume rm $volume 2>$null | Out-Null
        Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = "Stop"
    }
}
