#Requires -RunAsAdministrator
# Removes the Esports install-monitor agent from this PC.
# (To also drop the PC from the dashboard, use the Remove button there.)
$ErrorActionPreference = 'SilentlyContinue'
Unregister-ScheduledTask -TaskName 'Esports Install Monitor' -Confirm:$false
Remove-Item -LiteralPath (Join-Path $env:ProgramFiles 'EsportsMonitor') -Recurse -Force
Remove-Item -LiteralPath (Join-Path $env:ProgramData 'EsportsMonitor') -Recurse -Force
Write-Host 'Esports Install Monitor agent removed.'
