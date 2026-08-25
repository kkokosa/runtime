# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RuntimeRoot,
    [string]$RepositoryRoot,
    [string]$OutputDirectory,
    [ValidateRange(1, 10)]
    [int]$LaunchCount = 1,
    [ValidateRange(1, 100)]
    [int]$WarmupCount = 3,
    [ValidateRange(1, 100)]
    [int]$IterationCount = 10
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\p14-allocation-benchmark'
}

$dotnet = Join-Path $RepositoryRoot '.dotnet\dotnet.exe'
$project = Join-Path $scriptRoot 'allocation-benchmark\allocation-benchmark.csproj'
$corerun = Join-Path $RuntimeRoot 'corerun.exe'
foreach ($path in @($dotnet, $project, $corerun)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
& $dotnet build $project -c Release --nologo
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$variants = @(
    @{ Name = 'unregistered'; Environment = @() },
    @{
        Name = 'registered-empty'
        Environment = @(
            'DOTNET_GCAllocationNotificationTest:1',
            'DOTNET_GCAllocationNotificationTestUncounted:1')
    },
    @{
        Name = 'registered-counting'
        Environment = @(
            'DOTNET_GCAllocationNotificationTest:1',
            'DOTNET_GCAllocationNotificationTestCountOnly:1')
    }
)

$passed = 0
foreach ($gc in @('wks', 'srv')) {
    foreach ($variant in $variants) {
        $name = "$gc-$($variant.Name)"
        $environment = @(
            'DOTNET_ReadyToRun:0',
            'DOTNET_TieredCompilation:0',
            "DOTNET_gcServer:$(if ($gc -eq 'srv') { '1' } else { '0' })"
        ) + $variant.Environment
        $arguments = @(
            'run',
            '--no-build',
            '-c', 'Release',
            '--project', $project,
            '--',
            '--filter', '*',
            '--coreRun', $corerun,
            '--launchCount', $LaunchCount,
            '--warmupCount', $WarmupCount,
            '--iterationCount', $IterationCount,
            '--artifacts', (Join-Path $OutputDirectory $name),
            '--envvars'
        ) + $environment

        & $dotnet @arguments *> (Join-Path $OutputDirectory "$name.log")
        if ($LASTEXITCODE -ne 0) {
            throw "Benchmark failed: $name"
        }
        $passed++
        Write-Host "PASS: $name"
    }
}

Write-Host "$passed/6 allocation benchmark configurations passed"
