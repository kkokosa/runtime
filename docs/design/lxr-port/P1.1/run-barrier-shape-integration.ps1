# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory)]
    [string]$ProductionRuntimeRoot,
    [Parameter(Mandatory)]
    [string]$ValidationRuntimeRoot,
    [Parameter(Mandatory)]
    [string]$ProductionStandaloneGC,
    [Parameter(Mandatory)]
    [string]$ValidationStandaloneGC,
    [Parameter(Mandatory)]
    [string]$PreviousRuntimeRoot,
    [Parameter(Mandatory)]
    [string]$PreviousStandaloneGC,
    [Parameter(Mandatory)]
    [string]$RebuiltPreviousStandaloneGC,
    [Parameter(Mandatory)]
    [string]$GuardedPreviousStandaloneGC,
    [Parameter(Mandatory)]
    [string]$OlderMajorStandaloneGC,
    [Parameter(Mandatory)]
    [string]$NewerMajorStandaloneGC,
    [string]$DotNet,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path
}

if (-not $DotNet) {
    $DotNet = Join-Path $RepositoryRoot '.dotnet\dotnet.exe'
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\p11-barrier-shape-integration'
}

$smokeProject = Join-Path $scriptRoot 'runtime-smoke\runtime-smoke.csproj'
$smokeOutput = Join-Path $OutputDirectory 'smoke'
$smokeAssembly = Join-Path $smokeOutput 'runtime-smoke.dll'
$productionRuntime = Join-Path $ProductionRuntimeRoot 'corerun.exe'
$validationRuntime = Join-Path $ValidationRuntimeRoot 'corerun.exe'
$previousRuntime = Join-Path $PreviousRuntimeRoot 'corerun.exe'

foreach ($path in @(
    $DotNet,
    $smokeProject,
    $productionRuntime,
    $validationRuntime,
    $previousRuntime,
    $ProductionStandaloneGC,
    $ValidationStandaloneGC,
    $PreviousStandaloneGC,
    $RebuiltPreviousStandaloneGC,
    $GuardedPreviousStandaloneGC,
    $OlderMajorStandaloneGC,
    $NewerMajorStandaloneGC
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

$scenarios = @(
    @{ Name = 'production-built-in-workstation'; Runtime = $productionRuntime; GC = $null; Server = '0'; R2R = '1'; Result = 'pass' },
    @{ Name = 'production-built-in-server'; Runtime = $productionRuntime; GC = $null; Server = '1'; R2R = '1'; Result = 'pass' },
    @{ Name = 'production-standalone-workstation'; Runtime = $productionRuntime; GC = $ProductionStandaloneGC; Server = '0'; R2R = '1'; Result = 'pass' },
    @{ Name = 'production-standalone-server'; Runtime = $productionRuntime; GC = $ProductionStandaloneGC; Server = '1'; R2R = '1'; Result = 'pass' },
    @{ Name = 'standard-clobber-workstation'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass'; Standard = $true; Clobber = '1' },
    @{ Name = 'standard-clobber-server'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '1'; R2R = '0'; Result = 'pass'; Standard = $true; Clobber = '1' },
    @{ Name = 'standard-clobber-jit-stress-workstation'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass'; Standard = $true; Clobber = '1'; JitStressRegs = '8' },
    @{ Name = 'standard-clobber-jit-stress-server'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '1'; R2R = '0'; Result = 'pass'; Standard = $true; Clobber = '1'; JitStressRegs = '8' },
    @{ Name = 'standard-clobber-gc-stress'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass'; Standard = $true; Clobber = '1'; GCStress = '0xC' },
    @{ Name = 'standard-noop-workstation'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass'; Standard = $true; Clobber = '0' },
    @{ Name = 'old-gc-new-runtime-workstation'; Runtime = $productionRuntime; GC = $PreviousStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass' },
    @{ Name = 'old-gc-new-runtime-server'; Runtime = $productionRuntime; GC = $PreviousStandaloneGC; Server = '1'; R2R = '0'; Result = 'pass' },
    @{ Name = 'old-source-current-header-workstation'; Runtime = $productionRuntime; GC = $RebuiltPreviousStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass' },
    @{ Name = 'old-source-current-header-server'; Runtime = $productionRuntime; GC = $RebuiltPreviousStandaloneGC; Server = '1'; R2R = '0'; Result = 'pass' },
    @{ Name = 'new-gc-old-runtime-workstation'; Runtime = $previousRuntime; GC = $ProductionStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass' },
    @{ Name = 'new-gc-old-runtime-server'; Runtime = $previousRuntime; GC = $ProductionStandaloneGC; Server = '1'; R2R = '0'; Result = 'pass' },
    @{ Name = 'guarded-old-gc-new-runtime-workstation'; Runtime = $productionRuntime; GC = $GuardedPreviousStandaloneGC; Server = '0'; R2R = '0'; Result = 'pass' },
    @{ Name = 'guarded-old-gc-new-runtime-server'; Runtime = $productionRuntime; GC = $GuardedPreviousStandaloneGC; Server = '1'; R2R = '0'; Result = 'pass' },
    @{ Name = 'production-rejects-side-shape'; Runtime = $productionRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001' },
    @{ Name = 'production-rejects-older-major'; Runtime = $productionRuntime; GC = $OlderMajorStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004005' },
    @{ Name = 'production-loads-newer-major'; Runtime = $productionRuntime; GC = $NewerMajorStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x8000FFFF' },
    @{ Name = 'standard-rejects-r2r'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '1'; Result = 'failure'; Error = '0x80004001' },
    @{ Name = 'standard-rejects-unknown-shape'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001'; TestShape = '99' },
    @{ Name = 'standard-rejects-null-metadata'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001'; Malformed = '1' },
    @{ Name = 'standard-rejects-null-callback'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001'; Malformed = '2' },
    @{ Name = 'standard-rejects-granularity-overflow'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001'; Malformed = '3' },
    @{ Name = 'standard-rejects-invalid-polarity'; Runtime = $validationRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001'; Malformed = '4' },
    @{ Name = 'old-runtime-rejects-new-side-shape'; Runtime = $previousRuntime; GC = $ValidationStandaloneGC; Server = '0'; R2R = '0'; Result = 'failure'; Error = '0x80004001' }
)

$passed = 0
try {
    foreach ($scenario in $scenarios) {
        if ($scenario.GC) {
            $env:DOTNET_GCPath = $scenario.GC
        } else {
            Remove-Item Env:\DOTNET_GCPath -ErrorAction SilentlyContinue
        }

        $env:DOTNET_gcServer = $scenario.Server
        $env:DOTNET_ReadyToRun = $scenario.R2R
        $env:DOTNET_TieredCompilation = '0'

        foreach ($setting in @(
            @{ Name = 'DOTNET_JitStressRegs'; Value = $scenario.JitStressRegs },
            @{ Name = 'DOTNET_GCStress'; Value = $scenario.GCStress },
            @{ Name = 'DOTNET_GCWriteBarrierTestShape'; Value = $scenario.TestShape },
            @{ Name = 'DOTNET_GCWriteBarrierTestMalformed'; Value = $scenario.Malformed }
        )) {
            if ($null -ne $setting.Value) {
                Set-Item -Path "Env:\$($setting.Name)" -Value $setting.Value
            } else {
                Remove-Item -Path "Env:\$($setting.Name)" -ErrorAction SilentlyContinue
            }
        }

        if ($scenario.Standard) {
            $env:P11_EXPECT_STANDARD_ABI = '1'
            $env:DOTNET_GCWriteBarrierTestClobber = $scenario.Clobber
            if ($scenario.Clobber -eq '1') {
                $env:P11_EXPECT_CLOBBER = '1'
            } else {
                Remove-Item Env:\P11_EXPECT_CLOBBER -ErrorAction SilentlyContinue
            }
        } else {
            Remove-Item Env:\P11_EXPECT_STANDARD_ABI -ErrorAction SilentlyContinue
            Remove-Item Env:\P11_EXPECT_CLOBBER -ErrorAction SilentlyContinue
            Remove-Item Env:\DOTNET_GCWriteBarrierTestClobber -ErrorAction SilentlyContinue
        }
        Remove-Item Env:\DOTNET_GCWriteBarrierTestUncounted -ErrorAction SilentlyContinue

        $log = Join-Path $OutputDirectory "$($scenario.Name).log"
        & $scenario.Runtime $smokeAssembly *> $log
        $exitCode = $LASTEXITCODE
        $output = Get-Content -LiteralPath $log -Raw

        if ($scenario.Result -eq 'pass') {
            if (($exitCode -ne 0) -or ($output -notmatch '(?m)^PASS:')) {
                throw "Scenario failed: $($scenario.Name), exit $exitCode. See $log."
            }
        } elseif (($exitCode -eq 0) -or
                  ($output -notmatch [regex]::Escape($scenario.Error)) -or
                  ($output -match '(?m)^PASS:')) {
            throw "Scenario did not fail with $($scenario.Error) before managed execution: $($scenario.Name). See $log."
        }

        $passed++
        Write-Host "PASS: $($scenario.Name)"
    }
}
finally {
    Remove-Item Env:\DOTNET_GCPath -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_gcServer -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_ReadyToRun -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_TieredCompilation -ErrorAction SilentlyContinue
    Remove-Item Env:\P11_EXPECT_STANDARD_ABI -ErrorAction SilentlyContinue
    Remove-Item Env:\P11_EXPECT_CLOBBER -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_GCWriteBarrierTestClobber -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_GCWriteBarrierTestUncounted -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_GCWriteBarrierTestShape -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_GCWriteBarrierTestMalformed -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_JitStressRegs -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTNET_GCStress -ErrorAction SilentlyContinue
}

Write-Host "$passed/$($scenarios.Count) barrier-shape integration scenarios passed"
exit 0
