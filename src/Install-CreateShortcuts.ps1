<#
    Install-CreateShortcuts.ps1
    Creates Start Menu and Desktop shortcuts for Gaming Performance Suite
    Can be called by installer or manually
#>
param(
    [string]$InstallDir = $PSScriptRoot,
    [switch]$AllUsers,
    [switch]$AddToStartup
)

$ErrorActionPreference = 'Stop'

function New-Shortcut {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = '',
        [string]$IconLocation = '',
        [string]$Description = ''
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LinkPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = if ($WorkingDirectory) { $WorkingDirectory } else { (Split-Path -Parent $TargetPath) }
    $shortcut.IconLocation = if ($IconLocation) { $IconLocation } else { $TargetPath }
    $shortcut.Description = $Description
    $shortcut.Save()
}

# Start Menu
$startMenu = if ($AllUsers) { "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" } else { "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" }
$suiteMenu = Join-Path $startMenu "Gaming Performance Suite"
if (-not (Test-Path $suiteMenu)) { New-Item -ItemType Directory -Path $suiteMenu -Force | Out-Null }

New-Shortcut -LinkPath (Join-Path $suiteMenu "Gaming Performance Suite.lnk") -TargetPath (Join-Path $InstallDir "Start-GamingSuite.bat") -Description "Open Gaming Performance Suite"
New-Shortcut -LinkPath (Join-Path $suiteMenu "Start Watcher (Hidden).lnk") -TargetPath (Join-Path $InstallDir "Start-Watcher-Hidden.bat") -Description "Start background game watcher"
New-Shortcut -LinkPath (Join-Path $suiteMenu "Stop Gaming Performance Suite.lnk") -TargetPath (Join-Path $InstallDir "Stop-GamingSuite.bat") -Description "Stop watcher and restore settings"

# Desktop shortcut
$desktop = [Environment]::GetFolderPath("Desktop")
New-Shortcut -LinkPath (Join-Path $desktop "Gaming Performance Suite.lnk") -TargetPath (Join-Path $InstallDir "Start-GamingSuite.bat") -Description "Gaming Performance Suite"

# Optional startup
if ($AddToStartup) {
    $startup = [Environment]::GetFolderPath("Startup")
    New-Shortcut -LinkPath (Join-Path $startup "Gaming Performance Suite Watcher.lnk") -TargetPath (Join-Path $InstallDir "Start-Watcher-Hidden.bat") -Description "Gaming Performance Suite Background Watcher"
}

Write-Host "Shortcuts created successfully" -ForegroundColor Green
