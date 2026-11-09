# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# PrivateTests of Laxori on Windows (the Windows twin of the Linux test runs). Builds PrivateTests.csproj and runs
#   "all 2 T" for T in 1, 2, 4, 8, 13 once, and "all 2 13" <Repeats> times,
# in L2 mode (default) and L1 mode (DOTNET_LAXORIEscapedInPlace=0), with the region verifier on (DOTNET_LAXORIVerifyPrivate=1).
# usage: private-tests.ps1 [-Frame C:\lx-run\frame] [-Library clrlaxorigc.dll] [-Repeats 20] [-Out C:\lx-run\pt-results]
[CmdletBinding()]
param(
    [string]$Frame = 'C:\lx-run\frame',
    [string]$Library = 'clrlaxorigc.dll',
    [int]$Repeats = 20,
    [string]$Out = 'C:\lx-run\pt-results',
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path,
    [string]$Dotnet
)
$ErrorActionPreference = 'Stop'
if (-not $Dotnet) { $Dotnet = Join-Path $Repo '.dotnet\dotnet.exe' }
New-Item -ItemType Directory -Force $Out | Out-Null
$src = Join-Path $Repo 'docs\design\laxori-port\PrivateTests'
$build = Join-Path $Out 'build'
New-Item -ItemType Directory -Force $build | Out-Null
Copy-Item "$src\*" $build -Force
& $Dotnet build "$build\PrivateTests.csproj" -c Release -o "$build\out" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'PrivateTests build failed' }
$app = "$build\out\PrivateTests.dll"
$env:DOTNET_GCPath = Join-Path $Frame $Library
$env:DOTNET_LAXORIVerifyPrivate = '1'
$failed = 0; $total = 0
foreach ($mode in 'L2', 'L1') {
    if ($mode -eq 'L1') { $env:DOTNET_LAXORIEscapedInPlace = '0' } else { Remove-Item Env:DOTNET_LAXORIEscapedInPlace -ErrorAction SilentlyContinue }
    $runs = @(1, 2, 4, 8, 13) + (@(13) * $Repeats)
    $i = 0
    foreach ($t in $runs) {
        $i++
        $log = Join-Path $Out "$mode-t$t-$i.log"
        $ErrorActionPreference = 'Continue'
        & "$Frame\corerun.exe" $app all 2 $t *> $log
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $total++
        $last = (Get-Content $log | Select-Object -Last 1)
        if ($code -ne 0 -or $last -ne 'PASS') { $failed++; Write-Output "FAIL $mode threads=$t run=$i exit=$code :: $last (log $log)" }
        elseif ($i -le 5) { Write-Output "ok   $mode threads=$t" }
    }
    Write-Output "$mode done: runs=$($runs.Count)"
}
Write-Output "PrivateTests total=$total failed=$failed"
exit $failed
