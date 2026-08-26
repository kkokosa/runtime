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
$runtime = Import-Csv (Join-Path $raw 'runtime-summary.csv')
$fullTests = Import-Csv (Join-Path $raw 'full-test-summary.csv')
$native = Import-Csv (Join-Path $raw 'native-validation-summary.csv')
$compatibility = Import-Csv (Join-Path $raw 'compatibility-summary.csv')
$malformed = Import-Csv (Join-Path $raw 'malformed-summary.csv')
$x86 = Import-Csv (Join-Path $raw 'x86-negotiation.csv')
$platform = Import-Csv (Join-Path $raw 'platform-summary.csv')
$identities = Import-Csv (Join-Path $raw 'source-identities.csv')
$benchmarks = Import-Csv (Join-Path $raw 'benchmark-summary.csv')
$stateBenchmarks = Import-Csv (Join-Path $raw 'state-lock-hash-benchmark.csv')
$codegen = Import-Csv (Join-Path $raw 'hot-function-codegen.csv')

if (($runtime.Count -ne 3) -or
    (@($runtime | Where-Object {
        ($_.result -ne 'PASS') -or ([int]$_.checks -ne 285)
    }).Count -ne 0)) {
    throw 'Runtime scenario evidence is incomplete.'
}

if (($fullTests.Count -ne 1) -or
    ([int]$fullTests[0].total -ne 4286) -or
    ([int]$fullTests[0].passed -ne 4130) -or
    ([int]$fullTests[0].failed -ne 7) -or
    ($fullTests[0].result -ne 'PASS_WITH_INFRASTRUCTURE_FAILURES')) {
    throw 'Full-suite accounting is incomplete.'
}

$x64Native = @($native | Where-Object architecture -eq 'x64')
$x86Native = @($native | Where-Object architecture -eq 'x86')
$linuxNative = @($native | Where-Object architecture -eq 'linux-x64')
if (($native.Count -ne 3) -or
    ($x64Native.Count -ne 1) -or
    ([int]$x64Native[0].passed -ne 25) -or
    ([int]$x64Native[0].total -ne 25) -or
    ($x86Native.Count -ne 1) -or
    ([int]$x86Native[0].passed -ne 6) -or
    ([int]$x86Native[0].total -ne 6) -or
    ($linuxNative.Count -ne 1) -or
    ([int]$linuxNative[0].passed -ne 25) -or
    ([int]$linuxNative[0].total -ne 25)) {
    throw 'Native architecture evidence is incomplete.'
}

if (($compatibility.Count -ne 7) -or
    (@($compatibility | Where-Object Result -ne 'PASS').Count -ne 0)) {
    throw 'Compatibility evidence is incomplete.'
}

if (($malformed.Count -ne 11) -or
    (@($malformed | Where-Object passed -ne 'True').Count -ne 0)) {
    throw 'Malformed startup evidence is incomplete.'
}

if (($x86.Count -ne 1) -or
    ($x86[0].passed -ne 'True') -or
    ([int]$x86[0].disabled_exit -ne 100) -or
    ([int]$x86[0].enabled_exit -eq 100)) {
    throw 'x86 fail-closed evidence is incomplete.'
}

if (($platform.Count -ne 7) -or
    (@($platform | Where-Object result -ne 'PASS').Count -ne 0)) {
    throw 'Platform accounting is incomplete.'
}

foreach ($identity in $identities) {
    $path = Join-Path $RepositoryRoot $identity.name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Identity source is missing: $($identity.name)"
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $length = (Get-Item -LiteralPath $path).Length
    if (($hash -ne $identity.sha256) -or ($length -ne [int64]$identity.length)) {
        throw "Identity mismatch: $($identity.name)"
    }
}

if (($benchmarks.Count -ne 14) -or
    (@($benchmarks | Where-Object {
        ([double]$_.ratio -lt 0.80) -or ([double]$_.ratio -gt 1.20)
    }).Count -ne 0)) {
    throw 'Benchmark evidence is incomplete or outside its noise guard.'
}

if (($stateBenchmarks.Count -ne 6) -or
    (($stateBenchmarks.State | Sort-Object -Unique) -join ',') -ne '0,2,3') {
    throw 'Stress-state benchmark evidence is incomplete.'
}

if ($codegen.Count -ne 6) {
    throw 'Hot-function codegen evidence is incomplete.'
}
foreach ($symbol in $codegen | Group-Object symbol) {
    if (($symbol.Count -ne 2) -or
        (($symbol.Group.normalized_sha256 | Select-Object -Unique).Count -ne 1) -or
        (($symbol.Group.instruction_count | Select-Object -Unique).Count -ne 1)) {
        throw "Hot-function codegen changed: $($symbol.Name)"
    }
}

Write-Host 'PASS: P1.6 object-header bit evidence'
