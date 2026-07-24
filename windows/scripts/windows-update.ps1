<#
.SYNOPSIS
    One pass of Windows Update: install whatever's available, report whether
    a reboot is needed. Prints exactly one of:
      WINDOWS_UPDATE: CLEAN
      WINDOWS_UPDATE: REBOOT_REQUIRED

.DESCRIPTION
    Confirmed on real hardware that the eval media does not self-patch --
    this has to be an explicit provisioning step. ALSO confirmed on real
    hardware: the Windows Update Agent refuses download/install operations
    from a remote (SSH) session's token -- "Access denied. You don't have
    permission to perform this task." A pass run inline over SSH reports
    success while installing nothing, and the same updates are re-offered
    forever. So this script (which IS run over SSH) only orchestrates: it
    registers a one-shot scheduled task running as SYSTEM (a local logon,
    which WUA accepts), starts it, and polls for its result.

    build.ps1 calls this in a loop: reboot and repeat while it reports
    REBOOT_REQUIRED, stop at CLEAN. Multiple rounds are normal -- a
    cumulative update unlocks the next batch.
#>
[CmdletBinding()]
param(
    # The big cumulative on stale media is a multi-GB install; be generous.
    [int]$TimeoutMinutes = 120
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers
}

$workerPath = 'C:\wu-worker.ps1'
$resultPath = 'C:\wu-result.txt'
$taskName = 'runny-wu-once'

# The worker runs as SYSTEM via Task Scheduler; everything it knows goes
# into the result file, since we can't see its console.
@'
$ErrorActionPreference = 'Continue'
try {
    Import-Module PSWindowsUpdate
    $updates = Get-WindowsUpdate -MicrosoftUpdate
    if (-not $updates -or $updates.Count -eq 0) {
        Set-Content -Path C:\wu-result.txt -Value 'WINDOWS_UPDATE: CLEAN'
        exit 0
    }
    "installing $($updates.Count) update(s):" | Set-Content -Path C:\wu-progress.txt
    $updates | ForEach-Object { "  $($_.KB) $($_.Title)" } | Add-Content -Path C:\wu-progress.txt
    Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false |
        Out-File -FilePath C:\wu-install-log.txt -Encoding utf8
    if (Get-WURebootStatus -Silent) {
        Set-Content -Path C:\wu-result.txt -Value 'WINDOWS_UPDATE: REBOOT_REQUIRED'
    } else {
        Set-Content -Path C:\wu-result.txt -Value 'WINDOWS_UPDATE: CLEAN'
    }
} catch {
    Set-Content -Path C:\wu-result.txt -Value "WINDOWS_UPDATE: ERROR $_"
}
'@ | Set-Content -Path $workerPath

Remove-Item $resultPath, 'C:\wu-progress.txt' -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File $workerPath"
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes($TimeoutMinutes))
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastProgress = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    if (Test-Path 'C:\wu-progress.txt') {
        $p = (Get-Content 'C:\wu-progress.txt' -Raw -ErrorAction SilentlyContinue)
        if ($p -and $p -ne $lastProgress) { Write-Output $p.Trim(); $lastProgress = $p }
    }
    if (Test-Path $resultPath) {
        $result = (Get-Content $resultPath -Raw).Trim()
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Output $result
        if ($result -like 'WINDOWS_UPDATE: ERROR*') { exit 1 }
        exit 0
    }
}

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Output "WINDOWS_UPDATE: ERROR timed out after $TimeoutMinutes minutes"
exit 1
