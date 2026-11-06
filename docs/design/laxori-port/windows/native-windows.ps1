# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# Laxori native engine validation programs on Windows x64 (MSVC). The Windows twin of run-native-all.sh and of the
# P2.x, P3.x and P4 run-*.sh scripts (same sources, same defines, same checks; cl.exe instead of g++/clang++).
#
# usage: native-windows.ps1 [-Program all|p2.1|p2.2|p2.3|p2.4|p2.5|p3.1|p3.2|p3.3|p3.4|p4] [-Config Release|Debug]
#                           [-Control <name>] [-Selector <p4 selector> ...] [-Bitmap] [-Output <dir>] [-Repo <path>]
#   -Control   builds the program with one mutation control (see run-laxori-rc-vertical.sh for the P4 names, P2.4 takes
#              any define through -ExtraDefine). The run has to FAIL; the script then reports "CONTROL <name> detected".
#   -Selector  P4 only: the selectors to run one by one. Default: the default run and every engine selector of
#              P31-object-start-walk/run-p4-selectors.sh.
#   -Bitmap    the ValidObject bit plane build (default: object starts from the count plane, LAXORI_OBJECT_START_WALK).
[CmdletBinding()]
param(
    [string]$Program = 'all',
    [ValidateSet('Release', 'Debug')][string]$Config = 'Release',
    [string]$Control = 'None',
    [string[]]$Selector,
    [string[]]$ExtraDefine = @(),
    [switch]$Bitmap,
    [string]$Output,
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
)
$ErrorActionPreference = 'Stop'
if (-not $Output) { $Output = Join-Path $Repo 'artifacts\laxori-native-windows' }
New-Item -ItemType Directory -Force $Output | Out-Null
$Output = (Resolve-Path $Output).Path

$gc = Join-Path $Repo 'src\coreclr\gc'
$lx = Join-Path $Repo 'src\coreclr\gc_laxori'
$native = Join-Path $Repo 'src\native'
$D = Join-Path $Repo 'docs\design\laxori-port'
$vs = Join-Path $Repo 'eng\native\init-vs-env.cmd'

$optFlags = if ($Config -eq 'Debug') { '/Od /MTd /DDEBUG /D_DEBUG' } else { '/O2 /MT /DNDEBUG' }
$warn = '/W4 /WX /wd4100 /wd4324 /wd4458 /wd4127 /wd4201 /wd4146 /wd4244 /wd4267 /wd4456 /wd4457 /wd4459 /wd4701 /wd4702 /wd4706 /wd4996 /wd4310 /wd4200 /wd4310 /wd4324 /wd4334 /wd4703'
$platform = '/DBUILD_AS_STANDALONE /DTARGET_WINDOWS /DHOST_WINDOWS /DWIN32 /DTARGET_AMD64 /DHOST_AMD64 /DTARGET_64BIT /DHOST_64BIT'
$walk = if ($Bitmap) { '' } else { '/DLAXORI_OBJECT_START_WALK' }
$includes = "/I`"$lx`" /I`"$gc`" /I`"$gc\env`" /I`"$native`" /I`"$native\inc`""
$engine = 'laxori_side_metadata.cpp', 'laxori_immix_block.cpp'

function L([string[]]$names) { $names | ForEach-Object { Join-Path $lx $_ } }

# name = @{ sources; defines; success pattern; strict (full warning set) }
$programs = [ordered]@{
    'p2.1' = @{ src = @("$D\P2.1\side-metadata-validation.cpp", "$D\P2.1\side-metadata-test-platform.cpp") + (L 'laxori_side_metadata.cpp'); def = '/DLAXORI_SIDE_METADATA_TEST_PLATFORM'; ok = '^(\d+)/(\d+) side metadata checks passed$' }
    'p2.2' = @{ src = @("$D\P2.2\immix-block-validation.cpp", "$D\P2.1\side-metadata-test-platform.cpp") + (L $engine); def = "$walk /DLAXORI_BLOCK_OPERATION_TEST_HOOK"; ok = '^(\d+)/(\d+) immix block checks passed$' }
    'p2.3' = @{ src = @("$D\P2.3\reference-count-validation.cpp", "$D\P2.1\side-metadata-test-platform.cpp") + (L ($engine + 'laxori_reference_count.cpp')); def = $walk; ok = '^(\d+)/(\d+) ' }
    'p2.4' = @{ src = @("$D\P2.4\immix-allocation-validation.cpp", "$D\P2.1\side-metadata-test-platform.cpp") + (L ($engine + 'laxori_immix_allocation.cpp', 'laxori_immix_zeroing.cpp')); def = "$walk /DLAXORI_F9_TEST_HOOKS"; ok = '^(\d+)/(\d+) ' }
    'p2.5' = @{ src = @("$D\P2.5\large-object-space-validation.cpp", "$D\P2.5\large-object-space-test-platform.cpp") + (L ($engine + 'laxori_large_object_space.cpp')); def = "$walk /DLAXORI_SIDE_METADATA_TEST_PLATFORM"; ok = '^(\d+)/(\d+) ' }
    'p3.1' = @{ src = @("$D\P3.1\laxori-work-packet-validation.cpp") + (L 'laxori_work_packet.cpp', 'laxori_work_scheduler.cpp'); def = ''; ok = '^PASS: (\d+)/(\d+) ' }
    'p3.2' = @{ src = @("$D\P3.2\laxori-pause-validation.cpp") + (L 'laxori_work_packet.cpp', 'laxori_work_scheduler.cpp', 'laxori_pause_schedule.cpp', 'laxori_pause_coordinator.cpp'); def = ''; ok = '^PASS' }
    'p3.3' = @{ src = @("$D\P3.3\laxori-deferred-bucket-validation.cpp") + (L 'laxori_work_packet.cpp', 'laxori_work_scheduler.cpp'); def = ''; ok = '^PASS' }
    'p3.4' = @{ src = @("$D\P3.4\laxori-completion-counter-validation.cpp") + (L 'laxori_completion_counter.cpp', 'laxori_work_packet.cpp', 'laxori_work_scheduler.cpp'); def = '/DLAXORI_ENABLE_LAZY_COMPLETION_COUNTER'; ok = '^PASS' }
    'p4'   = @{ src = (L 'laxori_side_metadata.cpp', 'laxori_immix_block.cpp', 'laxori_immix_allocation.cpp', 'laxori_immix_zeroing.cpp', 'laxori_reference_count.cpp', 'laxori_large_object_space.cpp', 'laxori_work_packet.cpp', 'laxori_work_scheduler.cpp', 'laxori_pause_schedule.cpp', 'laxori_pause_coordinator.cpp', 'laxori_completion_counter.cpp', 'laxori_reference_counting.cpp') + @("$D\P2.5\large-object-space-test-platform.cpp", "$D\P4\laxori-rc-validation.cpp"); def = "$walk /DLAXORI_SIDE_METADATA_TEST_PLATFORM /DLAXORI_ENABLE_LAZY_COMPLETION_COUNTER"; ok = '^PASS: (\d+)/(\d+) integrated P4 checks$' }
}

$controlDefines = @{
    EarlyRoot = 'LAXORI_RC_EARLY_ROOT_CONTROL'; SweepQuery = 'LAXORI_RC_SWEEP_QUERY_CONTROL'; TraceSatb = 'LAXORI_TRACE_SKIP_SATB_CONTROL'
    TraceDeletion = 'LAXORI_TRACE_SKIP_DELETION_CONTROL'; MarkingWindowWide = 'LAXORI_MARKING_WINDOW_WIDE_CONTROL'
    MarkingWindowNone = 'LAXORI_MARKING_WINDOW_NONE_CONTROL'; SelectLoseChunk = 'LAXORI_SELECT_LOSE_CHUNK_CONTROL'
    SelectSkipChunk = 'LAXORI_SELECT_SKIP_CHUNK_CONTROL'; SelectGatherReversed = 'LAXORI_SELECT_GATHER_REVERSED_CONTROL'
    SelectDeadLines = 'LAXORI_SELECT_DEAD_LINES_CONTROL'; SelectOccupied = 'LAXORI_SELECT_OCCUPIED_CONTROL'
    PredictorUpdate = 'LAXORI_POLICY_WRONG_UPDATE_CONTROL'; TriggerOrder = 'LAXORI_POLICY_WRONG_ORDER_CONTROL'
    Lifetime = 'LAXORI_PROBE_SKIP_RECLAIM_CONTROL'; StorageDiagnostics = 'LAXORI_STORAGE_SKIP_COPY_CONTROL'
    ObjectInterior = 'LAXORI_OBJECT_INTERIOR_CONTROL'; PendingRetirement = 'LAXORI_RETIRE_PENDING_CONTROL'
    MatureStale = 'LAXORI_REMSET_STALE_CONTROL'; MatureReplay = 'LAXORI_REMSET_REPLAY_CONTROL'; MatureShape = 'LAXORI_REMSET_SHAPE_CONTROL'
    MatureScan = 'LAXORI_MATURE_SCAN_REBASE_CONTROL'; MatureReaderCompletion = 'LAXORI_MATURE_READER_COMPLETION_CONTROL'
    MatureDeadScan = 'LAXORI_MATURE_DEAD_SCAN_CONTROL'; MatureEarlyRelease = 'LAXORI_MATURE_EARLY_RELEASE_CONTROL'
    MatureCount = 'LAXORI_MATURE_COUNT_CONTROL'; MaturePredictor = 'LAXORI_MATURE_PREDICTOR_CONTROL'
    ReserveUnits = 'LAXORI_RESERVE_UNITS_CONTROL'; LogPublication = 'LAXORI_LOG_PUBLICATION_CONTROL'; LogDecode = 'LAXORI_LOG_DECODE_CONTROL'
    LogCapacity = 'LAXORI_LOG_CAPACITY_CONTROL'; LogReuse = 'LAXORI_LOG_REUSE_CONTROL'; LogDrop = 'LAXORI_LOG_DROP_CONTROL'
    TraceBatchDrop = 'LAXORI_TRACE_BATCH_DROP_CONTROL'; TraceBatchUnbatched = 'LAXORI_TRACE_BATCH_UNBATCHED_CONTROL'
    TraceBatchEarly = 'LAXORI_TRACE_BATCH_EARLY_CONTROL'; PauseTraceMark = 'LAXORI_PAUSE_TRACE_MARK_CONTROL'
    PauseTraceLimit = 'LAXORI_PAUSE_TRACE_LIMIT_CONTROL'; PauseTraceStore = 'LAXORI_PAUSE_TRACE_REPLAY_STORE_CONTROL'
    PreZeroTakeAsClean = 'LAXORI_PREZERO_TAKE_AS_CLEAN_CONTROL'; PreZeroNoPauseGate = 'LAXORI_PREZERO_NO_PAUSE_GATE_CONTROL'
    WalkNoContinuationSkip = 'LAXORI_WALK_NO_CONTINUATION_SKIP_CONTROL'; WalkOneWord = 'LAXORI_WALK_ONE_WORD_CONTROL'
    WalkNoExtent = 'LAXORI_WALK_NO_EXTENT_CONTROL'; WalkNoPinnedSpan = 'LAXORI_WALK_NO_PINNED_SPAN_CONTROL'
    WalkTrustedResolve = 'LAXORI_WALK_TRUSTED_RESOLVE_CONTROL'; WalkEnumContinuation = 'LAXORI_WALK_ENUM_CONTINUATION_CONTROL'
}
$controlSelector = @(
    @('^Mature(Stale|Replay)$', '--mature-remset'), @('^MatureShape$', '--mature-remset-wrap'), @('^Mature(Scan|ReaderCompletion)$', '--mature-reader'),
    @('^MatureDeadScan$', '--mature-completed-scan'), @('^Mature(EarlyRelease|Count|Predictor)$', '--mature'), @('^ReserveUnits$', '--p8-policy'),
    @('^Log', '--log-storage'), @('^TraceBatch', '--trace-batching'), @('^PauseTrace', '--pause-trace'), @('^PreZero', '--prezero'),
    @('^Walk', '--object-start'), @('^MarkingWindow', '--marking-window'), @('^Select', '--select-parallel'))

$allSelectors = @('', '--pause-trace', '--lazy-sweep', '--d2-spans', '--prezero', '--fresh-block-race', '--s7-pins', '--s6-registry', '--s5b-overshoot',
    '--s4-sweep', '--s3-bookkeeping', '--lazy-large-release', '--inline-metadata', '--log-storage', '--mature', '--mature-remset',
    '--mature-reader', '--mature-retained-owner', '--mature-released-candidate', '--mature-headroom', '--mature-completed-scan',
    '--mature-remset-whole', '--mature-remset-wrap', '--mature-remset-same-shape', '--mature-remset-boundaries', '--nursery',
    '--nursery-reader', '--root-batching', '--trace-batching', '--aux-retirement', '--object-planes', '--storage-diagnostics',
    '--lifetime', '--p8-policy', '--p8-storage', '--zero-rc-control', '--f1-trace', '--f2-pause', '--f8-lazy', '--f4b-scheduler',
    '--f4-scheduler', '--f10-rc', '--item3', '--f5-policy', '--trace', '--marking-window', '--release-stage', '--object-start', '--select-parallel')

$extra = @($ExtraDefine | ForEach-Object { '/D' + $_ }) -join ' '
if ($Control -ne 'None') {
    if ($controlDefines.ContainsKey($Control)) { $extra += ' /D' + $controlDefines[$Control] }
    elseif ($Control -notlike '-D*' -and $ExtraDefine.Count -eq 0) { throw "Unknown control $Control" }
    if ($Control -like 'Walk*') { $extra += ' /DLAXORI_OBJECT_START_WALK' }
}

$names = if ($Program -eq 'all') { @($programs.Keys) } else { @($Program) }
$failed = 0
foreach ($name in $names) {
    $p = $programs[$name]
    $dir = Join-Path $Output ($name + $(if ($Control -ne 'None') { "-ctl-$Control" } else { '' }))
    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir "$name.exe"
    $quoted = ($p.src | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $strict = if ($name -in 'p3.1', 'p3.3') { '' } else { $warn }
    $cmd = "call `"$vs`" x64 >nul && cd /d `"$dir`" && cl.exe /nologo /std:c++17 /EHsc $strict $optFlags $platform $($p.def) $extra $includes $quoted /Fe:`"$exe`" /Fo:`"$dir\\`""
    Set-Content (Join-Path $dir 'compile-command.txt') $cmd
    & $env:ComSpec /d /s /c $cmd *> (Join-Path $dir 'build.log')
    if (-not (Test-Path $exe)) {
        Write-Output "BUILD FAILED $name"
        Get-Content (Join-Path $dir 'build.log') | Select-String 'error' | Select-Object -First 25 | ForEach-Object { $_.Line }
        $failed = 1; continue
    }
    $sels = @('')
    if ($name -eq 'p4') {
        if ($Control -ne 'None') {
            $sels = @('')
            foreach ($r in $controlSelector) { if ($Control -match $r[0]) { $sels = @($r[1]) } }
        } elseif ($Selector) { $sels = $Selector } else { $sels = $allSelectors }
    }
    foreach ($s in $sels) {
        $log = Join-Path $dir ('run' + $s.Replace('--', '-') + '.log')
        $ErrorActionPreference = 'Continue'
        if ($s) { & $exe $s *> $log } else { & $exe *> $log }
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $text = Get-Content $log -Raw
        $line = (Select-String -Path $log -Pattern '^(PASS|FAIL)|checks passed$' | Select-Object -Last 1).Line
        if ($s -eq '--zero-rc-control') {
            # a control inside the program: it has to fail (as on Linux)
            Write-Output ("[{0} {1}] exit={2} :: {3} (expected to fail)" -f $name, $s, $code, $line)
            if ($code -eq 0) { $failed = 1 }
            continue
        }
        if ($Control -ne 'None') {
            if ($code -eq 0 -or $text -notmatch 'FAIL') { Write-Output "CONTROL $Control NOT detected ($name $s): exit=$code"; $failed = 1 }
            else { Write-Output "CONTROL $Control detected ($name $s): exit=$code" }
            continue
        }
        Write-Output ("[{0}{1}] exit={2} :: {3}" -f $name, $(if ($s) { " $s" } else { '' }), $code, $line)
        if ($code -ne 0) { $failed = 1; Select-String -Path $log -Pattern 'FAIL' | Select-Object -First 5 | ForEach-Object { '    ' + $_.Line } }
    }
}
Write-Output "native $Config failed=$failed"
exit $failed
