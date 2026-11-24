# Registers SeemlessLauncher.ps1 as a logon task for every interactive user,
# elevated (installers need it; the Seemless account is an administrator,
# created by setup-account.ps1).
# Run as SYSTEM by firstboot.cmd, or elevated from "Enable automatic
# installs.cmd" on a launch drive for VMs installed before this existed.
param([string]$Source = $PSScriptRoot)

$ErrorActionPreference = 'Stop'
$target = Join-Path $env:ProgramData 'Seemless'
New-Item -ItemType Directory -Force -Path $target | Out-Null
$script = Join-Path $target 'SeemlessLauncher.ps1'
$from = Join-Path $Source 'SeemlessLauncher.ps1'
if ((Resolve-Path -LiteralPath $from).Path -ne $script) { Copy-Item -LiteralPath $from -Destination $script -Force }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
# A group principal runs the task in each user's own session at logon.
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath '\Seemless\' -TaskName 'Launcher' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "registered \Seemless\Launcher -> $script"
