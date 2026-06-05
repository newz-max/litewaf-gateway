param(
  [string]$Image = "litewaf-gateway:cc-advanced-smoke",
  [string]$Port = "18088"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [hashtable]$Headers = @{}
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-H", "Host: cc-advanced.local")
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

$network = "litewaf-cc-advanced-smoke-net"
$upstream = "litewaf-cc-advanced-smoke-upstream"
$gateway = "litewaf-cc-advanced-smoke-gateway"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/cc-advanced-smoke-active.json $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"

  Assert-Status "glob_first" (Invoke-SmokeRequest "$base/api/v1/login") "404"
  Assert-Status "glob_second" (Invoke-SmokeRequest "$base/api/v1/login") "429"

  Assert-Status "session_first" (Invoke-SmokeRequest "$base/session" @{ Cookie = "sid=abc" }) "404"
  Assert-Status "session_second" (Invoke-SmokeRequest "$base/session" @{ Cookie = "sid=abc" }) "429"

  Assert-Status "device_first" (Invoke-SmokeRequest "$base/device" @{ "User-Agent" = "LiteWafSmoke/1"; "Accept-Language" = "zh-CN" }) "404"
  Assert-Status "device_second" (Invoke-SmokeRequest "$base/device" @{ "User-Agent" = "LiteWafSmoke/1"; "Accept-Language" = "zh-CN" }) "429"

  Assert-Status "not_found_first" (Invoke-SmokeRequest "$base/missing") "404"
  Start-Sleep -Seconds 1
  Assert-Status "not_found_second" (Invoke-SmokeRequest "$base/missing") "429"

  Assert-Status "attack_first" (Invoke-SmokeRequest "$base/attack?q=ccattack") "404"
  Assert-Status "attack_second" (Invoke-SmokeRequest "$base/attack?q=ccattack") "429"

  $logs = docker logs $gateway --tail 500 2>&1
  $joinedLogs = $logs -join "`n"
  foreach ($pattern in @(
      '"rule_name":"Glob CC limit"',
      '"rule_name":"Session CC limit"',
      '"rule_name":"Device CC limit"',
      '"rule_name":"Not found CC limit"',
      '"rule_name":"Attack frequency CC limit"',
      '"counter":"session"',
      '"counter":"device"',
      '"counter":"not_found_frequency"',
      '"counter":"attack_frequency"'
    )) {
    if ($joinedLogs -notmatch [regex]::Escape($pattern)) {
      throw "expected gateway logs to contain $pattern"
    }
  }
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"
}
