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

cscript.exe //nologo C:\Windows\System32\slmgr.vbs /ato
if ($LASTEXITCODE -ne 0) {
    throw "slmgr /ato exited $LASTEXITCODE"
}

$dlv = cscript.exe //nologo C:\Windows\System32\slmgr.vbs /dlv
Write-Output $dlv

if (($dlv -join "`n") -notmatch 'License Status:\s*Licensed') {
    throw "activation did not result in License Status: Licensed -- refusing to seal an un-activated image. Output above."
}

Write-Output "activation confirmed: License Status: Licensed"
