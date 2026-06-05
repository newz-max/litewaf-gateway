param(
  [string]$Image = "litewaf-gateway:dynamic-protection-smoke",
  [string]$Port = "18086"
)

$ErrorActionPreference = "Stop"

function Invoke-Code {
  param(
    [string]$Url,
    [string]$Method = "GET",
    [string]$Cookie = ""
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-X", $Method, "-H", "Host: example.local")
  if ($Cookie -ne "") {
    $args += @("-H", "Cookie: $Cookie")
  }
  $args += $Url
  curl.exe @args
}

$network = "litewaf-dynamic-smoke-net"
$upstream = "litewaf-dynamic-smoke-upstream"
$gateway = "litewaf-dynamic-smoke-gateway"
$upstreamConf = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-dynamic-smoke-" + [guid]::NewGuid().ToString("N") + ".conf")

try {
  @"
server {
  listen 80;
  default_type text/html;

  location /json {
    default_type application/json;
    return 200 '{"ok":true}';
  }

  location / {
    return 200 '<!doctype html><html><head><title>dynamic smoke</title></head><body><main>ok</main></body></html>';
  }
}
"@ | Set-Content -LiteralPath $upstreamConf -Encoding ascii

  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network -v "${upstreamConf}:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/dynamic-protection-smoke-active.json -e LITEWAF_DYNAMIC_SECRET=smoke-secret $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  $cookieFile = New-TemporaryFile
  try {
    $issued = curl.exe -s -c $cookieFile -o NUL -w "%{http_code}" -H "Host: example.local" "$base/admin"
    $passed = curl.exe -s -b $cookieFile -o NUL -w "%{http_code}" -H "Host: example.local" "$base/admin"
  }
  finally {
    Remove-Item -LiteralPath $cookieFile -Force -ErrorAction SilentlyContinue
  }

  $queueCookieFile = New-TemporaryFile
  try {
    $queueFirst = curl.exe -s -c $queueCookieFile -o NUL -w "%{http_code}" -H "Host: example.local" "$base/queue"
    $queueSecond = Invoke-Code "$base/queue"
  }
  finally {
    Remove-Item -LiteralPath $queueCookieFile -Force -ErrorAction SilentlyContinue
  }

  $mutationBody = curl.exe -s -H "Host: example.local" "$base/"

  $results = [ordered]@{
    issued = $issued
    passed = $passed
    invalid = Invoke-Code "$base/admin" "GET" "litewaf_dyn_1_601=9999999999.invalid"
    expired = Invoke-Code "$base/admin" "GET" "litewaf_dyn_1_601=1.invalid"
    observe = Invoke-Code "$base/login" "POST" "litewaf_dyn_1_602=1.invalid"
    boundary = Invoke-Code "$base/admin2"
    queue_first = $queueFirst
    queue_second = $queueSecond
    dynamic_before_attack = Invoke-Code "$base/dynamic-before-attack?q=union%20select" "GET" "litewaf_dyn_1_605=1.invalid"
  }

  $expected = [ordered]@{
    issued = "200"
    passed = "200"
    invalid = "403"
    expired = "403"
    observe = "200"
    boundary = "200"
    queue_first = "200"
    queue_second = "503"
    dynamic_before_attack = "403"
  }

  foreach ($item in $results.GetEnumerator()) {
    Write-Output "$($item.Key)=$($item.Value)"
    if ($item.Value -ne $expected[$item.Key]) {
      throw "expected $($item.Key) to return $($expected[$item.Key]), got $($item.Value)"
    }
  }

  if ($mutationBody -notmatch 'data-litewaf-dynamic="603"') {
    throw "expected dynamic mutation snippet in HTML response"
  }

  $ErrorActionPreference = "Continue"
  $logs = docker logs $gateway --tail 320 2>&1
  $ErrorActionPreference = "Stop"
  foreach ($pattern in @(
      '"module":"dynamic-protection"',
      '"category":"dynamic-token"',
      '"category":"page-mutation"',
      '"category":"waiting-room"',
      '"advanced_target":"token-issued"',
      '"advanced_target":"token-passed"',
      '"advanced_target":"token-failed"',
      '"advanced_target":"mutation-applied"',
      '"advanced_target":"queue-admitted"',
      '"advanced_target":"queue-queued"',
      '"disposition":"blocked"',
      '"disposition":"observed"',
      '"disposition":"proxied"'
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
  Remove-Item -LiteralPath $upstreamConf -Force -ErrorAction SilentlyContinue
  $ErrorActionPreference = "Stop"
}
