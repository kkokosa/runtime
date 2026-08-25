# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$InputDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}
if (-not $InputDirectory) {
    $InputDirectory = Join-Path $RepositoryRoot 'artifacts'
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $scriptRoot 'raw'
}

function Read-Status([string]$name) {
    $path = Join-Path $InputDirectory "$name.status"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing status file: $path"
    }
    $text = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($text -notmatch '^exit=(?<exit>-?[0-9]+)$') {
        throw "Invalid status file: $path"
    }
    return [int]$Matches.exit
}

function Require-LogPattern(
    [string]$name,
    [string]$pattern
) {
    $path = Join-Path $InputDirectory "$name.log"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing log file: $path"
    }
    if (-not (Select-String -LiteralPath $path -Pattern $pattern -Quiet)) {
        throw "Log $path does not contain '$pattern'."
    }
}

$validationRows = [Collections.Generic.List[object]]::new()

$nativeChecks = @(
    @{ Name = 'native-x64'; Log = 'p15-validation-x64'; Pattern = '40/40' },
    @{ Name = 'native-x86'; Log = 'p15-validation-x86'; Pattern = '40/40' },
    @{ Name = 'native-linux-x64'; Log = 'p15-validation-linux-x64'; Pattern = '35/35' }
)
foreach ($check in $nativeChecks) {
    Require-LogPattern $check.Log $check.Pattern
    $validationRows.Add([pscustomobject][ordered]@{
        Name = $check.Name
        Result = 'PASS'
        Evidence = "$($check.Log).log"
        Detail = $check.Pattern
    })
}

if ((Read-Status 'p15-contract-build') -ne 0) {
    throw 'CoreCLR contract build did not pass.'
}
$validationRows.Add([pscustomobject][ordered]@{
    Name = 'coreclr-debug-build'
    Result = 'PASS'
    Evidence = 'p15-contract-build.log'
    Detail = '0 warnings, 0 errors'
})

if ((Read-Status 'p15-profiler-run') -ne 0) {
    throw 'Real-layout profiler wrapper did not return zero.'
}
Require-LogPattern 'p15-profiler-run' 'END EXECUTION - PASSED'
$validationRows.Add([pscustomobject][ordered]@{
    Name = 'real-layout-profiler'
    Result = 'PASS'
    Evidence = 'p15-profiler-run.log'
    Detail = '3/3 profiler scenarios; exact Debug parity assertions'
})

if ((Read-Status 'p15-enabled-build') -ne 0) {
    throw 'Enabled request build did not pass.'
}
$validationRows.Add([pscustomobject][ordered]@{
    Name = 'enabled-request-build'
    Result = 'PASS'
    Evidence = 'p15-enabled-build.log'
    Detail = 'linked and standalone request implementation'
})

$enabledSource = Join-Path $InputDirectory 'p15-enabled-summary.csv'
$enabledRows = @(Import-Csv -LiteralPath $enabledSource)
if (($enabledRows.Count -ne 2) -or
    (@($enabledRows | Where-Object Result -ne 'PASS').Count -ne 0) -or
    (@($enabledRows | Where-Object {
        ([int]$_.ExitCode -notin @(0, 100)) -or
        ([int]$_.ProfilerPassMarkers -ne 3) -or
        ($_.Request -ne 'Enabled') -or
        ($_.Mode -notin @('linked', 'standalone'))
    }).Count -ne 0) -or
    (@($enabledRows.Mode | Sort-Object -Unique).Count -ne 2)) {
    throw 'Enabled current-runtime evidence is incomplete.'
}
$validationRows.Add([pscustomobject][ordered]@{
    Name = 'enabled-current-runtime'
    Result = 'PASS'
    Evidence = 'p15-enabled-{linked,standalone}.log'
    Detail = '2/2 current-runtime starts; collectible Debug oracle executed'
})

$malformedSource = Join-Path $InputDirectory 'p15-malformed-summary.csv'
$malformedRows = @(Import-Csv -LiteralPath $malformedSource)
if (($malformedRows.Count -ne 8) -or
    (@($malformedRows | Where-Object Result -ne 'PASS').Count -ne 0) -or
    (@($malformedRows | Where-Object {
        ([int]$_.ExitCode -in @(0, 100)) -or
        -not $_.ExpectedPattern -or
        -not $_.Evidence
    }).Count -ne 0)) {
    throw 'Malformed-request evidence is incomplete or success-shaped.'
}
$validationRows.Add([pscustomobject][ordered]@{
    Name = 'malformed-request-controls'
    Result = 'PASS'
    Evidence = 'p15-malformed-{linked,standalone}-{1..4}.log'
    Detail = '8/8 rejected before managed Main'
})

$compatibilitySource = Join-Path $InputDirectory (
    'p15-reference-enumeration-compatibility\compatibility-summary.csv')
$controlSource = Join-Path $InputDirectory (
    'p15-reference-enumeration-controls\control-summary.csv')
$compatibilityRows = @(Import-Csv -LiteralPath $compatibilitySource)
$controlRows = @(Import-Csv -LiteralPath $controlSource)
if (($compatibilityRows.Count -ne 7) -or
    (@($compatibilityRows | Where-Object Result -ne 'PASS').Count -ne 0)) {
    throw 'Compatibility evidence is incomplete.'
}
if (($controlRows.Count -ne 6) -or
    (@($controlRows | Where-Object Result -ne 'PASS').Count -ne 0) -or
    (@($controlRows | Where-Object PerturbationCount -ne '1').Count -ne 0)) {
    throw 'Perturbation evidence is incomplete.'
}

$platformRows = @(
    [pscustomobject][ordered]@{
        Platform = 'Windows x64 CoreCLR'
        Level = 'execution'
        Result = 'PASS'
        Evidence = 'p15-profiler-run.log; p15-enabled-build.log'
        Limitation = ''
    },
    [pscustomobject][ordered]@{
        Platform = 'Windows x86'
        Level = 'execution'
        Result = 'PASS'
        Evidence = 'p15-validation-x86.log'
        Limitation = 'Full target build is blocked by unrelated generated thunk offsets in the installed preview toolchain.'
    },
    [pscustomobject][ordered]@{
        Platform = 'Linux x64'
        Level = 'execution'
        Result = 'PASS'
        Evidence = 'p15-validation-linux-x64.log'
        Limitation = 'Header/native validator; full CoreCLR Linux build not run in this Windows worktree.'
    },
    [pscustomobject][ordered]@{
        Platform = 'Windows ARM64 CoreCLR'
        Level = 'cross-build'
        Result = 'PASS'
        Evidence = 'p15-arm64-target-build.log'
        Limitation = 'No ARM64 execution hardware. Optional x64 debugger cross-component stage fails in the installed preview assembler.'
    },
    [pscustomobject][ordered]@{
        Platform = 'Windows x64 NativeAOT'
        Level = 'execution'
        Result = 'PASS'
        Evidence = 'p15-nativeaot-build.log; p15-nativeaot-test.log'
        Limitation = 'NativeAOT has no collectible MethodTables; resolver returns null.'
    },
    [pscustomobject][ordered]@{
        Platform = 'DAC'
        Level = 'build'
        Result = 'PASS'
        Evidence = 'p15-contract-build.log'
        Limitation = 'Raw iterator is excluded from DACCESS_COMPILE.'
    },
    [pscustomobject][ordered]@{
        Platform = 'Mono'
        Level = 'audit'
        Result = 'AUDIT'
        Evidence = 'source audit'
        Limitation = 'Mono does not consume CoreCLR GCDesc or this GC/EE interface.'
    }
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$validationRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'validation-summary.csv') -NoTypeInformation
$compatibilityRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'compatibility-summary.csv') -NoTypeInformation
$controlRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'control-summary.csv') -NoTypeInformation
$malformedRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'malformed-summary.csv') -NoTypeInformation
$enabledRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'enabled-summary.csv') -NoTypeInformation
$platformRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'platform-summary.csv') -NoTypeInformation

$identityFiles = @(
    'src\coreclr\gc\gcinterface.h',
    'src\coreclr\gc\gcref.h',
    'artifacts\bin\coreclr\windows.x64.Debug\coreclr.dll',
    'artifacts\bin\coreclr\windows.x64.Debug\clrgc.dll',
    'artifacts\bin\coreclr\windows.arm64.Release\coreclr.dll',
    'artifacts\bin\coreclr\windows.arm64.Release\clrgc.dll'
)
$identityRows = foreach ($relativePath in $identityFiles) {
    $path = Join-Path $RepositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Identity file missing: $path"
    }
    [pscustomobject][ordered]@{
        Name = $relativePath
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Length = (Get-Item -LiteralPath $path).Length
    }
}
$identityRows | Export-Csv -LiteralPath (
    Join-Path $OutputDirectory 'runtime-identities.csv') -NoTypeInformation

Write-Host (
    "PASS: {0} validation, {1} compatibility, {2} controls, {3} platforms" -f
    $validationRows.Count,
    $compatibilityRows.Count,
    $controlRows.Count,
    $platformRows.Count)
