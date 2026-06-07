param(
  [string]$LuaFile = (Join-Path $PSScriptRoot "..\lua\litewaf.lua")
)

$ErrorActionPreference = "Stop"

$source = Get-Content -Raw -LiteralPath $LuaFile
$required = @(
  "reason_code = ngx.ctx.denial_reason_code",
  "reason = bounded(ngx.ctx.denial_reason",
  'set_denial("rejected", "unknown-host"',
  'set_denial("blocked", "dynamic-ban"',
  'set_denial("blocked", "ip-access-list"',
  'set_denial("blocked", "access-control"',
  'set_denial("blocked", "upload-protection"',
  'set_denial("blocked", "bot-protection"',
  'set_denial("blocked", "dynamic-protection"',
  'set_denial("blocked", "waiting-room"',
  'set_denial("blocked", "waf-rule"',
  'set_denial("blocked", "score-threshold"'
)

$missing = @()
foreach ($needle in $required) {
  if (-not $source.Contains($needle)) {
    $missing += $needle
  }
}

if ($missing.Count -gt 0) {
  Write-Error ("Missing denial reason evidence: " + ($missing -join ", "))
}

Write-Output "denial_reason_static_check=ok"
