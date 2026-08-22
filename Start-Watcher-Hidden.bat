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

:: Already running? Cheap pid-file probe WITHOUT importing any module -
:: spawning a full PowerShell + module parse here added seconds of startup
:: lag on low-spec PCs. The watcher itself still enforces single-instance
:: via a global mutex, so this is only a friendly early-out.
powershell -NoProfile -Command "$p='.\logs\runtime\watcher.pid'; if (Test-Path $p) { $w=0; [void][int]::TryParse((Get-Content $p -Raw).Trim(), [ref]$w); if ($w -gt 0 -and (Get-Process -Id $w -ErrorAction SilentlyContinue)) { Write-Host 'Watcher is already running.'; exit 9 } }"
if %errorlevel% equ 9 exit /b

start "" /b powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ^
    -File "src\Main.ps1" -BackgroundWatch

echo Background watcher started. It will appear in logs\runtime when a game launches.
echo Stop it with:  Stop-GamingSuite.bat
timeout /t 2 >nul
