param(
  [string]$Image = "litewaf-gateway:bot-protection-smoke",
  [string]$Port = "18085"
)

$ErrorActionPreference = "Stop"

function Invoke-Code {
  param(
    [string]$Url,
    [string]$Method = "GET",
    [string]$Cookie = "",
    [string]$UserAgent = ""
  )
  $args = @("-s", "-o", "NUL", "-w", "%{http_code}", "-X", $Method, "-H", "Host: example.local")
  if ($Cookie -ne "") {
    $args += @("-H", "Cookie: $Cookie")
  }
  if ($UserAgent -ne "") {
    $args += @("-A", $UserAgent)
  }
  $args += $Url
  curl.exe @args
}

$network = "litewaf-bot-smoke-net"
$upstream = "litewaf-bot-smoke-upstream"
$gateway = "litewaf-bot-smoke-gateway"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/bot-protection-smoke-active.json -e LITEWAF_CHALLENGE_SECRET=smoke-secret $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  $cookieFile = New-TemporaryFile
  try {
    $challenge = curl.exe -s -c $cookieFile -o NUL -w "%{http_code}" -H "Host: example.local" "$base/admin"
    $verified = curl.exe -s -b $cookieFile -o NUL -w "%{http_code}" -H "Host: example.local" "$base/admin"
  }
  finally {
    Remove-Item -LiteralPath $cookieFile -Force -ErrorAction SilentlyContinue
  }

  $results = [ordered]@{
    challenge = $challenge
    verified = $verified
    invalid = Invoke-Code "$base/admin" "GET" "litewaf_bot_1_501=9999999999.invalid"
    expired = Invoke-Code "$base/admin" "GET" "litewaf_bot_1_501=1.invalid"
    captcha_issue = Invoke-Code "$base/captcha"
    behavior_pass = Invoke-Code "$base/behavior" "GET" "" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    behavior_challenge = Invoke-Code "$base/behavior"
    search_engine_bypass = Invoke-Code "$base/crawler" "GET" "" "Googlebot/2.1"
    boundary = Invoke-Code "$base/admin2"
    observe = Invoke-Code "$base/login" "POST"
    bot_before_attack = Invoke-Code "$base/bot-before-attack?q=union%20select"
  }

  $expected = [ordered]@{
    challenge = "200"
    verified = "404"
    invalid = "403"
    expired = "403"
    captcha_issue = "200"
    behavior_pass = "404"
    behavior_challenge = "200"
    search_engine_bypass = "404"
    boundary = "404"
    observe = "404"
    bot_before_attack = "200"
  }

  foreach ($item in $results.GetEnumerator()) {
    Write-Output "$($item.Key)=$($item.Value)"
    if ($item.Value -ne $expected[$item.Key]) {
      throw "expected $($item.Key) to return $($expected[$item.Key]), got $($item.Value)"
    }
  }

  $ErrorActionPreference = "Continue"
  $logs = docker logs $gateway --tail 260 2>&1
  $ErrorActionPreference = "Stop"
  foreach ($pattern in @(
      '"module":"bot-protection"',
      '"category":"challenge"',
      '"rule_name":"Admin JS Challenge"',
      '"rule_name":"Captcha Challenge"',
      '"rule_name":"Behavior Score"',
      '"rule_name":"Search Engine Bypass"',
      '"rule_name":"Login Observe Challenge"',
      '"rule_name":"Bot before attack"',
      '"challenge_mode":"js-challenge"',
      '"challenge_mode":"captcha"',
      '"challenge_result":"issued"',
      '"challenge_result":"passed"',
      '"challenge_result":"failed"',
      '"bot_result":"captcha-issued"',
      '"bot_result":"behavior-pass"',
      '"bot_result":"search-engine-bypass"',
      '"disposition":"blocked"',
      '"disposition":"observed"'
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
