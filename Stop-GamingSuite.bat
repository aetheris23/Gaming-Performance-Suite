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
