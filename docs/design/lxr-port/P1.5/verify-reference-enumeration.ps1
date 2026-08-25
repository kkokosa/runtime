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

$document = Join-Path $RepositoryRoot (
    'docs\design\lxr-port\P1.5-object-reference-enumeration.md')
$rawRoot = Join-Path $scriptRoot 'raw'
$validation = Join-Path $rawRoot 'validation-summary.csv'
$compatibility = Join-Path $rawRoot 'compatibility-summary.csv'
$controls = Join-Path $rawRoot 'control-summary.csv'
$malformed = Join-Path $rawRoot 'malformed-summary.csv'
$enabled = Join-Path $rawRoot 'enabled-summary.csv'
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

if (Test-Path -LiteralPath $validation) {
    $rows = @(Import-Csv -LiteralPath $validation)
    Confirm ($rows.Count -eq 8) (
        "Validation summary has $($rows.Count) rows; expected 8.")
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
    Confirm ($rows.Count -eq 6) (
        "Control summary has $($rows.Count) rows; expected 6.")
    Confirm (@($rows | Where-Object Result -ne 'PASS').Count -eq 0) (
        'A perturbation control is not PASS.')
    Confirm (@($rows | Where-Object PerturbationCount -ne '1').Count -eq 0) (
        'A perturbation does not have exact cardinality one.')
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

foreach ($path in @($runtimeIdentities, $benchmarkIdentities)) {
    if (Test-Path -LiteralPath $path) {
        $rows = @(Import-Csv -LiteralPath $path)
        Confirm ($rows.Count -gt 0) "$path is empty."
        foreach ($row in $rows) {
            Confirm ($row.Sha256 -match '^[0-9A-F]{64}$') (
                "Invalid SHA-256 for $($row.Name).")
            Confirm ([int64]$row.Length -gt 0) (
                "Invalid length for $($row.Name).")
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
