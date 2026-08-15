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

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $RepositoryRoot 'artifacts\p11-capability-validation'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$source = Join-Path $scriptRoot 'capability-validation.cpp'
$executable = Join-Path $OutputDirectory 'capability-validation.exe'
$object = Join-Path $OutputDirectory 'capability-validation.obj'
$initializeVisualStudio = Join-Path $RepositoryRoot 'eng\native\init-vs-env.cmd'
$command = @(
    "call `"$initializeVisualStudio`" x64",
    "cl /nologo /std:c++17 /EHsc `"$source`" /Fo:`"$object`" /Fe:`"$executable`"",
    "`"$executable`""
) -join ' && '

& $env:ComSpec /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
