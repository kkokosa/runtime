# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# Runs every mutation control of the P4 validation program on Windows (each control breaks one rule; the matching check must
# fail) plus the P2.4 walk control. Same list as run-laxori-rc-vertical.sh and P31-object-start-walk/run-walk-controls.sh.
# usage: run-controls.ps1 [-Output <dir>] [-Bitmap]
[CmdletBinding()]
param([string]$Output = 'C:\lx-nat-ctl', [switch]$Bitmap)
$here = $PSScriptRoot
$controls = 'EarlyRoot', 'SweepQuery', 'TraceSatb', 'TraceDeletion', 'MarkingWindowWide', 'MarkingWindowNone', 'SelectLoseChunk', 'SelectSkipChunk',
    'SelectGatherReversed', 'SelectDeadLines', 'SelectOccupied', 'PredictorUpdate', 'TriggerOrder', 'Lifetime', 'StorageDiagnostics', 'ObjectInterior',
    'PendingRetirement', 'MatureStale', 'MatureReplay', 'MatureShape', 'MatureScan', 'MatureReaderCompletion', 'MatureDeadScan', 'MatureEarlyRelease',
    'MatureCount', 'MaturePredictor', 'ReserveUnits', 'LogPublication', 'LogDecode', 'LogCapacity', 'LogReuse', 'LogDrop', 'TraceBatchDrop',
    'TraceBatchUnbatched', 'TraceBatchEarly', 'PauseTraceMark', 'PauseTraceLimit', 'PauseTraceStore', 'PreZeroTakeAsClean', 'PreZeroNoPauseGate',
    'WalkNoContinuationSkip', 'WalkOneWord', 'WalkNoExtent', 'WalkNoPinnedSpan', 'WalkTrustedResolve', 'WalkEnumContinuation'
$bad = 0
foreach ($c in $controls) {
    $args2 = @{ Program = 'p4'; Control = $c; Output = $Output }
    if ($Bitmap) { $args2['Bitmap'] = $true }
    $out = & "$here\native-windows.ps1" @args2 2>&1 | Out-String
    $line = ($out -split "`n" | Where-Object { $_ -match 'CONTROL|BUILD FAILED' } | Select-Object -First 1)
    Write-Output ("{0}: {1}" -f $c, $line.Trim())
    if ($line -notmatch 'detected' -or $line -match 'NOT detected') { $bad++ }
}
# P2.4: the walk variant must not write the ValidObject plane
$out = & "$here\native-windows.ps1" -Program p2.4 -Control None -ExtraDefine 'LAXORI_WALK_WRITE_VALID_CONTROL' -Output "$Output-p24" 2>&1 | Out-String
Write-Output ("P2.4 WalkWriteValid: " + (($out -split "`n" | Select-Object -First 3) -join ' | ').Trim())
Write-Output "controls not detected: $bad"
