$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo "litewaf-reload.sh"
if (-not (Test-Path $script)) {
    throw "litewaf-reload.sh not found"
}
$isWindowsRuntime = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$nativeSh = Get-Command sh -ErrorAction SilentlyContinue
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $nativeSh -and -not $wsl) {
    throw "Neither sh nor wsl is available to run litewaf-reload.sh"
}

function ConvertTo-UnixPath {
    param([string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    return ($fullPath -replace '\\', '/')
}

function Invoke-ShellScript {
    param(
        [string]$ScriptPath,
        [string]$OutputPath,
        [hashtable]$Environment
    )

    if ($nativeSh) {
        foreach ($entry in $Environment.GetEnumerator()) {
            Set-Item -Path "Env:\$($entry.Key)" -Value $entry.Value
        }
        & $nativeSh.Source $ScriptPath *> $OutputPath
        return $LASTEXITCODE
    }

    $args = @("-e", "env")
    foreach ($entry in $Environment.GetEnumerator()) {
        $args += "$($entry.Key)=$($entry.Value)"
    }
    $args += @("sh", (ConvertTo-UnixPath $ScriptPath))
    $stderrPath = "$OutputPath.stderr"
    $process = Start-Process -FilePath $wsl.Source -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $OutputPath -RedirectStandardError $stderrPath
    if (Test-Path $stderrPath) {
        Add-Content -Path $OutputPath -Value (Get-Content -Raw $stderrPath)
    }
    return $process.ExitCode
}

function Invoke-ShellChmod {
    param([string]$Path)

    if ($nativeSh -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod +x $Path
        return
    }
    if ($wsl) {
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $stdoutPath = [System.IO.Path]::GetTempFileName()
        try {
            $process = Start-Process -FilePath $wsl.Source -ArgumentList @("-e", "chmod", "+x", (ConvertTo-UnixPath $Path)) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            if ($process.ExitCode -ne 0) {
                throw "chmod failed: $(Get-Content -Raw $stderrPath)"
            }
        }
        finally {
            Remove-Item -Force $stderrPath, $stdoutPath -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ReloadCase {
    param(
        [string]$Name,
        [string]$FakeBody,
        [int]$ExpectedExit,
        [string]$ExpectedStatus
    )

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-reload-test-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $fake = Join-Path $tmp "openresty"
        $state = Join-Path $tmp "reload-status.json"
        Set-Content -Path $fake -Value $FakeBody -NoNewline -Encoding ascii
        if (-not $isWindowsRuntime -or $wsl) {
            Invoke-ShellChmod $fake
        }
        if ($wsl -and -not $nativeSh) {
            $openrestyBin = ConvertTo-UnixPath $fake
            $stateFile = ConvertTo-UnixPath $state
        } else {
            $openrestyBin = $fake
            $stateFile = $state
        }
        $output = Join-Path $tmp "output.txt"
        $exit = Invoke-ShellScript -ScriptPath $script -OutputPath $output -Environment @{
            OPENRESTY_BIN = $openrestyBin
            LITEWAF_RELOAD_STATE_FILE = $stateFile
            LITEWAF_RELOAD_MESSAGE_MAX_LEN = "80"
        }
        if ($exit -ne $ExpectedExit) {
            throw "$Name exit=$exit expected=$ExpectedExit output=$(Get-Content -Raw $output)"
        }
        $json = Get-Content -Raw $state | ConvertFrom-Json
        if ($json.status -ne $ExpectedStatus) {
            throw "$Name status=$($json.status) expected=$ExpectedStatus"
        }
    }
    finally {
        Remove-Item Env:\OPENRESTY_BIN -ErrorAction SilentlyContinue
        Remove-Item Env:\LITEWAF_RELOAD_STATE_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:\LITEWAF_RELOAD_MESSAGE_MAX_LEN -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Invoke-ReloadCase -Name "success" -ExpectedExit 0 -ExpectedStatus "reloaded" -FakeBody @'
#!/bin/sh
if [ "$1" = "-t" ]; then
  echo "syntax is ok"
  exit 0
fi
if [ "$1" = "-s" ] && [ "$2" = "reload" ]; then
  echo "reload ok"
  exit 0
fi
exit 2
'@

Invoke-ReloadCase -Name "validation" -ExpectedExit 1 -ExpectedStatus "validation_failed" -FakeBody @'
#!/bin/sh
if [ "$1" = "-t" ]; then
  echo "bad config"
  exit 1
fi
exit 2
'@

Invoke-ReloadCase -Name "reload" -ExpectedExit 1 -ExpectedStatus "reload_failed" -FakeBody @'
#!/bin/sh
if [ "$1" = "-t" ]; then
  echo "syntax is ok"
  exit 0
fi
if [ "$1" = "-s" ] && [ "$2" = "reload" ]; then
  echo "reload failed"
  exit 1
fi
exit 2
'@

Write-Host "reload-script-test passed"
