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

$document = Join-Path $RepositoryRoot 'docs\design\lxr-port\P1.2-x64-slot-log-barrier.md'
$microPath = Join-Path $scriptRoot 'raw\microbenchmark.csv'
$endToEndPath = Join-Path $scriptRoot 'raw\end-to-end-summary.csv'
$fastPath = Join-Path $scriptRoot 'raw\lowalloc-fast-summary.csv'
$churnFastPath = Join-Path $scriptRoot 'raw\churn-fast-summary.csv'
$pairedPath = Join-Path $scriptRoot 'raw\paired-ratio-summary.csv'

foreach ($path in @($document, $microPath, $endToEndPath, $fastPath, $churnFastPath, $pairedPath)) {
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing shipped artifact $path"
}

Require-Pattern 'src\coreclr\gc\gcinterface.h' 'GC_WRITE_BARRIER_COMPLETE_STORE_INTERFACE_MINOR_VERSION 10'
Require-Pattern 'src\coreclr\gc\gcinterface.h' 'GC_WRITE_BARRIER_EPOCH_RESET_INTERFACE_MINOR_VERSION 11'
Require-Pattern 'src\coreclr\gc\gcinterface.h' 'write_barrier_epoch_reset'
Require-Pattern 'src\coreclr\vm\amd64\JitHelpers_FastWriteBarriers.asm' 'JIT_WriteBarrier_SlotLog64'
Require-Pattern 'src\coreclr\vm\amd64\jithelpers_fastwritebarriers.S' 'JIT_WriteBarrier_SlotLog64'
Require-Pattern 'src\coreclr\vm\amd64\SlotLogWriteBarrier.asm' 'JIT_WriteBarrier_SlotLog_Slow'
Require-Pattern 'src\coreclr\vm\amd64\slotlogwritebarrier.S' 'JIT_WriteBarrier_SlotLog_Slow'
Require-Pattern 'src\coreclr\jit\assertionprop.cpp' 'JIT_FLAG_WRITE_BARRIER_REQUIRES_OLD_VALUE'
Require-Pattern 'src\coreclr\interpreter\compiler.cpp' 'RequiresOldValueWriteBarrier'
Require-Pattern 'src\coreclr\jit\lower.cpp' 'TryDecomposeInitBlockStoreAsIndirs'
Require-Pattern 'src\coreclr\System.Private.CoreLib\src\System\Buffer.CoreCLR.cs' 'ClearWithOldValueWriteBarrier'
Require-Pattern 'src\coreclr\System.Private.CoreLib\src\System\Object.CoreCLR.cs' 'dataOffset'
Require-Pattern 'src\libraries\System.Private.CoreLib\src\System\Runtime\CompilerServices\RuntimeHelpers.cs' 'RequiresOldValueWriteBarrier'
Require-Pattern 'src\coreclr\vm\arraynative.inl' 'ErectWriteBarrierRangePre'
Require-Pattern 'src\coreclr\vm\comutilnative.cpp' 'ErectWriteBarrierPre'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'SoftwareWriteWatchSetDirtyRegion'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'ErectWriteBarrierLayoutRangePre'
Require-Pattern 'src\coreclr\vm\interpexec.cpp' 'liveLocalsIntervals'
Require-Pattern 'src\coreclr\vm\interpexec.cpp' 'map->GetHighestSeries()'

if (Test-Path -LiteralPath $microPath) {
    $micro = @(Import-Csv -LiteralPath $microPath)
    $arms = @($micro.Arm | Sort-Object -Unique)
    $methods = @($micro.Method | Sort-Object -Unique)
    Confirm ($arms.Count -gt 1) 'Microbenchmark does not contain multiple arms.'
    Confirm ($methods.Count -gt 1) 'Microbenchmark does not contain both field and array methods.'
    foreach ($arm in $arms) {
        Confirm ((@($micro | Where-Object Arm -eq $arm).Count) -eq $methods.Count) (
            "Microbenchmark arm '$arm' does not contain every method.")
    }
}

$publishedRatios = @{}
if (Test-Path -LiteralPath $endToEndPath) {
    $endToEnd = @(Import-Csv -LiteralPath $endToEndPath)
    $scenarios = @($endToEnd.Scenario | Sort-Object -Unique)
    $gcs = @($endToEnd.GC | Sort-Object -Unique)
    foreach ($scenario in $scenarios) {
        Confirm ((@($endToEnd | Where-Object Scenario -eq $scenario).Count) -eq $gcs.Count) (
            "Scenario '$scenario' does not contain every GC mode.")
    }

    foreach ($row in $endToEnd) {
        $ratio = [double]$row.SlotOpsPerSecond / [double]$row.StockOpsPerSecond
        $allocationRatio =
            [double]$row.SlotAllocatedMbPerSecond / [double]$row.StockAllocatedMbPerSecond
        Confirm ([Math]::Abs($ratio - [double]$row.SlotOverStock) -lt 0.0001) (
            "Throughput ratio does not rederive for $($row.Scenario)/$($row.GC).")
        Confirm ([Math]::Abs($allocationRatio - [double]$row.AllocationRateRatio) -lt 0.0001) (
            "Allocation ratio does not rederive for $($row.Scenario)/$($row.GC).")
        $publishedRatios["$($row.Scenario)|$($row.GC)"] = [double]$row.SlotOverStock
    }
}

if (Test-Path -LiteralPath $fastPath) {
    foreach ($row in @(Import-Csv -LiteralPath $fastPath)) {
        $ratio = [double]$row.SlotFastOpsPerSecond / [double]$row.StockOpsPerSecond
        Confirm ([Math]::Abs($ratio - [double]$row.SlotFastOverStock) -lt 0.0001) (
            "Fast-path ratio does not rederive for $($row.GC).")
        Confirm ([int]$row.Collections -eq 0) "Fast-path run collected for $($row.GC)."
        $publishedRatios["low-allocation-compute-fast|$($row.GC)"] =
            [double]$row.SlotFastOverStock
    }
}

if (Test-Path -LiteralPath $churnFastPath) {
    foreach ($row in @(Import-Csv -LiteralPath $churnFastPath)) {
        $ratio = [double]$row.SlotFastOpsPerSecond / [double]$row.StockOpsPerSecond
        $allocationRatio =
            [double]$row.SlotFastAllocatedMbPerSecond / [double]$row.StockAllocatedMbPerSecond
        Confirm ([Math]::Abs($ratio - [double]$row.SlotFastOverStock) -lt 0.0001) (
            "Claimed-bit churn ratio does not rederive for $($row.GC).")
        Confirm ([Math]::Abs($allocationRatio - [double]$row.AllocationRateRatio) -lt 0.0001) (
            "Claimed-bit churn allocation ratio does not rederive for $($row.GC).")
        Confirm (
            ([double]$row.PairedMin -le [double]$row.SlotFastOverStock) -and
            ([double]$row.SlotFastOverStock -le [double]$row.PairedMax)
        ) "Claimed-bit churn paired bounds do not contain the ratio for $($row.GC)."
        Confirm ([int]$row.SlotGen2 -gt 0) "Claimed-bit churn did not exercise a full GC for $($row.GC)."
    }
}

if (Test-Path -LiteralPath $pairedPath) {
    foreach ($row in @(Import-Csv -LiteralPath $pairedPath)) {
        $key = "$($row.Scenario)|$($row.GC)"
        Confirm ($publishedRatios.ContainsKey($key)) "Paired ratio '$key' has no published source."
        if ($publishedRatios.ContainsKey($key)) {
            Confirm ([Math]::Abs($publishedRatios[$key] - [double]$row.MeanRatio) -lt 0.001) (
                "Paired ratio does not agree with the published mean for '$key'.")
        }
        Confirm (
            ([double]$row.Min -le [double]$row.MeanRatio) -and
            ([double]$row.MeanRatio -le [double]$row.Max)
        ) "Paired ratio bounds do not contain the mean for '$key'."
    }
}

if (Test-Path -LiteralPath $document) {
    $text = Get-Content -LiteralPath $document -Raw
    Confirm ($text -notmatch 'C:\\github\\runtimelab') 'Document references the abandoned runtimelab tree.'
    Confirm ($text -match 'abbdd1d') 'Document omits the PLDI binding revision.'
    Confirm ($text -match 'df8d30a3') 'Document omits the PLDI core revision.'
    Confirm ($text -match '0682434') 'Document omits the HEAD binding revision.'
    Confirm ($text -match '304ce69d') 'Document omits the HEAD core revision.'
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
