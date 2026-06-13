param(
  [string]$Image = "litewaf-gateway:route-selection-smoke",
  [string]$Port = "18089",
  [string]$OpenRestyRuntimeImage = "docker.m.daocloud.io/openresty/openresty:1.27.1.2-0-bookworm-fat"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url
  )
  curl.exe -s -H "Host: routes.local" $Url
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

$network = "litewaf-route-selection-smoke-net"
$defaultUpstream = "litewaf-route-selection-default"
$apiUpstream = "litewaf-route-selection-api"
$adminUpstream = "litewaf-route-selection-admin"
$gateway = "litewaf-route-selection-gateway"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $defaultUpstream $apiUpstream $adminUpstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build --build-arg "OPENRESTY_RUNTIME_IMAGE=$OpenRestyRuntimeImage" -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "gateway image build failed"
  }
  docker network create $network | Out-Null
  docker run -d --name $defaultUpstream --network $network hashicorp/http-echo:1.0 -text default | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "default upstream failed to start"
  }
  docker run -d --name $apiUpstream --network $network hashicorp/http-echo:1.0 -text api | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "api upstream failed to start"
  }
  docker run -d --name $adminUpstream --network $network hashicorp/http-echo:1.0 -text admin | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "admin upstream failed to start"
  }
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/route-selection-smoke-active.json $Image | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "gateway failed to start"
  }
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  Assert-Body "exact_route" (Invoke-SmokeRequest "$base/exact") "admin"
  Assert-Body "prefix_route" (Invoke-SmokeRequest "$base/api/users") "api"
  Assert-Body "glob_route" (Invoke-SmokeRequest "$base/assets/app.js") "admin"
  Assert-Body "disabled_route_fallback" (Invoke-SmokeRequest "$base/disabled") "default"
  Assert-Body "missing_route_fallback" (Invoke-SmokeRequest "$base/other") "default"

  $blockedStatus = curl.exe -s -o NUL -w "%{http_code}" -H "Host: routes.local" "$base/api/blocked"
  Write-Output "waf_after_route_status=$blockedStatus"
  if ($blockedStatus -ne "403") {
    throw "expected WAF access-control block after route selection to return 403, got $blockedStatus"
  }

  $ErrorActionPreference = "Continue"
  $logs = docker logs $gateway --tail 200 2>&1
  $ErrorActionPreference = "Stop"
  $joinedLogs = $logs -join "`n"
  foreach ($pattern in @(
      '"upstream":"http:\/\/litewaf-route-selection-api:5678"',
      '"event_type":"access-control"',
      '"disposition":"blocked"'
    )) {
    if ($joinedLogs -notmatch [regex]::Escape($pattern)) {
      throw "expected gateway logs to contain $pattern"
    }
  }
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $defaultUpstream $apiUpstream $adminUpstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"
}
