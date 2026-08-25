# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$OutputDirectory,
    [string]$Revision = 'HEAD'
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepositoryRoot (
        'artifacts\p15-reference-enumeration-gate')
}

$archive = Join-Path $OutputDirectory 'source.tar'
$cleanRoot = Join-Path $OutputDirectory 'clean'
$controlRoot = Join-Path $OutputDirectory 'missing-control-row'

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $cleanRoot -Force | Out-Null
New-Item -ItemType Directory -Path $controlRoot -Force | Out-Null

git -C $RepositoryRoot archive --format=tar --output=$archive $Revision
if ($LASTEXITCODE -ne 0) {
    throw "Unable to archive revision $Revision."
}
tar -xf $archive -C $cleanRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to extract clean archive.'
}
tar -xf $archive -C $controlRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to extract control archive.'
}

$relativeVerifier = 'docs\design\lxr-port\P1.5\verify-reference-enumeration.ps1'
$cleanVerifier = Join-Path $cleanRoot $relativeVerifier
$controlVerifier = Join-Path $controlRoot $relativeVerifier

$powerShell = (Get-Process -Id $PID).Path
& $powerShell -NoProfile -File $cleanVerifier -RepositoryRoot $cleanRoot
if ($LASTEXITCODE -ne 0) {
    throw 'Committed verifier failed on the clean archive.'
}

$controlCsv = Join-Path $controlRoot (
    'docs\design\lxr-port\P1.5\raw\control-summary.csv')
$lines = @(Get-Content -LiteralPath $controlCsv)
if ($lines.Count -ne 7) {
    throw "Control CSV has $($lines.Count) lines; expected 7 before perturbation."
}
Set-Content -LiteralPath $controlCsv -Value $lines[0..5]
$perturbedLines = @(Get-Content -LiteralPath $controlCsv)
if ($perturbedLines.Count -ne 6) {
    throw 'Control perturbation did not delete exactly one row.'
}

$controlLog = Join-Path $OutputDirectory 'missing-control-row.log'
& $powerShell -NoProfile -File $controlVerifier `
    -RepositoryRoot $controlRoot *> $controlLog
$controlExitCode = $LASTEXITCODE
$controlOutput = Get-Content -LiteralPath $controlLog -Raw
if (($controlExitCode -eq 0) -or
    ($controlOutput -notmatch 'Control summary has 5 rows; expected 6')) {
    throw 'Deleted-row perturbation did not fail for the expected reason.'
}

Write-Host 'PASS: clean archive accepted'
Write-Host 'PASS: exactly one deleted control row rejected'
$global:LASTEXITCODE = 0
