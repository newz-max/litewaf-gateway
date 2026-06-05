param(
  [string]$Image = "litewaf-gateway:real-ip-smoke",
  [string]$TrustedPort = "18089",
  [string]$UntrustedPort = "18090"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [hashtable]$Headers = @{}
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-H", "Host: real-ip.local")
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

function Assert-LogMissing {
  param(
    [string]$Name,
    [string]$Logs,
    [string]$Pattern
  )
  if ($Logs -match [regex]::Escape($Pattern)) {
    throw "expected $Name logs to omit $Pattern"
  }
}

$network = "litewaf-real-ip-smoke-net"
$upstream = "litewaf-real-ip-smoke-upstream"
$trustedGateway = "litewaf-real-ip-smoke-trusted"
$untrustedGateway = "litewaf-real-ip-smoke-untrusted"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $trustedGateway $untrustedGateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $trustedGateway --network $network -p "${TrustedPort}:8080" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/real-ip-smoke-active.json `
    -e LITEWAF_REAL_IP_TRUSTED_CIDRS=172.16.0.0/12 `
    -e LITEWAF_REAL_IP_HEADER=X-Forwarded-For `
    -e LITEWAF_REAL_IP_RECURSIVE=on `
    $Image | Out-Null
  docker run -d --name $untrustedGateway --network $network -p "${UntrustedPort}:8080" `
    -e LITEWAF_CONFIG_PATH=/etc/litewaf/real-ip-smoke-active.json `
    $Image | Out-Null
  Start-Sleep -Seconds 2

  $trustedBase = "http://localhost:$TrustedPort"
  $untrustedBase = "http://localhost:$UntrustedPort"

  Assert-Status "direct_safe_default" (Invoke-SmokeRequest "$untrustedBase/" @{ "X-Forwarded-For" = "198.51.100.10" }) "200"
  Assert-Status "trusted_ip_block" (Invoke-SmokeRequest "$trustedBase/" @{ "X-Forwarded-For" = "198.51.100.10" }) "403"
  Assert-Status "trusted_cidr_block" (Invoke-SmokeRequest "$trustedBase/" @{ "X-Forwarded-For" = "198.51.100.77, 172.18.0.10" }) "403"

  Assert-Status "cc_first" (Invoke-SmokeRequest "$trustedBase/cc" @{ "X-Forwarded-For" = "203.0.113.20" }) "404"
  Assert-Status "cc_second" (Invoke-SmokeRequest "$trustedBase/cc" @{ "X-Forwarded-For" = "203.0.113.20" }) "429"

  Assert-Status "cc_path_first" (Invoke-SmokeRequest "$trustedBase/cc-path/a" @{ "X-Forwarded-For" = "203.0.113.30" }) "404"
  Assert-Status "cc_path_second" (Invoke-SmokeRequest "$trustedBase/cc-path/a" @{ "X-Forwarded-For" = "203.0.113.30" }) "429"
  Assert-Status "cc_path_other" (Invoke-SmokeRequest "$trustedBase/cc-path/b" @{ "X-Forwarded-For" = "203.0.113.30" }) "404"

  Assert-Status "ban_first" (Invoke-SmokeRequest "$trustedBase/ban" @{ "X-Forwarded-For" = "203.0.113.40" }) "404"
  Assert-Status "ban_second" (Invoke-SmokeRequest "$trustedBase/ban" @{ "X-Forwarded-For" = "203.0.113.40" }) "429"
  Assert-Status "ban_followup" (Invoke-SmokeRequest "$trustedBase/" @{ "X-Forwarded-For" = "203.0.113.40" }) "403"

  $trustedLogs = (docker logs $trustedGateway --tail 500 2>&1) -join "`n"
  $untrustedLogs = (docker logs $untrustedGateway --tail 200 2>&1) -join "`n"

  Assert-LogContains "trusted" $trustedLogs '"client_ip":"198.51.100.10"'
  Assert-LogContains "trusted" $trustedLogs '"client_ip":"198.51.100.77"'
  Assert-LogContains "trusted" $trustedLogs '"client_ip":"203.0.113.20"'
  Assert-LogContains "trusted" $trustedLogs '"client_ip":"203.0.113.30"'
  Assert-LogContains "trusted" $trustedLogs '"client_ip":"203.0.113.40"'
  Assert-LogContains "trusted" $trustedLogs '"rule_name":"Forwarded client IP block"'
  Assert-LogContains "trusted" $trustedLogs '"rule_name":"Forwarded CIDR block"'
  Assert-LogContains "trusted" $trustedLogs '"rule_name":"Forwarded client IP CC"'
  Assert-LogContains "trusted" $trustedLogs '"rule_name":"Forwarded client IP path CC"'
  Assert-LogContains "trusted" $trustedLogs '"rule_name":"Forwarded client IP ban"'
  Assert-LogMissing "untrusted" $untrustedLogs '"client_ip":"198.51.100.10"'
}
finally {
  $ErrorActionPreference = "Continue"
  docker rm -f $trustedGateway $untrustedGateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"
}
