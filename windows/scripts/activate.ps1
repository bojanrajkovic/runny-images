<#
.SYNOPSIS
    Online-activate this Windows Server evaluation install and verify it
    landed in the real 180-day evaluation window, not just the 10-day
    pre-activation grace period.

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

# /ato reaches Microsoft's activation service over the network, so it can fail
# for reasons that have nothing to do with this image -- observed once as
# 0x8004FE93, which then succeeded unchanged on the very next attempt. One blip
# should not cost an hour-long build. The retries stay deliberately gentle:
# hammering /ato from a single inherited identity is the shape abuse detection
# looks for, and three spaced attempts are nowhere near it.
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

$dlv = cscript.exe //nologo C:\Windows\System32\slmgr.vbs /dlv
Write-Output $dlv

if (($dlv -join "`n") -notmatch 'License Status:\s*Licensed') {
    throw "activation did not result in License Status: Licensed -- refusing to seal an un-activated image. Output above."
}

Write-Output "activation confirmed: License Status: Licensed"
