# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$CurrentRuntimeRoot,
    [string]$FrameworkRoot,
    [Parameter(Mandatory)]
    [string]$PreviousRuntimeRoot,
    [Parameter(Mandatory)]
    [string]$PreviousStandaloneGC,
    [string]$DotNet,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}

if (-not $CurrentRuntimeRoot) {
    $CurrentRuntimeRoot = Join-Path $RepositoryRoot 'artifacts\bin\coreclr\windows.x64.Debug'
}

if (-not $DotNet) {
    $DotNet = Join-Path $RepositoryRoot '.dotnet\dotnet.exe'
}

if (-not $FrameworkRoot) {
    $FrameworkRoot = Join-Path $RepositoryRoot 'artifacts\tests\coreclr\windows.x64.Debug\Tests\Core_Root'
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\p11-capability-integration'
}

$smokeProject = Join-Path $scriptRoot 'runtime-smoke\runtime-smoke.csproj'
$smokeOutput = Join-Path $OutputDirectory 'smoke'
$currentStandaloneGC = Join-Path $CurrentRuntimeRoot 'clrgc.dll'
$currentRuntime = Join-Path $CurrentRuntimeRoot 'corerun.exe'
$previousRuntime = Join-Path $PreviousRuntimeRoot 'corerun.exe'

foreach ($path in @(
    $DotNet,
    $smokeProject,
    $currentStandaloneGC,
    $currentRuntime,
    $PreviousStandaloneGC,
    $previousRuntime
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file not found: $path"
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
& $DotNet build $smokeProject -c Release -o $smokeOutput --nologo
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $FrameworkRoot -PathType Container)) {
    throw "Framework directory not found: $FrameworkRoot"
}

Get-ChildItem -LiteralPath $FrameworkRoot -File |
    Where-Object {
        (($_.Name -like 'System.*.dll') -or
         ($_.Name -like 'Microsoft.*.dll') -or
         ($_.Name -in @('mscorlib.dll', 'netstandard.dll'))) -and
        ($_.Name -ne 'System.Private.CoreLib.dll')
    } |
    Copy-Item -Destination $smokeOutput -Force

$smokeAssembly = Join-Path $smokeOutput 'runtime-smoke.dll'
$scenarios = @(
    @{ Name = 'new runtime and inherited 5.9 card-table declaration, workstation'; Runtime = $currentRuntime; GC = $currentStandaloneGC; Server = '0' },
    @{ Name = 'new runtime and inherited 5.9 card-table declaration, server'; Runtime = $currentRuntime; GC = $currentStandaloneGC; Server = '1' },
    @{ Name = 'new runtime and unchanged 5.8 standalone GC, workstation'; Runtime = $currentRuntime; GC = $PreviousStandaloneGC; Server = '0' },
    @{ Name = 'new runtime and unchanged 5.8 standalone GC, server'; Runtime = $currentRuntime; GC = $PreviousStandaloneGC; Server = '1' },
    @{ Name = '5.8 runtime and new standalone GC, workstation'; Runtime = $previousRuntime; GC = $currentStandaloneGC; Server = '0' },
    @{ Name = '5.8 runtime and new standalone GC, server'; Runtime = $previousRuntime; GC = $currentStandaloneGC; Server = '1' }
)

$passed = 0
try {
    foreach ($scenario in $scenarios) {
        $env:DOTNET_GCPath = $scenario.GC
        $env:DOTNET_gcServer = $scenario.Server
        $output = & $scenario.Runtime $smokeAssembly 2>&1
        if (($LASTEXITCODE -ne 0) -or ($output -notcontains 'PASS')) {
            throw "Scenario failed: $($scenario.Name)`n$output"
        }

        $passed++
        Write-Host "PASS: $($scenario.Name)"
    }
}
finally {
    Remove-Item Env:\DOTNET_GCPath -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_gcServer -ErrorAction SilentlyContinue
}

Write-Host "$passed/$($scenarios.Count) integration scenarios passed"
