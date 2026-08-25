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

$document = Join-Path $RepositoryRoot (
    'docs\design\lxr-port\P1.4-allocation-complete-notification.md')
$validation = Join-Path $scriptRoot 'raw\validation-summary.csv'
$platform = Join-Path $scriptRoot 'raw\platform-summary.csv'
$codegen = Join-Path $scriptRoot 'raw\helper-codegen.csv'
$benchmark = Join-Path $scriptRoot 'raw\benchmark-summary.csv'
$benchmarkInvocations = Join-Path $scriptRoot 'raw\benchmark-invocations.csv'
$churn = Join-Path $scriptRoot 'raw\allocation-churn-invocations.csv'
$churnSummary = Join-Path $scriptRoot 'raw\churn-summary.csv'
$runtimeIdentities = Join-Path $scriptRoot 'raw\runtime-identities.csv'

foreach ($path in @(
    $document,
    $validation,
    $platform,
    $codegen,
    $benchmark,
    $benchmarkInvocations,
    $churn,
    $churnSummary,
    $runtimeIdentities
)) {
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing shipped artifact $path"
}

Require-Pattern 'src\coreclr\gc\gcinterface.h' 'GC_INTERFACE_MINOR_VERSION 13'
Require-Pattern 'src\coreclr\gc\gcinterface.h' 'GC_ALLOCATION_NOTIFICATION_INTERFACE_MINOR_VERSION 13'
Require-Pattern 'src\coreclr\gc\gcinterface.h' 'AllocationCompleteCallback'
Require-Pattern 'src\coreclr\gc\gcinterface.h' 'GetAllocationNotificationParameters()'
Require-PatternCount 'src\coreclr\gc\gcinterface.h' 'GetAllocationNotificationParameters()' 1
Require-Pattern 'src\coreclr\CMakeLists.txt' 'CLR_CMAKE_ENABLE_ALLOCATION_NOTIFICATION_TEST'
Require-Pattern 'src\coreclr\vm\gcheaputilities.cpp' 'g_pConfig->ReadyToRun()'
Require-Pattern 'src\coreclr\vm\gcheaputilities.cpp' 's_useThreadAllocationContexts = true;'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'RhpAllocationComplete(Object* object'
Require-Pattern 'src\coreclr\vm\gchelpers.cpp' 'FireAllocationSampled('
Require-Pattern 'src\coreclr\vm\runtimehandles.cpp' 'RhpAllocationComplete(obj, size);'
Require-Pattern 'src\coreclr\vm\comutilnative.cpp' (
    'if (GCHeapUtilities::IsAllocationNotificationEnabled())')
Require-Pattern 'src\coreclr\vm\comutilnative.cpp' 'COMPlusThrow(kNotSupportedException);'
Require-Pattern 'src\coreclr\nativeaot\Runtime\gcheaputilities.cpp' (
    'parameters->request_status = AllocationNotificationRequestStatus::Unsupported;')
Require-Pattern 'src\coreclr\runtime\amd64\AllocFastNotification.asm' (
    'jmp         RhpAllocationCompleteEpilogue')
Require-Pattern 'src\coreclr\runtime\amd64\AllocFastNotification.asm' (
    'call        RhpAllocationComplete')
Require-Pattern 'src\coreclr\runtime\amd64\AllocFastNotification.S' (
    'jmp         C_FUNC(RhpAllocationCompleteEpilogue)')
Require-Pattern 'src\coreclr\runtime\amd64\AllocFastNotification.S' (
    'call        C_FUNC(RhpAllocationComplete)')
Require-Pattern 'src\coreclr\vm\jitinterfacegen.cpp' 'RhpNewFast_Notify'
Require-Pattern 'src\coreclr\dlls\mscoree\mscorwks_allocationnotificationtest_unixexports.src' (
    'GC_AllocationNotificationTest_GetCount')
Require-Pattern 'docs\design\lxr-port\P1.4\runtime-smoke\Program.cs' (
    'PASS: exact allocation-complete notifications')
Require-Pattern 'docs\design\lxr-port\P1.4\runtime-smoke\Program.cs' (
    'P14_EXPECT_STACK_ALLOCATION')
Require-Pattern 'src\tests\profiler\native\gcallocateprofiler\gcallocateprofiler.cpp' (
    'Allocation profiler callback preceded the allocation-complete callback')
Forbid-Pattern 'src\coreclr\runtime\amd64\AllocFast.asm' 'RhpAllocationComplete'
Forbid-Pattern 'src\coreclr\runtime\amd64\AllocFast.S' 'RhpAllocationComplete'
Forbid-Pattern 'src\coreclr\vm\amd64\AllocSlow.asm' 'RhpAllocationComplete'

$masm = Get-Content -LiteralPath (
    Join-Path $RepositoryRoot 'src\coreclr\runtime\amd64\AllocFastNotification.asm') -Raw
$masmStore = $masm.IndexOf('OFFSETOF__ee_alloc_context__alloc_ptr], r11')
$masmCall = $masm.IndexOf('call        RhpAllocationComplete')
Confirm (($masmStore -ge 0) -and ($masmCall -ge 0) -and ($masmStore -lt $masmCall)) (
    'Windows helper does not publish the frontier before the callback.')

$gas = Get-Content -LiteralPath (
    Join-Path $RepositoryRoot 'src\coreclr\runtime\amd64\AllocFastNotification.S') -Raw
$gasStore = $gas.IndexOf('OFFSETOF__ee_alloc_context__alloc_ptr], r11')
$gasCall = $gas.IndexOf('call        C_FUNC(RhpAllocationComplete)')
Confirm (($gasStore -ge 0) -and ($gasCall -ge 0) -and ($gasStore -lt $gasCall)) (
    'System V helper does not publish the frontier before the callback.')

$runtimeHandles = Get-Content -LiteralPath (
    Join-Path $RepositoryRoot 'src\coreclr\vm\runtimehandles.cpp') -Raw
$internalStore = $runtimeHandles.IndexOf(
    'allocContext->m_GCAllocContext.alloc_ptr = allocPtr + size;')
$internalCall = $runtimeHandles.IndexOf('RhpAllocationComplete(obj, size);')
Confirm (
    ($internalStore -ge 0) -and
    ($internalCall -ge 0) -and
    ($internalStore -lt $internalCall)) (
    'Runtime internal allocator does not publish the frontier before the callback.')

$frozenHeap = Get-Content -LiteralPath (
    Join-Path $RepositoryRoot 'src\coreclr\vm\frozenobjectheap.cpp') -Raw
$frozenCall = $frozenHeap.IndexOf('RhpAllocationCompleteFrozen(obj, PtrAlign(objectSize));')
$frozenRegister = $frozenHeap.IndexOf(
    'curSeg->RegisterOrUpdate(curSegmentCurrent, curSegSizeCommitted);')
Confirm (
    ($frozenCall -ge 0) -and
    ($frozenRegister -ge 0) -and
    ($frozenCall -lt $frozenRegister)) (
    'Frozen object notification does not precede segment registration.')

if (Test-Path -LiteralPath $validation) {
    $rows = @(Import-Csv -LiteralPath $validation)
    Confirm ($rows.Count -gt 0) 'Validation summary is empty.'
    foreach ($row in $rows) {
        Confirm ($row.Result -eq 'PASS') "Validation row '$($row.Name)' is not PASS."
        Confirm ([bool]$row.Evidence) "Validation row '$($row.Name)' omits evidence."
    }
}

if (Test-Path -LiteralPath $platform) {
    $rows = @(Import-Csv -LiteralPath $platform)
    $levels = @($rows.Level | Sort-Object -Unique)
    Confirm ($levels -contains 'execution') 'Platform summary omits execution evidence.'
    Confirm ($levels -contains 'cross-build') 'Platform summary omits cross-build evidence.'
    Confirm ($levels -contains 'audit') 'Platform summary omits source-audit evidence.'
    foreach ($row in $rows) {
        Confirm ($row.Result -in @('PASS', 'AUDIT')) (
            "Platform row '$($row.Platform)' has invalid result '$($row.Result)'.")
    }
}

if (Test-Path -LiteralPath $codegen) {
    $rows = @(Import-Csv -LiteralPath $codegen)
    Confirm ($rows.Count -ge 6) 'Helper codegen summary is incomplete.'
    foreach ($row in $rows) {
        Confirm ($row.Sha256 -match '^[0-9A-Fa-f]{64}$') (
            "Helper row '$($row.Build)/$($row.Variant)' has an invalid hash.")
        Confirm ([int64]$row.Length -gt 0) (
            "Helper row '$($row.Build)/$($row.Variant)' has no length.")
    }

    foreach ($configuration in @('Debug', 'Release')) {
        $enabled = @($rows | Where-Object {
            $_.OS -eq 'windows' -and
            $_.Configuration -eq $configuration -and
            $_.Variant -eq 'default' -and
            $_.Build -eq 'enabled'
        })
        $disabled = @($rows | Where-Object {
            $_.OS -eq 'windows' -and
            $_.Configuration -eq $configuration -and
            $_.Variant -eq 'default' -and
            $_.Build -eq 'disabled'
        })
        Confirm (($enabled.Count -eq 1) -and ($disabled.Count -eq 1)) (
            "Missing enabled/disabled default helper pair for $configuration.")
        if (($enabled.Count -eq 1) -and ($disabled.Count -eq 1)) {
            Confirm ($enabled[0].Sha256 -eq $disabled[0].Sha256) (
                "Default helper bytes changed in $configuration.")
        }
    }
}

if (Test-Path -LiteralPath $benchmark) {
    $rows = @(Import-Csv -LiteralPath $benchmark)
    $variants = @($rows.Variant | Sort-Object -Unique)
    foreach ($variant in @('unregistered', 'registered-empty', 'registered-counting')) {
        Confirm ($variants -contains $variant) "Benchmark summary omits $variant."
    }
    foreach ($row in $rows) {
        Confirm ([double]$row.MeanNanoseconds -gt 0) (
            "Benchmark row '$($row.GC)/$($row.Variant)/$($row.Method)' has no mean.")
    }

    if (Test-Path -LiteralPath $benchmarkInvocations) {
        $rawRows = @(Import-Csv -LiteralPath $benchmarkInvocations)
        $expectedRawCount = (
            $rows |
                ForEach-Object { [int]$_.IterationCount } |
                Measure-Object -Sum).Sum
        Confirm ($rawRows.Count -eq $expectedRawCount) (
            "Benchmark raw data has $($rawRows.Count) rows; expected $expectedRawCount.")
        foreach ($rawRow in $rawRows) {
            Confirm ([double]$rawRow.NanosecondsPerOperation -gt 0) (
                "Benchmark invocation '$($rawRow.GC)/$($rawRow.Variant)/$($rawRow.Method)' has no timing.")
        }
    }
}

if (Test-Path -LiteralPath $churn) {
    $rows = @(Import-Csv -LiteralPath $churn)
    Confirm (($rows.Count % 4) -eq 0) 'Churn raw row count is not a complete WKS/Server pair matrix.'
    foreach ($row in $rows) {
        Confirm ([double]$row.OpsPerSecond -gt 0) (
            "Churn row '$($row.Pair)/$($row.Variant)' has no throughput.")
        Confirm (($row.CollectorConfirmed -eq 'true') -and
            ($row.ReportValid -eq 'true') -and
            ($row.VerificationSuccess -eq 'true')) (
            "Churn row '$($row.Pair)/$($row.Variant)' is not collector-confirmed and valid.")
        Confirm ($row.CoreClrSha256 -match '^[0-9A-Fa-f]{64}$') (
            "Churn row '$($row.Pair)/$($row.Variant)' omits runtime identity.")
    }

    foreach ($pair in @($rows.Pair | Sort-Object -Unique)) {
        $pairRows = @($rows | Where-Object Pair -eq $pair)
        Confirm ($pairRows.Count -eq 2) "Pair '$pair' does not have two variants."
        Confirm (@($pairRows.Variant | Sort-Object -Unique).Count -eq 2) (
            "Pair '$pair' does not compare distinct variants.")
    }

    if (Test-Path -LiteralPath $churnSummary) {
        $summaryRows = @(Import-Csv -LiteralPath $churnSummary)
        foreach ($summaryRow in $summaryRows) {
            $ratios = @()
            foreach ($pair in @(
                $rows |
                    Where-Object GC -eq $summaryRow.GC |
                    Select-Object -ExpandProperty Pair -Unique
            )) {
                $pairRows = @($rows | Where-Object Pair -eq $pair)
                $unregistered = [double](
                    $pairRows |
                        Where-Object Variant -eq 'unregistered').OpsPerSecond
                $registered = [double](
                    $pairRows |
                        Where-Object Variant -eq 'registered-empty').OpsPerSecond
                $ratios += $registered / $unregistered
            }

            $mean = ($ratios | Measure-Object -Average).Average
            $geomean = [Math]::Exp(((
                $ratios |
                    ForEach-Object { [Math]::Log($_) } |
                    Measure-Object -Average).Average))
            Confirm ($ratios.Count -eq [int]$summaryRow.PairCount) (
                "Churn pair count does not rederive for $($summaryRow.GC).")
            Confirm ([Math]::Abs($mean - [double]$summaryRow.MeanRatio) -lt 0.000001) (
                "Churn mean ratio does not rederive for $($summaryRow.GC).")
            Confirm ([Math]::Abs($geomean - [double]$summaryRow.GeomeanRatio) -lt 0.000001) (
                "Churn geomean ratio does not rederive for $($summaryRow.GC).")
        }
    }
}

if (Test-Path -LiteralPath $runtimeIdentities) {
    $rows = @(Import-Csv -LiteralPath $runtimeIdentities)
    Confirm ($rows.Count -ge 3) 'Runtime identity summary is incomplete.'
    foreach ($row in $rows) {
        Confirm ($row.Sha256 -match '^[0-9A-Fa-f]{64}$') (
            "Runtime identity '$($row.Name)' has an invalid hash.")
    }
}

if ($failures.Count -ne 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" }
    Write-Host "RESULT: FAIL ($($failures.Count)/$checks)"
    exit 1
}

Write-Host "RESULT: PASS ($checks checks)"
