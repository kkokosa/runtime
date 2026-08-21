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
$throughputInvocations = Join-Path $scriptRoot 'raw\bulk-throughput-invocations.csv'
$layoutHelperPilots = Join-Path $scriptRoot 'raw\layout-helper-pilots.csv'
$largeLayoutBenchmark = Join-Path $scriptRoot 'raw\large-layout-benchmark.csv'
$layoutHelperCodegen = Join-Path $scriptRoot 'raw\layout-helper-codegen.csv'
$customLayoutCodegen = Join-Path $scriptRoot 'raw\custom-layout-codegen.csv'
$stockFillCodegen = Join-Path $scriptRoot 'raw\stock-fill-codegen.csv'
$stockFillDisassembly = Join-Path $scriptRoot 'raw\stock-fill-codegen.txt'

foreach ($path in @(
    $document,
    $validation,
    $platform,
    $benchmark,
    $committedBenchmark,
    $runtimeIdentities,
    $codegen,
    $throughputInvocations,
    $layoutHelperPilots,
    $largeLayoutBenchmark,
    $layoutHelperCodegen,
    $customLayoutCodegen,
    $stockFillCodegen,
    $stockFillDisassembly
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
Require-Pattern 'src\coreclr\jit\lower.cpp' 'layout->GetSize() > MaxUnrolledLayoutBytes'
Require-Pattern 'src\coreclr\jit\lower.cpp' 'GetGcLayoutClassHandle()'
Require-Pattern 'src\coreclr\jit\lower.cpp' 'GetGcLayoutOffset()'
Require-Pattern 'src\coreclr\jit\layout.cpp' 'm_gcLayoutOffset + offset'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'chunkLayoutOffset = gcLayoutOffset + chunkOffset'
Require-Pattern 'src\coreclr\System.Private.CoreLib\src\System\Buffer.CoreCLR.cs' (
    'BulkMoveValueClassWithOldValueWriteBarrier(')
Require-Pattern 'src\coreclr\System.Private.CoreLib\src\System\Buffer.CoreCLR.cs' (
    'ClearValueClassWithOldValueWriteBarrier(')
Require-Pattern 'src\coreclr\System.Private.CoreLib\src\System\Buffer.CoreCLR.cs' 'Thread.FastPollGC();'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'ErectWriteBarrierLayoutChunkPre'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'lowestOffsetSeries[-middle]'
Require-PatternCount 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_BULK_WRITEBARRIER_WITH_LAYOUT,' 1
Require-PatternCount 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_BULK_WRITEBARRIER_CLEAR_WITH_LAYOUT,' 1
Require-Pattern 'src\coreclr\nativeaot\Runtime\gcenv.ee.cpp' 'args->write_barrier_shape != WriteBarrierShape::CardTable'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'all-claimed bulk reference copy'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'out-of-range metadata bit'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'layout-aware JIT struct copy'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'mixed-reference Span.Fill'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'very-large backward-overlap Span.CopyTo'
Require-Pattern 'docs\design\lxr-port\P1.1\runtime-smoke\Program.cs' 'very-large volatile mixed-layout copy'
Require-Pattern 'src\tests\async\objects-captured\objects-captured.cs' 'ValidateVeryLargeResult'
Require-Pattern 'src\tests\async\objects-captured\objects-captured.cs' '[InlineArray(2048)]'
Forbid-Pattern 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_ASSIGN_BYREF'
Forbid-Pattern 'src\coreclr\inc\corinfo.h' 'CORINFO_HELP_ASSIGN_REF_ENSURE_NONHEAP'
Forbid-Pattern 'src\coreclr\jit\lower.cpp' 'assert(!blk->IsOnHeapAndContainsReferences())'

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
    foreach ($method in @(
        'ReferenceArrayCopy',
        'ReferenceArrayClear',
        'ReferenceSpanFill',
        'MixedStructCopy',
        'VeryLargeMixedStructCopy',
        'VeryLargeMixedStructClear',
        'MultiThreadThroughput'
    )) {
        Confirm ($methods -contains $method) "Benchmark summary omits $method."
    }

    foreach ($row in @($rows | Where-Object Method -ne 'MultiThreadThroughput')) {
        Confirm ($row.P13OverStockStatistic -eq 'ratio-of-means') (
            "$($row.Method) is not explicitly labeled as a ratio of means.")
        $ratio = [double]$row.P13Mean / [double]$row.StockMean
        Confirm ([Math]::Abs($ratio - [double]$row.P13OverStock) -lt 0.0001) (
            "P1.3/stock ratio does not rederive for $($row.Method)/$($row.GC).")
        Confirm ([Math]::Abs($ratio - [double]$row.RatioOfMeans) -lt 0.0001) (
            "Ratio-of-means column does not rederive for $($row.Method)/$($row.GC).")
        if ($row.P12Mean) {
            $p12Ratio = [double]$row.P13Mean / [double]$row.P12Mean
            Confirm ([Math]::Abs($p12Ratio - [double]$row.P13OverP12) -lt 0.0001) (
                "P1.3/P1.2 ratio does not rederive for $($row.Method)/$($row.GC).")
        }
    }

    if (Test-Path -LiteralPath $throughputInvocations) {
        $rawRows = @(Import-Csv -LiteralPath $throughputInvocations)
        $throughputRows = @($rows | Where-Object Method -eq 'MultiThreadThroughput')
        $expectedRawCount = (
            $throughputRows |
                ForEach-Object { 2 * [int]$_.PairCount } |
                Measure-Object -Sum).Sum
        Confirm ($rawRows.Count -eq $expectedRawCount) (
            "Throughput raw data has $($rawRows.Count) rows; expected $expectedRawCount from the summary.")

        foreach ($rawRow in $rawRows) {
            Confirm (([int]$rawRow.Gen0 + [int]$rawRow.Gen1 + [int]$rawRow.Gen2) -eq 0) (
                "Throughput row $($rawRow.Pair)/$($rawRow.Variant) collected.")
            Confirm (($rawRow.ReadyToRun -eq '0') -and ($rawRow.TieredCompilation -eq '0')) (
                "Throughput row $($rawRow.Pair)/$($rawRow.Variant) changed codegen configuration.")
            Confirm ($rawRow.ClaimBits -eq $(if ($rawRow.Variant -eq 'family') { '1' } else { '0' })) (
                "Throughput row $($rawRow.Pair)/$($rawRow.Variant) has the wrong claim state.")
            Confirm ($rawRow.CoreClrSha256 -match '^[0-9a-fA-F]{64}$') (
                "Throughput row $($rawRow.Pair)/$($rawRow.Variant) omits build identity.")
            Confirm ($rawRow.CompletionMarker -match '^low-allocation-compute:stores=\d+$') (
                "Throughput row $($rawRow.Pair)/$($rawRow.Variant) omits its completion marker.")
        }

        $pairs = @($rawRows | Group-Object Pair)
        foreach ($pair in $pairs) {
            Confirm ($pair.Count -eq 2) "Throughput pair '$($pair.Name)' does not contain two rows."
            Confirm ((@($pair.Group.Variant | Sort-Object -Unique) -join ',') -eq 'family,stock') (
                "Throughput pair '$($pair.Name)' does not contain stock and family.")
            Confirm ((@($pair.Group.Order | Sort-Object -Unique) -join ',') -eq '0,1') (
                "Throughput pair '$($pair.Name)' does not contain both execution orders.")
            foreach ($property in @('Invocation', 'Seed', 'GC', 'Arm', 'Workers')) {
                Confirm (@($pair.Group.$property | Sort-Object -Unique).Count -eq 1) (
                    "Throughput pair '$($pair.Name)' disagrees on $property.")
            }

            $invocation = [int]$pair.Group[0].Invocation
            $expectedFirst = if (($invocation % 2) -eq 0) { 'stock' } else { 'family' }
            $first = @($pair.Group | Where-Object Order -eq '0')
            Confirm (($first.Count -eq 1) -and ($first[0].Variant -eq $expectedFirst)) (
                "Throughput pair '$($pair.Name)' does not alternate its first arm.")
            Confirm ($pair.Name -eq "$($pair.Group[0].GC)-$invocation") (
                "Throughput pair '$($pair.Name)' has inconsistent identity fields.")
        }

        foreach ($summaryRow in $throughputRows) {
            Confirm ($summaryRow.P13OverStockStatistic -eq 'mean-of-pair-ratios') (
                "$($summaryRow.GC) throughput is not labeled as a mean of pair ratios.")
            $rawGc = if ($summaryRow.GC -eq 'Workstation') { 'wks' } else { 'srv' }
            $gcPairs = @($rawRows | Where-Object GC -eq $rawGc | Group-Object Pair)
            Confirm ($gcPairs.Count -eq [int]$summaryRow.PairCount) (
                "$($summaryRow.GC) raw pair count does not match the summary.")

            $pairRatios = @(
                foreach ($pair in $gcPairs) {
                    $stock = [double]@($pair.Group | Where-Object Variant -eq 'stock')[0].OpsPerSecond
                    $family = [double]@($pair.Group | Where-Object Variant -eq 'family')[0].OpsPerSecond
                    $family / $stock
                }
            )
            $stockMean = (
                $rawRows |
                    Where-Object { ($_.GC -eq $rawGc) -and ($_.Variant -eq 'stock') } |
                    Measure-Object OpsPerSecond -Average).Average
            $familyMean = (
                $rawRows |
                    Where-Object { ($_.GC -eq $rawGc) -and ($_.Variant -eq 'family') } |
                    Measure-Object OpsPerSecond -Average).Average
            $meanPairRatio = ($pairRatios | Measure-Object -Average).Average
            $pairMin = ($pairRatios | Measure-Object -Minimum).Minimum
            $pairMax = ($pairRatios | Measure-Object -Maximum).Maximum
            $ratioOfMeans = $familyMean / $stockMean

            Confirm ([Math]::Abs($stockMean - [double]$summaryRow.StockMean) -lt 0.01) (
                "$($summaryRow.GC) stock mean does not rederive from raw rows.")
            Confirm ([Math]::Abs($familyMean - [double]$summaryRow.P13Mean) -lt 0.01) (
                "$($summaryRow.GC) family mean does not rederive from raw rows.")
            Confirm ([Math]::Abs($meanPairRatio - [double]$summaryRow.P13OverStock) -lt 0.0001) (
                "$($summaryRow.GC) mean pair ratio does not rederive from raw rows.")
            Confirm ([Math]::Abs($pairMin - [double]$summaryRow.PairedMin) -lt 0.0001) (
                "$($summaryRow.GC) paired minimum does not rederive from raw rows.")
            Confirm ([Math]::Abs($pairMax - [double]$summaryRow.PairedMax) -lt 0.0001) (
                "$($summaryRow.GC) paired maximum does not rederive from raw rows.")
            Confirm ([Math]::Abs($ratioOfMeans - [double]$summaryRow.RatioOfMeans) -lt 0.0001) (
                "$($summaryRow.GC) ratio of means does not rederive from raw rows.")
        }
    }
}

if (Test-Path -LiteralPath $layoutHelperPilots) {
    $pilotRows = @(Import-Csv -LiteralPath $layoutHelperPilots)
    $helperRows = @($pilotRows | Where-Object Selection -eq 'helper')
    $referenceCounts = @($helperRows.References | Sort-Object { [int]$_ } -Unique)
    Confirm (($referenceCounts -join ',') -eq '4,16,64') (
        'Layout-helper pilots must contain the 4/16/64-reference configurations.')
    Confirm ($helperRows.Count -eq (3 * $referenceCounts.Count)) (
        'Each layout-helper pilot must contain three runtime arms.')

    foreach ($row in $pilotRows) {
        $normalized = [double]$row.ReportedMeanNs / [double]$row.NormalizationDivisor
        Confirm ([Math]::Abs($normalized - [double]$row.MeanNsPerReference) -lt 0.0001) (
            "Pilot normalization does not rederive for $($row.References)/$($row.Selection)/$($row.Arm).")
        Confirm (($row.Launches -eq '3') -and ($row.Warmups -eq '8') -and ($row.Iterations -eq '20')) (
            "Pilot configuration changed for $($row.References)/$($row.Selection)/$($row.Arm).")
        Confirm (($row.ReadyToRun -eq '0') -and ($row.TieredCompilation -eq '0')) (
            "Pilot codegen configuration changed for $($row.References)/$($row.Selection)/$($row.Arm).")
    }

    foreach ($references in $referenceCounts) {
        $group = @($helperRows | Where-Object References -eq $references)
        Confirm ((@($group.Arm | Sort-Object -Unique) -join ',') -eq 'P1.2,P1.3,Stock') (
            "The $references-reference helper pilot omits a runtime arm.")
        $p12 = [double]@($group | Where-Object Arm -eq 'P1.2')[0].MeanNsPerReference
        $p13 = [double]@($group | Where-Object Arm -eq 'P1.3')[0].MeanNsPerReference
        Confirm ($p13 -gt $p12) "The $references-reference pilot does not support the no-crossover claim."
    }

    $final64 = @($pilotRows | Where-Object Selection -eq 'per-slot-final')
    Confirm (($final64.Count -eq 3) -and
        ((@($final64.Arm | Sort-Object -Unique) -join ',') -eq 'P1.2,P1.3,Stock')) (
        'The final 64-reference per-slot evidence is incomplete.')
}

if ((Test-Path -LiteralPath $largeLayoutBenchmark) -and (Test-Path -LiteralPath $benchmark)) {
    $largeRows = @(Import-Csv -LiteralPath $largeLayoutBenchmark)
    $summaryRows = @(Import-Csv -LiteralPath $benchmark)
    $largeMethods = @($largeRows.Method | Sort-Object -Unique)
    Confirm (($largeMethods -join ',') -eq 'VeryLargeMixedStructClear,VeryLargeMixedStructCopy') (
        'Very-large benchmark evidence must contain copy and clear.')
    Confirm ($largeRows.Count -eq (3 * $largeMethods.Count)) (
        'Each very-large benchmark must contain three runtime arms.')
    foreach ($method in $largeMethods) {
        $methodRows = @($largeRows | Where-Object Method -eq $method)
        Confirm ((@($methodRows.Arm | Sort-Object -Unique) -join ',') -eq 'P1.2,P1.3,Stock') (
            "Very-large benchmark '$method' omits a runtime arm.")
        Confirm ((@($methodRows.LayoutBytes | Sort-Object -Unique) -join ',') -eq '49152') (
            "Very-large benchmark '$method' changed layout size.")
        Confirm ((@($methodRows.References | Sort-Object -Unique) -join ',') -eq '4096') (
            "Very-large benchmark '$method' changed reference count.")
        $summary = @($summaryRows | Where-Object Method -eq $method)
        Confirm ($summary.Count -eq 1) "Very-large benchmark '$method' has no unique summary row."
        if ($summary.Count -eq 1) {
            foreach ($arm in @('Stock', 'P1.2', 'P1.3')) {
                $raw = [double]@($methodRows | Where-Object Arm -eq $arm)[0].MeanNsPerReference
                $column = switch ($arm) {
                    'Stock' { 'StockMean' }
                    'P1.2' { 'P12Mean' }
                    'P1.3' { 'P13Mean' }
                }
                Confirm ([Math]::Abs($raw - [double]$summary[0].$column) -lt 0.0001) (
                    "Very-large benchmark '$method/$arm' does not match its summary.")
            }
        }
    }
}

if (Test-Path -LiteralPath $layoutHelperCodegen) {
    $rows = @(Import-Csv -LiteralPath $layoutHelperCodegen)
    foreach ($row in $rows) {
        Confirm ($row.RuntimeResult -eq 'PASS') "Codegen row '$($row.Case)/$($row.Method)' did not pass."
        Confirm (($row.CoreClrSha256 -match '^[0-9A-F]{64}$') -and
            ($row.ClrJitSha256 -match '^[0-9A-F]{64}$') -and
            ($row.DisassemblySha256 -match '^[0-9A-F]{64}$')) (
            "Codegen row '$($row.Case)/$($row.Method)' omits exact identities.")
    }

    $perSlot = @($rows | Where-Object Case -eq '64-reference-final')
    Confirm (($perSlot.Count -eq 1) -and
        ($perSlot[0].Selection -eq 'per-slot') -and
        ([int]$perSlot[0].CodeBytes -eq 1419) -and
        ([int]$perSlot[0].HelperCalls -eq 0)) (
        'The 64-reference policy codegen evidence is incomplete.')

    foreach ($method in @('Program:StoreVeryLargeValue', 'Program:ClearVeryLargeValue')) {
        $prefix = @($rows | Where-Object { ($_.Case -eq 'very-large-prefix') -and ($_.Method -eq $method) })
        $final = @($rows | Where-Object { ($_.Case -eq 'very-large-final') -and ($_.Method -eq $method) })
        Confirm (($prefix.Count -eq 1) -and ($final.Count -eq 1)) (
            "Very-large codegen evidence is incomplete for $method.")
        if (($prefix.Count -eq 1) -and ($final.Count -eq 1)) {
            Confirm (([int]$prefix[0].CodeBytes -gt 10000) -and ([int]$prefix[0].HelperCalls -eq 0)) (
                "Pre-fix codegen does not demonstrate LIR expansion for $method.")
            Confirm (([int]$final[0].CodeBytes -lt 128) -and ([int]$final[0].HelperCalls -eq 1)) (
                "Final codegen is not bounded to one helper for $method.")
        }
    }

    $volatile = @($rows | Where-Object Case -eq 'very-large-volatile-final')
    Confirm (($volatile.Count -eq 1) -and
        ($volatile[0].Method -eq '(dynamicClass):VolatileVeryLargeCopy') -and
        ([int]$volatile[0].HelperCalls -eq 1) -and
        ([int]$volatile[0].CodeBytes -lt 128)) (
        'Volatile very-large codegen is not bounded to one helper.')

    foreach ($mode in @('minopts', 'cold')) {
        $modeRows = @($rows | Where-Object Case -eq "very-large-$mode-final")
        $suffix = if ($mode -eq 'minopts') { 'MinOpts' } else { 'Cold' }
        $expectedModeMethods = @(
            "Program:ClearVeryLargeValue$suffix",
            "Program:StoreVeryLargeValue$suffix"
        ) -join ','
        Confirm (($modeRows.Count -eq 2) -and
            ((@($modeRows.Method | Sort-Object) -join ',') -eq $expectedModeMethods)) (
            "$mode very-large codegen evidence does not contain copy and clear.")
        foreach ($row in $modeRows) {
            Confirm (([int]$row.HelperCalls -eq 1) -and ([int]$row.CodeBytes -lt 128)) (
                "$mode codegen is not bounded to one helper for '$($row.Method)'.")
        }
    }
}

if (Test-Path -LiteralPath $customLayoutCodegen) {
    $rows = @(Import-Csv -LiteralPath $customLayoutCodegen)
    $prefix = @($rows | Where-Object Case -eq 'runtime-async-slice-prefix')
    $final = @($rows | Where-Object Case -eq 'runtime-async-slice-final')
    Confirm (($prefix.Count -eq 1) -and ($final.Count -eq 1)) (
        'Runtime-async custom-slice codegen must contain prefix and final rows.')
    if (($prefix.Count -eq 1) -and ($final.Count -eq 1)) {
        foreach ($row in @($prefix[0], $final[0])) {
            Confirm (($row.Method -eq 'Async2ObjectsWithYields:ValidateVeryLargeResult') -and
                ($row.ValueBytes -eq '49160') -and
                ($row.SliceOffset -eq '8') -and
                ($row.SliceBytes -eq '49144') -and
                ($row.References -eq '4096') -and
                ($row.Result -eq 'PASS')) (
                "Runtime-async custom-slice row '$($row.Case)' has inconsistent configuration.")
            Confirm (($row.CoreClrSha256 -match '^[0-9A-F]{64}$') -and
                ($row.ClrJitSha256 -match '^[0-9A-F]{64}$') -and
                ($row.DisassemblySha256 -match '^[0-9A-F]{64}$')) (
                "Runtime-async custom-slice row '$($row.Case)' omits exact identities.")
        }
        Confirm (([int]$prefix[0].CodeBytes -gt 100000) -and
            ([int]$prefix[0].ClearHelperCalls -eq 0)) (
            'Pre-fix runtime-async slice does not demonstrate unbounded expansion.')
        Confirm (([int]$final[0].CodeBytes -lt 1024) -and
            ([int]$final[0].ClearHelperCalls -eq 1)) (
            'Final runtime-async slice is not bounded to one clear helper.')
    }
}

if ((Test-Path -LiteralPath $stockFillCodegen) -and (Test-Path -LiteralPath $stockFillDisassembly)) {
    $rows = @(Import-Csv -LiteralPath $stockFillCodegen)
    $requiredMethods = @(
        'Program:FillReferences(System.Object[],System.Object):System.Object (FullOpts)',
        'Program:FillMixedReferences(MixedReferences[],MixedReferences):System.Object (FullOpts)'
    )
    $actualMethods = @($rows.Method | Sort-Object) -join ','
    $expectedMethods = @($requiredMethods | Sort-Object) -join ','
    Confirm ($actualMethods -eq $expectedMethods) (
        'Stock Fill codegen evidence does not contain the exact required method names.')

    $text = (Get-Content -LiteralPath $stockFillDisassembly -Raw) -replace "`r`n", "`n"
    foreach ($row in $rows) {
        $pattern = '(?ms)^; Assembly listing for method ' +
            [regex]::Escape($row.Method) +
            '.*?(?=^; Assembly listing for method|\z)'
        $match = [regex]::Match($text, $pattern)
        Confirm $match.Success "Normalized stock disassembly omits '$($row.Method)'."
        if ($match.Success) {
            $normalizedLines = @(
                $match.Value.TrimEnd() -split "`n" |
                    ForEach-Object { $_.TrimEnd() }
            )
            $normalized = ($normalizedLines -join "`n") + "`n"
            $hash = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes($normalized)))
            $codeBytes = [regex]::Match(
                $normalized,
                'Total bytes of code (?<bytes>\d+)').Groups['bytes'].Value
            Confirm (($row.Equal -eq 'true') -and
                ($row.BaselineNormalizedSha256 -eq $row.ChangedNormalizedSha256) -and
                ($hash -eq $row.BaselineNormalizedSha256)) (
                "Stock Fill identity does not rederive for '$($row.Method)'.")
            Confirm (($codeBytes -eq $row.BaselineCodeBytes) -and
                ($codeBytes -eq $row.ChangedCodeBytes)) (
                "Stock Fill code size does not rederive for '$($row.Method)'.")
        }
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
