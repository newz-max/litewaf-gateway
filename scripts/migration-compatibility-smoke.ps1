param(
  [string]$Image = "litewaf-gateway:migration-compatibility-smoke",
  [string]$Port = "18087"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$HostHeader
  )
  curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" $Url
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

function Start-Gateway {
  param([string]$ConfigFile)
  $ErrorActionPreference = "Continue"
  docker rm -f $script:gateway 2>$null | Out-Null
  $ErrorActionPreference = "Stop"
  docker run -d --name $script:gateway --network $script:network -p "${script:Port}:8080" -e LITEWAF_CONFIG_PATH="/etc/litewaf/$ConfigFile" $script:Image | Out-Null
  Start-Sleep -Seconds 2
}

function Stop-Gateway {
  $ErrorActionPreference = "Continue"
  $script:lastLogs += docker logs $script:gateway --tail 300 2>&1
  docker rm -f $script:gateway 2>$null | Out-Null
  $ErrorActionPreference = "Stop"
}

$script:network = "litewaf-migration-smoke-net"
$script:upstream = "litewaf-migration-smoke-upstream"
$script:gateway = "litewaf-migration-smoke-gateway"
$script:lastLogs = @()

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $script:gateway $script:upstream 2>$null | Out-Null
  docker network rm $script:network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $script:network | Out-Null
  docker run -d --name $script:upstream --network $script:network nginx:1.27-alpine | Out-Null

  $base = "http://localhost:$Port"

  Start-Gateway "migration-compatibility-legacy-smoke-active.json"
  Assert-Status "legacy_access_block" (Invoke-SmokeRequest "$base/legacy-block" "legacy.local") "403"
  Assert-Status "legacy_cc_first" (Invoke-SmokeRequest "$base/legacy-cc" "legacy.local") "404"
  Assert-Status "legacy_cc_second" (Invoke-SmokeRequest "$base/legacy-cc" "legacy.local") "429"
  Stop-Gateway

  Start-Gateway "migration-compatibility-module-smoke-active.json"
  Assert-Status "module_access_block" (Invoke-SmokeRequest "$base/module-block" "module.local") "403"
  Assert-Status "module_cc_first" (Invoke-SmokeRequest "$base/module-cc" "module.local") "404"
  Assert-Status "module_cc_second" (Invoke-SmokeRequest "$base/module-cc" "module.local") "429"
  Stop-Gateway

  Start-Gateway "migration-compatibility-smoke-active.json"
  Assert-Status "mixed_access_block" (Invoke-SmokeRequest "$base/mixed" "mixed.local") "403"
  Assert-Status "mixed_cc_first" (Invoke-SmokeRequest "$base/mixed-cc" "mixed.local") "404"
  Assert-Status "mixed_cc_second" (Invoke-SmokeRequest "$base/mixed-cc" "mixed.local") "429"
  Stop-Gateway

  $joinedLogs = $script:lastLogs -join "`n"
  foreach ($pattern in @(
      '"event_type":"access-list"',
      '"event_type":"rate-limit"',
      '"module":"access-control"',
      '"module":"cc-protection"',
      '"rule_name":"Module path block"',
      '"rule_name":"Mixed module block"',
      '"rule_name":"Module CC limit"',
      '"rule_name":"Mixed module CC"'
    )) {
    if ($joinedLogs -notmatch [regex]::Escape($pattern)) {
      throw "expected gateway logs to contain $pattern"
    }
  }
}
finally {
  $ErrorActionPreference = "Continue"
  if ($script:gateway) {
    docker rm -f $script:gateway 2>$null | Out-Null
  }
  if ($script:upstream) {
    docker rm -f $script:upstream 2>$null | Out-Null
  }
  if ($script:network) {
    docker network rm $script:network 2>$null | Out-Null
  }
  $ErrorActionPreference = "Stop"
}
