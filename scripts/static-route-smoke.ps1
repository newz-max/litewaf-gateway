param(
  [string]$Image = "litewaf-gateway:static-route-smoke",
  [string]$Port = "18091",
  [string]$OpenRestyRuntimeImage = "docker.m.daocloud.io/openresty/openresty:1.27.1.2-0-bookworm-fat"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$Output = "-"
  )
  if ($Output -eq "-") {
    return curl.exe -s -H "Host: static.local" $Url
  }
  return curl.exe -s -o $Output -w "%{http_code}" -H "Host: static.local" $Url
}

function Assert-Body {
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

$network = "litewaf-static-route-smoke-net"
$upstream = "litewaf-static-route-upstream"
$gateway = "litewaf-static-route-gateway"
$runtime = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-static-route-" + [guid]::NewGuid().ToString("N"))

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  $listenerDir = Join-Path $runtime "listeners"
  $staticDir = Join-Path $runtime "www\uploads"
  New-Item -ItemType Directory -Force -Path $listenerDir, $staticDir | Out-Null
  Set-Content -Path (Join-Path $staticDir "hello.txt") -Encoding ascii -Value "static-ok"

  Set-Content -Path (Join-Path $runtime "active.json") -Encoding ascii -Value @'
{
  "version": "static-route-smoke",
  "generated_at": "2026-06-15T00:00:00Z",
  "applications": [
    {
      "id": 701,
      "name": "Static Route",
      "mode": "protect",
      "enabled": true,
      "hosts": ["static.local"],
      "listeners": [{"port": 8080, "protocol": "http", "enabled": true}],
      "upstreams": [{"name": "primary", "url": "http://litewaf-static-route-upstream:5678", "weight": 1, "enabled": true}],
    "routes": [
        {
          "id": 1,
          "name": "Uploads",
          "path": "/uploads",
          "path_match": "prefix",
          "target_type": "static",
          "static_root": "/tmp/litewaf-static-route/www/uploads",
          "static_mode": "alias",
          "priority": 10,
          "enabled": true
        }
      ],
      "rules": [],
      "policy": {"risk_threshold": 100, "default_action": "block"}
    }
  ],
  "protection_rules": [],
  "sites": []
}
'@

  Set-Content -Path (Join-Path $listenerDir "applications.conf") -Encoding ascii -Value @'
server {
    listen 8080;
    server_name static.local;

    location = "/uploads" {
        set $litewaf_upstream "";
        set $litewaf_request_id "";
        set $litewaf_client_ip $remote_addr;

        access_by_lua_block { litewaf.access() }
        log_by_lua_block { litewaf.log() }
        return 301 $uri/;
    }

    location ^~ "/uploads/" {
        set $litewaf_upstream "";
        set $litewaf_request_id "";
        set $litewaf_client_ip $remote_addr;

        access_by_lua_block { litewaf.access() }
        header_filter_by_lua_block { litewaf.header_filter() }
        body_filter_by_lua_block { litewaf.body_filter() }
        log_by_lua_block { litewaf.log() }

        alias "/tmp/litewaf-static-route/www/uploads/";
        try_files $uri =404;
    }

    location / {
        set $litewaf_upstream "";
        set $litewaf_request_id "";
        set $litewaf_client_ip $remote_addr;

        access_by_lua_block { litewaf.access() }
        header_filter_by_lua_block { litewaf.header_filter() }
        body_filter_by_lua_block { litewaf.body_filter() }
        log_by_lua_block { litewaf.log() }

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $litewaf_client_ip;
        proxy_set_header X-Request-ID $litewaf_request_id;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass $litewaf_upstream;
    }
}
'@

  docker build --build-arg "OPENRESTY_RUNTIME_IMAGE=$OpenRestyRuntimeImage" -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "gateway image build failed"
  }
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network hashicorp/http-echo:1.0 -text fallback | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" `
    -v "${runtime}:/etc/litewaf" `
    -v "${runtime}\www:/tmp/litewaf-static-route/www:ro" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/active.json `
    $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  Assert-Body "static_file" (Invoke-SmokeRequest "$base/uploads/hello.txt").Trim() "static-ok"
  $slashStatus = Invoke-SmokeRequest "$base/uploads" "NUL"
  Assert-Body "static_prefix_redirect" $slashStatus "301"
  $missingStatus = Invoke-SmokeRequest "$base/uploads/missing.txt" "NUL"
  Assert-Body "missing_static_status" $missingStatus "404"
  Assert-Body "fallback_proxy" (Invoke-SmokeRequest "$base/api").Trim() "fallback"

  Write-Output "static-route-smoke passed"
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  Remove-Item -Recurse -Force $runtime -ErrorAction SilentlyContinue
  $ErrorActionPreference = "Stop"
}
