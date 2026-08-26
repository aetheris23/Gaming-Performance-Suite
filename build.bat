@echo off
:: ============================================================
::  Rebuilds GamingPerformanceSuite.zip from repository sources.
::  The 3 .bat launcher files are GENERATED during build (not
::  tracked in git) and included in the output ZIP.
::
::  Run this once after cloning / downloading the repo.
::  Does NOT require Administrator privileges.
:: ============================================================
title Gaming Performance Suite - Builder

cd /d "%~dp0"

echo Building GamingPerformanceSuite.zip...
echo - Generating launcher .bat files...
echo - Packaging source files...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "src\Build-Suite.ps1"

echo.
echo Done. The ZIP contains Start-GamingSuite.bat, Start-Watcher-Hidden.bat,
echo and Stop-GamingSuite.bat ready to use.
pause
