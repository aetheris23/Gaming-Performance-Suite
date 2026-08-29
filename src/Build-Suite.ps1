<#
    Build-Suite.ps1 - repacks GamingPerformanceSuite.zip from source.

    After cloning or downloading the repository, run once:
        powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1
    or simply double-click build.bat in the repository root.

    The launchers are GENERATED during build (not tracked in git) and
    included in the output ZIP so end-users get a ready-to-run package:
      - Start-GamingSuite.bat / Start-Watcher-Hidden.bat / Stop-GamingSuite.bat
        (Windows, PowerShell 5.1+)
      - Start-GamingSuite.sh / Start-Watcher-Hidden.sh (Linux / macOS,
        PowerShell 7+)

    The output ZIP is a RUNTIME-ONLY distribution:
      - includes: the 5 launchers, README.md, .gitignore and the src/ suite
      - EXCLUDES the build tooling (build.bat and src\Build-Suite.ps1),
        so extracting the ZIP can never duplicate or overwrite the builder.
    Rebuild from the source repository, not from the ZIP.
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'GamingPerformanceSuite.zip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot

# ---- Generate .bat launchers in a temp directory ----
$genDir = Join-Path $root '.build_generated'
if (Test-Path $genDir) { Remove-Item $genDir -Recurse -Force }
New-Item -ItemType Directory -Path $genDir -Force | Out-Null

# --- Start-GamingSuite.bat ---
$batStart = @'
@echo off
:: ============================================================
::  Gaming Performance Suite - Launcher (interactive menu)
::  Double-click this file to start. It self-elevates to
::  Administrator (required for priority/power tweaks).
::
::  For fully background operation use Start-Watcher-Hidden.bat
::  instead; stop it with Stop-GamingSuite.bat.
:: ============================================================
title Gaming Performance Suite Launcher

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

echo ============================================
echo   Starting Gaming Performance Suite...
echo ============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "src\Main.ps1"

echo.
echo Suite closed. Press any key to exit.
pause >nul
'@
Set-Content -Path (Join-Path $genDir 'Start-GamingSuite.bat') -Value $batStart -Encoding ASCII

# --- Start-Watcher-Hidden.bat ---
$batWatcher = @'
@echo off
:: ============================================================
::  Starts the Game Watcher HIDDEN in the background.
::  - no console window to keep open or minimize
::  - runs at BelowNormal priority, ~0%% CPU while idle
::  - auto-detects games: boosts them, drops render resolution,
::    restores native on exit
::  Stop it any time with Stop-GamingSuite.bat
:: ============================================================
title Gaming Performance Suite - Background Watcher

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

powershell -NoProfile -Command "$p='.\logs\runtime\watcher.pid'; if (Test-Path $p) { $w=0; [void][int]::TryParse((Get-Content $p -Raw).Trim(), [ref]$w); if ($w -gt 0 -and (Get-Process -Id $w -ErrorAction SilentlyContinue)) { Write-Host 'Watcher is already running.'; exit 9 } }"
if %errorlevel% equ 9 exit /b

start "" /b powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ^
    -File "src\Main.ps1" -BackgroundWatch

echo Background watcher started. It will appear in logs\runtime when a game launches.
echo Stop it with:  Stop-GamingSuite.bat
timeout /t 2 >nul
'@
Set-Content -Path (Join-Path $genDir 'Start-Watcher-Hidden.bat') -Value $batWatcher -Encoding ASCII

# --- Stop-GamingSuite.bat ---
$batStop = @'
@echo off
:: ============================================================
::  Stops the background Game Watcher instantly (kernel event)
::  and restores native resolution / priorities / timer.
:: ============================================================
title Stop Gaming Performance Suite

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Import-Module '.\src\Common.psm1' -Force; Stop-BackgroundWatcher"

echo.
echo Done. This window closes in a moment.
timeout /t 4 >nul
'@
Set-Content -Path (Join-Path $genDir 'Stop-GamingSuite.bat') -Value $batStop -Encoding ASCII

# --- Start-GamingSuite.sh (Linux / macOS) ---
$shStart = @'
#!/usr/bin/env bash
# ============================================================
#  Gaming Performance Suite - Launcher (interactive menu)
#  Linux / macOS entry point. Elevates to root when required
#  (priority/power/network tweaks need root on Unix).
#  Requires PowerShell 7+ (pwsh).
# ============================================================
set -e
cd "$(dirname "$0")"

command -v pwsh >/dev/null 2>&1 || { echo "PowerShell 7+ (pwsh) is required." >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Requesting root privileges (needed for priority/power tweaks)..."
    exec sudo -E pwsh -NoProfile -File "src/Main.ps1"
else
    pwsh -NoProfile -File "src/Main.ps1"
fi
'@
$shStartBytes = [Text.Encoding]::ASCII.GetBytes(($shStart -replace "`r`n", "`n"))
[System.IO.File]::WriteAllBytes((Join-Path $genDir 'Start-GamingSuite.sh'), $shStartBytes)

# --- Start-Watcher-Hidden.sh (Linux / macOS) ---
$shWatcher = @'
#!/usr/bin/env bash
# ============================================================
#  Starts the Game Watcher HIDDEN in the background (Linux/macOS).
#  Auto-detects games: boosts them, drops render resolution,
#  restores native on exit. Stop it with:
#     pwsh -NoProfile -File src/Main.ps1  -> menu option 5, or
#     sudo pwsh -NoProfile -Command "Import-Module ./src/Common.psm1 -Force; Stop-BackgroundWatcher"
# ============================================================
set -e
cd "$(dirname "$0")"

command -v pwsh >/dev/null 2>&1 || { echo "PowerShell 7+ (pwsh) is required." >&2; exit 1; }

PIDFILE="logs/runtime/watcher.pid"
if [ -f "$PIDFILE" ]; then
    W=$(tr -d ' \n' < "$PIDFILE")
    if [ -n "$W" ] && kill -0 "$W" 2>/dev/null; then
        echo "Watcher is already running."
        exit 0
    fi
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Starting background watcher via sudo..."
    exec sudo -b pwsh -NoProfile -File "src/Main.ps1" -BackgroundWatch
else
    nohup pwsh -NoProfile -File "src/Main.ps1" -BackgroundWatch >/dev/null 2>&1 &
    disown
fi
echo "Background watcher started. Stop it anytime with Stop-BackgroundWatcher."
'@
$shWatcherBytes = [Text.Encoding]::ASCII.GetBytes(($shWatcher -replace "`r`n", "`n"))
[System.IO.File]::WriteAllBytes((Join-Path $genDir 'Start-Watcher-Hidden.sh'), $shWatcherBytes)

Write-Host 'Generated launcher files in .build_generated/' -ForegroundColor Green

# ---- Source files that live in the repo ----
# RUNTIME-ONLY package: the build tooling (build.bat, src\Build-Suite.ps1)
# is deliberately excluded from the ZIP so it can never be duplicated or
# overwritten by extracting the distribution over the source tree.
$srcFiles = @(
    'README.md',
    '.gitignore',
    'src\Common.psm1',
    'src\Main.ps1',
    'src\Config.ps1',
    'src\DisplayScale.psm1',
    'src\GameBoost.psm1',
    'src\GpuDetect.psm1',
    'src\NetTune.psm1',
    'src\ColorCorrect.psm1'
)

$missing = @($srcFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missing.Count -gt 0) {
    throw ('Cannot build - missing file(s): ' + ($missing -join ', '))
}

# ---- Combined file list: generated launchers + source files ----
$generatedLaunchers = @(
    'Start-GamingSuite.bat',
    'Start-Watcher-Hidden.bat',
    'Stop-GamingSuite.bat',
    'Start-GamingSuite.sh',
    'Start-Watcher-Hidden.sh'
)
$allFiles = $generatedLaunchers + $srcFiles

$outPath = Join-Path $root $OutputName
if (Test-Path -LiteralPath $outPath) {
    Remove-Item -LiteralPath $outPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fileStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($rel in $allFiles) {
        $full = if ($generatedLaunchers -contains $rel) {
            Join-Path $genDir $rel
        } else {
            Join-Path $root $rel
        }
        $entry = $zip.CreateEntry(($rel.Replace('\', '/')), [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $entryStream.Write($bytes, 0, $bytes.Length)
        } finally {
            $entryStream.Dispose()
        }
    }
} finally {
    $zip.Dispose()
    $fileStream.Dispose()
}

# Cleanup generated files
Remove-Item $genDir -Recurse -Force -ErrorAction SilentlyContinue

$info = Get-Item -LiteralPath $outPath
Write-Host ('Created {0} ({1:N0} bytes, {2} entries) - runtime-only package, builder excluded.' -f $info.FullName, $info.Length, $allFiles.Count)
