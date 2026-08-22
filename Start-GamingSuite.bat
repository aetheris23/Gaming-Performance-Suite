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

:: Re-launch self as Administrator if not already elevated
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Jump to the drive+path of this script so relative paths work
cd /d "%~dp0"

echo ============================================
echo   Starting Gaming Performance Suite...
echo ============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "src\Main.ps1"

echo.
echo Suite closed. Press any key to exit.
pause >nul
