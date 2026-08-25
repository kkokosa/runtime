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

function Require-Pattern(
    [string]$relativePath,
    [string]$pattern
) {
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
    [int]$expected
) {
    $path = Join-Path $RepositoryRoot $relativePath
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing $relativePath"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $actual = @(Select-String -LiteralPath $path -SimpleMatch $pattern).Count
        Confirm ($actual -eq $expected) (
            "$relativePath contains '$pattern' $actual times; expected $expected.")
    }
}

function Forbid-Pattern(
    [string]$relativePath,
    [string]$pattern
) {
    $path = Join-Path $RepositoryRoot $relativePath
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) "Missing $relativePath"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Confirm (-not [bool](
            Select-String -LiteralPath $path -SimpleMatch $pattern -Quiet)) (
            "$relativePath unexpectedly contains '$pattern'")
    }
}

$document = Join-Path $RepositoryRoot (
    'docs\design\lxr-port\P1.5-object-reference-enumeration.md')
$rawRoot = Join-Path $scriptRoot 'raw'
$validation = Join-Path $rawRoot 'validation-summary.csv'
$compatibility = Join-Path $rawRoot 'compatibility-summary.csv'
$controls = Join-Path $rawRoot 'control-summary.csv'
$malformed = Join-Path $rawRoot 'malformed-summary.csv'
$enabled = Join-Path $rawRoot 'enabled-summary.csv'
$nativeAotValidation = Join-Path $rawRoot 'nativeaot-validation-summary.csv'
$nativeAotControls = Join-Path $rawRoot 'nativeaot-control-summary.csv'
$nativeAotIdentities = Join-Path $rawRoot 'nativeaot-identities.csv'
$platforms = Join-Path $rawRoot 'platform-summary.csv'
$runtimeIdentities = Join-Path $rawRoot 'runtime-identities.csv'
$benchmarkInvocations = Join-Path $rawRoot 'benchmark-invocations.csv'
$benchmarkSummary = Join-Path $rawRoot 'benchmark-summary.csv'
$benchmarkIdentities = Join-Path $rawRoot 'benchmark-identities.csv'

foreach ($path in @(
    $document,
    $validation,
    $compatibility,
    $controls,
    $malformed,
    $enabled,
    $nativeAotValidation,
    $nativeAotControls,
    $nativeAotIdentities,
    $platforms,
    $runtimeIdentities,
    $benchmarkInvocations,
    $benchmarkSummary,
    $benchmarkIdentities
)) {
    Confirm (Test-Path -LiteralPath $path -PathType Leaf) (
        "Missing shipped artifact $path")
}

Require-Pattern 'src\coreclr\gc\gcinterface.h' (
    '#define GC_INTERFACE_MINOR_VERSION 14')
Require-Pattern 'src\coreclr\gc\gcinterface.h' (
    '#define GC_OBJECT_REFERENCE_ENUMERATION_INTERFACE_MINOR_VERSION 14')
Require-Pattern 'src\coreclr\gc\gcinterface.h' (
    '#define GC_ALLOCATION_NOTIFICATION_INTERFACE_MINOR_VERSION 13')
Require-Pattern 'src\coreclr\gc\gcinterface.h' (
    'GetObjectReferenceEnumerationParameters()')
Require-PatternCount 'src\coreclr\gc\gcinterface.h' (
    'GetObjectReferenceEnumerationParameters()') 1
Require-Pattern 'src\coreclr\gc\gcinterface.h' (
    'static ObjectReferenceEnumerationParameters parameters = {};')
Require-Pattern 'src\coreclr\gc\gcref.h' 'class GCReferenceRanges'
Require-Pattern 'src\coreclr\gc\gcref.h' 'class GCReferenceRangeIterator'
Require-Pattern 'src\coreclr\gc\gcref.h' '#ifndef DACCESS_COMPILE'
Require-PatternCount 'src\coreclr\gc\gcref.h' (
    'reinterpret_cast<ArrayBase*>(object)->GetNumComponents()') 1
Require-PatternCount 'src\coreclr\gc\gcref.h' (
    'GetGCReferenceObjectLayout(') 3
Forbid-Pattern 'src\coreclr\gc\gcref.h' 'static_cast<ArrayBase*>(object)'
Forbid-Pattern 'src\coreclr\gc\gcref.h' 'object->GetSize()'
Require-Pattern (
    'docs\design\lxr-port\P1.5\' +
    'nativeaot-reference-enumeration-validation.cpp') (
    'MethodTable* methodTable = GetMethodTable();')
Require-Pattern (
    'docs\design\lxr-port\P1.5\' +
    'run-nativeaot-reference-enumeration-validation.ps1') (
    'Exact pre-fix header did not reproduce the NativeAOT cast failure.')
Require-Pattern 'src\coreclr\vm\gcheaputilities.cpp' (
    'ConfigureObjectReferenceEnumeration')
Require-Pattern 'src\coreclr\nativeaot\Runtime\gcheaputilities.cpp' (
    'ConfigureObjectReferenceEnumeration')
Require-Pattern 'src\coreclr\gc\interface.cpp' (
    'ValidateObjectReferenceRanges')
Require-Pattern (
    'src\tests\profiler\native\gcheapenumerationprofiler\' +
    'gcheapenumerationprofiler.cpp') 'EnumerateObjectReferences'

$header = Get-Content -LiteralPath (
    Join-Path $RepositoryRoot 'src\coreclr\gc\gcinterface.h') -Raw
Confirm (
    $header -notmatch (
        'GetObjectReferenceEnumerationParameters\(\)\s+PURE_VIRTUAL')) (
    'The 5.14 IGCHeap method is pure virtual.')
$referenceHeader = Get-Content -LiteralPath (
    Join-Path $RepositoryRoot 'src\coreclr\gc\gcref.h') -Raw
$containsIndex = $referenceHeader.IndexOf(
    'if (!methodTable->ContainsGCPointers())')
$layoutIndex = $referenceHeader.IndexOf(
    'GetGCReferenceObjectLayout(object, methodTable);')
Confirm (
    ($containsIndex -ge 0) -and
    ($layoutIndex -gt $containsIndex)) (
    'Reference layout is computed before the no-reference early return.')

if (Test-Path -LiteralPath $validation) {
    $rows = @(Import-Csv -LiteralPath $validation)
    Confirm ($rows.Count -eq 10) (
        "Validation summary has $($rows.Count) rows; expected 10.")
    Confirm (@($rows | Where-Object Result -ne 'PASS').Count -eq 0) (
        'A validation row is not PASS.')
    Confirm (@($rows | Where-Object Name -eq 'native-x64').Detail -eq '40/40') (
        'Windows x64 native check cardinality changed.')
    Confirm (@($rows | Where-Object Name -eq 'native-x86').Detail -eq '40/40') (
        'Windows x86 native check cardinality changed.')
    Confirm (@($rows | Where-Object Name -eq 'native-linux-x64').Detail -eq '35/35') (
        'Linux x64 native check cardinality changed.')
}

if (Test-Path -LiteralPath $compatibility) {
    $rows = @(Import-Csv -LiteralPath $compatibility)
    Confirm ($rows.Count -eq 7) (
        "Compatibility summary has $($rows.Count) rows; expected 7.")
    Confirm (@($rows | Where-Object Result -ne 'PASS').Count -eq 0) (
        'A compatibility row is not PASS.')
    foreach ($name in @(
        'old-binary-current-runtime',
        'new-disabled-gc-old-runtime',
        'new-enabled-gc-old-runtime',
        'old-source-current-header-current-runtime',
        'pure-virtual-control-build'
    )) {
        Confirm (@($rows | Where-Object Name -eq $name).Count -eq 1) (
            "Compatibility summary omits $name.")
    }
}

if (Test-Path -LiteralPath $controls) {
    $rows = @(Import-Csv -LiteralPath $controls)
    Confirm ($rows.Count -eq 8) (
        "Control summary has $($rows.Count) rows; expected 8.")
    Confirm (@($rows | Where-Object Result -ne 'PASS').Count -eq 0) (
        'A perturbation control is not PASS.')
    Confirm (@($rows | Where-Object PerturbationCount -ne '1').Count -eq 0) (
        'A perturbation does not have exact cardinality one.')
    foreach ($name in @(
        'nativeaot-static-cast',
        'nativeaot-unmasked-object-size'
    )) {
        Confirm (@($rows | Where-Object Name -eq $name).Count -eq 1) (
            "Control summary omits $name.")
    }
}

if (Test-Path -LiteralPath $nativeAotValidation) {
    $rows = @(Import-Csv -LiteralPath $nativeAotValidation)
    Confirm ($rows.Count -eq 2) (
        "NativeAOT validation summary has $($rows.Count) rows; expected 2.")
    $final = @($rows | Where-Object Name -eq 'final-nativeaot-shared-gc')
    $preFix = @($rows | Where-Object Name -eq 'pre-fix-nativeaot-compile')
    Confirm (
        ($final.Count -eq 1) -and
        ($final[0].Result -eq 'PASS') -and
        ($final[0].Observed -eq (
            '21/21 NativeAOT reference enumeration checks passed')) -and
        ($final[0].ProductCommit -match '^[0-9a-f]{40}$')) (
        'Final NativeAOT compile/execution evidence is invalid.')
    Confirm (
        ($preFix.Count -eq 1) -and
        ($preFix[0].Result -eq 'PASS') -and
        ($preFix[0].Observed -match 'inaccessible') -and
        ($preFix[0].ProductCommit -eq (
            '04c9b4c959193b8adb29924abd4c1da2336c1014'))) (
        'Pre-fix NativeAOT compile evidence is invalid.')
}

if (Test-Path -LiteralPath $nativeAotControls) {
    $rows = @(Import-Csv -LiteralPath $nativeAotControls)
    Confirm ($rows.Count -eq 2) (
        "NativeAOT control summary has $($rows.Count) rows; expected 2.")
    foreach ($name in @(
        'nativeaot-static-cast',
        'nativeaot-unmasked-object-size'
    )) {
        $match = @($rows | Where-Object Name -eq $name)
        Confirm (
            ($match.Count -eq 1) -and
            ($match[0].ProductCommit -match '^[0-9a-f]{40}$') -and
            ($match[0].PerturbationCount -eq '1') -and
            ($match[0].Result -eq 'PASS') -and
            [bool]$match[0].Observed) (
            "NativeAOT control evidence is invalid for $name.")
    }
}

if (Test-Path -LiteralPath $enabled) {
    $rows = @(Import-Csv -LiteralPath $enabled)
    Confirm ($rows.Count -eq 2) (
        "Enabled summary has $($rows.Count) rows; expected 2.")
    foreach ($mode in @('linked', 'standalone')) {
        $match = @($rows | Where-Object {
            ($_.Mode -eq $mode) -and
            ($_.Request -eq 'Enabled')
        })
        Confirm ($match.Count -eq 1) (
            "Enabled summary omits exactly one $mode row.")
        if ($match.Count -eq 1) {
            Confirm (
                ([int]$match[0].ExitCode -in @(0, 100)) -and
                ([int]$match[0].ProfilerPassMarkers -eq 3) -and
                ($match[0].Result -eq 'PASS')) (
                "Enabled $mode row is not a successful three-scenario run.")
        }
    }
}

if (Test-Path -LiteralPath $malformed) {
    $rows = @(Import-Csv -LiteralPath $malformed)
    Confirm ($rows.Count -eq 8) (
        "Malformed summary has $($rows.Count) rows; expected 8.")
    Confirm (@($rows | Where-Object Result -ne 'PASS').Count -eq 0) (
        'A malformed request control is not PASS.')
    Confirm (@($rows | Where-Object {
        ([int]$_.ExitCode -in @(0, 100)) -or
        -not $_.ExpectedPattern -or
        -not $_.Evidence
    }).Count -eq 0) 'Malformed evidence contains a success-shaped run.'

    $expectedPatterns = @{
        1 = 'descriptor was not initialized to NotProcessed'
        2 = 'resolver must be initialized to null'
        3 = 'descriptor is null'
        4 = 'request is invalid'
    }
    foreach ($mode in @('linked', 'standalone')) {
        foreach ($value in 1..4) {
            $match = @($rows | Where-Object {
                ($_.Mode -eq $mode) -and
                ([int]$_.Malformed -eq $value)
            })
            Confirm ($match.Count -eq 1) (
                "Malformed summary omits exactly one $mode/$value row.")
            if ($match.Count -eq 1) {
                Confirm (
                    $match[0].ExpectedPattern -eq $expectedPatterns[$value]) (
                    "Malformed $mode/$value has the wrong expected pattern.")
            }
        }
    }
}

if (Test-Path -LiteralPath $platforms) {
    $rows = @(Import-Csv -LiteralPath $platforms)
    Confirm ($rows.Count -eq 7) (
        "Platform summary has $($rows.Count) rows; expected 7.")
    $levels = @($rows.Level | Sort-Object -Unique)
    foreach ($level in @('execution', 'cross-build', 'build', 'audit')) {
        Confirm ($levels -contains $level) "Platform summary omits $level."
    }
    Confirm (@($rows | Where-Object {
        $_.Result -notin @('PASS', 'AUDIT')
    }).Count -eq 0) 'A platform result is invalid.'
}

foreach ($path in @(
    $runtimeIdentities,
    $benchmarkIdentities,
    $nativeAotIdentities
)) {
    if (Test-Path -LiteralPath $path) {
        $rows = @(Import-Csv -LiteralPath $path)
        Confirm ($rows.Count -gt 0) "$path is empty."
        foreach ($row in $rows) {
            Confirm ($row.Sha256 -match '^[0-9A-F]{64}$') (
                "Invalid SHA-256 for $($row.Name).")
            Confirm ([int64]$row.Length -gt 0) (
                "Invalid length for $($row.Name).")
            if ($path -eq $nativeAotIdentities) {
                Confirm ($row.ProductCommit -match '^[0-9a-f]{40}$') (
                    "Invalid product commit for $($row.Name).")
            }
        }
    }
}

if ((Test-Path -LiteralPath $benchmarkInvocations) -and
    (Test-Path -LiteralPath $benchmarkSummary)) {
    $rawRows = @(Import-Csv -LiteralPath $benchmarkInvocations)
    $summaryRows = @(Import-Csv -LiteralPath $benchmarkSummary)
    Confirm ($rawRows.Count -eq 216) (
        "Benchmark raw data has $($rawRows.Count) rows; expected 216.")
    Confirm ($summaryRows.Count -eq 9) (
        "Benchmark summary has $($summaryRows.Count) rows; expected 9.")

    foreach ($group in @($rawRows | Group-Object Method, Scenario)) {
        Confirm ($group.Count -eq 24) (
            "Benchmark group $($group.Name) has $($group.Count) rows; expected 24.")
        Confirm (@($group.Group | Where-Object {
            ([double]$_.NanosecondsPerOperation -le 0) -or
            ([int64]$_.Operations -le 0)
        }).Count -eq 0) "Benchmark group $($group.Name) has invalid samples."
    }

    $documentText = Get-Content -LiteralPath $document -Raw
    foreach ($scenario in 0..2) {
        $visitor = @($summaryRows | Where-Object {
            ($_.Method -eq 'ReferenceRangeVisitor') -and
            ([int]$_.Scenario -eq $scenario)
        })
        Confirm ($visitor.Count -eq 1) (
            "Missing visitor summary for scenario $scenario.")
        if ($visitor.Count -eq 1) {
            $ratio = ([double]$visitor[0].Ratio).ToString(
                'F2',
                [Globalization.CultureInfo]::InvariantCulture)
            Confirm ($documentText.Contains("$ratio" + 'x')) (
                "Document does not contain derived visitor ratio $ratio for scenario $scenario.")
        }
    }
}

if ($failures.Count -ne 0) {
    foreach ($failure in $failures) {
        Write-Error $failure
    }
    throw "$($failures.Count) of $checks P1.5 verification checks failed."
}

Write-Host "PASS: $checks P1.5 verification checks"
