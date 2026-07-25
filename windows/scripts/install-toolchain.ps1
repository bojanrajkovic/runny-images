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

# v1 curated keep list.
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
    'dotnet-sdk'
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

# VS Build Tools only -- MSVC + MSBuild, not the Enterprise IDE.
choco install visualstudio2022buildtools -y --no-progress `
    --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart"
if ($LASTEXITCODE -notin $okExit) {
    throw "choco install visualstudio2022buildtools failed with exit code $LASTEXITCODE"
}

Write-Output "toolchain install complete"
