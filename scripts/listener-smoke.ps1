param(
  [string]$Image = "litewaf/litewaf-gateway:latest",
  [string]$HttpPort = "18080",
  [string]$HttpsPort = "18443",
  [string]$CustomHttpPort = "19981",
  [switch]$Build
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$HostHeader = "listener.local",
    [switch]$Insecure
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-H", "Host: $HostHeader")
  if ($Insecure) {
    $args = @("-k") + $args
  }
  $args += $Url
  curl.exe @args
}

function Assert-Status {
  param(
    [string]$Name,
    [string]$Actual,
    [string]$Expected
  )
  Write-Output "$Name=$Actual"
  if ($Actual -ne $Expected) {
    throw "expected $Name to return $Expected, got $Actual"
  }
}

$network = "litewaf-listener-smoke-net"
$upstream = "litewaf-listener-smoke-upstream"
$gateway = "litewaf-listener-smoke-gateway"
$runtime = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-listener-smoke-" + [guid]::NewGuid().ToString("N"))

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  $listenerDir = Join-Path $runtime "listeners"
  $certDir = Join-Path $runtime "certs\1"
  New-Item -ItemType Directory -Force -Path $listenerDir, $certDir | Out-Null

  docker run --rm `
    -v "${certDir}:/certs" `
    alpine/openssl:3.5.0 `
    req -x509 -newkey rsa:2048 -nodes -days 1 `
    -subj "/CN=listener.local" `
    -keyout /certs/privkey.pem `
    -out /certs/fullchain.pem | Out-Null

  Set-Content -Path (Join-Path $runtime "active.json") -Encoding ascii -Value @'
{
  "version": "listener-smoke",
  "generated_at": "2026-06-06T00:00:00Z",
  "applications": [
    {
      "id": 501,
      "name": "Listener smoke HTTP",
      "mode": "protect",
      "enabled": true,
      "hosts": ["listener.local"],
      "listeners": [{"port": 80, "protocol": "http", "enabled": true}],
      "upstreams": [{"name": "primary", "url": "http://litewaf-listener-smoke-upstream:80", "weight": 1, "enabled": true}],
      "rules": [],
      "policy": {}
    },
    {
      "id": 502,
      "name": "Listener smoke HTTPS",
      "mode": "protect",
      "enabled": true,
      "hosts": ["listener.local"],
      "listeners": [{"port": 443, "protocol": "https", "certificate_id": 1, "enabled": true}],
      "upstreams": [{"name": "primary", "url": "http://litewaf-listener-smoke-upstream:80", "weight": 1, "enabled": true}],
      "rules": [],
      "policy": {}
    },
    {
      "id": 503,
      "name": "Listener smoke custom",
      "mode": "protect",
      "enabled": true,
      "hosts": ["listener.local"],
      "listeners": [{"port": 9981, "protocol": "http", "enabled": true}],
      "upstreams": [{"name": "primary", "url": "http://litewaf-listener-smoke-upstream:80", "weight": 1, "enabled": true}],
      "rules": [],
      "policy": {}
    }
  ]
}
'@

  Set-Content -Path (Join-Path $listenerDir "applications.conf") -Encoding ascii -Value @"
server {
    listen 80;
    server_name listener.local;
    location / {
        set `$litewaf_upstream "";
        set `$litewaf_request_id "";
        set `$litewaf_client_ip `$remote_addr;
        access_by_lua_block { litewaf.access() }
        header_filter_by_lua_block { litewaf.header_filter() }
        body_filter_by_lua_block { litewaf.body_filter() }
        log_by_lua_block { litewaf.log() }
        proxy_http_version 1.1;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$litewaf_client_ip;
        proxy_set_header X-Request-ID `$litewaf_request_id;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        proxy_pass `$litewaf_upstream;
    }
}

server {
    listen 443 ssl;
    server_name listener.local;
    ssl_certificate /etc/litewaf/certs/1/fullchain.pem;
    ssl_certificate_key /etc/litewaf/certs/1/privkey.pem;
    location / {
        set `$litewaf_upstream "";
        set `$litewaf_request_id "";
        set `$litewaf_client_ip `$remote_addr;
        access_by_lua_block { litewaf.access() }
        header_filter_by_lua_block { litewaf.header_filter() }
        body_filter_by_lua_block { litewaf.body_filter() }
        log_by_lua_block { litewaf.log() }
        proxy_http_version 1.1;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$litewaf_client_ip;
        proxy_set_header X-Request-ID `$litewaf_request_id;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        proxy_pass `$litewaf_upstream;
    }
}

server {
    listen 9981;
    server_name listener.local;
    location / {
        set `$litewaf_upstream "";
        set `$litewaf_request_id "";
        set `$litewaf_client_ip `$remote_addr;
        access_by_lua_block { litewaf.access() }
        header_filter_by_lua_block { litewaf.header_filter() }
        body_filter_by_lua_block { litewaf.body_filter() }
        log_by_lua_block { litewaf.log() }
        proxy_http_version 1.1;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$litewaf_client_ip;
        proxy_set_header X-Request-ID `$litewaf_request_id;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        proxy_pass `$litewaf_upstream;
    }
}
"@

  if ($Build) {
    docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "docker build failed for $Image"
    }
  } else {
    docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "image $Image not found; build it first or rerun with -Build"
    }
  }
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network `
    -p "${HttpPort}:80" `
    -p "${HttpsPort}:443" `
    -p "${CustomHttpPort}:9981" `
    -v "${runtime}:/etc/litewaf" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/active.json `
    $Image | Out-Null
  Start-Sleep -Seconds 3

  $ErrorActionPreference = "Continue"
  $configCheck = docker exec $gateway /usr/local/openresty/bin/openresty -t 2>&1
  $configExit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($configExit -ne 0) {
    throw "openresty config check failed: $configCheck"
  }

  Assert-Status "http_80" (Invoke-SmokeRequest "http://localhost:$HttpPort/") "200"
  Assert-Status "https_443" (Invoke-SmokeRequest "https://localhost:$HttpsPort/" -Insecure) "200"
  Assert-Status "custom_http_9981" (Invoke-SmokeRequest "http://localhost:$CustomHttpPort/") "200"
  Assert-Status "wrong_port_match" (Invoke-SmokeRequest "http://localhost:$HttpPort/" -HostHeader "missing.local") "404"

  Write-Output "listener-smoke passed"
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  Remove-Item -Recurse -Force $runtime -ErrorAction SilentlyContinue
  $ErrorActionPreference = "Stop"
}
