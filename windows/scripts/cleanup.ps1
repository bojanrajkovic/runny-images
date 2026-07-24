<#
.SYNOPSIS
    Pre-seal cleanup: drop the provisioning debris the image doesn't need
    to carry, then TRIM free space so host-side compaction can reclaim it.

.DESCRIPTION
    A freshly provisioned image carries every transient byte the build
    wrote -- the Windows Update download cache (multi-GB after a cumulative
    on stale media), superseded WinSxS components, choco/temp caches. None
    of it serves a runner guest, and every GiB left in is a GiB to
    LZ4-compress at pack time and push/pull on every consuming host.

    The final ReTrim is what makes host-side Optimize-VHD effective:
    Hyper-V passes guest TRIM/UNMAP through to the dynamic VHDX, releasing
    the freed blocks without any zero-fill pass or external tools.

    DISM /ResetBase makes installed updates permanent (non-uninstallable) --
    exactly right for an ephemeral image that is rebuilt, never rolled back.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

'--- free space before ---'
'{0:N1} GiB free' -f ((Get-PSDrive C).Free/1GB)

Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue

'--- DISM component cleanup (slow; several minutes) ---'
dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

Remove-Item 'C:\ProgramData\chocolatey\lib-bad' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

'--- free space after cleanup ---'
'{0:N1} GiB free' -f ((Get-PSDrive C).Free/1GB)

'--- retrim (releases freed blocks to the dynamic VHDX) ---'
Optimize-Volume -DriveLetter C -ReTrim -Verbose

'CLEANUP DONE'
