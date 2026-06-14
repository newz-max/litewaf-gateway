param(
  [string]$LuaFile = (Join-Path $PSScriptRoot "..\lua\litewaf.lua")
)

$ErrorActionPreference = "Stop"

$content = Get-Content -Path $LuaFile -Raw

foreach ($needle in @(
    'tostring(route.target_type or "proxy") == "static"',
    'ngx.ctx.route_target_type = "static"',
    'ngx.ctx.route_static_root = route.static_root or ""',
    'ngx.ctx.disposition = "served-static"',
    'route_target_type = ngx.ctx.route_target_type',
    'route_static_root = ngx.ctx.route_static_root',
    'route_static_mode = ngx.ctx.route_static_mode'
  )) {
  if (-not $content.Contains($needle)) {
    throw "static route contract missing: $needle"
  }
}

Write-Output "static_route_contract_check=ok"
