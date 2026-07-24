<#
.SYNOPSIS
    Build the curated Windows Server 2025 runner image, end to end:
    fresh eval VHDX -> provisioned, activated, patched, toolchained,
    launcher-baked, sealed parent VHDX -> smoke-tested -> packed as a
    tart-format OCI layout ready for `oras cp` to a registry.

.DESCRIPTION
    FIRST DRAFT -- assembles individually-proven pieces (the unattend/
    SetupComplete offline-inject flow, the per-step scripts in scripts/),
    but this orchestration has NOT been run end-to-end on real hardware yet.
    Walk it stage by stage on the build host the first time.

    Run on a Windows host with Hyper-V, from an elevated PowerShell.
    Uses standard Hyper-V cmdlets (New-VM/Start-VM) rather than any
    runny-internal API -- the factory is deliberately independent of runny's
    runtime, it only ships bytes runny can read.

.PARAMETER BaseVhdx
    A PRISTINE (never-booted) WS2025 eval VHDX. Download fresh from
    https://aka.ms/WinServ2025vhd-enus -- a booted one has already burned
    its OOBE and won't take the unattend.

.PARAMETER RunnyctlPath
    Path to a runnyctl binary from a pinned runny GitHub Release (never a
    floating "latest" -- the pack format must match what this pipeline was
    validated against).

.PARAMETER OutDir
    Where the sealed VHDX and the packed OCI layout land.

.PARAMETER SwitchName
    Hyper-V switch for the build VM. Needs outbound internet (activation,
    Windows Update, Chocolatey).

.PARAMETER DockerEscapeHatch
    Opt into the Linux-container/WSL2 layer. See
    scripts/docker-escape-hatch.ps1 -- a documented stub, not turnkey.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseVhdx,
    [Parameter(Mandatory)][string]$RunnyctlPath,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out'),
    [string]$SwitchName = 'Default Switch',
    [switch]$DockerEscapeHatch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$guestUser = 'Administrator'
$vmName = 'runny-image-build'
$scriptsDir = Join-Path $PSScriptRoot 'scripts'
$workVhdx = Join-Path $OutDir 'windows-server-2025-runner.vhdx'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ssh.exe has no non-interactive password auth, so the build uses a
# throwaway keypair: the public half is injected offline in stage 0
# (SetupComplete.cmd sets the ACL Windows OpenSSH requires for admin-group
# keys), and the whole authorized_keys file is deleted again at seal --
# the shipped image authenticates with the well-known password only.
$buildKey = Join-Path $OutDir 'build-key'
if (-not (Test-Path $buildKey)) {
    # Empty passphrase via cmd.exe: Windows PowerShell 5.1 either drops an
    # empty-string argument to a native command entirely or (quoted as '""')
    # passes the two literal quote characters as the passphrase -- both
    # silently produce a key that BatchMode auth can never use. cmd's ""
    # is a real empty argument.
    & cmd.exe /c "ssh-keygen -q -t ed25519 -N `"`" -C runny-images-build -f `"$buildKey`""
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed' }
}

function Invoke-Guest {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Command)
    ssh.exe -i $buildKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes "$guestUser@$Ip" $Command
    if ($LASTEXITCODE -ne 0) { throw "guest command failed ($LASTEXITCODE): $Command" }
}

function Copy-ToGuest {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Local, [Parameter(Mandatory)][string]$Remote)
    scp.exe -i $buildKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o BatchMode=yes $Local "${guestUser}@${Ip}:$Remote"
    if ($LASTEXITCODE -ne 0) { throw "scp to guest failed: $Local -> $Remote" }
}

function Wait-GuestSsh {
    param([Parameter(Mandatory)][string]$VmName, [int]$TimeoutSec = 1800)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $ip = (Get-VMNetworkAdapter -VMName $VmName).IPAddresses |
            Where-Object { $_ -match '^\d+\.' -and $_ -notmatch '^169\.254\.' } |
            Select-Object -First 1
        if (-not $ip) { continue }
        $probe = Test-NetConnection -ComputerName $ip -Port 22 -WarningAction SilentlyContinue
        if ($probe.TcpTestSucceeded) { return $ip }
    }
    throw "guest SSH did not come up within ${TimeoutSec}s"
}

# --- Stage 0: offline-inject provisioning files into the pristine VHDX ---
Write-Host '== stage 0: inject unattend.xml + SetupComplete.cmd =='
# Parse the answer file host-side before spending a boot on it -- Windows
# Setup hard-fails the whole file on any XML error (including double
# hyphens in comments), and the failure surfaces as a modal dialog on the
# VM console, not in this script's output.
[xml](Get-Content -Raw (Join-Path $PSScriptRoot 'unattend.xml')) | Out-Null
Copy-Item $BaseVhdx $workVhdx -Force
$mount = Mount-VHD -Path $workVhdx -Passthru
try {
    $osVolume = $mount | Get-Disk | Get-Partition | Get-Volume |
        Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } |
        Select-Object -First 1
    if (-not $osVolume) { throw 'no Windows volume found in the base VHDX' }
    $root = "$($osVolume.DriveLetter):"
    New-Item -ItemType Directory -Force -Path "$root\Windows\Setup\Scripts" | Out-Null
    # Panther doesn't exist on never-booted media -- setup creates it during
    # OOBE; injecting before first boot means creating it ourselves.
    New-Item -ItemType Directory -Force -Path "$root\Windows\Panther" | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'unattend.xml') "$root\Windows\Panther\unattend.xml" -Force
    Copy-Item (Join-Path $PSScriptRoot 'SetupComplete.cmd') "$root\Windows\Setup\Scripts\SetupComplete.cmd" -Force
    New-Item -ItemType Directory -Force -Path "$root\ProgramData\ssh" | Out-Null
    Copy-Item "$buildKey.pub" "$root\ProgramData\ssh\administrators_authorized_keys" -Force
} finally {
    Dismount-VHD -Path $workVhdx
}

# --- Stage 1: boot; OOBE + SetupComplete run headlessly; wait for SSH ---
Write-Host '== stage 1: first boot (headless OOBE; SSH comes up when done) =='
New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $workVhdx -SwitchName $SwitchName | Out-Null
try {
    Set-VMProcessor -VMName $vmName -Count 4
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
    Start-VM -Name $vmName
    $ip = Wait-GuestSsh -VmName $vmName
    Write-Host "guest SSH up at $ip"

    # --- Stage 2: activate ---
    Write-Host '== stage 2: activation =='
    Copy-ToGuest -Ip $ip -Local (Join-Path $scriptsDir 'activate.ps1') -Remote 'C:\activate.ps1'
    Invoke-Guest -Ip $ip -Command 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\activate.ps1'

    # --- Stage 3: Windows Update loop (install -> reboot -> repeat until clean) ---
    Write-Host '== stage 3: windows update loop =='
    Copy-ToGuest -Ip $ip -Local (Join-Path $scriptsDir 'windows-update.ps1') -Remote 'C:\windows-update.ps1'
    $maxPasses = 8
    for ($pass = 1; $pass -le $maxPasses; $pass++) {
        Write-Host "  update pass $pass..."
        $out = ssh.exe -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL "$guestUser@$ip" 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\windows-update.ps1'
        Write-Host ($out -join "`n")
        if ($out -match 'WINDOWS_UPDATE: CLEAN') { break }
        if ($pass -eq $maxPasses) { throw "windows update did not converge in $maxPasses passes" }
        Invoke-Guest -Ip $ip -Command 'shutdown /r /t 5'
        Start-Sleep -Seconds 30
        $ip = Wait-GuestSsh -VmName $vmName
    }

    # --- Stage 4: toolchain ---
    Write-Host '== stage 4: toolchain =='
    Copy-ToGuest -Ip $ip -Local (Join-Path $scriptsDir 'install-toolchain.ps1') -Remote 'C:\install-toolchain.ps1'
    Invoke-Guest -Ip $ip -Command 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\install-toolchain.ps1'
    if ($DockerEscapeHatch) {
        Copy-ToGuest -Ip $ip -Local (Join-Path $scriptsDir 'docker-escape-hatch.ps1') -Remote 'C:\docker-escape-hatch.ps1'
        Invoke-Guest -Ip $ip -Command 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\docker-escape-hatch.ps1'
    }

    # --- Stage 5: launcher + AutoLogon ---
    Write-Host '== stage 5: launcher + AutoLogon =='
    Invoke-Guest -Ip $ip -Command 'powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path C:\runny | Out-Null"'
    Copy-ToGuest -Ip $ip -Local (Join-Path $scriptsDir 'launcher.ps1') -Remote 'C:\runny\launcher.ps1'
    Copy-ToGuest -Ip $ip -Local (Join-Path $scriptsDir 'install-launcher.ps1') -Remote 'C:\install-launcher.ps1'
    Invoke-Guest -Ip $ip -Command 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\install-launcher.ps1'

    # --- Stage 6: seal ---
    Write-Host '== stage 6: seal (graceful shutdown) =='
    # Remove the build-time SSH key -- the shipped image authenticates with
    # the well-known password only (runny rotates it post-boot).
    Invoke-Guest -Ip $ip -Command 'powershell -NoProfile -Command "Remove-Item -Force C:\ProgramData\ssh\administrators_authorized_keys,C:\activate.ps1,C:\windows-update.ps1,C:\install-toolchain.ps1,C:\install-launcher.ps1,C:\provisioned.txt -ErrorAction SilentlyContinue"'
    Invoke-Guest -Ip $ip -Command 'shutdown /s /t 5'
    while ((Get-VM -Name $vmName).State -ne 'Off') { Start-Sleep -Seconds 5 }
} finally {
    if ((Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        if ((Get-VM -Name $vmName).State -ne 'Off') { Stop-VM -Name $vmName -TurnOff -Force }
        Remove-VM -Name $vmName -Force
    }
}

# --- Stage 7: smoke test the sealed image ---
Write-Host '== stage 7: smoke test =='
& (Join-Path $PSScriptRoot 'smoke-test.ps1') -Vhdx $workVhdx -SwitchName $SwitchName

# --- Stage 8: pack ---
Write-Host '== stage 8: pack to OCI layout =='
$layout = Join-Path $OutDir 'oci-layout'
# cpu/memory here are the image's baked defaults, overridable per-slot by the
# consumer's pool config -- 2 vCPU / 4 GiB matches the conservative defaults
# the cirruslabs guest images ship. memory-size is bytes.
& $RunnyctlPath image pack $workVhdx --os windows --arch amd64 `
    --cpu-count 2 --memory-size 4294967296 --oci-layout $layout
if ($LASTEXITCODE -ne 0) { throw "runnyctl image pack failed ($LASTEXITCODE)" }

$ubr = 'UNKNOWN'
$mount = Mount-VHD -Path $workVhdx -ReadOnly -Passthru
try {
    $osVolume = $mount | Get-Disk | Get-Partition | Get-Volume |
        Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } |
        Select-Object -First 1
    if ($osVolume) {
        reg.exe load HKLM\RUNNYIMG "$($osVolume.DriveLetter):\Windows\System32\config\SOFTWARE" | Out-Null
        $ubr = (Get-ItemProperty 'HKLM:\RUNNYIMG\Microsoft\Windows NT\CurrentVersion').UBR
        reg.exe unload HKLM\RUNNYIMG | Out-Null
    }
} finally {
    Dismount-VHD -Path $workVhdx
}
$sha = (git -C $PSScriptRoot rev-parse --short HEAD 2>$null)
if (-not $sha) { $sha = 'nogit' }

Write-Host ''
Write-Host "sealed VHDX: $workVhdx"
Write-Host "OCI layout:  $layout"
Write-Host "suggested tag: windows-server-2025-runner:$ubr-$sha"
Write-Host "push with:   oras cp --from-oci-layout `"$layout@<manifest-digest>`" <registry>/<project>/windows-server-2025-runner:$ubr-$sha"
