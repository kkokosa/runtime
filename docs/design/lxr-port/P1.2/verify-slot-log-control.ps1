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

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "p12-slot-log-$([Guid]::NewGuid())"
$archive = Join-Path $temporaryRoot 'tip.tar'
$original = Join-Path $temporaryRoot 'original'
$perturbed = Join-Path $temporaryRoot 'perturbed'

try {
    New-Item -ItemType Directory -Path $original -Force | Out-Null
    git -C $RepositoryRoot archive --format=tar --output=$archive HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to archive HEAD.'
    }

    tar -xf $archive -C $original
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to extract HEAD.'
    }

    $verifier = Join-Path $original 'docs\design\lxr-port\P1.2\verify-slot-log.ps1'
    & pwsh -NoProfile -File $verifier -RepositoryRoot $original
    if ($LASTEXITCODE -ne 0) {
        throw 'Verifier rejected the exact committed archive.'
    }

    Copy-Item -LiteralPath $original -Destination $perturbed -Recurse
    $summary = Join-Path $perturbed 'docs\design\lxr-port\P1.2\raw\end-to-end-summary.csv'
    $rows = @(Import-Csv -LiteralPath $summary)
    $rows[0].SlotOverStock = '9.9999'
    $rows | Export-Csv -LiteralPath $summary -NoTypeInformation

    $perturbedVerifier = Join-Path $perturbed 'docs\design\lxr-port\P1.2\verify-slot-log.ps1'
    & pwsh -NoProfile -File $perturbedVerifier -RepositoryRoot $perturbed *> $null
    if ($LASTEXITCODE -eq 0) {
        throw 'Verifier accepted a perturbed published ratio.'
    }

    & pwsh -NoProfile -File $verifier -RepositoryRoot $original
    if ($LASTEXITCODE -ne 0) {
        throw 'Verifier did not pass again on the untouched archive.'
    }

    Write-Host 'RESULT: PASS (archive pass, perturbation fail, archive re-pass)'
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
