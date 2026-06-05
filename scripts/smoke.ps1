param(
  [string]$Gateway = "http://localhost:8081",
  [string]$HostHeader = "example.local"
)

$normal = curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" "$Gateway/"
$blocked = curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" "$Gateway/?q=union%20select"
$encoded = curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" "$Gateway/?q=%2575%256e%2569%256f%256e%2520%2573%2565%256c%2565%2563%2574"
$xss = curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" "$Gateway/?q=%3Cscript%3Ealert(1)%3C/script%3E"
$rce = curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" "$Gateway/?q=%3Bcat%20/etc/passwd"
$traversal = curl.exe -s -o NUL -w "%{http_code}" -H "Host: $HostHeader" "$Gateway/%2e%2e/%2e%2e/etc/passwd"
$jsonBody = curl.exe -s -o NUL -w "%{http_code}" -X POST -H "Host: $HostHeader" -H "Content-Type: application/json" --data '{"q":"<script>alert(1)</script>"}' "$Gateway/api/login"
$upload = curl.exe -s -o NUL -w "%{http_code}" -X POST -H "Host: $HostHeader" -F "file=@$PSCommandPath;filename=shell.php;type=application/octet-stream" "$Gateway/upload"
$metrics = curl.exe -s "$Gateway/metrics"

Write-Output "normal=$normal"
Write-Output "blocked=$blocked"
Write-Output "encoded=$encoded"
Write-Output "xss=$xss"
Write-Output "rce=$rce"
Write-Output "traversal=$traversal"
Write-Output "json_body=$jsonBody"
Write-Output "upload=$upload"
Write-Output "metrics_length=$($metrics.Length)"

if ($normal -ne "200") {
  throw "expected normal request to return 200"
}
if ($blocked -ne "403") {
  throw "expected SQLi request to return 403"
}
if ($encoded -notin @("403", "200")) {
  throw "expected encoded payload request to return a valid gateway response"
}
if ($xss -notin @("403", "200")) {
  throw "expected XSS request to return a valid gateway response"
}
if ($rce -notin @("403", "200")) {
  throw "expected RCE request to return a valid gateway response"
}
if ($traversal -notin @("403", "200", "404")) {
  throw "expected path traversal request to return a valid gateway response"
}
if ($jsonBody -notin @("403", "200", "404")) {
  throw "expected JSON body request to return a valid gateway response"
}
if ($upload -notin @("403", "200", "404")) {
  throw "expected upload request to return a valid gateway response"
}
if ($metrics -and ($metrics -notmatch "litewaf_gateway_up")) {
  throw "expected metrics response to contain litewaf_gateway_up when metrics are enabled"
}
