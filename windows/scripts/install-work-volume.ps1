<#
.SYNOPSIS
    Create the ReFS volume that the runner's working directory is mounted on,
    and bake the (empty) mount point the launcher attaches it to at boot.

.DESCRIPTION
    Job working directories do a lot of duplicating files that already exist
    on the same volume -- staging build output, fanning out node_modules,
    assembling artifacts. On ReFS those copies are block clones: the file
    system points the new file at the existing extents instead of writing the
    bytes again.

    Measured on this image, inside the guest: a 4 GiB copy within an ReFS
    volume finished in 0.45s and consumed no space at all, while the identical
    copy from that volume to NTFS took 16.37s and cost the full 4 GiB. The
    backing VHDX did not grow by a byte for the ReFS copy, which is what
    distinguishes real extent cloning from a merely fast disk.

    Two limits worth knowing before expecting a win. Block cloning only
    applies WITHIN one ReFS volume -- a checkout that copies from C:\ into the
    work directory writes real bytes. And it is CopyFile/CopyFileEx that
    clones; anything writing through its own read/write loop, including tar
    and most archive extraction, allocates normally.

    Created at build time rather than per boot: formatting costs seconds of
    every job's startup, attaching a ready-made volume costs about one. The
    cost is negligible -- an empty 200 GB dynamic volume is ~0.35 GB in the
    image.

    diskpart does the creation because New-VHD is a Hyper-V module cmdlet and
    the guest has no Hyper-V role; the launcher's boot-time attach uses
    Mount-DiskImage, which is the Storage module and always present.
#>
[CmdletBinding()]
param(
    [int]$MaxSizeGB = 200,
    [string]$VhdPath = 'C:\runny\work.vhdx',
    [string]$MountPoint = 'C:\actions-runner\_work'
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $VhdPath) | Out-Null
if (Test-Path $VhdPath) {
    Dismount-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $VhdPath -Force
}

$script = "$env:TEMP\runny-work-vhd.txt"
@"
create vdisk file="$VhdPath" maximum=$($MaxSizeGB * 1024) type=expandable
select vdisk file="$VhdPath"
attach vdisk
"@ | Set-Content -Path $script -Encoding ASCII

$out = diskpart /s $script 2>&1
if ($LASTEXITCODE -ne 0) { throw "diskpart failed creating $VhdPath : $($out -join ' ')" }
Remove-Item $script -Force -ErrorAction SilentlyContinue

# The disk takes a moment to surface after attach; resolve it by image path
# rather than guessing at a disk number.
Start-Sleep -Seconds 3
$disk = Get-DiskImage -ImagePath $VhdPath | Get-Disk
if (-not $disk) { throw "attached $VhdPath but no disk appeared" }

Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
$null = New-Partition -DiskNumber $disk.Number -UseMaximumSize
$part = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne 'Reserved' } | Select-Object -First 1
Format-Volume -Partition $part -FileSystem ReFS -NewFileSystemLabel work -Confirm:$false -Force | Out-Null

$vol = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber | Get-Volume
if ($vol.FileSystem -ne 'ReFS') { throw "formatted volume reports $($vol.FileSystem), expected ReFS" }

# Detach before sealing: an image that ships with the volume attached would
# carry stale mount state into every clone.
Dismount-DiskImage -ImagePath $VhdPath | Out-Null

# Bake the mount point empty. Add-PartitionAccessPath requires the directory to
# exist and be empty, and runny's runner extraction creates C:\actions-runner
# only when absent -- so a pre-existing tree with _work inside survives
# provisioning untouched.
New-Item -ItemType Directory -Force -Path $MountPoint | Out-Null

Write-Output ("work volume created: {0} ({1} GB max, {2:N2} GB on disk), mount point {3}" -f `
    $VhdPath, $MaxSizeGB, ((Get-Item $VhdPath).Length / 1GB), $MountPoint)
