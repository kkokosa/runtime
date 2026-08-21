# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "p13-store-paths-$([Guid]::NewGuid())"
$archive = Join-Path $temporaryRoot 'tip.tar'
$archiveRoot = Join-Path $temporaryRoot 'original'
$perturbedRoot = Join-Path $temporaryRoot 'perturbed'

function Assert-LiteralCount(
    [string]$Text,
    [string]$Value,
    [int]$ExpectedCount,
    [string]$Description
) {
    $actualCount = [regex]::Matches($Text, [regex]::Escape($Value)).Count
    if ($actualCount -ne $ExpectedCount) {
        throw "$Description matched $actualCount sites; expected $ExpectedCount."
    }
}

function Invoke-Perturbation(
    [string]$RelativePath,
    [string]$OriginalText,
    [string]$ReplacementText,
    [string]$Description
) {
    $sourcePath = Join-Path $archiveRoot $RelativePath
    $path = Join-Path $perturbedRoot $RelativePath
    Copy-Item -LiteralPath $sourcePath -Destination $path -Force
    try {
        $text = Get-Content -LiteralPath $path -Raw
        Assert-LiteralCount $text $OriginalText 1 "$Description original"
        $text = $text.Replace($OriginalText, $ReplacementText)
        Assert-LiteralCount $text $OriginalText 0 "$Description original after perturbation"
        Assert-LiteralCount $text $ReplacementText 1 "$Description replacement"
        Set-Content -LiteralPath $path -Value $text -NoNewline

        $verifier = Join-Path $perturbedRoot 'docs\design\lxr-port\P1.3\verify-store-paths.ps1'
        & pwsh -NoProfile -File $verifier -RepositoryRoot $perturbedRoot *> $null
        if ($LASTEXITCODE -eq 0) {
            throw "Verifier accepted perturbation: $Description"
        }
    } finally {
        Copy-Item -LiteralPath $sourcePath -Destination $path -Force
    }
}

try {
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    git -C $RepositoryRoot archive --format=tar --output=$archive HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to archive HEAD.'
    }
    tar -xf $archive -C $archiveRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to extract HEAD.'
    }

    $verifier = Join-Path $archiveRoot 'docs\design\lxr-port\P1.3\verify-store-paths.ps1'
    & pwsh -NoProfile -File $verifier -RepositoryRoot $archiveRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Verifier rejected the exact committed archive.'
    }
    New-Item -ItemType Directory -Path $perturbedRoot -Force | Out-Null
    tar -xf $archive -C $perturbedRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to extract the perturbation tree.'
    }

    Invoke-Perturbation `
        'src\coreclr\gc\gcinterface.h' `
        'GC_WRITE_BARRIER_BULK_SCAN_INTERFACE_MINOR_VERSION 12' `
        'GC_WRITE_BARRIER_BULK_SCAN_INTERFACE_MINOR_VERSION 11' `
        'bulk interface version'
    Invoke-Perturbation `
        'src\coreclr\vm\gchelpers.cpp' `
        'workBits = ~workBits;' `
        'workBits = workBits;' `
        'clear-bit polarity'
    Invoke-Perturbation `
        'src\libraries\System.Private.CoreLib\src\System\SpanHelpers.T.cs' `
        'Buffer.BulkFillWithOldValueWriteBarrier(' `
        'Buffer.BulkMoveWithOldValueWriteBarrier(' `
        'Span fill funnel'
    Invoke-Perturbation `
        'src\coreclr\jit\lower.cpp' `
        'CORINFO_HELP_BULK_WRITEBARRIER_CLEAR_WITH_LAYOUT,' `
        'CORINFO_HELP_BROKEN_LAYOUT_CLEAR,' `
        'JIT layout clear helper'
    Invoke-Perturbation `
        'docs\design\lxr-port\P1.3\raw\benchmark-summary.csv' `
        ',1.8734,' `
        ',9.9999,' `
        'published benchmark ratio'

    & pwsh -NoProfile -File $verifier -RepositoryRoot $archiveRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Verifier did not pass again on the untouched archive.'
    }

    Write-Host 'RESULT: PASS (archive pass, five exact perturbations fail, archive re-pass)'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
