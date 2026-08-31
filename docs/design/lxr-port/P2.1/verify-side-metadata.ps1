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

$raw = Join-Path $scriptRoot 'raw'
$metadataManifest = Get-Content (Join-Path $scriptRoot 'metadata-specs.json') -Raw |
    ConvertFrom-Json
$evidenceManifest = Get-Content (Join-Path $scriptRoot 'evidence-manifest.json') -Raw |
    ConvertFrom-Json

if (($metadataManifest.schemaVersion -ne 1) -or
    ($metadataManifest.addressBits -ne 47) -or
    ($metadataManifest.globalBase -ne '0x00000c0000000000') -or
    ($metadataManifest.localBase -ne '0x00004c0000000000') -or
    ($metadataManifest.oracles.pldi.binding -ne
        'abbdd1dbbe7277e4b0dfd1d37ba613c53f5ca50d') -or
    ($metadataManifest.oracles.pldi.core -ne
        'df8d30a39237a5bf5a8e27ca5a6f46acc6080c94') -or
    ($metadataManifest.oracles.head.binding -ne
        '0682434ae725787e38defbc17bd66dc918e4bdb7') -or
    ($metadataManifest.oracles.head.core -ne
        '304ce69d43aae87de501111fceb8cbd33173a03a')) {
    throw 'Address layout or oracle identity mismatch.'
}

$specs = @($metadataManifest.specs)
$specIds = @($specs | ForEach-Object id)
$duplicates = @($specIds | Group-Object | Where-Object Count -ne 1)
if (($specs.Count -le 0) -or ($duplicates.Count -ne 0)) {
    throw 'Metadata spec IDs are missing or duplicated.'
}

$headerPath = Join-Path $RepositoryRoot 'src\coreclr\gc\side_metadata.h'
$implementationPath = Join-Path $RepositoryRoot 'src\coreclr\gc\side_metadata.cpp'
$header = Get-Content -LiteralPath $headerPath -Raw
$implementation = Get-Content -LiteralPath $implementationPath -Raw
$enumMatch = [regex]::Match(
    $header,
    'enum class LxrSideMetadataKind[^{]*\{(?<body>.*?)\};',
    [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $enumMatch.Success) {
    throw 'Unable to find the product metadata enum.'
}
$enumIds = @(
    [regex]::Matches($enumMatch.Groups['body'].Value, '(?m)^\s*(\w+),\s*$') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -ne 'Count' })
$enumDifference = @(
    Compare-Object ($specIds | Sort-Object) ($enumIds | Sort-Object))
if (($enumIds.Count -ne $specs.Count) -or ($enumDifference.Count -ne 0)) {
    throw 'Product and manifest metadata spec sets differ.'
}

$addSpecs = @(
    [regex]::Matches(
        $implementation,
        'ADD_SPEC\((\w+),\s*(Global|Local),\s*([^,]+),\s*(\d+),\s*(\d+)') |
        ForEach-Object {
            [pscustomobject]@{
                id = $_.Groups[1].Value
                scope = $_.Groups[2].Value
                active = $_.Groups[3].Value.Trim()
                reserved = [int]$_.Groups[4].Value
                granularity = [int]$_.Groups[5].Value
            }
        })
if (($addSpecs.Count -ne $specs.Count) -or
    (@($addSpecs.id | Group-Object | Where-Object Count -ne 1).Count -ne 0)) {
    throw 'Product metadata layout entries are missing or duplicated.'
}
foreach ($spec in $specs) {
    $product = @($addSpecs | Where-Object id -eq $spec.id)
    if (($product.Count -ne 1) -or
        ($product[0].scope -ne $spec.scope) -or
        ($product[0].reserved -ne [int]$spec.reservedLogBitsPerValue) -or
        ($product[0].granularity -ne [int]$spec.logBytesPerValue)) {
        throw "Product metadata layout differs for $($spec.id)."
    }
    if (($spec.id -ne 'ReferenceCount') -and
        ($product[0].active -ne ([string]$spec.logBitsPerValue))) {
        throw "Product metadata width differs for $($spec.id)."
    }
}

foreach ($pattern in @(
    'AddressBits = 47',
    '0x00000c0000000000',
    '0x00004c0000000000',
    'VirtualReserveAt',
    'ComputeFirstWordCoverageForByteOrder',
    'ComputeLastWordCoverageForByteOrder'
)) {
    if (($header + $implementation) -notmatch [regex]::Escape($pattern)) {
        throw "Required product contract is missing: $pattern"
    }
}

$requiredEvidence = @(
    'attempt-summary.csv',
    'benchmark-controls.csv',
    'benchmark-identity.csv',
    'benchmark-raw.csv',
    'build-summary.csv',
    'linux-validation-command.txt',
    'linux-validation-summary.csv',
    'public-wrapper-smoke-summary.csv',
    'platform-summary.csv',
    'runtime-smoke-summary.csv',
    'source-commit.txt',
    'source-identities.csv',
    'validation-summary.csv',
    'windows-validation-attempts.csv'
)
foreach ($file in $requiredEvidence) {
    if (-not (Test-Path -LiteralPath (Join-Path $raw $file) -PathType Leaf)) {
        throw "Required evidence is missing: $file"
    }
}

$validation = @(Import-Csv (Join-Path $raw 'validation-summary.csv'))
$expectedValidation = @($evidenceManifest.validationPlatforms)
$actualValidation = @($validation.platform)
$validationDifference = @(
    Compare-Object ($expectedValidation | Sort-Object) ($actualValidation | Sort-Object))
if (($validation.Count -ne $expectedValidation.Count) -or
    (@($actualValidation | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    ($validationDifference.Count -ne 0) -or
    (@($validation | Where-Object {
        ($_.result -ne 'PASS') -or
        ([int]$_.passed -ne [int]$_.total) -or
        ([int]$_.total -le 0)
    }).Count -ne 0)) {
    throw 'Validation platform evidence is incomplete.'
}
foreach ($row in $validation) {
    $log = Join-Path $raw $row.log
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
        throw "Validation log is missing: $($row.log)"
    }
    $match = Select-String -LiteralPath $log -Pattern '(\d+)/(\d+) side metadata checks passed'
    if (($match.Count -ne 1) -or
        ([int]$match.Matches[0].Groups[1].Value -ne [int]$row.passed) -or
        ([int]$match.Matches[0].Groups[2].Value -ne [int]$row.total)) {
        throw "Validation log count differs for $($row.platform)."
    }
}

$linuxValidation = @(Import-Csv (Join-Path $raw 'linux-validation-summary.csv'))
$linuxSummary = @($validation | Where-Object platform -eq 'linux-x64')
if (($linuxValidation.Count -ne 1) -or
    ($linuxSummary.Count -ne 1) -or
    ([int]$linuxValidation[0].passed -ne [int]$linuxSummary[0].passed) -or
    ([int]$linuxValidation[0].total -ne [int]$linuxSummary[0].total) -or
    ($linuxValidation[0].result -ne $linuxSummary[0].result)) {
    throw 'Linux validation summary differs from the platform evidence.'
}

$runtime = @(Import-Csv (Join-Path $raw 'runtime-smoke-summary.csv'))
$expectedRuntime = [Collections.Generic.List[string]]::new()
foreach ($polarity in $evidenceManifest.runtimeDimensions.polarity) {
    foreach ($linkage in $evidenceManifest.runtimeDimensions.linkage) {
        foreach ($gcMode in $evidenceManifest.runtimeDimensions.gcMode) {
            $expectedRuntime.Add("$polarity|$linkage|$gcMode")
        }
    }
}
$actualRuntime = @($runtime | ForEach-Object {
    "$($_.polarity)|$($_.linkage)|$($_.gc_mode)"
})
$runtimeDifference = @(
    Compare-Object ($expectedRuntime | Sort-Object) ($actualRuntime | Sort-Object))
if (($runtime.Count -ne $expectedRuntime.Count) -or
    (@($actualRuntime | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    ($runtimeDifference.Count -ne 0) -or
    (@($runtime | Where-Object {
        ($_.result -ne 'PASS') -or ([int]$_.exit_code -ne 0)
    }).Count -ne 0)) {
    throw 'Runtime smoke evidence is incomplete.'
}

$builds = @(Import-Csv (Join-Path $raw 'build-summary.csv'))
$expectedBuilds = @($evidenceManifest.buildNames)
$actualBuilds = @($builds.name)
$buildDifference = @(
    Compare-Object ($expectedBuilds | Sort-Object) ($actualBuilds | Sort-Object))
if (($builds.Count -ne $expectedBuilds.Count) -or
    (@($actualBuilds | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    ($buildDifference.Count -ne 0) -or
    (@($builds | Where-Object {
        ($_.name -ne 'long-path-baseline') -and ($_.result -ne 'PASS')
    }).Count -ne 0) -or
    (@($builds | Where-Object {
        ($_.name -eq 'long-path-baseline') -and
        (($_.result -ne 'EXPECTED_PATH_FAILURE') -or ([int]$_.exit_code -eq 0))
    }).Count -ne 0)) {
    throw 'Build evidence is incomplete.'
}
foreach ($build in $builds) {
    if (-not (Test-Path -LiteralPath (Join-Path $raw $build.evidence) -PathType Leaf)) {
        throw "Build log is missing: $($build.evidence)"
    }
}

$program = Get-Content (
    Join-Path $scriptRoot 'side-metadata-benchmark\Program.cs') -Raw
$methodCount = @([regex]::Matches($program, '(?m)^\s*\[Benchmark')).Count
$rcSpec = @($specs | Where-Object id -eq 'ReferenceCount')
$widthCount = @($rcSpec.logBitsPerValue -split '\|').Count
$expectedBenchmarkRows = $methodCount * $widthCount
$benchmark = @(Import-Csv (Join-Path $raw 'benchmark-raw.csv'))
$benchmarkKeys = @($benchmark | ForEach-Object {
    "$($_.Method)|$($_.LogReferenceCountBits)"
})
if (($benchmark.Count -ne $expectedBenchmarkRows) -or
    (@($benchmarkKeys | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    (@($benchmark | Where-Object { -not $_.Mean }).Count -ne 0)) {
    throw 'Benchmark rows are incomplete or duplicated.'
}

$benchmarkIdentity = @(Import-Csv (Join-Path $raw 'benchmark-identity.csv'))
if (($benchmarkIdentity.Count -ne 1) -or
    ([int]$benchmarkIdentity[0].launch_count -ne
        [int]$evidenceManifest.benchmark.launchCount) -or
    ([int]$benchmarkIdentity[0].warmup_count -ne
        [int]$evidenceManifest.benchmark.warmupCount) -or
    ([int]$benchmarkIdentity[0].iteration_count -ne
        [int]$evidenceManifest.benchmark.iterationCount) -or
    ([int]$benchmarkIdentity[0].rows -ne $expectedBenchmarkRows) -or
    ($benchmarkIdentity[0].benchmark_runtime -notmatch '^\.NET 11\.0') -or
    ($benchmarkIdentity[0].result -ne 'PASS')) {
    throw 'Benchmark identity is incomplete.'
}

$controls = @(Import-Csv (Join-Path $raw 'benchmark-controls.csv'))
if (($controls.Count -ne $widthCount) -or
    (@($controls.log_rc_bits | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    (@($controls | Where-Object {
        ($_.result -ne 'PASS') -or
        ([double]$_.aa_ratio -lt [double]$evidenceManifest.benchmark.aaMinimum) -or
        ([double]$_.aa_ratio -gt [double]$evidenceManifest.benchmark.aaMaximum)
    }).Count -ne 0)) {
    throw 'Benchmark A/A noise control is incomplete.'
}
if (@($controls | Where-Object {
    [double]$_.extra_cas_ratio -lt
        [double]$evidenceManifest.benchmark.sensitivityMinimum
}).Count -ne 0) {
    throw 'Benchmark sensitivity control is incomplete.'
}

$wrapper = @(Import-Csv (Join-Path $raw 'public-wrapper-smoke-summary.csv'))
$expectedWrapper = @($evidenceManifest.publicWrapper.steps)
$wrapperDifference = @(
    Compare-Object ($expectedWrapper | Sort-Object) ($wrapper.name | Sort-Object))
if (($wrapper.Count -ne $expectedWrapper.Count) -or
    (@($wrapper.name | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    ($wrapperDifference.Count -ne 0) -or
    (@($wrapper | Where-Object result -ne 'PASS').Count -ne 0)) {
    throw 'Public full-evidence wrapper smoke is incomplete.'
}

function Get-CanonicalIdentity([string]$Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
    return [pscustomobject]@{
        Hash = $hash
        Length = $bytes.Length
    }
}

$sourceManifestPath = Join-Path $scriptRoot 'source-manifest.txt'
$expectedSources = @(
    Get-Content -LiteralPath $sourceManifestPath |
        Where-Object { $_ -and -not $_.StartsWith('#') })
$identities = @(Import-Csv (Join-Path $raw 'source-identities.csv'))
$actualSources = @($identities.name)
$sourceDifference = @(
    Compare-Object ($expectedSources | Sort-Object) ($actualSources | Sort-Object))
if (($identities.Count -ne $expectedSources.Count) -or
    (@($actualSources | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    ($sourceDifference.Count -ne 0)) {
    throw 'Source identity path set mismatch.'
}
foreach ($identity in $identities) {
    $path = Join-Path $RepositoryRoot $identity.name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Identity source is missing: $($identity.name)"
    }
    $canonical = Get-CanonicalIdentity $path
    if (($canonical.Hash -ne $identity.canonical_sha256) -or
        ($canonical.Length -ne [int64]$identity.canonical_length)) {
        throw "Source identity mismatch: $($identity.name)"
    }
}

$sourceCommit = (Get-Content (Join-Path $raw 'source-commit.txt') -Raw).Trim()
if ($sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Source commit identity is malformed.'
}
if (@($identities | Where-Object implementation_commit -ne $sourceCommit).Count -ne 0) {
    throw 'Source implementation commit identities differ.'
}

$perturbations = @($evidenceManifest.perturbations)
if (($perturbations.Count -ne 18) -or
    (@($perturbations.id | Group-Object | Where-Object Count -ne 1).Count -ne 0) -or
    (@($perturbations.property | Group-Object |
        Where-Object { $_.Count -ne 2 }).Count -ne 0)) {
    throw 'Perturbation manifest must contain two payloads for each property.'
}

Write-Host 'PASS: P2.1 side metadata evidence'
