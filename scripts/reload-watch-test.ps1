$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo "litewaf-reload-watch.sh"
if (-not (Test-Path $script)) {
    throw "litewaf-reload-watch.sh not found"
}

$nativeSh = Get-Command sh -ErrorAction SilentlyContinue
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $nativeSh -and -not $wsl) {
    throw "Neither sh nor wsl is available to run litewaf-reload-watch.sh"
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

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("litewaf-reload-watch-test-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $watchDir = Join-Path $tmp "watch"
    New-Item -ItemType Directory -Force -Path $watchDir | Out-Null
    Set-Content -Path (Join-Path $watchDir "active.json") -Value "{}" -Encoding ascii

    $reloadScript = Join-Path $tmp "reload.sh"
    $countFile = Join-Path $tmp "reload-count"
    Set-Content -Path $reloadScript -Encoding ascii -NoNewline -Value @'
#!/bin/sh
count_file="$LITEWAF_RELOAD_COUNT_FILE"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
'@

    if ($nativeSh) {
        & $nativeSh.Source -c "chmod +x '$($reloadScript -replace '\\', '/')'"
        $watchPath = $watchDir
        $env:LITEWAF_RELOAD_WATCH_PATH = $watchPath
        $env:LITEWAF_RELOAD_WATCH_INTERVAL = "1"
        $env:LITEWAF_RELOAD_WATCH_DEBOUNCE = "1"
        $env:LITEWAF_RELOAD_SCRIPT = $reloadScript
        $env:LITEWAF_RELOAD_COUNT_FILE = $countFile
        $process = Start-Process -FilePath $nativeSh.Source -ArgumentList @($script) -PassThru -WindowStyle Hidden
    } else {
        $watchPath = ConvertTo-UnixPath $watchDir
        $process = Start-Process -FilePath $wsl.Source -ArgumentList @(
            "-e", "env",
            "LITEWAF_RELOAD_WATCH_PATH=$watchPath",
            "LITEWAF_RELOAD_WATCH_INTERVAL=1",
            "LITEWAF_RELOAD_WATCH_DEBOUNCE=1",
            "LITEWAF_RELOAD_SCRIPT=$(ConvertTo-UnixPath $reloadScript)",
            "LITEWAF_RELOAD_COUNT_FILE=$(ConvertTo-UnixPath $countFile)",
            "sh", (ConvertTo-UnixPath $script)
        ) -PassThru -WindowStyle Hidden
    }

    Start-Sleep -Seconds 2
    Set-Content -Path (Join-Path $watchDir "active.json") -Value '{"version":"test"}' -Encoding ascii

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $countFile) -and ((Get-Content -Raw $countFile).Trim() -ge 1)) {
            Write-Host "reload-watch-test passed"
            return
        }
        Start-Sleep -Milliseconds 500
    }

    throw "watcher did not invoke reload after config change"
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:\LITEWAF_RELOAD_WATCH_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\LITEWAF_RELOAD_WATCH_INTERVAL -ErrorAction SilentlyContinue
    Remove-Item Env:\LITEWAF_RELOAD_WATCH_DEBOUNCE -ErrorAction SilentlyContinue
    Remove-Item Env:\LITEWAF_RELOAD_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item Env:\LITEWAF_RELOAD_COUNT_FILE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
