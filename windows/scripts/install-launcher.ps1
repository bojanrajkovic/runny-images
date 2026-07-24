<#
.SYNOPSIS
    Bake AutoLogon + the interactive-session launcher into the image.

.DESCRIPTION
    AutoLogon (Administrator/Administrator, same well-known non-secret creds
    as the guest login itself) fires the console logon on every boot;
    the Task Scheduler task then starts launcher.ps1 IN that interactive
    session (session 1, not session 0) the moment logon completes. This is
    the GitHub Actions community's own documented workaround for UI-capable
    Windows runners (community discussion #67003) -- `actions/runner` has no
    built-in AutoLogon-aware mode.

    "Run only when user is logged on" (LogonType Interactive below), NOT
    "whether logged on or not" -- the latter runs in session 0, no desktop,
    defeating the entire point.

    launcher.ps1 itself must be copied alongside this script to
    C:\runny\launcher.ps1 before this runs -- see build.ps1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not (Test-Path 'C:\runny\launcher.ps1')) {
    throw "C:\runny\launcher.ps1 not found -- build.ps1 must copy it into place before running this script"
}

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value 'Administrator'
Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value 'Administrator'
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value '.'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\runny\launcher.ps1'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User 'Administrator'
# LogonType Interactive == Task Scheduler's "Run only when user is logged on".
$principal = New-ScheduledTaskPrincipal -UserId 'Administrator' -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName 'runny-launcher' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "AutoLogon + runny-launcher scheduled task installed"
