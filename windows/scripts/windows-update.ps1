<#
.SYNOPSIS
    One pass of Windows Update: install whatever's available, report whether
    a reboot is needed.

.DESCRIPTION
    Confirmed on real hardware that the eval media does not self-patch --
    wuauserv runs but nothing auto-installs, and a fresh WS2025 eval VHDX
    was still sitting ~2 years stale (last patched Sept 2024). This has to be
    an explicit provisioning step, not assumed.

    build.ps1 calls this in a loop: each pass installs what's currently
    offered, then reboots and reconnects if this script reports
    REBOOT_REQUIRED, repeating until a pass reports CLEAN (no updates found).
    A single pass is not enough -- Windows Update commonly needs several
    rounds (a cumulative update unlocks the next batch) to actually reach
    "nothing pending".
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers
}
Import-Module PSWindowsUpdate

$updates = Get-WindowsUpdate -MicrosoftUpdate
if (-not $updates -or $updates.Count -eq 0) {
    Write-Output "WINDOWS_UPDATE: CLEAN"
    exit 0
}

Write-Output "found $($updates.Count) update(s), installing..."
$result = Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false -Verbose

$rebootPending = Get-WURebootStatus -Silent
if ($rebootPending) {
    Write-Output "WINDOWS_UPDATE: REBOOT_REQUIRED"
} else {
    Write-Output "WINDOWS_UPDATE: CLEAN"
}
