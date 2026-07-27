<#
.SYNOPSIS
    Install the curated v1 toolchain via Chocolatey.

.DESCRIPTION
    Curated, not full `windows-latest` parity -- lean by default, the same
    philosophy as cirruslabs' tiered guest images; grow the list on
    demonstrated need, not speculatively. Edge is already on the box by
    default, so it's not in this list.

    Docker/nested-virt is intentionally NOT here -- see
    docker-escape-hatch.ps1 for that, disabled by default.

    Need a package or VS component this doesn't install? Edit the lists
    below directly, or see the README's "Toolchain scope" section for
    adding one to an already-built install via `vs_buildtools.exe modify
    --add` without touching this file.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = "$env:Path;C:\ProgramData\chocolatey\bin"
}

# v1 curated keep list, plus a few general CI utilities and native-build
# companions banked from a razor pass over actions/runner-images ("is this
# likely necessary for a random build?"): 7zip/jq are near-universal CI
# utilities, vswhere/ninja are the standard companions to the VC toolchain
# below (node-gyp, CMake, and most native-build tooling shell out to vswhere
# to find MSVC). cmake.install is added separately -- its installer doesn't
# add itself to PATH without an explicit install arg.
$packages = @(
    'git',
    'gh',
    'powershell-core',
    'azure-cli',
    'awscli',
    'gcloudsdk',
    'golang',
    'nodejs-lts',
    'python',
    'dotnet-sdk',
    '7zip.install',
    'jq',
    'vswhere',
    'ninja'
)

# 3010 = success-reboot-required, 1641 = success-reboot-initiated -- both
# are successful installs (the build's own between-stage reboot handles the
# pending restart); only genuinely failing codes should abort the build.
$okExit = @(0, 1641, 3010)

foreach ($pkg in $packages) {
    choco install $pkg -y --no-progress
    if ($LASTEXITCODE -notin $okExit) {
        throw "choco install $pkg failed with exit code $LASTEXITCODE"
    }
}

# cmake.install's NSIS installer leaves CMake off PATH entirely in unattended
# mode unless told otherwise -- unlike the packages above, this isn't optional.
choco install cmake.install -y --no-progress --installargs 'ADD_CMAKE_TO_PATH=System'
if ($LASTEXITCODE -notin $okExit) {
    throw "choco install cmake.install failed with exit code $LASTEXITCODE"
}

# This session's PATH was captured before the installs ran, so re-read it from
# the registry -- that is what a runner job session inherits. pwsh is the one
# worth asserting on: it is the shell workflows request by name (`shell: pwsh`),
# and a silently PATH-less PowerShell 7 is exactly how it shipped missing before.
$env:Path = @(
    [Environment]::GetEnvironmentVariable('Path', 'Machine'),
    [Environment]::GetEnvironmentVariable('Path', 'User')
) -join ';'
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    throw 'pwsh is not on the PATH after install -- job sessions would not find PowerShell 7'
}

# vcpkg -- the standard C/C++ package manager, natural companion to the
# CMake/Ninja/vswhere/VCTools cluster above. Not a choco package; built from
# source, adapted from actions/runner-images' Install-Vcpkg.ps1. Placed after
# the PATH re-read above so `git` (installed via the loop) actually resolves.
$vcpkgRoot = 'C:\vcpkg'

# This stage has to survive being re-run against an image that already carries
# the toolchain: resuming from a partially-built base is the normal path when an
# earlier attempt failed late, and every choco install above is happy to repeat.
# A bare `git clone` into an existing directory is not -- it aborts the whole
# build on "destination path already exists", which is how stage 4 died on a
# rebuild that had nothing else left to do.
if (Test-Path (Join-Path $vcpkgRoot '.git')) {
    Write-Output "vcpkg already present at $vcpkgRoot -- skipping clone"
} else {
    git clone 'https://github.com/Microsoft/vcpkg.git' $vcpkgRoot -q
    if ($LASTEXITCODE -ne 0) {
        throw "git clone of vcpkg failed with exit code $LASTEXITCODE"
    }
}

# Bootstrap compiles vcpkg.exe from source, which is minutes; skip it when the
# binary is already there. `integrate install` below is cheap and idempotent, so
# it runs unconditionally.
if (-not (Test-Path (Join-Path $vcpkgRoot 'vcpkg.exe'))) {
    & "$vcpkgRoot\bootstrap-vcpkg.bat"
    if ($LASTEXITCODE -ne 0) {
        throw "vcpkg bootstrap failed with exit code $LASTEXITCODE"
    }
}

& "$vcpkgRoot\vcpkg.exe" integrate install
if ($LASTEXITCODE -ne 0) {
    throw "vcpkg integrate install failed with exit code $LASTEXITCODE"
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$vcpkgRoot*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$vcpkgRoot", 'Machine')
}
[Environment]::SetEnvironmentVariable('VCPKG_INSTALLATION_ROOT', $vcpkgRoot, 'Machine')

# VS Build Tools only -- MSVC + MSBuild, not the Enterprise IDE. Add-ons
# beyond the base VCTools workload, confirmed against actions/runner-images'
# toolset-2025.json and Windows2025-Readme.md:
#   - VC.Runtimes.x86.x64.Spectre: native Node addons (node-pty, etc.) built via
#     node-gyp/MSBuild fail with MSB8040 without it.
#   - VC.Redist.14.Latest: the standalone VC++ redistributable DLLs that a huge
#     fraction of unrelated prebuilt Windows binaries assume are already
#     present, not just what we compile ourselves.
#   - VC.ATL / VC.ATLMFC (+ Spectre variants): still-live legacy Windows
#     desktop/COM development (MFC apps, ATL/COM components). Cheap enough
#     (tens of MB) that the exclusion cost -- a cryptic afxwin.h/atlbase.h
#     not-found error with no obvious cause -- isn't worth it. ARM64 variants
#     skipped: cross-compiling from x64 is rare enough to stay demonstrated-need.
choco install visualstudio2022buildtools -y --no-progress `
    --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Runtimes.x86.x64.Spectre --add Microsoft.VisualStudio.Component.VC.Redist.14.Latest --add Microsoft.VisualStudio.Component.VC.ATL --add Microsoft.VisualStudio.Component.VC.ATL.Spectre --add Microsoft.VisualStudio.Component.VC.ATLMFC --add Microsoft.VisualStudio.Component.VC.ATLMFC.Spectre --includeRecommended --passive --norestart"
if ($LASTEXITCODE -notin $okExit) {
    throw "choco install visualstudio2022buildtools failed with exit code $LASTEXITCODE"
}

Write-Output "toolchain install complete"
