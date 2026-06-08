Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$lua = Join-Path $repo "lua\litewaf.lua"
$content = Get-Content -Path $lua -Raw

$forbidden = @(
  "geo_country",
  "geo_region",
  "geo_city",
  "geo_longitude",
  "geo_latitude",
  "http_cf_ipcountry",
  "http_cloudfront_viewer_country",
  "http_x_geo_country",
  "http_x_geo_region",
  "http_x_geo_city",
  "http_x_country_code",
  "http_x_country",
  "http_x_city",
  "http_cf_region",
  "http_cf_ipcity",
  "http_cf_iplongitude",
  "http_cf_iplatitude"
)

foreach ($pattern in $forbidden) {
  if ($content -match [regex]::Escape($pattern)) {
    throw "gateway log contract must not emit authoritative geo header field: $pattern"
  }
}

Write-Host "geoip-log-contract-test passed"
