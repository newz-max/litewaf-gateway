param(
  [string]$Image = "litewaf-gateway:access-control-smoke",
  [string]$Port = "18083"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$HostHeader = "example.local",
    [string[]]$ExtraHeaders = @()
  )
  $headers = @("-H", "Host: $HostHeader")
  foreach ($header in $ExtraHeaders) {
    $headers += @("-H", $header)
  }
  curl.exe -s -o NUL -w "%{http_code}" @headers $Url
}

$network = "litewaf-access-smoke-net"
$upstream = "litewaf-access-smoke-upstream"
$gateway = "litewaf-access-smoke-gateway"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/access-control-smoke-active.json $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  $results = [ordered]@{
    normal = Invoke-SmokeRequest "$base/"
    admin = Invoke-SmokeRequest "$base/admin"
    admin_boundary = Invoke-SmokeRequest "$base/admin2"
    header = Invoke-SmokeRequest "$base/header" "example.local" @("X-LiteWaf-Block: yes")
    access_before_cc = Invoke-SmokeRequest "$base/access-before-cc"
    host = Invoke-SmokeRequest "$base/" "host-rule.local"
  }

  $expected = [ordered]@{
    normal = "200"
    admin = "403"
    admin_boundary = "404"
    header = "403"
    access_before_cc = "403"
    host = "403"
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
      '"module":"access-control"',
      '"category":"access-control"',
      '"rule_name":"Admin path block"',
      '"rule_name":"Header block"',
      '"rule_name":"Access before CC"',
      '"rule_name":"Host suffix block"'
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
