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

    Observability contract for the orchestrator (which can only reach the
    guest over SSH, outside this session): all runner output is redirected to
    $LogPath, and the runner's exit code is written to $ExitPath when it
    exits. Tailing the log and watching for the exit file is how an external
    orchestrator follows the runner's lifecycle.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\actions-runner\.jitconfig',
    [string]$RunnerRoot = 'C:\actions-runner',
    [string]$MarkerPath = 'C:\runny\launcher-marker.txt',
    [string]$LogPath = 'C:\runny\runner.log',
    [string]$ExitPath = 'C:\runny\runner-exit.txt',
    [string]$WorkVhdPath = 'C:\runny\work.vhdx'
)

$ErrorActionPreference = 'Stop'

# Anything written to the runner log must be UTF-16LE, because the daemon's
# watcher decodes that file by its byte-order mark and PowerShell's own
# redirect (below) writes UTF-16LE. A UTF-8 line here would leave the file
# mixed-encoding, and every line after it would decode to mojibake -- including
# the "Listening for Jobs" marker the state machine matches on.
function Write-RunnerLog([string]$Message) {
    "runny: $Message" | Out-File -FilePath $LogPath -Append -Encoding Unicode
}

$sessionId = (Get-Process -Id $PID).SessionId
"pid=$PID sessionId=$sessionId started=$(Get-Date -Format o)" | Set-Content -Path $MarkerPath

# Mount the ReFS work volume before the runner can want it, so job file copies
# within the working directory are block clones rather than real writes.
#
# Failure is loud but deliberately NOT fatal. A guest that cannot mount the
# volume still runs jobs correctly, just without the copy acceleration, and
# aborting here would turn a performance feature into an availability one --
# the daemon would destroy and recycle a perfectly serviceable guest. The
# factory smoke test asserts the volume hard instead, so a broken image cannot
# ship in the first place; this path only covers a runtime surprise.
$workDir = Join-Path $RunnerRoot '_work'
try {
    if (-not (Test-Path $WorkVhdPath)) { throw "work volume image missing at $WorkVhdPath" }

    # This block has to be idempotent: the launcher's scheduled task is
    # registered with RestartCount 3, so a crashed launcher re-runs it. Note
    # if/else rather than an early return -- `return` inside a top-level try
    # exits the whole SCRIPT, which would skip starting the runner entirely.
    $existing = Get-Volume -FilePath $workDir -ErrorAction SilentlyContinue
    if ($existing -and $existing.FileSystem -eq 'ReFS') {
        Write-RunnerLog ("ReFS work volume already mounted at {0} ({1:N0} GB)" -f $workDir, ($existing.Size / 1GB))
    } else {
        # Clear a stale registration first. Add-PartitionAccessPath fails with
        # "the requested access path is already in use" if one survives, and the
        # directory is left as a reparse point aimed at a volume that no longer
        # exists -- unusable even for ordinary file creation. mountvol /D is the
        # only thing that removes a mount point whose volume is already gone,
        # since Remove-PartitionAccessPath needs a partition that still resolves.
        & mountvol.exe $workDir /D 2>&1 | Out-Null

        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        # Mount-DiskImage is the Storage module, not Hyper-V: no role is
        # installed in the guest and none is needed to attach a loopback VHDX.
        Mount-DiskImage -ImagePath $WorkVhdPath -StorageType VHDX -Access ReadWrite | Out-Null
        Start-Sleep -Seconds 2
        $disk = Get-DiskImage -ImagePath $WorkVhdPath | Get-Disk
        $part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath $workDir
        Start-Sleep -Seconds 2
        $vol = Get-Volume -FilePath $workDir
        if ($vol.FileSystem -ne 'ReFS') { throw "volume at $workDir reports $($vol.FileSystem), expected ReFS" }
        Write-RunnerLog ("ReFS work volume mounted at {0} ({1:N0} GB)" -f $workDir, ($vol.Size / 1GB))
    }
} catch {
    Write-RunnerLog "WARNING: ReFS work volume unavailable, falling back to NTFS -- file copies inside the job workspace will be slower: $_"
    "refs-mount-failed: $_" | Add-Content -Path $MarkerPath
}

# Test-Path goes true the instant the file is created, not when it's finished
# being written -- so the documented contract requires consumers to stage the
# blob elsewhere and rename it into place. Keep that requirement in the README
# in step with any change here: a plain upload races into a truncated config.
while (-not (Test-Path $ConfigPath)) {
    Start-Sleep -Seconds 2
}

$jitConfig = (Get-Content -Raw $ConfigPath).Trim()
Remove-Item -Force $ConfigPath

# The listener binary is invoked directly rather than through run.cmd:
# run.cmd routes through cmd.exe, whose 8191-character command-line ceiling a
# multi-kilobyte JIT blob can breach, and its run-helper wrapper only exists
# to restart the listener across self-updates -- which JIT-config runners run
# with disabled. Output goes to a log file and the exit code to a marker file
# so the orchestrator can follow the runner's lifecycle over SSH from outside
# this session.
$listener = Join-Path $RunnerRoot 'bin\Runner.Listener.exe'
if (-not (Test-Path $listener)) {
    "ERROR: $listener not found after config arrived" | Add-Content -Path $MarkerPath
    exit 1
}

"launching runner at $(Get-Date -Format o)" | Add-Content -Path $MarkerPath

# Two things here are load-bearing.
#
# `*>>` appends rather than truncating, so the mount diagnostic written above
# survives the runner starting. Same encoding either way (UTF-16LE), so the
# watcher's BOM-keyed decode still reads one consistent stream.
#
# ErrorActionPreference drops to Continue for exactly this call. PowerShell
# surfaces a native command's stderr as error records when the stream is
# redirected, and under Stop the FIRST such line terminates the script --
# verified on this host for both `*>` and `*>>`. That would kill the launcher
# before it wrote the exit-code file, leaving the daemon watching a log that
# stopped and no exit code: a hang exactly when the runner is failing and its
# diagnostics matter most.
$ErrorActionPreference = 'Continue'
& $listener run --jitconfig $jitConfig *>> $LogPath
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
"$code" | Set-Content -Path $ExitPath
"runner exited code=$code at $(Get-Date -Format o)" | Add-Content -Path $MarkerPath
exit $code
