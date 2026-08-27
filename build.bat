@echo off
:: ============================================================
::  Rebuilds GamingPerformanceSuite.zip from repository sources.
::  The 3 .bat launcher files are GENERATED during build (not
::  tracked in git) and included in the output ZIP.
::
::  The ZIP is a RUNTIME-ONLY package: it ships the 3 launchers
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
echo - Generating launcher .bat files...
echo - Packaging source files...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "src\Build-Suite.ps1"

echo.
echo Done. The ZIP contains Start-GamingSuite.bat, Start-Watcher-Hidden.bat,
echo and Stop-GamingSuite.bat ready to use (build tooling not included).
pause
