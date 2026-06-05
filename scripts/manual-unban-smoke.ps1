param(
  [string]$Image = "litewaf-gateway:manual-unban-smoke",
  [string]$Port = "18091"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [hashtable]$Headers = @{}
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-H", "Host: manual-unban.local")
  foreach ($key in $Headers.Keys) {
    $args += @("-H", "${key}: $($Headers[$key])")
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

function Assert-LogContains {
  param(
    [string]$Name,
    [string]$Logs,
    [string]$Pattern
  )
  if ($Logs -notmatch [regex]::Escape($Pattern)) {
    throw "expected $Name logs to contain $Pattern"
  }
}

$network = "litewaf-manual-unban-smoke-net"
$upstream = "litewaf-manual-unban-smoke-upstream"
$gateway = "litewaf-manual-unban-smoke-gateway"
$api = "litewaf-manual-unban-smoke-api"
$clearIp = "203.0.113.41"
$keptIp = "203.0.113.42"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $api $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/manual-unban-smoke-active.json `
    -e LITEWAF_REAL_IP_TRUSTED_CIDRS=172.16.0.0/12 `
    -e LITEWAF_REAL_IP_HEADER=X-Forwarded-For `
    -e LITEWAF_REAL_IP_RECURSIVE=on `
    -e LITEWAF_INGESTION_URL=http://${api}:8080 `
    -e LITEWAF_INGESTION_TOKEN=smoke-token `
    -e LITEWAF_DYNAMIC_BAN_CLEAR_INTERVAL=1 `
    $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  Assert-Status "clear_ip_first" (Invoke-SmokeRequest "$base/ban" @{ "X-Forwarded-For" = $clearIp }) "404"
  Assert-Status "clear_ip_second" (Invoke-SmokeRequest "$base/ban" @{ "X-Forwarded-For" = $clearIp }) "429"
  Assert-Status "clear_ip_banned" (Invoke-SmokeRequest "$base/" @{ "X-Forwarded-For" = $clearIp }) "403"
  Assert-Status "kept_ip_first" (Invoke-SmokeRequest "$base/ban" @{ "X-Forwarded-For" = $keptIp }) "404"
  Assert-Status "kept_ip_second" (Invoke-SmokeRequest "$base/ban" @{ "X-Forwarded-For" = $keptIp }) "429"
  Assert-Status "kept_ip_banned" (Invoke-SmokeRequest "$base/" @{ "X-Forwarded-For" = $keptIp }) "403"

  $python = @"
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"items": [{"site_id": 41, "client_ip": "$clearIp", "status": "cleared", "revision": 1, "message": "manual smoke clear"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.send_response(201)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
"@
  docker run -d --name $api --network $network python:3.12-alpine python -c $python | Out-Null
  Start-Sleep -Seconds 3

  Assert-Status "clear_ip_unbanned" (Invoke-SmokeRequest "$base/" @{ "X-Forwarded-For" = $clearIp }) "200"
  Assert-Status "kept_ip_still_banned" (Invoke-SmokeRequest "$base/" @{ "X-Forwarded-For" = $keptIp }) "403"
  Assert-Status "clear_ip_reban_first" (Invoke-SmokeRequest "$base/ban" @{ "X-Forwarded-For" = $clearIp }) "404"
  Assert-Status "clear_ip_reban_second" (Invoke-SmokeRequest "$base/ban" @{ "X-Forwarded-For" = $clearIp }) "429"

  $logs = (docker logs $gateway --tail 500 2>&1) -join "`n"
  Assert-LogContains "gateway" $logs '"event":"dynamic_ban_clear"'
  Assert-LogContains "gateway" $logs '"client_ip":"203.0.113.41"'
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $api $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"
}
