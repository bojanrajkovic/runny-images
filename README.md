# runny-images

Builds the curated Windows Server 2025 runner image that [runny](https://github.com/bojanrajkovic/runny)'s Windows-guest support pulls at runtime. Packer-adjacent PowerShell automation, no Go, no runny code — this repo only produces artifacts runny consumes via `internal/oci.PullTo`.

## What this produces

A tart-format OCI image (Apple/cirruslabs' image layout, written by `runnyctl image pack`) carrying a Windows Server 2025 VHDX: activated, patched, a curated toolchain installed, no sysprep, baked with the AutoLogon + interactive-session launcher runny's Windows-guest bring-up expects. Pushed to an OCI registry runny can pull from.

Base media is the free Microsoft Windows Server 2025 evaluation VHDX ([aka.ms/WinServ2025vhd-enus](https://aka.ms/WinServ2025vhd-enus)). The image is never redistributed publicly — it carries Microsoft OS bits, so it belongs on a private/internal registry only.

## Design in brief

- **No sysprep.** Un-generalized differencing clones off the sealed parent coexist fine (duplicate machine SID/`COMPUTERNAME` are harmless for never-domain-joined ephemeral guests addressed by IP), and skipping generalize is what makes the ephemeral clone boot in seconds instead of minutes.
- **Activate at build time, never per guest.** `slmgr /ato` runs once per build and the sealed parent's 180-day evaluation window is inherited by every clone; rebuild well inside that window (~150 days). `/rearm` is not a substitute — on a never-activated install it only resets the 10-day pre-activation grace period.
- **Windows Update is an explicit build step.** The eval media ships stale and does not patch itself.
- **Interactive-session launcher.** AutoLogon + a Task Scheduler task ("Run only when user is logged on") starts the runner in the interactive desktop session — session 0 services have no desktop, and `actions/runner` has no built-in AutoLogon mode ([actions/runner#563](https://github.com/actions/runner/issues/563)). See [Guest contract](#guest-contract) for the protocol this exposes.
- **Well-known guest credentials** (`Administrator`/`Administrator`), matching the cirruslabs guest-image convention; runny rotates them post-boot. The guest's isolation is the security boundary, not password secrecy.
- **Tag scheme:** `windows-server-2025-runner:<UBR>-<short-sha>` — the OS build number never changes between rebuilds off the same media; the Update Build Revision is the real patch-currency signal.

## Guest contract

The image carries no runner binary, no registration state, and nothing that needs runny at runtime — anything that can SSH into the guest can drive it. This section is the interface; treat it as stable and the rest of the repo as implementation detail. The `C:\runny\` prefix is a label, not a dependency.

**Credentials and access.** Log in as `Administrator` / `Administrator` (see the credentials note above for why those aren't secret). OpenSSH is enabled and listening on port 22 by first boot, and AutoLogon leaves the console session logged in from boot onward.

**Why there's a launcher at all.** A process spawned over SSH lands in session 0, which has no desktop, so an orchestrator cannot start a UI-capable runner directly. The image bakes AutoLogon plus a Task Scheduler task (`runny-launcher`, registered "run only when user is logged on") that starts `launcher.ps1` inside the interactive session at every logon. The launcher is already running before you connect; you don't start it, you feed it.

```
   consumer (over SSH)                     guest session 1
   ──────────────────                      ───────────────
                                           launcher.ps1 running since boot
                                           writes launcher-marker.txt
                                           polls for .jitconfig every 2s
   1. stage runner ────────────────────►   C:\actions-runner\
   2. write .jitconfig.tmp             │
   3. rename → .jitconfig ─────────────►   picked up, deleted, exec'd
                                           bin\Runner.Listener.exe run --jitconfig
   4. tail runner.log     ◄─────────────   stdout + stderr
   5. watch runner-exit.txt ◄───────────   exit code, written on exit
```

| Path | Written by | Meaning |
| --- | --- | --- |
| `C:\actions-runner\` | consumer | Where the runner must be staged. The launcher execs `bin\Runner.Listener.exe` beneath it. |
| `C:\actions-runner\.jitconfig` | consumer | Arrival starts the runner. Must be written atomically — see below. |
| `C:\runny\launcher-marker.txt` | image | Launcher PID and session ID at startup, then lifecycle lines. |
| `C:\runny\runner.log` | image | Runner stdout and stderr, truncated at each launch. |
| `C:\runny\runner-exit.txt` | image | Runner exit code, written once the runner exits. |

Four things about that protocol are load-bearing:

- **Write `.jitconfig` atomically** — stage it under a different name and rename it into place. The launcher polls with `Test-Path`, which goes true the moment the file is created, so a direct upload can be read half-written and hand the runner a truncated config.
- **The config is consumed and deleted before the runner starts.** It's a one-shot registration credential and shouldn't outlive its use on disk. Don't expect to read it back.
- **One runner per boot.** The launcher exits when the runner does, so a fresh cycle means a fresh boot. The task is set to restart the launcher up to 3 times if it exits nonzero, so a failing runner will be followed by another poll rather than a dead guest.
- **The exit file is the completion signal**, not the log. Tail `runner.log` for progress; wait on `runner-exit.txt` to know the runner is done and why.

**Consumers that aren't GitHub Actions.** The valuable, transferable piece here is the mechanism — AutoLogon plus an at-logon task with `LogonType Interactive` — not the JIT-config protocol layered on it. `launcher.ps1` takes `-ConfigPath`, `-RunnerRoot`, `-MarkerPath`, `-LogPath` and `-ExitPath`; the baked task simply doesn't pass them. Re-register the task over SSH with your own arguments, or point it at your own script entirely, and the session-1 launch behaviour still works. Two details are worth stealing rather than rediscovering: invoke the listener binary directly instead of through `run.cmd`, whose `cmd.exe` command line tops out at 8191 characters that a multi-kilobyte JIT blob breaches, and register the task as "run only when user is logged on" — the "whether logged on or not" variant runs in session 0 and defeats the whole exercise.

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

## Requirements

- A Windows host with the `Hyper-V` PowerShell module — VM creation uses standard `New-VM`/`Set-VMFirmware`/`Start-VM`, not runny's internal HCS API.
- `runnyctl` — a pinned GitHub Release binary from the `runny` repo (never `latest`; the tart-format writer's version must match what this pipeline was validated against).
- [`oras`](https://oras.land) for the registry push.
- Windows OpenSSH client (built into modern Windows) for guest provisioning over SSH.

## Toolchain scope

Curated, not full `windows-latest` parity — lean by default (the same philosophy as cirruslabs' tiered guest images), growing only on demonstrated need. v1 keeps Git, PowerShell 7, the `gh`/`az`/`aws`/`gcloud` CLIs, Go, Node LTS, Python, the .NET SDK, and VS Build Tools; see `install-toolchain.ps1`. `docker-escape-hatch.ps1` is disabled by default; see its header comment for how to opt a build into nested-virt + WSL2 + Linux-container support if you need it (nothing in runny's own use case does, but this is general-purpose tooling).

The long tail deliberately stays out — mobile (Android/iOS/MAUI/Xamarin), game engines, cloud-IDE tooling, and legacy web/BI tooling are each real but narrow verticals, and anyone who needs one of them already knows exactly which component they need. Two ways to add it, in order of permanence:

- **Bake it into every future build.** Edit the `--add` list in `install-toolchain.ps1` (VS components) or the `$packages` array (choco packages) directly in your fork, then rebuild.
- **Add it to an already-built install without touching the curated file.** VS Build Tools supports unattended `modify` against an existing installation:

  ```powershell
  Invoke-WebRequest https://aka.ms/vs/17/release/vs_buildtools.exe -OutFile vs_buildtools.exe
  .\vs_buildtools.exe modify `
      --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
      --add <componentId> `
      --quiet --norestart --wait
  ```

  Run it as an extra step appended to your own copy of `build.ps1` (after `install-toolchain.ps1`, before seal), or by hand against a running guest before sealing.

Either way, the component ID catalog lives in actions/runner-images' [`Windows2025-Readme.md`](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md) and [`toolset-2025.json`](https://github.com/actions/runner-images/blob/main/images/windows/toolsets/toolset-2025.json) — that's where every `Microsoft.VisualStudio.Component.*` ID currently in this repo's own list came from.
