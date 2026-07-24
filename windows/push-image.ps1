<#
.SYNOPSIS
    Pushes the packed OCI layout to a registry: reads the manifest digest out
    of the layout's index.json and runs the oras cp.

.DESCRIPTION
    Run after build.ps1 (or a standalone `runnyctl image pack`) has produced
    the layout. Assumes `oras login <registry>` has already been done — this
    script never touches credentials.

    -Repository is everything between the registry host and the tag, so it
    absorbs registries with and without a project level: Harbor wants
    "project/name" (e.g. runny-images/windows-server-2025-runner), ghcr-style
    registries want "owner/name", and a flat registry just wants "name".

.EXAMPLE
    .\push-image.ps1 -Registry harbor.example.com `
        -Repository runny-images/windows-server-2025-runner -Tag 33158-b970001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Registry,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$Tag,
    [string]$LayoutPath = (Join-Path $PSScriptRoot 'out\oci-layout')
)

$ErrorActionPreference = 'Stop'

$indexPath = Join-Path $LayoutPath 'index.json'
if (-not (Test-Path $indexPath)) {
    throw "no OCI layout at $LayoutPath (missing index.json) -- run build.ps1 or runnyctl image pack first"
}

$manifests = (Get-Content -Raw $indexPath | ConvertFrom-Json).manifests
if (-not $manifests -or $manifests.Count -lt 1) {
    throw "$indexPath lists no manifests"
}
if ($manifests.Count -gt 1) {
    # A pack always writes exactly one image; more means a stale or hand-edited
    # layout, and guessing which manifest to push would be a silent wrong-image.
    throw "$indexPath lists $($manifests.Count) manifests, expected exactly one -- re-pack into a clean layout"
}
$digest = $manifests[0].digest

$ref = "$Registry/${Repository}:$Tag"
Write-Host "pushing $LayoutPath@$digest"
Write-Host "     -> $ref"
oras cp --from-oci-layout "$LayoutPath@$digest" $ref
if ($LASTEXITCODE -ne 0) {
    throw "oras cp failed ($LASTEXITCODE)"
}
Write-Host "PUSHED: $ref"
Write-Host "digest: $digest"
