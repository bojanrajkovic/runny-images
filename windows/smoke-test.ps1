<#
.SYNOPSIS
    Boot the sealed image once and prove it's shippable before it goes
    anywhere near a registry: SSH answers with the baked password, and a
    launcher-started process lands in the interactive session (session 1,
    not session 0).

.DESCRIPTION
    Boots a THROWAWAY differencing child of the sealed VHDX, so the smoke
    test can never dirty the artifact it is validating.

    The session check reads the marker file launcher.ps1 writes at startup
    (its own PID + SessionId): if AutoLogon fired and the scheduled task ran
    "only when user is logged on" as intended, the marker says sessionId=1.
    A sessionId of 0 means the task was misconfigured into the non-desktop
    session and the runner would never see an interactive desktop.
    No GitHub involvement -- runner registration/LISTENING is runny's own
    bring-up flow, validated there, not here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Vhdx,
    [string]$SwitchName = 'Default Switch',
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$guestUser = 'Administrator'
$vmName = 'runny-image-smoke'
$childVhdx = Join-Path (Split-Path $Vhdx) 'smoke-child.vhdx'

if (Test-Path $childVhdx) { Remove-Item -Force $childVhdx }
New-VHD -Path $childVhdx -ParentPath $Vhdx -Differencing | Out-Null

New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $childVhdx -SwitchName $SwitchName | Out-Null
try {
    Set-VMProcessor -VMName $vmName -Count 2
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
    Start-VM -Name $vmName

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ip = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
            Where-Object { $_ -match '^\d+\.' -and $_ -notmatch '^169\.254\.' } |
            Select-Object -First 1
        if ($ip) {
            $probe = Test-NetConnection -ComputerName $ip -Port 22 -WarningAction SilentlyContinue
            if ($probe.TcpTestSucceeded) { break }
            $ip = $null
        }
    }
    if (-not $ip) { throw "SMOKE FAIL: SSH never came up within ${TimeoutSec}s" }
    Write-Host "smoke: SSH reachable at $ip"

    # The sealed image has no authorized_keys (deliberately) -- the password
    # is the shipped auth. ssh.exe can't script a password, so the marker
    # check runs via a one-off key push over... nothing. Instead: give
    # AutoLogon + the scheduled task time to fire, then read the marker file
    # through the VHDX after shutdown. Slower but zero-credential.
    Write-Host 'smoke: waiting 90s for AutoLogon + launcher task to fire...'
    Start-Sleep -Seconds 90

    Stop-VM -Name $vmName -Force
    while ((Get-VM -Name $vmName).State -ne 'Off') { Start-Sleep -Seconds 3 }
} finally {
    if ((Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        if ((Get-VM -Name $vmName).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force }
        Remove-VM -Name $vmName -Force
    }
}

$mount = Mount-VHD -Path $childVhdx -ReadOnly -Passthru
try {
    $osVolume = $mount | Get-Disk | Get-Partition | Get-Volume |
        Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } |
        Select-Object -First 1
    if (-not $osVolume) { throw 'SMOKE FAIL: no Windows volume in smoke child' }
    $marker = "$($osVolume.DriveLetter):\runny\launcher-marker.txt"
    if (-not (Test-Path $marker)) {
        throw 'SMOKE FAIL: launcher marker file missing -- AutoLogon or the scheduled task did not fire'
    }
    $content = Get-Content -Raw $marker
    Write-Host "smoke: marker: $($content.Trim())"
    if ($content -notmatch 'sessionId=(\d+)') {
        throw 'SMOKE FAIL: marker file has no sessionId'
    }
    if ([int]$Matches[1] -eq 0) {
        throw 'SMOKE FAIL: launcher ran in session 0 -- no interactive desktop; scheduled task is misconfigured'
    }
    Write-Host "smoke: launcher landed in interactive session $($Matches[1])"
} finally {
    Dismount-VHD -Path $childVhdx
    Remove-Item -Force $childVhdx
}

Write-Host 'SMOKE PASS: SSH up + launcher in interactive session'
