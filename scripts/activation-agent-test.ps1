param(
    [string]$Image = "litewaf/local-gateway:takeover-agent-dev"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

& docker run --rm `
    -v "${repo}:/workspace:ro" `
    --entrypoint /bin/sh `
    $Image `
    /workspace/scripts/activation-agent-test.sh

if ($LASTEXITCODE -ne 0) {
    throw "activation agent test failed with exit code $LASTEXITCODE"
}
