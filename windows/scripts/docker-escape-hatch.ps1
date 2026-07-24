<#
.SYNOPSIS
    OPTIONAL, OFF BY DEFAULT: Linux-container Docker support via WSL2.
    build.ps1 does not call this; opt in with `build.ps1 -DockerEscapeHatch`.

.DESCRIPTION
    Why it's off by default, and what turning it on means:

    - GitHub Actions' `container:`/`services:` workflow YAML and Docker
      container actions are Linux-runner-only in the Actions runner software
      itself -- nothing installed on a Windows image changes that. Those
      workflows belong on a Linux runner. This hatch only enables plain
      `docker run <linux-image>` shell steps.
    - Linux containers on Windows require WSL2, i.e. a nested VM inside the
      guest. That needs nested virtualization exposed to the guest VM: on
      the HOST, per guest VM, run
          Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true
      (and note runny's HCS-created guests would need the equivalent in
      their compute-system document -- untested against runny's
      differencing-clone flow as of this writing).
    - Nested virt costs: no dynamic memory while enabled, extra hypervisor
      latency, and a fatter/slower-booting image. The default image's
      fast-ephemeral-boot profile is the priority, so this stays opt-in.

    If you enable this, budget a real validation pass: boot a clone, confirm
    `wsl --status` is healthy and `docker run --rm alpine echo ok` works,
    before trusting the image.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

throw "docker-escape-hatch.ps1 is a documented stub -- read the header comment, then implement/validate for your environment before enabling. (Sketch: wsl --install --no-launch; choco install docker-desktop; configure WSL2 backend; requires nested virtualization exposed by the host.)"
