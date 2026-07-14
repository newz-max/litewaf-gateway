param(
    [string]$Image = "openresty/openresty:1.27.1.2-0-bookworm-fat"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

& docker run --rm `
    -v "${repo}:/workspace:ro" `
    $Image `
    /usr/local/openresty/bin/resty `
    -I /workspace/lua `
    /workspace/scripts/activation-contract-test.lua `
    /workspace/conf/contracts

if ($LASTEXITCODE -ne 0) {
    throw "activation contract test failed with exit code $LASTEXITCODE"
}
