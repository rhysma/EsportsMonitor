#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the Esports install-monitor agent on this PC.

.DESCRIPTION
    - Copies Check-EsportsInstalls.ps1 to C:\Program Files\EsportsMonitor
    - Saves the server URL and agent key to C:\ProgramData\EsportsMonitor (admins/SYSTEM only)
    - Registers a scheduled task that runs as SYSTEM at startup and every N minutes
    - Runs the first check immediately

    Run from an elevated PowerShell prompt in the folder containing both scripts.
    If your PCs use a reboot-to-restore tool (Deep Freeze, Reboot Restore Rx, etc.),
    install while the machine is thawed.

.EXAMPLE
    .\Install-Agent.ps1 -ServerUrl http://esports-monitor.otc.local:8080 -AgentKey 'paste-key-here'
#>
param(
    [Parameter(Mandatory)][string]$ServerUrl,
    [Parameter(Mandatory)][string]$AgentKey,
    [ValidateRange(5, 1440)][int]$IntervalMinutes = 15
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Esports Install Monitor'

# Check the server is reachable and the key is right before installing anything
$ServerUrl = $ServerUrl.TrimEnd('/')
if ($ServerUrl -like 'http://*') {
    Write-Warning 'ServerUrl uses http://, so the agent key is sent unencrypted. Use https:// for an internet-hosted server.'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    Invoke-RestMethod -Uri "$ServerUrl/api/config" -Headers @{ 'X-Agent-Key' = $AgentKey } -TimeoutSec 20 -UseBasicParsing | Out-Null
    Write-Host "Connected to $ServerUrl and the agent key was accepted."
} catch {
    throw "Couldn't reach $ServerUrl/api/config with this key: $($_.Exception.Message). Check the URL, the key, and that the campus network allows outbound HTTPS to the server."
}

$installDir = Join-Path $env:ProgramFiles 'EsportsMonitor'
$dataDir    = Join-Path $env:ProgramData 'EsportsMonitor'
New-Item -ItemType Directory -Path $installDir, $dataDir -Force | Out-Null

$src = Join-Path $PSScriptRoot 'Check-EsportsInstalls.ps1'
$script = Join-Path $installDir 'Check-EsportsInstalls.ps1'
Copy-Item -LiteralPath $src -Destination $script -Force

# Save settings and restrict the data folder to SYSTEM + Administrators (keeps the key away from students)
[ordered]@{ ServerUrl = $ServerUrl.TrimEnd('/'); AgentKey = $AgentKey } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dataDir 'agent-settings.json') -Encoding UTF8
& icacls.exe $dataDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

$atStartup = New-ScheduledTaskTrigger -AtStartup
$atStartup.Delay = 'PT2M'   # give the network a moment after boot
$repeating = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atStartup, $repeating) `
    -Principal $principal -Settings $settings -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed. '$TaskName' runs every $IntervalMinutes minutes and at startup."
Write-Host "Log file: $(Join-Path $dataDir 'agent.log')"
