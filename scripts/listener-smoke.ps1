param(
  [string]$Image = "litewaf/local-gateway:takeover-dev",
  [string]$HttpPort = "18084",
  [string]$HttpsPort = "18443",
  [string]$CustomHttpPort = "19981",
  [string]$AdminPort = "18085",
  [string]$TrustedHttpPort = "18086",
  [string]$OpenRestyRuntimeImage = "litewaf/local-gateway:dev",
  [switch]$Build
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$HostHeader = "a.listener.local",
    [switch]$Insecure
  )
  $args = @("-sS", "-H", "Host: $HostHeader")
  if ($Insecure) {
    $args = @("-k") + $args
  }
  $args += $Url
  return curl.exe @args
}

function Invoke-SmokeStatus {
  param(
    [string]$Url,
    [string]$HostHeader = "a.listener.local",
    [switch]$Insecure
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-H", "Host: $HostHeader")
  if ($Insecure) {
    $args = @("-k") + $args
  }
  $args += $Url
  return curl.exe @args
}

function Assert-Equal {
  param([string]$Name, [string]$Actual, [string]$Expected)
  Write-Output "$Name=$Actual"
  if ($Actual -ne $Expected) {
    throw "expected $Name to equal $Expected, got $Actual"
  }
}

function Assert-Match {
  param([string]$Name, [string]$Actual, [string]$Pattern)
  Write-Output "$Name=$Actual"
  if ($Actual -notmatch $Pattern) {
    throw "expected $Name to match $Pattern, got $Actual"
  }
}

$network = "litewaf-listener-smoke-net"
$upstreamA = "litewaf-listener-smoke-upstream-a"
$upstreamB = "litewaf-listener-smoke-upstream-b"
$gateway = "litewaf-listener-smoke-gateway"
$trustedGateway = "litewaf-listener-smoke-gateway-trusted"
$runtime = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-listener-smoke-" + [guid]::NewGuid().ToString("N"))
$largePayload = Join-Path $runtime "large-request.bin"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $trustedGateway $upstreamA $upstreamB 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  if ($Build) {
    docker build --build-arg "OPENRESTY_RUNTIME_IMAGE=$OpenRestyRuntimeImage" -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "docker build failed for $Image"
    }
  } else {
    docker image inspect $Image *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "image $Image not found; build it first or rerun with -Build"
    }
  }

  $listenerDir = Join-Path $runtime "listeners"
  $certificateDir = Join-Path $runtime "certificates"
  New-Item -ItemType Directory -Force -Path $listenerDir, $certificateDir | Out-Null

  docker run --rm -v "${certificateDir}:/certificates" --entrypoint openssl $Image `
    req -x509 -newkey rsa:2048 -nodes -days 1 `
    -subj "/CN=secure.listener.local" `
    -addext "subjectAltName=DNS:secure.listener.local" `
    -keyout /certificates/1.key `
    -out /certificates/1.crt | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "certificate generation failed"
  }

  Set-Content -Path (Join-Path $runtime "active.json") -Encoding ascii -Value @'
{
  "version": "listener-smoke",
  "generated_at": "2026-07-14T00:00:00Z",
  "applications": [
    {"id":501,"name":"Listener A","mode":"protect","enabled":true,"hosts":["a.listener.local"],"listeners":[{"port":80,"protocol":"http","enabled":true}],"upstreams":[{"name":"primary","url":"http://litewaf-listener-smoke-upstream-a:80","weight":1,"enabled":true}],"proxy_config":{"websocket_enabled":true},"rules":[],"policy":{}},
    {"id":502,"name":"Listener B","mode":"protect","enabled":true,"hosts":["b.listener.local"],"listeners":[{"port":80,"protocol":"http","enabled":true}],"upstreams":[{"name":"primary","url":"http://litewaf-listener-smoke-upstream-b:80","weight":1,"enabled":true}],"rules":[],"policy":{}},
    {"id":503,"name":"Listener HTTPS","mode":"protect","enabled":true,"hosts":["secure.listener.local"],"listeners":[{"port":443,"protocol":"https","certificate_id":1,"enabled":true}],"upstreams":[{"name":"primary","url":"http://litewaf-listener-smoke-upstream-a:80","weight":1,"enabled":true}],"rules":[],"policy":{}},
    {"id":504,"name":"Listener Custom","mode":"protect","enabled":true,"hosts":["custom.listener.local"],"listeners":[{"port":9981,"protocol":"http","enabled":true}],"upstreams":[{"name":"primary","url":"http://litewaf-listener-smoke-upstream-b:80","weight":1,"enabled":true}],"rules":[],"policy":{}}
  ]
}
'@

  $sharedLocation = @'
        set $litewaf_upstream "";
        set $litewaf_request_id "";
        set $litewaf_client_ip $remote_addr;
        access_by_lua_block { litewaf.access() }
        header_filter_by_lua_block { litewaf.header_filter() }
        body_filter_by_lua_block { litewaf.body_filter() }
        log_by_lua_block { litewaf.log() }
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $litewaf_client_ip;
        proxy_set_header X-Request-ID $litewaf_request_id;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass $litewaf_upstream;
'@
  $internalReady = @'
    location = /.litewaf/internal-ready {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        content_by_lua_block { litewaf.internal_ready() }
    }
'@
  Set-Content -Path (Join-Path $listenerDir "applications.conf") -Encoding ascii -Value @"
server { listen 80 default_server; server_name _; return 404; }
server {
    listen 80;
    server_name a.listener.local;
$internalReady
    location / {
$sharedLocation
    }
}
server {
    listen 80;
    server_name b.listener.local;
$internalReady
    location / {
$sharedLocation
    }
}
server { listen 443 ssl default_server; ssl_reject_handshake on; }
server {
    listen 443 ssl;
    server_name secure.listener.local;
    ssl_certificate /etc/litewaf/certificates/1.crt;
    ssl_certificate_key /etc/litewaf/certificates/1.key;
$internalReady
    location / {
$sharedLocation
    }
}
server { listen 9981 default_server; server_name _; return 404; }
server {
    listen 9981;
    server_name custom.listener.local;
$internalReady
    location / {
$sharedLocation
    }
}
"@
  Set-Content -Path (Join-Path $listenerDir "body-size.conf") -Encoding ascii -Value "client_max_body_size 50m;"

  $upstreamAConfig = Join-Path $runtime "upstream-a.conf"
  $upstreamBConfig = Join-Path $runtime "upstream-b.conf"
  Set-Content -Path $upstreamAConfig -Encoding ascii -Value @'
events {}
http {
  client_max_body_size 5m;
  server {
    listen 80;
    location = /websocket-test {
      default_type text/plain;
      return 200 "upgrade=$http_upgrade|connection=$http_connection";
    }
    location = /large-request {
      default_type text/plain;
      content_by_lua_block {
        ngx.req.read_body()
        ngx.say(ngx.var.content_length or "0")
      }
    }
    location = /slow {
      default_type text/plain;
      content_by_lua_block {
        ngx.sleep(4)
        ngx.say("slow-ok")
      }
    }
    location / {
      default_type text/plain;
      return 200 "app-a|$http_x_real_ip|$http_x_forwarded_for|$http_x_forwarded_proto|$http_x_request_id|$http_host";
    }
  }
}
'@
  Set-Content -Path $upstreamBConfig -Encoding ascii -Value 'events {} http { server { listen 80; location / { default_type text/plain; return 200 "app-b|$http_x_real_ip|$http_x_forwarded_for|$http_x_forwarded_proto|$http_x_request_id|$http_host"; } } }'

  docker network create $network | Out-Null
  docker run -d --name $upstreamA --network $network -v "${upstreamAConfig}:/tmp/upstream.conf:ro" --entrypoint /usr/local/openresty/bin/openresty $Image -c /tmp/upstream.conf -g "daemon off;" | Out-Null
  docker run -d --name $upstreamB --network $network -v "${upstreamBConfig}:/tmp/upstream.conf:ro" --entrypoint /usr/local/openresty/bin/openresty $Image -c /tmp/upstream.conf -g "daemon off;" | Out-Null
  docker run -d --name $gateway --network $network `
    -p "${AdminPort}:8080" `
    -p "${HttpPort}:80" `
    -p "${HttpsPort}:443" `
    -p "${CustomHttpPort}:9981" `
    -v "${runtime}:/etc/litewaf" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/active.json `
    -e LITEWAF_DEPLOYMENT_MODE=bridge `
    $Image | Out-Null
  docker run -d --name $trustedGateway --network $network `
    -p "${TrustedHttpPort}:80" `
    -v "${runtime}:/etc/litewaf" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/active.json `
    -e LITEWAF_DEPLOYMENT_MODE=bridge `
    -e LITEWAF_REAL_IP_TRUSTED_CIDRS=172.16.0.0/12 `
    -e LITEWAF_REAL_IP_HEADER=X-Forwarded-For `
    -e LITEWAF_REAL_IP_RECURSIVE=on `
    $Image | Out-Null
  Start-Sleep -Seconds 2

  $ErrorActionPreference = "Continue"
  $configCheck = docker exec $gateway /usr/local/openresty/bin/openresty -t 2>&1
  $configExit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($configExit -ne 0) {
    throw "openresty config check failed: $configCheck"
  }

  Assert-Equal "admin_health" (Invoke-SmokeStatus "http://127.0.0.1:$AdminPort/healthz") "200"
  Assert-Match "runtime_version" (Invoke-SmokeRequest "http://127.0.0.1:$AdminPort/runtime-version") '"version":"listener-smoke"'
  Assert-Match "host_a" (Invoke-SmokeRequest "http://127.0.0.1:$HttpPort/" -HostHeader "a.listener.local") '^app-a\|[^|]+\|[^|]+\|http\|[^|]+\|a\.listener\.local$'
  Assert-Match "host_b" (Invoke-SmokeRequest "http://127.0.0.1:$HttpPort/" -HostHeader "b.listener.local") '^app-b\|[^|]+\|[^|]+\|http\|[^|]+\|b\.listener\.local$'
  Assert-Match "untrusted_forwarded_identity" (curl.exe -sS -H "Host: a.listener.local" -H "X-Forwarded-For: 198.51.100.10" "http://127.0.0.1:$HttpPort/") '^app-a\|(?!198\.51\.100\.10\|)'
  Assert-Match "trusted_forwarded_identity" (curl.exe -sS -H "Host: a.listener.local" -H "X-Forwarded-For: 198.51.100.10" "http://127.0.0.1:$TrustedHttpPort/") '^app-a\|198\.51\.100\.10\|'
  Assert-Equal "unknown_host" (Invoke-SmokeStatus "http://127.0.0.1:$HttpPort/" -HostHeader "unknown.listener.local") "404"
  Assert-Match "application_health_path" (Invoke-SmokeRequest "http://127.0.0.1:$HttpPort/healthz" -HostHeader "a.listener.local") '^app-a\|'
  Assert-Match "application_metrics_path" (Invoke-SmokeRequest "http://127.0.0.1:$HttpPort/metrics" -HostHeader "a.listener.local") '^app-a\|'
  Assert-Equal "external_internal_ready" (Invoke-SmokeStatus "http://127.0.0.1:$HttpPort/.litewaf/internal-ready" -HostHeader "a.listener.local") "403"
  Assert-Match "https_sni" (curl.exe -k -sS --resolve "secure.listener.local:${HttpsPort}:127.0.0.1" "https://secure.listener.local:${HttpsPort}/") '^app-a\|[^|]+\|[^|]+\|https\|[^|]+\|secure\.listener\.local$'
  Assert-Match "custom_listener" (Invoke-SmokeRequest "http://127.0.0.1:$CustomHttpPort/" -HostHeader "custom.listener.local") '^app-b\|'
  Assert-Equal "websocket_headers" (curl.exe -sS -H "Host: a.listener.local" -H "Connection: Upgrade" -H "Upgrade: websocket" "http://127.0.0.1:$HttpPort/websocket-test") "upgrade=websocket|connection=upgrade"

  [System.IO.File]::WriteAllBytes($largePayload, [byte[]]::new(2MB))
  Assert-Equal "large_request" (curl.exe -sS -H "Host: a.listener.local" -H "Content-Type: application/octet-stream" --data-binary "@$largePayload" "http://127.0.0.1:$HttpPort/large-request").Trim() "2097152"

  $slowJob = Start-Job -ScriptBlock {
    param($Port)
    curl.exe -sS -H "Host: a.listener.local" "http://127.0.0.1:$Port/slow"
  } -ArgumentList $HttpPort
  Start-Sleep -Seconds 1
  docker exec $gateway /usr/local/openresty/bin/openresty -s reload
  if ($LASTEXITCODE -ne 0) {
    throw "gateway reload failed during long connection test"
  }
  $slowResult = Receive-Job -Job $slowJob -Wait -AutoRemoveJob
  Assert-Equal "long_connection_during_reload" $slowResult.Trim() "slow-ok"
  Assert-Match "post_reload_request" (Invoke-SmokeRequest "http://127.0.0.1:$HttpPort/" -HostHeader "a.listener.local") '^app-a\|'

  $ErrorActionPreference = "Continue"
  $wrongSniStatus = curl.exe -k -s -o NUL -w "%{http_code}" --resolve "unknown.listener.local:${HttpsPort}:127.0.0.1" "https://unknown.listener.local:${HttpsPort}/"
  $wrongSniExit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  Assert-Equal "unknown_sni_status" $wrongSniStatus "000"
  if ($wrongSniExit -eq 0) {
    throw "unknown SNI unexpectedly completed a TLS request"
  }

  Write-Output "listener-smoke passed"
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $trustedGateway $upstreamA $upstreamB 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
  $ErrorActionPreference = "Stop"
}
