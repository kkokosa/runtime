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

$log = Join-Path $RepositoryRoot 'artifacts\p1.6-clear-control.log'
$saved = [Environment]::GetEnvironmentVariable('P16_CLEAR_AFTER_COMPACTION_CONTROL')
try {
    [Environment]::SetEnvironmentVariable('P16_CLEAR_AFTER_COMPACTION_CONTROL', '1')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $scriptRoot 'run-object-header-bits-runtime.ps1') `
        -RepositoryRoot $RepositoryRoot -GCMode Workstation *> $log
    $exitCode = $LASTEXITCODE
}
finally {
    [Environment]::SetEnvironmentVariable('P16_CLEAR_AFTER_COMPACTION_CONTROL', $saved)
}

$output = Get-Content -LiteralPath $log -Raw
if (($exitCode -eq 0) -or
    ($output -notmatch 'state 2 survives compacting GC')) {
    throw 'One-site state-clear control did not fail for the expected reason.'
}

Write-Host '1/1 object-header bit clear controls failed as expected'
exit 0
