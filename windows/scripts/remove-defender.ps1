# remove-defender.ps1 -- take Microsoft Defender out of the image entirely.
#
# Why at all: this image runs one CI job and is then destroyed. Defender's value
# is overwhelmingly about persistence and dwell time, neither of which exists
# here, and it charges for that with real-time scanning of exactly the workload
# a build generates -- thousands of short-lived compiler outputs, package
# extractions and test binaries. The controls that actually bound a hostile job
# are the hypervisor boundary and the guest's network posture, not a signature
# scanner running inside the disposable guest.
#
# Why removal rather than `Set-MpPreference -DisableRealtimeMonitoring`: Tamper
# Protection can revert or silently ignore that toggle, which is the worst
# outcome -- an image that looks hardened and isn't. Uninstalling the feature is
# decisive and verifiable from outside the guest (smoke-test.ps1 checks the
# engine binary is gone from the sealed VHDX).
#
# Why not exclusions: a Windows toolchain scatters across %TEMP%, NuGet and pip
# caches, MSBuild intermediates and the runner's own tree, so a path list is a
# maintenance burden that silently goes stale as the toolchain grows.
#
# Server SKUs ship Defender as an optional feature, which is what makes this
# possible at all; on client Windows it is not removable.

$ErrorActionPreference = 'Stop'

$installed = Get-WindowsFeature |
    Where-Object { $_.Name -like 'Windows-Defender*' -and $_.Installed }

if (-not $installed) {
    # Not a silent pass: if a future base image ships without Defender that is
    # worth seeing in the build log rather than inferring from its absence.
    Write-Host 'defender: no installed Windows-Defender features; nothing to remove'
    return
}

Write-Host ("defender: removing " + (($installed.Name) -join ', '))

# -Remove deletes the payload from the component store as well as disabling the
# feature. That matters here beyond tidiness: this image ships as a disk image
# over a registry, so anything left in WinSxS is paid for on every pull.
$result = Uninstall-WindowsFeature -Name $installed.Name -Remove

if (-not $result.Success) {
    throw "defender: Uninstall-WindowsFeature failed (exit $($result.ExitCode))"
}

Write-Host "defender: removed; restart needed = $($result.RestartNeeded)"

# The caller reboots immediately after this script, which completes the removal.
# Nothing here waits for it -- see build.ps1's stage 4.
