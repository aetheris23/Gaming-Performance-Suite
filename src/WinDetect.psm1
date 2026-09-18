# ============================================================
#  WinDetect.psm1 - Windows build / edition / flavor detection
#
#  Auto-detects the SPECIFIC Windows version running on the PC
#  so the suite can adapt to every official and custom build:
#
#    - Version           10.0.x, 10 vs 11, Server vs client
#    - Feature release   DisplayVersion (21H2 / 22H2 / 23H2 / 24H2)
#    - Build/UBR         19045.4894, 26100.3830, ...
#    - Edition           Pro / Home / Enterprise / LTSC / Server
#    - Flavor            Standard | ReviOS | AtlasOS | GhostSpectre
#                         | Tiny11 | LTSC | Server | Unknown
#
#  Custom debloated builds (ReviOS, AtlasOS, Ghost Spectre,
#  Tiny11, ...) routinely REMOVE components that stock Windows
#  ships with - most importantly the stock "High performance"
#  power scheme that the old power-plan code tried to duplicate.
#  Knowing the flavor up front lets the suite pick safe
#  fallbacks (clone the ACTIVE scheme instead) and skip actions
#  whose tools were stripped away (e.g. no powercfg, no netsh).
#
#  Feature probes are cheap and run once, then cached:
#    PowerCfgAvailable, HighPerfPowerPlan, UltimatePowerPlan,
#    ActivePowerGuid, NetshWlanAvailable, MmcssGamesClass,
#    WindowsPowerShellAvailable.
#
#  All probes are best-effort and never throw - on a machine
#  where a tool was removed, or a value is missing, the probe
#  simply reports the safe default.
# ============================================================

Set-StrictMode -Version Latest

$script:WinInfoCache = $null

function Get-RegValue {
    <# Reads a registry value; returns $null when missing/unreadable. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Get-WindowsFlavor {
    <#
        Best-effort identification of the installed Windows flavor:
        Standard | ReviOS | AtlasOS | GhostSpectre | Tiny11 | LTSC | Server | Unknown.

        Detection is HEURISTIC. Custom builds do not expose an official
        "I am ReviOS" registry key, so we combine well-known marker keys,
        ProductName/InstallationType strings and RequiredProductId-style
        conventions. It is advisory only: the suite never hard-depends on
        the verdict - it only uses it to pick safer fallbacks.
    #>
    param(
        [AllowNull()]$BuildInfo
    )

    $product    = ''
    $instType   = ''
    $productKey = $null
    if ($BuildInfo) {
        $productKey = $BuildInfo.ProductName
        $instType   = [string]$BuildInfo.InstallationType
    }
    if ($productKey) { $product = ([string]$productKey).ToLowerInvariant() }
    $it = $instType.ToLowerInvariant()

    # ---- Server first (never classify a server as a "desktop" flavor) ----
    if ($product -match 'server' -or $it -match 'server') { return 'Server' }

    # ---- LTSC / LTSB ----
    if ($product -match 'ltsc|ltsb') { return 'LTSC' }

    # ---- ReviOS ----
    if ((Test-Path 'HKLM:\SOFTWARE\ReviOS') -or $product -match 'revi') { return 'ReviOS' }

    # ---- AtlasOS ----
    if ((Test-Path 'HKLM:\SOFTWARE\AtlasOS') -or $product -match 'atlas') { return 'AtlasOS' }

    # ---- Ghost Spectre (often renames the edition, eg "Windows 11 Pro G") ----
    if ((Test-Path 'HKLM:\SOFTWARE\GhostToolkit') -or $product -match 'ghostspectre|ghost spectre|\bbuild\s*(?:of\s*)?g\b|\s\bg\s*(?:build)?$') { return 'GhostSpectre' }

    # ---- Tiny11 (installer/applier; marker key when available) ----
    if ((Test-Path 'HKLM:\SOFTWARE\Tiny11') -or $product -match 'tiny11') { return 'Tiny11' }

    # ---- Desktop build 10/11 with an unidentifiable ProductName ----
    if (-not $product -or $product -match '^windows\s*(10|11)\s*$' -or $product -match 'unknown') { return 'Unknown' }

    return 'Standard'
}

function Get-WindowsBuildInfo {
    <#
        Gathers and caches a complete Windows identity: version, build,
        UBR, feature release, edition, flavor (ReviOS/AtlasOS/...) and the
        presence of the tools/schemes this suite relies on.
        Use -Refresh to re-probe (rare).
        Never throws - every probe degrades to a safe default.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:WinInfoCache) { return $script:WinInfoCache }

    $nv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $productName = [string](Get-RegValue -Path $nv -Name 'ProductName')
    $editionId   = [string](Get-RegValue -Path $nv -Name 'EditionID')
    $instType    = [string](Get-RegValue -Path $nv -Name 'InstallationType')
    $buildRaw    = [string](Get-RegValue -Path $nv -Name 'CurrentBuildNumber')
    $ubrRaw      = [string](Get-RegValue -Path $nv -Name 'UBR')
    $displayVer  = [string](Get-RegValue -Path $nv -Name 'DisplayVersion')
    $releaseId   = [string](Get-RegValue -Path $nv -Name 'ReleaseId')

    $build = 0; [void][int]::TryParse($buildRaw, [ref]$build)
    $ubr   = 0; [void][int]::TryParse($ubrRaw,  [ref]$ubr)

    $isServer = ([bool]($productName -match 'server') -or [bool]([string]$instType -match 'server'))
    $isWin10  = (-not $isServer -and $build -gt 0 -and $build -lt 22000)
    $isWin11  = (-not $isServer -and $build -ge 22000)

    $featureRelease = $displayVer
    if (-not $featureRelease -and $releaseId) { $featureRelease = $releaseId }
    if (-not $featureRelease)                 { $featureRelease = "build $build" }

    # ---- edition short name ----
    $edition = 'Unknown'
    $e = $editionId.ToLowerInvariant()
    if      ($e -match 'iotenterprise.?s')  { $edition = 'IoT Enterprise LTSC' }
    elseif  ($e -match 'enterprise.?s')     { $edition = 'Enterprise LTSC' }
    elseif  ($e -match 'professionalw')     { $edition = 'Pro for Workstations' }
    elseif  ($e -match 'professionaleducation') { $edition = 'Pro Education' }
    elseif  ($e -match 'professional')       { $edition = 'Pro' }
    elseif  ($e -match 'enterprise')         { $edition = 'Enterprise' }
    elseif  ($e -match 'education')          { $edition = 'Education' }
    elseif  ($e -match 'home')               { $edition = 'Home' }
    elseif  ($isServer)                      { $edition = 'Server' }
    else                                     { $edition = $editionId }
    if (-not $edition -or $edition -eq 'Unknown') { $edition = $productName }

    # ---- tool / scheme probes ----
    $powerCfg = Get-Command powercfg -ErrorAction SilentlyContinue
    $netsh    = Get-Command netsh    -ErrorAction SilentlyContinue
    $ps51     = Get-Command powershell.exe -ErrorAction SilentlyContinue

    $highPerfPlan = $false
    $ultimatePlan = $false
    $activeGuid   = $null
    if ($powerCfg) {
        try {
            $schemes = @(& powercfg /list 2>$null)
            $schemesText = ($schemes -join "`n")
            $highPerfPlan = ($schemesText -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
            $ultimatePlan = ($schemesText -match 'e9a42b02-d5df-448d-aa00-03f14749eb61')
            $activeOut = (& powercfg /getactivescheme 2>$null | Out-String)
            if ($activeOut -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $activeGuid = $Matches[1].ToLowerInvariant()
            }
        } catch { }
    }

    $mmcssGames = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'

    $flavor = Get-WindowsFlavor -BuildInfo ([pscustomobject]@{
        ProductName       = $productName
        InstallationType  = $instType
    })

    $info = @{
        IsWindows                 = $true
        IsWindows10               = $isWin10
        IsWindows11               = $isWin11
        IsWindowsServer           = $isServer
        Version                   = '10.0'
        Build                     = $build
        UBR                       = $ubr
        FullBuild                 = if ($build -gt 0) { (if ($ubr -gt 0) { '{0}.{1}' -f $build, $ubr } else { [string]$build }) } else { 'unknown' }
        Edition                   = $edition
        EditionId                 = $editionId
        ProductName               = $productName
        InstallationType          = $instType
        DisplayVersion            = $featureRelease
        Flavor                    = $flavor
        IsDebloated               = ($flavor -in @('ReviOS','AtlasOS','GhostSpectre','Tiny11','Unknown'))
        PowerCfgAvailable         = [bool]$powerCfg
        HighPerfPowerPlan         = $highPerfPlan
        UltimatePowerPlan         = $ultimatePlan
        ActivePowerGuid           = $activeGuid
        NetshWlanAvailable        = [bool]$netsh
        WindowsPowerShellAvailable= [bool]$ps51
        MmcssGamesClass           = $mmcssGames
    }
    # remove nulls so StrictMode consumers don't trip
    foreach ($k in @($info.Keys)) { if ($null -eq $info[$k]) { $info[$k] = '' } }

    $script:WinInfoCache = $info
    return $info
}

function Get-OsStatusLine {
    <# Compact one-line OS summary for banners/status:
       "Windows 11 Pro 24H2 (build 26100.3830) [ReviOS]" #>
    param([switch]$Refresh)
    $os = Get-WindowsBuildInfo -Refresh:$Refresh
    $flavorTag = if ($os.Flavor -ne 'Standard') { " [{0}]" -f $os.Flavor } else { '' }
    if ($os.IsWindowsServer) { $t = 'Windows Server' } else { $t = if ($os.IsWindows11) { 'Windows 11' } elseif ($os.IsWindows10) { 'Windows 10' } else { 'Windows' } }
    return ('{0} {1} {2} (build {3}){4}' -f $t, $os.Edition, $os.DisplayVersion, $os.FullBuild, $flavorTag)
}

Export-ModuleMember -Function Get-WindowsBuildInfo, Get-WindowsFlavor, Get-OsStatusLine