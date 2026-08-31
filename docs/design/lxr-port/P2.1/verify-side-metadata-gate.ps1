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
$parent = if ($OutputDirectory) { $OutputDirectory } else { [IO.Path]::GetTempPath() }
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$runRoot = Join-Path $parent ('p21-side-metadata-gate-' + [guid]::NewGuid().ToString('N'))
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
        (Join-Path $Root 'docs\design\lxr-port\P2.1\verify-side-metadata.ps1') `
        -RepositoryRoot $Root *> $log
    $exitCode = $LASTEXITCODE
    $text = Get-Content -LiteralPath $log -Raw
    if ($ExpectSuccess) {
        if (($exitCode -ne 0) -or
            ($text -notmatch 'PASS: P2.1 side metadata evidence')) {
            throw "Clean verification failed: $Name. See $log."
        }
    } elseif (($exitCode -eq 0) -or
        ($text -notmatch [regex]::Escape($ExpectedFailure))) {
        throw "Perturbation $Name did not fail for '$ExpectedFailure'. See $log."
    }
    $summary.Add([pscustomobject][ordered]@{
        name = $Name
        expected = if ($ExpectSuccess) { 'pass' } else { 'fail' }
        exit_code = $exitCode
        expected_reason = $ExpectedFailure
        result = 'PASS'
        log = [IO.Path]::GetFileName($log)
    })
}

function New-PerturbationTree([string]$Name) {
    $destination = Join-Path $runRoot $Name
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $manifest = Join-Path $clean 'docs\design\lxr-port\P2.1\source-manifest.txt'
    foreach ($relative in Get-Content -LiteralPath $manifest) {
        if (-not $relative) {
            continue
        }
        $source = Join-Path $clean $relative
        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
    Copy-Item -LiteralPath (Join-Path $clean 'docs\design\lxr-port\P2.1\raw') `
        -Destination (Join-Path $destination 'docs\design\lxr-port\P2.1') -Recurse
    return $destination
}

function Replace-ExactlyOnce(
    [string]$Path,
    [string]$Old,
    [string]$New
) {
    $text = Get-Content -LiteralPath $Path -Raw
    $count = [regex]::Matches($text, [regex]::Escape($Old)).Count
    if ($count -ne 1) {
        throw "Mutation expected one '$Old' in $Path, found $count."
    }
    Set-Content -LiteralPath $Path -Value $text.Replace($Old, $New) -NoNewline
}

git -C $RepositoryRoot -c core.longpaths=true diff --quiet HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'The exact-archive gate requires a clean worktree.'
}
git -C $RepositoryRoot -c core.longpaths=true diff --cached --quiet HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'The exact-archive gate requires an empty index.'
}
$status = @(git -C $RepositoryRoot -c core.longpaths=true status --porcelain=v1)
if ($status.Count -ne 0) {
    throw 'The exact-archive gate requires no untracked files.'
}
git -C $RepositoryRoot archive --format=tar --output=$archive HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create the exact HEAD archive.'
}
tar -xf $archive -C $clean
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to extract the exact HEAD archive.'
}

Invoke-Verifier 'clean-1' $clean $true ''
Invoke-Verifier 'clean-2' $clean $true ''

$tree = New-PerturbationTree 'mapping-address-bits'
Replace-ExactlyOnce `
    (Join-Path $tree 'docs\design\lxr-port\P2.1\metadata-specs.json') `
    '"addressBits": 47' `
    '"addressBits": 46'
Invoke-Verifier 'mapping-address-bits' $tree $false 'Address layout or oracle identity mismatch.'

$tree = New-PerturbationTree 'mapping-source-constant'
Replace-ExactlyOnce `
    (Join-Path $tree 'src\coreclr\gc\side_metadata.h') `
    'AddressBits = 47' `
    'AddressBits = 46'
Invoke-Verifier 'mapping-source-constant' $tree $false 'Required product contract is missing: AddressBits = 47'

$tree = New-PerturbationTree 'granularity-rc-data'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\metadata-specs.json'
$json = Get-Content $path -Raw | ConvertFrom-Json
@($json.specs | Where-Object id -eq 'ReferenceCount')[0].logBytesPerValue = 4
$json | ConvertTo-Json -Depth 10 | Set-Content $path
Invoke-Verifier 'granularity-rc-data' $tree $false 'Product metadata layout differs for ReferenceCount.'

$tree = New-PerturbationTree 'granularity-rc-width'
Replace-ExactlyOnce `
    (Join-Path $tree 'docs\design\lxr-port\P2.1\metadata-specs.json') `
    '"1|2|3"' `
    '"1|2"'
Invoke-Verifier 'granularity-rc-width' $tree $false 'Benchmark rows are incomplete or duplicated.'

$tree = New-PerturbationTree 'atomicity-cas-source'
Replace-ExactlyOnce `
    (Join-Path $tree 'src\coreclr\gc\side_metadata.cpp') `
    'uintptr_t newWord = (oldWord & ~location.mask) | ((newValue << location.shift) & location.mask);' `
    'uintptr_t newWord = oldWord;'
Invoke-Verifier 'atomicity-cas-source' $tree $false 'Source identity mismatch: src\coreclr\gc\side_metadata.cpp'

$tree = New-PerturbationTree 'atomicity-load-source'
Replace-ExactlyOnce `
    (Join-Path $tree 'src\coreclr\gc\side_metadata.cpp') `
    'uintptr_t value = VolatileLoad(word);' `
    'uintptr_t value = VolatileLoadWithoutBarrier(word);'
Invoke-Verifier 'atomicity-load-source' $tree $false 'Source identity mismatch: src\coreclr\gc\side_metadata.cpp'

$tree = New-PerturbationTree 'neighbor-validation-missing'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\validation-summary.csv'
$rows = @(Import-Csv $path | Where-Object platform -ne 'windows-x64')
$rows | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'neighbor-validation-missing' $tree $false 'Validation platform evidence is incomplete.'

$tree = New-PerturbationTree 'neighbor-validation-failure'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\validation-summary.csv'
$rows = @(Import-Csv $path)
$rows[0].passed = ([int]$rows[0].total - 1).ToString()
$rows | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'neighbor-validation-failure' $tree $false 'Validation platform evidence is incomplete.'

$tree = New-PerturbationTree 'bounds-global-anchor'
Replace-ExactlyOnce `
    (Join-Path $tree 'docs\design\lxr-port\P2.1\metadata-specs.json') `
    '0x00000c0000000000' `
    '0x00000d0000000000'
Invoke-Verifier 'bounds-global-anchor' $tree $false 'Address layout or oracle identity mismatch.'

$tree = New-PerturbationTree 'bounds-source-anchor'
Replace-ExactlyOnce `
    (Join-Path $tree 'src\coreclr\gc\side_metadata.h') `
    '0x00000c0000000000' `
    '0x00000d0000000000'
Invoke-Verifier 'bounds-source-anchor' $tree $false 'Required product contract is missing: 0x00000c0000000000'

$tree = New-PerturbationTree 'bulk-missing-row'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\benchmark-raw.csv'
$rows = @(Import-Csv $path)
$remove = @($rows | Where-Object Method -eq 'BulkRead64KiB' | Select-Object -First 1)
$removed = $false
$remaining = foreach ($row in $rows) {
    if (-not $removed -and [object]::ReferenceEquals($row, $remove[0])) {
        $removed = $true
        continue
    }
    $row
}
$remaining | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'bulk-missing-row' $tree $false 'Benchmark rows are incomplete or duplicated.'

$tree = New-PerturbationTree 'bulk-duplicate-row'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\benchmark-raw.csv'
$rows = @(Import-Csv $path)
@($rows + @($rows | Where-Object Method -eq 'Reset64KiB' | Select-Object -First 1)) |
    Export-Csv $path -NoTypeInformation
Invoke-Verifier 'bulk-duplicate-row' $tree $false 'Benchmark rows are incomplete or duplicated.'

$tree = New-PerturbationTree 'identity-hash'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\source-identities.csv'
$rows = @(Import-Csv $path)
$rows[0].canonical_sha256 = '0' * 64
$rows | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'identity-hash' $tree $false 'Source identity mismatch:'

$tree = New-PerturbationTree 'identity-path'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\source-identities.csv'
$rows = @(Import-Csv $path)
$rows[0].name = 'missing\source.cpp'
$rows | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'identity-path' $tree $false 'Source identity path set mismatch.'

$tree = New-PerturbationTree 'evidence-missing-file'
Remove-Item -LiteralPath (
    Join-Path $tree 'docs\design\lxr-port\P2.1\raw\benchmark-controls.csv')
Invoke-Verifier 'evidence-missing-file' $tree $false 'Required evidence is missing: benchmark-controls.csv'

$tree = New-PerturbationTree 'evidence-duplicate-validation'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\validation-summary.csv'
$rows = @(Import-Csv $path)
@($rows + $rows[0]) | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'evidence-duplicate-validation' $tree $false 'Validation platform evidence is incomplete.'

$tree = New-PerturbationTree 'benchmark-sensitivity'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\benchmark-controls.csv'
$rows = @(Import-Csv $path)
$rows[0].extra_cas_ratio = '1.0'
$rows | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'benchmark-sensitivity' $tree $false 'Benchmark sensitivity control is incomplete.'

$tree = New-PerturbationTree 'benchmark-noise'
$path = Join-Path $tree 'docs\design\lxr-port\P2.1\raw\benchmark-controls.csv'
$rows = @(Import-Csv $path)
$rows[0].aa_ratio = '2.0'
$rows | Export-Csv $path -NoTypeInformation
Invoke-Verifier 'benchmark-noise' $tree $false 'Benchmark A/A noise control is incomplete.'

$summary | Export-Csv (Join-Path $runRoot 'gate-summary.csv') -NoTypeInformation
Write-Host 'PASS: 2 clean archive runs and 18 independent perturbations'
Write-Host "Output: $runRoot"
