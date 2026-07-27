<#
.SYNOPSIS
    Online-activate this Windows Server evaluation install if it is not
    already activated, and verify it holds a usable share of the real 180-day
    evaluation window rather than the 10-day pre-activation grace period.

.DESCRIPTION
    Deliberately uses `slmgr /ato`, never `/rearm` -- confirmed on real
    hardware that `/rearm` on a not-yet-activated machine only resets the
    10-day "Initial grace period" window, it does not grant the real 180-day
    evaluation. `/ato` is fast (seconds) and worked cleanly over the Default
    Switch NAT path in testing.

    Runs ONCE per factory build, against the parent, never per ephemeral
    guest boot: activation would otherwise add Microsoft's servers as a
    dependency of every job's boot, and every differencing child shares the
    same inherited Installation ID, so calling /ato from what looks like the
    same machine identity on every cycle risks tripping activation-abuse
    detection. A build-time call is a fundamentally gentler shape.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# An image must not ship with less evaluation left than this. A short window is
# invisible at build time -- the image packs, smoke-tests and publishes clean --
# and shows up in the field as guests shutting down hourly.
$minRemainingDays = 45

function Get-Dlv { (cscript.exe //nologo C:\Windows\System32\slmgr.vbs /dlv) -join "`n" }

$dlv = Get-Dlv

if ($dlv -match 'License Status:\s*Licensed') {
    # Already licensed: a build resuming from an already-activated base. Do NOT
    # call /ato again. It re-contacts Microsoft from an Installation ID this
    # image has already activated with -- the abuse-detection shape the header
    # warns about -- and was observed hanging indefinitely with the guest fully
    # responsive and idle, where a first activation completes in seconds.
    Write-Output 'already licensed -- skipping /ato'
} else {
    # /ato reaches Microsoft's activation service over the network, so it can
    # fail for reasons that have nothing to do with this image -- observed once
    # as 0x8004FE93, which then succeeded unchanged on the very next attempt.
    # One blip should not cost an hour-long build. The retries stay deliberately
    # gentle: hammering /ato from a single inherited identity is the shape abuse
    # detection looks for, and three spaced attempts are nowhere near it.
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        cscript.exe //nologo C:\Windows\System32\slmgr.vbs /ato
        if ($LASTEXITCODE -eq 0) { break }
        if ($i -eq $attempts) {
            throw "slmgr /ato exited $LASTEXITCODE after $attempts attempts"
        }
        $delay = 30 * $i
        Write-Output "slmgr /ato exited $LASTEXITCODE; retrying in $delay s (attempt $($i + 1)/$attempts)"
        Start-Sleep -Seconds $delay
    }
    $dlv = Get-Dlv
}

Write-Output $dlv

if ($dlv -notmatch 'License Status:\s*Licensed') {
    throw "activation did not result in License Status: Licensed -- refusing to seal an un-activated image. Output above."
}

# Verify rather than assume. Skipping activation is only safe if the window the
# image inherits is long enough to be worth shipping; when it is not, the build
# stops here and the operator rearms or re-baselines from fresh media, instead
# of finding out from an expired runner months later.
if ($dlv -match 'Timebased activation expiration:\s*(\d+)\s*minute') {
    $days = [math]::Floor([int64]$Matches[1] / 1440)
    Write-Output "evaluation window remaining: $days day(s)"
    if ($days -lt $minRemainingDays) {
        throw "only $days day(s) of evaluation remain, minimum is $minRemainingDays -- rearm or re-baseline from fresh media before building a shippable image."
    }
}

Write-Output "activation confirmed: License Status: Licensed"
