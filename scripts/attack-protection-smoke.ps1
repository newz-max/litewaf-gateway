param(
  [string]$Image = "litewaf-gateway:attack-protection-smoke",
  [string]$Port = "18082"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param([string]$Url)
  curl.exe -s -o NUL -w "%{http_code}" -H "Host: example.local" $Url
}

$network = "litewaf-attack-smoke-net"
$upstream = "litewaf-attack-smoke-upstream"
$gateway = "litewaf-attack-smoke-gateway"

try {
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/smoke-active.json $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  $results = [ordered]@{
    normal = Invoke-SmokeRequest "$base/"
    sqli = Invoke-SmokeRequest "$base/?q=union%20select"
    xss_observe = Invoke-SmokeRequest "$base/?q=%3Cscript%3Ealert(1)%3C/script%3E"
    rce = Invoke-SmokeRequest "$base/?q=%3Bcat"
    traversal = Invoke-SmokeRequest "$base/%2e%2e/%2e%2e/etc/passwd"
    disabled_group = Invoke-SmokeRequest "$base/?q=disabledattack"
    cc_before_attack_first = Invoke-SmokeRequest "$base/cc?q=union%20select"
    cc_before_attack_second = Invoke-SmokeRequest "$base/cc?q=union%20select"
  }

  $expected = [ordered]@{
    normal = "200"
    sqli = "403"
    xss_observe = "200"
    rce = "403"
    traversal = "403"
    disabled_group = "200"
    cc_before_attack_first = "403"
    cc_before_attack_second = "429"
  }

  foreach ($item in $results.GetEnumerator()) {
    Write-Output "$($item.Key)=$($item.Value)"
    if ($item.Value -ne $expected[$item.Key]) {
      throw "expected $($item.Key) to return $($expected[$item.Key]), got $($item.Value)"
    }
  }

  $logs = docker logs $gateway --tail 200 2>&1
  foreach ($pattern in @(
      '"module":"attack-protection"',
      '"attack_type":"sqli"',
      '"attack_type":"xss"',
      '"attack_type":"rce"',
      '"attack_type":"path-traversal"',
      '"module":"cc-protection"'
    )) {
    if (($logs -join "`n") -notmatch [regex]::Escape($pattern)) {
      throw "expected gateway logs to contain $pattern"
    }
  }
}
finally {
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
}
