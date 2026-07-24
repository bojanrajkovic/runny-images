# runny-images

Builds the curated Windows Server 2025 runner image that [runny](https://github.com/bojanrajkovic/runny)'s Windows-guest support pulls at runtime. Packer-adjacent PowerShell automation, no Go, no runny code — this repo only produces artifacts runny consumes via `internal/oci.PullTo`.

## What this produces

A tart-format OCI image (Apple/cirruslabs' image layout, written by `runnyctl image pack`) carrying a Windows Server 2025 VHDX: activated, patched, a curated toolchain installed, no sysprep, baked with the AutoLogon + interactive-session launcher runny's Windows-guest bring-up expects. Pushed to an OCI registry runny can pull from.

Base media is the free Microsoft Windows Server 2025 evaluation VHDX ([aka.ms/WinServ2025vhd-enus](https://aka.ms/WinServ2025vhd-enus)). The image is never redistributed publicly — it carries Microsoft OS bits, so it belongs on a private/internal registry only.

## Design in brief

- **No sysprep.** Un-generalized differencing clones off the sealed parent coexist fine (duplicate machine SID/`COMPUTERNAME` are harmless for never-domain-joined ephemeral guests addressed by IP), and skipping generalize is what makes the ephemeral clone boot in seconds instead of minutes.
- **Activate at build time, never per guest.** `slmgr /ato` runs once per build and the sealed parent's 180-day evaluation window is inherited by every clone; rebuild well inside that window (~150 days). `/rearm` is not a substitute — on a never-activated install it only resets the 10-day pre-activation grace period.
- **Windows Update is an explicit build step.** The eval media ships stale and does not patch itself.
- **Interactive-session launcher.** AutoLogon + a Task Scheduler task ("Run only when user is logged on") starts the runner in the interactive desktop session — session 0 services have no desktop, and `actions/runner` has no built-in AutoLogon mode ([actions/runner#563](https://github.com/actions/runner/issues/563)).
- **Well-known guest credentials** (`Administrator`/`Administrator`), matching the cirruslabs guest-image convention; runny rotates them post-boot. The guest's isolation is the security boundary, not password secrecy.
- **Tag scheme:** `windows-server-2025-runner:<UBR>-<short-sha>` — the OS build number never changes between rebuilds off the same media; the Update Build Revision is the real patch-currency signal.

## Pipeline (manual for now)

No CI wired up — everything runs by hand on a Hyper-V build host. See `build.ps1`.

```
build.ps1
  → provision (unattend.xml + SetupComplete.cmd get a fresh eval VHDX past OOBE with SSH open)
  → activate.ps1        (slmgr /ato, verify Licensed -- never /rearm)
  → windows-update.ps1  (install + reboot + reloop until clean)
  → install-toolchain.ps1
  → install-launcher.ps1 (AutoLogon + Task Scheduler launcher)
  → seal (graceful shutdown)
  → smoke-test.ps1      (boot the sealed VHDX once, confirm SSH, before it ships)
  → runnyctl image pack <vhdx> --oci-layout ./out
  → oras cp ./out <registry>/<project>/windows-server-2025-runner:<tag>
```

`build.ps1` is a first draft — it assembles per-step pieces that are each independently simple, but the end-to-end orchestration has not been run against real hardware yet. Validate it on the build host before trusting a real build off it.

## Requirements

- A Windows host with the `Hyper-V` PowerShell module — VM creation uses standard `New-VM`/`Set-VMFirmware`/`Start-VM`, not runny's internal HCS API.
- `runnyctl` — a pinned GitHub Release binary from the `runny` repo (never `latest`; the tart-format writer's version must match what this pipeline was validated against).
- [`oras`](https://oras.land) for the registry push.
- Windows OpenSSH client (built into modern Windows) for guest provisioning over SSH.

## Toolchain scope

Curated, not full `windows-latest` parity — lean by default (the same philosophy as cirruslabs' tiered guest images), growing only on demonstrated need. v1 keeps Git, PowerShell 7, the `gh`/`az`/`aws`/`gcloud` CLIs, Go, Node LTS, Python, the .NET SDK, and VS Build Tools; see `install-toolchain.ps1`. `docker-escape-hatch.ps1` is disabled by default; see its header comment for how to opt a build into nested-virt + WSL2 + Linux-container support if you need it (nothing in runny's own use case does, but this is general-purpose tooling).
