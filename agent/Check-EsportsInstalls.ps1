<#
.SYNOPSIS
    Ozarks Tech Esports install monitor - PC agent.

.DESCRIPTION
    Checks that the required games and apps are installed on this PC and reports
    the results (plus free disk space) to the Esports Monitor server.

    The list of apps and how to detect each one comes from the server
    (GET /api/config), so adding a title is a server-side config change.
    The last config received is cached locally so checks still run if the
    server is briefly unreachable.

    Normally run every 15 minutes as SYSTEM by the scheduled task that
    Install-Agent.ps1 creates.

.EXAMPLE
    # Test on a PC without sending anything, using a local copy of config.json
    .\Check-EsportsInstalls.ps1 -ConfigPath ..\server\config.json -DryRun

.EXAMPLE
    # One-off run against the server
    .\Check-EsportsInstalls.ps1 -ServerUrl http://esports-monitor:8080 -AgentKey <key>
#>
[CmdletBinding()]
param(
    [string]$ServerUrl,
    [string]$AgentKey,
    [string]$ConfigPath,   # use a local config.json instead of fetching from the server
    [switch]$DryRun        # print the report instead of sending it
)

$ErrorActionPreference = 'Stop'
$AgentVersion = '1.0.0'

$DataDir          = Join-Path $env:ProgramData 'EsportsMonitor'
$SettingsPath     = Join-Path $DataDir 'agent-settings.json'
$CachedConfigPath = Join-Path $DataDir 'config-cache.json'
$LogPath          = Join-Path $DataDir 'agent.log'

if (-not (Test-Path -LiteralPath $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }
        Add-Content -LiteralPath $LogPath -Value $line
    } catch { }
    Write-Verbose $line
}

# ---------------------------------------------------------------------------
# Settings and config
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $SettingsPath) {
    $saved = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    if (-not $ServerUrl) { $ServerUrl = $saved.ServerUrl }
    if (-not $AgentKey)  { $AgentKey  = $saved.AgentKey }
}
if ($ServerUrl) { $ServerUrl = $ServerUrl.TrimEnd('/') }
if (-not $ServerUrl -and -not $DryRun) {
    Write-Log 'No ServerUrl configured. Run Install-Agent.ps1 or pass -ServerUrl.'
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$headers = @{ 'X-Agent-Key' = [string]$AgentKey }

$config = $null
if ($ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} elseif ($ServerUrl) {
    try {
        $config = Invoke-RestMethod -Uri "$ServerUrl/api/config" -Headers $headers -TimeoutSec 20 -UseBasicParsing
        ConvertTo-Json -InputObject $config -Depth 10 | Set-Content -LiteralPath $CachedConfigPath -Encoding UTF8
    } catch {
        Write-Log "Could not fetch config from server: $($_.Exception.Message)"
    }
}
if (-not $config -and (Test-Path -LiteralPath $CachedConfigPath)) {
    Write-Log 'Using cached config.'
    $config = Get-Content -LiteralPath $CachedConfigPath -Raw | ConvertFrom-Json
}
if (-not $config) {
    Write-Log 'No config available; nothing to check.'
    exit 1
}

# ---------------------------------------------------------------------------
# Environment lookups (cached per run)
# ---------------------------------------------------------------------------
$script:Drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { $_.DeviceID })

$script:Profiles = @(
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'S-1-5-21-*' } |
        ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath } |
        Where-Object { $_ } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -Unique
)

$script:SteamLibs        = $null
$script:EpicItems        = $null
$script:UninstallEntries = $null

function Expand-RulePath([string]$Path) {
    # <ANYDRIVE>    -> every fixed drive (C:, D:, ...)
    # <USERPROFILE> -> every real user profile folder on the PC
    $paths = @($Path)
    if ($Path.Contains('<ANYDRIVE>')) {
        $paths = @(foreach ($p in $paths) { foreach ($d in $script:Drives) { $p.Replace('<ANYDRIVE>', $d) } })
    }
    if ($Path.Contains('<USERPROFILE>')) {
        $paths = @(foreach ($p in $paths) { foreach ($u in $script:Profiles) { $p.Replace('<USERPROFILE>', $u) } })
    }
    @(foreach ($p in $paths) { [Environment]::ExpandEnvironmentVariables($p) })
}

function Find-FirstPath([string]$Path) {
    if ($Path -match '[\*\?]') {
        $hit = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } elseif (Test-Path -LiteralPath $Path) {
        return $Path
    }
    return $null
}

function Get-SteamLibraries {
    if ($null -ne $script:SteamLibs) { return $script:SteamLibs }
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $v = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallPath
        if ($v) { $steam = $v; break }
    }
    if (-not $steam) { $steam = Join-Path ${env:ProgramFiles(x86)} 'Steam' }
    if (Test-Path -LiteralPath $steam) { $libs.Add($steam) }

    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw
        foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
            $lp = $m.Groups[1].Value.Replace('\\', '\')
            if ((Test-Path -LiteralPath $lp) -and -not ($libs -contains $lp)) { $libs.Add($lp) }
        }
    }
    $script:SteamLibs = $libs.ToArray()
    return $script:SteamLibs
}

function Get-EpicManifests {
    if ($null -ne $script:EpicItems) { return $script:EpicItems }
    $items = New-Object System.Collections.Generic.List[object]
    $dir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.item' -ErrorAction SilentlyContinue) {
            try { $items.Add((Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json)) } catch { }
        }
    }
    $script:EpicItems = $items.ToArray()
    return $script:EpicItems
}

function Get-UninstallEntries {
    if ($null -ne $script:UninstallEntries) { return $script:UninstallEntries }
    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    $roots.Add('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    # Per-user installs for anyone currently signed in
    foreach ($h in Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue) {
        if ($h.PSChildName -like 'S-1-5-21-*' -and $h.PSChildName -notlike '*_Classes') {
            $roots.Add("Registry::HKEY_USERS\$($h.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall")
        }
    }
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($r in $roots) {
        if (-not (Test-Path -Path $r)) { continue }
        foreach ($k in Get-ChildItem -Path $r -ErrorAction SilentlyContinue) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName) { $entries.Add($p) }
        }
    }
    $script:UninstallEntries = $entries.ToArray()
    return $script:UninstallEntries
}

# ---------------------------------------------------------------------------
# Rule checks. Each returns $null (no evidence) or a hashtable:
#   installed  - the app is present and playable
#   attention  - present, but an update/repair is pending
#   detail     - human-readable explanation shown on the dashboard
# ---------------------------------------------------------------------------
function New-Result([bool]$Installed, [bool]$Attention, [string]$Detail) {
    @{ installed = $Installed; attention = $Attention; detail = $Detail }
}

function Test-FileRule($Rule) {
    foreach ($p in Expand-RulePath ([string]$Rule.path)) {
        $hit = Find-FirstPath $p
        if ($hit) { return (New-Result $true $false $hit) }
    }
    return $null
}

function Test-SteamRule($Rule) {
    foreach ($lib in Get-SteamLibraries) {
        $acf = Join-Path $lib ('steamapps\appmanifest_{0}.acf' -f $Rule.appid)
        if (-not (Test-Path -LiteralPath $acf)) { continue }
        $text = Get-Content -LiteralPath $acf -Raw

        $flags = 0
        if ($text -match '"StateFlags"\s+"(\d+)"') { $flags = [int64]$Matches[1] }
        $dir = $null
        if ($text -match '"installdir"\s+"([^"]+)"') { $dir = Join-Path $lib ('steamapps\common\' + $Matches[1]) }

        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
            return (New-Result $false $false "Steam lists it in $lib but the game folder is missing")
        }
        if (($flags -band 4) -eq 0) {
            return (New-Result $false $false "Steam shows it as not fully installed (StateFlags $flags)")
        }
        if ($flags -ne 4) {
            return (New-Result $true $true "Steam: update or validation pending (StateFlags $flags)")
        }
        return (New-Result $true $false "Steam ($lib)")
    }
    return $null
}

function Test-EpicRule($Rule) {
    foreach ($it in Get-EpicManifests) {
        $byApp  = $Rule.app_name -and ($it.AppName -eq $Rule.app_name)
        $byName = $Rule.display_name -and ($it.DisplayName -like $Rule.display_name)
        if (-not ($byApp -or $byName)) { continue }

        $loc = [string]$it.InstallLocation
        if (-not $loc -or -not (Test-Path -LiteralPath $loc)) {
            return (New-Result $false $false "Epic lists it but the install folder is missing ($loc)")
        }
        if ($it.LaunchExecutable) {
            $exe = Join-Path $loc $it.LaunchExecutable
            if (-not (Test-Path -LiteralPath $exe)) {
                return (New-Result $false $false "Epic install is broken: game executable missing")
            }
        }
        if ($it.bIsIncompleteInstall -or $it.bNeedsValidation) {
            return (New-Result $true $true 'Epic: install incomplete or needs verification')
        }
        return (New-Result $true $false "Epic Games ($loc)")
    }
    return $null
}

function Test-UninstallRule($Rule) {
    foreach ($e in Get-UninstallEntries) {
        if ($e.DisplayName -notlike $Rule.display_name) { continue }
        $loc = ([string]$e.InstallLocation).Trim().Trim('"')
        if ($loc -and -not (Test-Path -LiteralPath $loc)) {
            return (New-Result $false $false "Listed in Programs, but the folder is missing ($loc)")
        }
        return (New-Result $true $false "Installed program: $($e.DisplayName)")
    }
    return $null
}

function Test-AppxRule($Rule) {
    $pkg = Get-AppxPackage -AllUsers -Name $Rule.package -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { return (New-Result $true $false "Microsoft Store app ($($pkg.Version))") }
    return $null
}

function Test-ServiceRule($Rule) {
    $svc = Get-Service -Name $Rule.name -ErrorAction SilentlyContinue
    if ($svc) { return (New-Result $true $false "Service '$($Rule.name)' present ($($svc.Status))") }
    return $null
}

function Test-App($App) {
    $results = New-Object System.Collections.Generic.List[object]
    $errors  = New-Object System.Collections.Generic.List[string]

    foreach ($rule in @($App.rules)) {
        try {
            $r = switch ([string]$rule.type) {
                'file'      { Test-FileRule $rule }
                'steam'     { Test-SteamRule $rule }
                'epic'      { Test-EpicRule $rule }
                'uninstall' { Test-UninstallRule $rule }
                'appx'      { Test-AppxRule $rule }
                'service'   { Test-ServiceRule $rule }
                default     { throw "Unknown rule type '$($rule.type)'" }
            }
            if ($r) { $results.Add($r) }
        } catch {
            $errors.Add("$($rule.type): $($_.Exception.Message)")
        }
    }

    # Best evidence wins: healthy install > install needing attention > broken install > nothing
    $best = $results | Where-Object { $_.installed -and -not $_.attention } | Select-Object -First 1
    if (-not $best) { $best = $results | Where-Object { $_.installed } | Select-Object -First 1 }
    if (-not $best) { $best = $results | Select-Object -First 1 }
    if (-not $best) { $best = New-Result $false $false 'Not found' }

    [ordered]@{
        id              = [string]$App.id
        name            = [string]$App.name
        installed       = [bool]$best.installed
        needs_attention = [bool]$best.attention
        detail          = [string]$best.detail
        error           = ($errors -join '; ')
    }
}

# ---------------------------------------------------------------------------
# Run checks and report
# ---------------------------------------------------------------------------
$appResults = @(foreach ($app in @($config.apps)) { Test-App $app })

$disks = @(foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
    [ordered]@{
        drive    = $d.DeviceID
        free_gb  = [math]::Round($d.FreeSpace / 1GB, 1)
        total_gb = [math]::Round($d.Size / 1GB, 1)
    }
})

$os = Get-CimInstance Win32_OperatingSystem
$report = [ordered]@{
    hostname      = $env:COMPUTERNAME
    agent_version = $AgentVersion
    checked_at    = (Get-Date).ToUniversalTime().ToString('o')
    os            = "$($os.Caption) ($($os.Version))"
    last_boot     = $os.LastBootUpTime.ToUniversalTime().ToString('o')
    disks         = $disks
    apps          = $appResults
}

$json = ConvertTo-Json -InputObject $report -Depth 6

if ($DryRun) {
    $json
    exit 0
}

try {
    $body = [Text.Encoding]::UTF8.GetBytes($json)
    $resp = Invoke-RestMethod -Uri "$ServerUrl/api/report" -Method Post -Headers $headers -Body $body `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -UseBasicParsing
    $missing = @($appResults | Where-Object { -not $_.installed }).Count
    Write-Log "Report sent. $missing app(s) missing; server sees $($resp.issues) issue(s)."
} catch {
    Write-Log "Report failed: $($_.Exception.Message)"
    exit 2
}
