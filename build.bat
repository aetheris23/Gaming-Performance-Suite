@echo off
setlocal
:: ============================================================
::  Builds Gaming Performance Suite v3.2 from repository sources.
::  The launcher files are GENERATED during build (not tracked
::  in git) and included in the output ZIP:
::    Windows : Start-GamingSuite.bat / Start-Watcher-Hidden.bat /
::              Stop-GamingSuite.bat
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
if errorlevel 1 (
    echo ERROR: Could not enter the project directory.
    pause
    exit /b 1
)

echo Building GamingPerformanceSuite.zip...
echo - Generating launcher files...
echo - Packaging source files...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "src\Build-Suite.ps1"
if errorlevel 1 (
    echo.
    echo ERROR: Build failed. Review the PowerShell error above.
    pause
    exit /b 1
)

if not exist "GamingPerformanceSuite.zip" (
    echo.
    echo ERROR: The build completed without creating GamingPerformanceSuite.zip.
    pause
    exit /b 1
)

echo.
echo Build succeeded: GamingPerformanceSuite.zip is ready to extract.
echo The archive contains runtime files only; build tooling is excluded.
pause
exit /b 0
