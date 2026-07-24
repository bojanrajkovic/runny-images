<#
.SYNOPSIS
    Baked into the image at C:\runny\launcher.ps1. Runs in the interactive
    session (session 1) at every AutoLogon via the runny-launcher scheduled
    task, waits for the per-cycle runner config to arrive over SSH, then
    starts the Actions runner in this session.

.DESCRIPTION
    Why this exists: an SSH-spawned process is never in the console session,
    so the host can't start the runner in the interactive desktop directly.
    Instead the host SSH-drops the JIT config at a known path and this
    already-running launcher picks it up. The config is read then deleted
    immediately -- it's a one-shot registration credential and should not
    outlive its use on disk.

    Polls rather than sleeping a fixed interval: config delivery timing
    depends on the host's provisioning flow, not on anything knowable here.

    Deliberately Windows PowerShell 5.1 compatible (no pwsh-isms): the
    launcher must work even if the optional toolchain layer (which carries
    PowerShell 7) is broken or absent.

    The marker file written at startup (session ID + PID) is what the
    factory's smoke test reads to prove launcher processes land in session 1,
    without needing any GitHub involvement.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\actions-runner\.jitconfig',
    [string]$RunnerRoot = 'C:\actions-runner',
    [string]$MarkerPath = 'C:\runny\launcher-marker.txt'
)

$ErrorActionPreference = 'Stop'

$sessionId = (Get-Process -Id $PID).SessionId
"pid=$PID sessionId=$sessionId started=$(Get-Date -Format o)" | Set-Content -Path $MarkerPath

while (-not (Test-Path $ConfigPath)) {
    Start-Sleep -Seconds 2
}

$jitConfig = (Get-Content -Raw $ConfigPath).Trim()
Remove-Item -Force $ConfigPath

$runCmd = Join-Path $RunnerRoot 'run.cmd'
if (-not (Test-Path $runCmd)) {
    "ERROR: $runCmd not found after config arrived" | Add-Content -Path $MarkerPath
    exit 1
}

"launching runner at $(Get-Date -Format o)" | Add-Content -Path $MarkerPath
& $runCmd --jitconfig $jitConfig
