# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}

$parent = if ($OutputDirectory) {
    $OutputDirectory
} else {
    [IO.Path]::GetTempPath()
}
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$runRoot = Join-Path $parent ("p16-object-header-bits-gate-" + [guid]::NewGuid())
$archive = Join-Path $runRoot 'source.tar'
$clean = Join-Path $runRoot 'clean'
$summary = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $clean -Force | Out-Null

function Invoke-Verifier(
    [string]$Name,
    [string]$Root,
    [bool]$ExpectSuccess,
    [string]$ExpectedFailure
) {
    $log = Join-Path $runRoot "$Name.log"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $Root 'docs\design\lxr-port\P1.6\verify-object-header-bits.ps1') `
        -RepositoryRoot $Root *> $log
    $exitCode = $LASTEXITCODE
    $text = Get-Content -LiteralPath $log -Raw

    if ($ExpectSuccess) {
        if (($exitCode -ne 0) -or
            ($text -notmatch 'PASS: P1.6 object-header bit evidence')) {
            throw "Clean archive verification failed. See $log."
        }
    } elseif (($exitCode -eq 0) -or ($text -notmatch $ExpectedFailure)) {
        throw "Perturbation '$Name' did not fail for '$ExpectedFailure'. See $log."
    }

    $summary.Add([pscustomobject][ordered]@{
        name = $Name
        expected = $(if ($ExpectSuccess) { 'pass' } else { 'fail' })
        exit_code = $exitCode
        result = 'PASS'
        evidence = [IO.Path]::GetFileName($log)
    })
}

git -C $RepositoryRoot diff --quiet HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'The archive gate requires a clean committed worktree.'
}
git -C $RepositoryRoot diff --cached --quiet HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'The archive gate requires an empty index.'
}

git -C $RepositoryRoot archive --format=tar --output=$archive HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create exact HEAD archive.'
}
tar -xf $archive -C $clean
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to extract exact HEAD archive.'
}

Invoke-Verifier 'clean' $clean $true ''

$missingRuntimeRow = Join-Path $runRoot 'missing-runtime-row'
Copy-Item -LiteralPath $clean -Destination $missingRuntimeRow -Recurse
$runtimePath = Join-Path $missingRuntimeRow (
    'docs\design\lxr-port\P1.6\raw\runtime-summary.csv')
$runtimeRows = @(Import-Csv $runtimePath)
$runtimeRows[0..($runtimeRows.Count - 2)] |
    Export-Csv $runtimePath -NoTypeInformation
Invoke-Verifier 'missing-runtime-row' $missingRuntimeRow $false (
    'Runtime scenario evidence is incomplete')

$changedCodegen = Join-Path $runRoot 'changed-codegen'
Copy-Item -LiteralPath $clean -Destination $changedCodegen -Recurse
$codegenPath = Join-Path $changedCodegen (
    'docs\design\lxr-port\P1.6\raw\hot-function-codegen.csv')
$codegenRows = @(Import-Csv $codegenPath)
$codegenRows[0].normalized_sha256 = '0' * 64
$codegenRows | Export-Csv $codegenPath -NoTypeInformation
Invoke-Verifier 'changed-codegen' $changedCodegen $false (
    'Hot-function codegen changed')

$x86FalsePositive = Join-Path $runRoot 'x86-false-positive'
Copy-Item -LiteralPath $clean -Destination $x86FalsePositive -Recurse
$x86Path = Join-Path $x86FalsePositive (
    'docs\design\lxr-port\P1.6\raw\x86-negotiation.csv')
$x86Rows = @(Import-Csv $x86Path)
$x86Rows[0].enabled_exit = '100'
$x86Rows | Export-Csv $x86Path -NoTypeInformation
Invoke-Verifier 'x86-false-positive' $x86FalsePositive $false (
    'x86 fail-closed evidence is incomplete')

$summary | Export-Csv (Join-Path $runRoot 'gate-summary.csv') -NoTypeInformation
Write-Host "PASS: exact archive and 3 perturbation controls"
Write-Host "Output: $runRoot"
exit 0
