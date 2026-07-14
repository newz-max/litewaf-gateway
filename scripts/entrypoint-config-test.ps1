param(
    [string]$Image = "litewaf/local-gateway:dev"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

function Invoke-RenderCase {
    param(
        [string]$Name,
        [string]$Mode,
        [string]$ResolverSource,
        [string]$ExpectedListen,
        [string]$ExpectedResolver,
        [bool]$ExpectSuccess = $true
    )

    $runtime = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-entrypoint-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    try {
        Set-Content -Path (Join-Path $runtime "resolv.conf") -Encoding ascii -Value $ResolverSource
        $arguments = @(
            "run", "--rm",
            "-v", "${repo}:/workspace:ro",
            "-v", "${runtime}:/test",
            "-e", "LITEWAF_REAL_IP_CONF=/test/realip.conf",
            "-e", "LITEWAF_ADMIN_CONF=/test/admin.conf",
            "-e", "LITEWAF_RESOLVER_CONF=/test/resolver.conf",
            "-e", "LITEWAF_RESOLV_CONF=/test/resolv.conf",
            "-e", "LITEWAF_LISTENER_DIR=/test/listeners",
            "-e", "LITEWAF_RELOAD_STATE_FILE=/test/reload-status.json",
            "-e", "LITEWAF_DEPLOYMENT_MODE=$Mode",
            "--entrypoint", "/bin/sh",
            $Image,
            "/workspace/docker-entrypoint.sh", "true"
        )
        $ErrorActionPreference = "Continue"
        $output = & docker @arguments 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if (-not $ExpectSuccess) {
            if ($exit -eq 0) {
                throw "$Name unexpectedly succeeded"
            }
            return
        }
        if ($exit -ne 0) {
            throw "$Name failed: $($output -join [Environment]::NewLine)"
        }
        $admin = Get-Content -Raw (Join-Path $runtime "admin.conf")
        $resolver = Get-Content -Raw (Join-Path $runtime "resolver.conf")
        foreach ($needle in @(
            "listen $ExpectedListen;",
            "location = /healthz",
            "location = /metrics",
            "location = /runtime-version"
        )) {
            if (-not $admin.Contains($needle)) {
                throw "$Name admin config missing $needle"
            }
        }
        if (-not $resolver.Contains($ExpectedResolver)) {
            throw "$Name resolver config missing $ExpectedResolver"
        }
    }
    finally {
        Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-RenderCase -Name "host" -Mode "host-network" -ResolverSource "nameserver 10.0.0.2" -ExpectedListen "127.0.0.1:18082" -ExpectedResolver "resolver 10.0.0.2 valid=10s;"
Invoke-RenderCase -Name "bridge-ipv6" -Mode "bridge" -ResolverSource "nameserver 2001:db8::53" -ExpectedListen "0.0.0.0:8080" -ExpectedResolver "resolver [2001:db8::53] valid=10s;"
Invoke-RenderCase -Name "missing-resolver" -Mode "bridge" -ResolverSource "search example.test" -ExpectedListen "" -ExpectedResolver "" -ExpectSuccess $false

Write-Host "entrypoint-config-test passed"
