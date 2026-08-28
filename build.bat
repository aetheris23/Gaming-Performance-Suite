@echo off
:: ============================================================
::  Rebuilds GamingPerformanceSuite.zip from repository sources.
::  The launcher files are GENERATED during build (not tracked
::  in git) and included in the output ZIP:
::    Windows : Start-GamingSuite.bat / Start-Watcher-Hidden.bat /
::              Stop-GamingSuite.bat
::    Linux/macOS: Start-GamingSuite.sh / Start-Watcher-Hidden.sh
::
::  The ZIP is a RUNTIME-ONLY package: it ships the launchers
::  plus the suite. This builder (build.bat + src\Build-Suite.ps1)
::  is deliberately NOT packaged, so extracting the ZIP can never
::  overwrite or duplicate the build tooling.
::
::  Run this once after cloning / downloading the repo.
::  Does NOT require Administrator privileges.
:: ============================================================
title Gaming Performance Suite - Builder

cd /d "%~dp0"

echo Building GamingPerformanceSuite.zip...
echo - Generating launcher files...
echo - Packaging source files...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "src\Build-Suite.ps1"

echo.
echo Done. The ZIP contains the .bat and .sh launchers plus the suite,
echo ready to use (build tooling not included).
pause
