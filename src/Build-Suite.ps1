<#
    Build-Suite.ps1 - repacks GamingPerformanceSuite.zip from source.

    After cloning or downloading the repository, run once:
        powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1
    or simply double-click build.bat in the repository root.
#>
[CmdletBinding()]
param(
    [string]$OutputName = 'GamingPerformanceSuite.zip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot

$files = @(
    'Stop-GamingSuite.bat',
    'Start-Watcher-Hidden.bat',
    'Start-GamingSuite.bat',
    'build.bat',
    'README.md',
    '.gitignore',
    'src\Common.psm1',
    'src\Main.ps1',
    'src\Config.ps1',
    'src\DisplayScale.psm1',
    'src\GameBoost.psm1',
    'src\GpuDetect.psm1',
    'src\Build-Suite.ps1'
)

$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
if ($missing.Count -gt 0) {
    throw ('Cannot build - missing file(s): ' + ($missing -join ', '))
}

$outPath = Join-Path $root $OutputName
if (Test-Path -LiteralPath $outPath) {
    Remove-Item -LiteralPath $outPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$fileStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($rel in $files) {
        $full = Join-Path $root $rel
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

$info = Get-Item -LiteralPath $outPath
Write-Host ('Created {0} ({1:N0} bytes, {2} entries)' -f $info.FullName, $info.Length, $files.Count)
