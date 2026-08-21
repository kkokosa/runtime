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

$failures = [Collections.Generic.List[string]]::new()
$checks = 0

function Confirm([bool]$condition, [string]$message) {
    $script:checks++
    if (-not $condition) {
        $script:failures.Add($message)
    }
}

function Require-Pattern([string]$relativePath, [string]$pattern) {
    $path = Join-Path $RepositoryRoot $relativePath
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing $relativePath"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Confirm ([bool](Select-String -LiteralPath $path -SimpleMatch $pattern -Quiet)) (
            "$relativePath does not contain '$pattern'")
    }
}

function Require-PatternCount(
    [string]$relativePath,
    [string]$pattern,
    [int]$expectedCount
) {
    $path = Join-Path $RepositoryRoot $relativePath
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing $relativePath"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $actualCount = @(Select-String -LiteralPath $path -SimpleMatch $pattern).Count
        Confirm ($actualCount -eq $expectedCount) (
            "$relativePath contains '$pattern' $actualCount times; expected $expectedCount.")
    }
}

function Forbid-Pattern([string]$relativePath, [string]$pattern) {
    $path = Join-Path $RepositoryRoot $relativePath
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing $relativePath"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Confirm (-not [bool](Select-String -LiteralPath $path -SimpleMatch $pattern -Quiet)) (
            "$relativePath unexpectedly contains '$pattern'")
    }
}

$document = Join-Path $RepositoryRoot 'docs\design\lxr-port\P1.3-store-path-coverage-and-bulk-barrier.md'
$validation = Join-Path $scriptRoot 'raw\validation-summary.csv'
$platform = Join-Path $scriptRoot 'raw\platform-summary.csv'
$benchmark = Join-Path $scriptRoot 'raw\benchmark-summary.csv'
$committedBenchmark = Join-Path $scriptRoot 'raw\committed-benchmark-summary.csv'
$runtimeIdentities = Join-Path $scriptRoot 'raw\runtime-identities.csv'
$codegen = Join-Path $scriptRoot 'raw\codegen-summary.txt'

foreach ($path in @(
    $document,
    $validation,
    $platform,
    $benchmark,
    $committedBenchmark,
    $runtimeIdentities,
    $codegen
)) {
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing shipped artifact $path"
}

if (Test-Path -LiteralPath $runtimeIdentities) {
    $rows = @(Import-Csv -LiteralPath $runtimeIdentities)
    Confirm ($rows.Count -eq 3) 'Runtime identity summary must contain exactly three arms.'
    Confirm (@($rows | Where-Object Arm -eq 'P1.3').Count -eq 1) (
        'Runtime identity summary omits the P1.3 arm.')
}

Require-Pattern 'src\coreclr\gc\gcinterface.h' 'GC_WRITE_BARRIER_BULK_SCAN_INTERFACE_MINOR_VERSION 12'
Require-Pattern 'src\coreclr\gc\gcinterface.h' 'WriteBarrierBulkScanParameters write_barrier_bulk_scan'
Require-Pattern 'src\coreclr\vm\gcenv.ee.cpp' 'IsValidWriteBarrierBulkScan'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'WriteBarrierBulkAction ClassifyWriteBarrierBulk'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'workBits = ~workBits;'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'activeMask <<='
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'activeMask &='
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'WriteBarrierBulkAction::AllClaimed'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'ErectWriteBarrierLayoutFillPre'
Require-Pattern 'src\libraries\System.Private.CoreLib\src\System\SpanHelpers.T.cs' 'BulkFillWithOldValueWriteBarrier'
Require-Pattern 'src\coreclr\jit\lower.cpp' 'CORINFO_HELP_BULK_WRITEBARRIER_WITH_LAYOUT'
Require-Pattern 'src\coreclr\jit\lower.cpp' 'CORINFO_HELP_BULK_WRITEBARRIER_CLEAR_WITH_LAYOUT'
Require-Pattern 'src\coreclr\jit\lower.cpp' 'ShouldUseLayoutBulkHelper'
Require-PatternCount 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_BULK_WRITEBARRIER_WITH_LAYOUT,' 1
Require-PatternCount 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_BULK_WRITEBARRIER_CLEAR_WITH_LAYOUT,' 1
Require-Pattern 'src\coreclr\nativeaot\Runtime\gcenv.ee.cpp' 'args->write_barrier_shape != WriteBarrierShape::CardTable'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'all-claimed bulk reference copy'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'out-of-range metadata bit'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'layout-aware JIT struct copy'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'mixed-reference Span.Fill'
Forbid-Pattern 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_ASSIGN_BYREF'
Forbid-Pattern 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_ASSIGN_REF_ENSURE_NONHEAP'

if (Test-Path -LiteralPath $validation) {
    $rows = @(Import-Csv -LiteralPath $validation)
    Confirm ($rows.Count -gt 0) 'Validation summary is empty.'
    foreach ($row in $rows) {
        Confirm ($row.Result -eq 'PASS') "Validation row '$($row.Name)' is not PASS."
    }
}

if (Test-Path -LiteralPath $platform) {
    $rows = @(Import-Csv -LiteralPath $platform)
    $levels = @($rows.Level | Sort-Object -Unique)
    Confirm ($levels -contains 'execution') 'Platform summary omits execution evidence.'
    Confirm ($levels -contains 'cross-build') 'Platform summary omits cross-build evidence.'
    Confirm ($levels -contains 'audit') 'Platform summary omits source/assembly audit evidence.'
}

if (Test-Path -LiteralPath $benchmark) {
    $rows = @(Import-Csv -LiteralPath $benchmark)
    $methods = @($rows.Method | Sort-Object -Unique)
    foreach ($method in @('ReferenceArrayCopy', 'ReferenceArrayClear', 'ReferenceSpanFill', 'MixedStructCopy', 'MultiThreadThroughput')) {
        Confirm ($methods -contains $method) "Benchmark summary omits $method."
    }
    foreach ($row in $rows) {
        $ratio = [double]$row.P13Mean / [double]$row.StockMean
        Confirm ([Math]::Abs($ratio - [double]$row.P13OverStock) -lt 0.0001) (
            "P1.3/stock ratio does not rederive for $($row.Method)/$($row.GC).")
    }
}

if (Test-Path -LiteralPath $codegen) {
    $text = Get-Content -LiteralPath $codegen -Raw
    Confirm ($text -match 'CORINFO_HELP_BULK_WRITEBARRIER_WITH_LAYOUT') (
        'Codegen evidence omits the layout copy helper.')
    Confirm ($text -match 'CORINFO_HELP_BULK_WRITEBARRIER_CLEAR_WITH_LAYOUT') (
        'Codegen evidence omits the layout clear helper.')
    Confirm ($text -match 'stock disassembly: byte-identical') (
        'Codegen evidence omits stock byte identity.')
}

if (Test-Path -LiteralPath $document) {
    $text = Get-Content -LiteralPath $document -Raw
    Confirm ($text -notmatch 'C:\\github\\runtimelab') 'Document references the excluded runtimelab tree.'
    foreach ($revision in @('abbdd1d', 'df8d30a3', '0682434', '304ce69d')) {
        Confirm ($text -match $revision) "Document omits oracle revision $revision."
    }
    Confirm ($text -match 'arXiv:2210.17175') 'Document omits the exact paper identity.'
}

if ($failures.Count -ne 0) {
    foreach ($failure in $failures) {
        Write-Error $failure
    }
    Write-Host "RESULT: FAIL ($($failures.Count) failures across $checks checks)"
    exit 1
}

Write-Host "RESULT: PASS ($checks checks)"
exit 0
