#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs (or upgrades) the Esports Monitor server on a Windows machine.

.DESCRIPTION
    - Copies the server files to C:\EsportsMonitor\server
      (on an upgrade, your existing config.json and monitor.db are kept)
    - Restricts that folder to Administrators, SYSTEM and LOCAL SERVICE (config.json holds secrets)
    - Checks config.json is valid (real agent key, dashboard password)
    - Registers a scheduled task "Esports Monitor Server" that runs as LOCAL SERVICE at
      startup, and re-checks every 5 minutes so it comes back if it ever stops
    - Starts it and confirms it answers on localhost

    Requires Python 3.9+ installed from python.org with "Install for all users"
    (the Microsoft Store version can't be used by a background service).

.EXAMPLE
    # From the unzipped kit, in an elevated PowerShell window:
    .\deploy\windows\Install-Server.ps1
#>
param(
    [string]$InstallDir = 'C:\EsportsMonitor',
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
$TaskName  = 'Esports Monitor Server'
$kitServer = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'server'
$serverDir = Join-Path $InstallDir 'server'

# --- Python -----------------------------------------------------------------
if (-not $PythonPath) {
    $candidates = @(Get-Command python.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }) +
                  @(Get-ChildItem "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $PythonPath = $candidates |
        Where-Object { $_ -and $_ -notmatch '\\WindowsApps\\' -and $_ -notmatch '\\AppData\\' } |
        Select-Object -First 1
}
if (-not $PythonPath -or -not (Test-Path -LiteralPath $PythonPath)) {
    throw "No all-users Python found. Install Python 3.9+ from python.org, choose 'Customize installation' > 'Install Python for all users', then re-run (or pass -PythonPath)."
}
$ok = & $PythonPath -c "import sys; print(sys.version_info >= (3, 9))"
if ($ok -ne 'True') { throw "$PythonPath is older than Python 3.9." }
Write-Host "Using Python: $PythonPath"

# --- Files ------------------------------------------------------------------
$upgrade = Test-Path -LiteralPath (Join-Path $serverDir 'config.json')
New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
foreach ($f in 'server.py', 'dashboard.html', 'config.json') {
    if ($f -eq 'config.json' -and $upgrade) { continue }   # never overwrite your settings
    Copy-Item -LiteralPath (Join-Path $kitServer $f) -Destination $serverDir -Force
}
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-19:(OI)(CI)M' | Out-Null

$configPath = Join-Path $serverDir 'config.json'
if (-not $upgrade) {
    Write-Host ''
    Write-Host "Copied a fresh config.json to $configPath" -ForegroundColor Yellow
    Write-Host 'Edit agent_key, dashboard_password and dashboard_url, then run this script again.' -ForegroundColor Yellow
    Write-Host "Random key you can paste in:  $(& $PythonPath -c 'import secrets; print(secrets.token_urlsafe(32))')"
    exit 0
}

# --- Validate config --------------------------------------------------------
& $PythonPath (Join-Path $serverDir 'server.py') --check
if ($LASTEXITCODE -ne 0) { throw "Fix config.json ($configPath) and run this script again." }
$port = (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).listen_port
if (-not $port) { $port = 8080 }

# --- Scheduled task ---------------------------------------------------------
$action = New-ScheduledTaskAction -Execute $PythonPath `
    -Argument ('"{0}"' -f (Join-Path $serverDir 'server.py')) -WorkingDirectory $serverDir
$atStartup = New-ScheduledTaskTrigger -AtStartup
$watchdog  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atStartup, $watchdog) `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

# --- Confirm it's answering ---------------------------------------------------
$up = $false
foreach ($i in 1..10) {
    Start-Sleep -Seconds 1
    try { Invoke-RestMethod "http://127.0.0.1:$port/healthz" -TimeoutSec 3 -UseBasicParsing | Out-Null; $up = $true; break } catch { }
}
if ($up) {
    Write-Host "Esports Monitor is running on http://127.0.0.1:$port (local only)." -ForegroundColor Green
    Write-Host 'Next: point your IIS site at it (see README, step 1d).'
} else {
    Write-Warning "The task started but the server isn't answering. Check $(Join-Path $serverDir 'monitor.log')."
}
