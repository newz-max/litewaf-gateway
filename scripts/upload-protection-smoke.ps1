param(
  [string]$Image = "litewaf-gateway:upload-protection-smoke",
  [string]$Port = "18084"
)

$ErrorActionPreference = "Stop"

function Invoke-SmokeRequest {
  param(
    [string]$Url,
    [string]$FileName = "file.txt",
    [string]$Content = "hello"
  )
  $temp = New-TemporaryFile
  try {
    Set-Content -LiteralPath $temp -Value $Content -NoNewline
    curl.exe -s -o NUL -w "%{http_code}" -X POST -H "Host: example.local" -F "file=@$temp;filename=$FileName;type=application/octet-stream" $Url
  }
  finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

$network = "litewaf-upload-smoke-net"
$upstream = "litewaf-upload-smoke-upstream"
$gateway = "litewaf-upload-smoke-gateway"

try {
  $ErrorActionPreference = "Continue"
  docker rm -f $gateway $upstream 2>$null | Out-Null
  docker network rm $network 2>$null | Out-Null
  $ErrorActionPreference = "Stop"

  docker build -t $Image (Resolve-Path "$PSScriptRoot\..") | Out-Host
  docker network create $network | Out-Null
  docker run -d --name $upstream --network $network nginx:1.27-alpine | Out-Null
  docker run -d --name $gateway --network $network -p "${Port}:8080" -e LITEWAF_CONFIG_PATH=/etc/litewaf/upload-protection-smoke-active.json $Image | Out-Null
  Start-Sleep -Seconds 2

  $base = "http://localhost:$Port"
  $results = [ordered]@{
    normal = Invoke-SmokeRequest "$base/upload" "safe.txt" "hello"
    extension_block = Invoke-SmokeRequest "$base/upload" "shell.php" "hello"
    boundary = Invoke-SmokeRequest "$base/upload2" "shell.php" "hello"
    size_block = Invoke-SmokeRequest "$base/avatar" "avatar.png" ("x" * 256)
    observe = Invoke-SmokeRequest "$base/observe" "tool.exe" "hello"
    upload_before_attack = Invoke-SmokeRequest "$base/upload-before-attack?q=union%20select" "shell.php" "hello"
  }

  $expected = [ordered]@{
    normal = "404"
    extension_block = "403"
    boundary = "404"
    size_block = "403"
    observe = "404"
    upload_before_attack = "403"
  }

  foreach ($item in $results.GetEnumerator()) {
    Write-Output "$($item.Key)=$($item.Value)"
    if ($item.Value -ne $expected[$item.Key]) {
      throw "expected $($item.Key) to return $($expected[$item.Key]), got $($item.Value)"
    }
  }

  $ErrorActionPreference = "Continue"
  $logs = docker logs $gateway --tail 240 2>&1
  $ErrorActionPreference = "Stop"
  foreach ($pattern in @(
      '"module":"upload-protection"',
      '"category":"upload"',
      '"rule_name":"Script upload block"',
      '"rule_name":"Avatar size block"',
      '"rule_name":"Upload observe"',
      '"rule_name":"Upload before attack"',
      '"target":"upload_extension"',
      '"target":"upload_size"',
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
