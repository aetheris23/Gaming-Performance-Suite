@echo off
:: ============================================================
::  Rebuilds GamingPerformanceSuite.zip from repository sources.
::  Run this once after cloning / downloading the repo.
::  Does NOT require Administrator privileges.
:: ============================================================
title Gaming Performance Suite - Builder

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "src\Build-Suite.ps1"

echo.
echo Done. You can now use Start-Watcher-Hidden.bat as usual.
pause
