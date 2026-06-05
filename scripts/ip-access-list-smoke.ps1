param(
  [string]$Image = "litewaf-gateway:ip-access-list-smoke",
  [string]$Port = "18087"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$HostHeader = "example.local",
    [string]$ForwardedFor = ""
  )
  $headers = @("-H", "Host: $HostHeader")
  if ($ForwardedFor -ne "") {
    $headers += @("-H", "X-Forwarded-For: $ForwardedFor")
  }
  curl.exe -s -o NUL -w "%{http_code}" @headers $Url
}

$network = "litewaf-ip-access-smoke-net"
$upstream = "litewaf-ip-access-smoke-upstream"
$gateway = "litewaf-ip-access-smoke-gateway"

$ErrorActionPreference = "Continue"
docker info 2>$null | Out-Null
$dockerStatus = $LASTEXITCODE
$ErrorActionPreference = "Stop"
if ($dockerStatus -ne 0) {
  throw "Docker engine is unavailable; start Docker Desktop Linux engine before running this smoke."
}

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/ip-access-list-smoke-active.json -e LITEWAF_REAL_IP_TRUSTED_CIDRS=0.0.0.0/0 $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  $results = [ordered]@{
    exact_allow = Invoke-SmokeRequest "$base/?q=union%20select" "example.local" "203.0.113.10"
    exact_block = Invoke-SmokeRequest "$base/" "example.local" "203.0.113.20"
    cidr_block = Invoke-SmokeRequest "$base/" "cidr.local" "198.51.100.9"
    exact_before_cidr = Invoke-SmokeRequest "$base/" "example.local" "198.51.100.5"
    no_match_ignores_legacy = Invoke-SmokeRequest "$base/" "example.local" "192.0.2.50"
  }

  $expected = [ordered]@{
    exact_allow = "200"
    exact_block = "403"
    cidr_block = "403"
    exact_before_cidr = "200"
    no_match_ignores_legacy = "200"
  }

  foreach ($item in $results.GetEnumerator()) {
    Write-Output "$($item.Key)=$($item.Value)"
    if ($item.Value -ne $expected[$item.Key]) {
      throw "expected $($item.Key) to return $($expected[$item.Key]), got $($item.Value)"
    }
  }

  $ErrorActionPreference = "Continue"
  $logs = docker logs $gateway --tail 200 2>&1
  $ErrorActionPreference = "Stop"
  foreach ($pattern in @(
      '"module":"ip-access-list"',
      '"category":"ip-access-list"',
      '"rule_name":"Site exact allow"',
      '"rule_name":"Site exact block"',
      '"rule_name":"Global CIDR block"',
      '"ip_list_kind":"allow"',
      '"ip_list_kind":"block"'
    )) {
    if (($logs -join "`n") -notmatch [regex]::Escape($pattern)) {
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
