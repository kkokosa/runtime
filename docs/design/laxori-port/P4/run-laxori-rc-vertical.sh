#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
configuration="${1:-Debug}"
output="${2:-$root/artifacts/P4/vertical-linux-$configuration}"
control="${3:-None}"
mkdir -p "$output"
flags=(-O0 -g -DDEBUG -D_DEBUG)
if [[ "$configuration" == Release ]]; then
    flags=(-O2 -DNDEBUG)
elif [[ "$configuration" != Debug ]]; then
    echo "Unsupported configuration: $configuration" >&2
    exit 1
fi
# The engine uses count-plane object starts (no ValidObject plane) unless LAXORI_OBJECT_START_BITMAP=1 is set (P31).
# Every control below can run in both variants.
if [[ -z "${LAXORI_OBJECT_START_BITMAP:-}" ]]; then
    flags+=(-DLAXORI_OBJECT_START_WALK)
fi
case "$control" in
    None) ;;
    EarlyRoot) flags+=(-DLAXORI_RC_EARLY_ROOT_CONTROL -Wno-unused-function) ;;
    SweepQuery) flags+=(-DLAXORI_RC_SWEEP_QUERY_CONTROL -Wno-unused-function) ;;
    TraceSatb) flags+=(-DLAXORI_TRACE_SKIP_SATB_CONTROL) ;;
    TraceDeletion) flags+=(-DLAXORI_TRACE_SKIP_DELETION_CONTROL) ;;
    MarkingWindowWide) flags+=(-DLAXORI_MARKING_WINDOW_WIDE_CONTROL) ;;
    MarkingWindowNone) flags+=(-DLAXORI_MARKING_WINDOW_NONE_CONTROL) ;;
    SelectLoseChunk) flags+=(-DLAXORI_SELECT_LOSE_CHUNK_CONTROL) ;;
    SelectSkipChunk) flags+=(-DLAXORI_SELECT_SKIP_CHUNK_CONTROL) ;;
    SelectGatherReversed) flags+=(-DLAXORI_SELECT_GATHER_REVERSED_CONTROL) ;;
    SelectDeadLines) flags+=(-DLAXORI_SELECT_DEAD_LINES_CONTROL) ;;
    SelectOccupied) flags+=(-DLAXORI_SELECT_OCCUPIED_CONTROL) ;;
    PredictorUpdate) flags+=(-DLAXORI_POLICY_WRONG_UPDATE_CONTROL) ;;
    TriggerOrder) flags+=(-DLAXORI_POLICY_WRONG_ORDER_CONTROL) ;;
    Lifetime) flags+=(-DLAXORI_PROBE_SKIP_RECLAIM_CONTROL) ;;
    StorageDiagnostics) flags+=(-DLAXORI_STORAGE_SKIP_COPY_CONTROL) ;;
    ObjectInterior) flags+=(-DLAXORI_OBJECT_INTERIOR_CONTROL) ;;
    PendingRetirement) flags+=(-DLAXORI_RETIRE_PENDING_CONTROL) ;;
    MatureStale) flags+=(-DLAXORI_REMSET_STALE_CONTROL) ;;
    MatureReplay) flags+=(-DLAXORI_REMSET_REPLAY_CONTROL) ;;
    MatureShape) flags+=(-DLAXORI_REMSET_SHAPE_CONTROL) ;;
    MatureScan) flags+=(-DLAXORI_MATURE_SCAN_REBASE_CONTROL) ;;
    MatureReaderCompletion) flags+=(-DLAXORI_MATURE_READER_COMPLETION_CONTROL) ;;
    MatureDeadScan) flags+=(-DLAXORI_MATURE_DEAD_SCAN_CONTROL) ;;
    MatureEarlyRelease) flags+=(-DLAXORI_MATURE_EARLY_RELEASE_CONTROL) ;;
    MatureCount) flags+=(-DLAXORI_MATURE_COUNT_CONTROL) ;;
    MaturePredictor) flags+=(-DLAXORI_MATURE_PREDICTOR_CONTROL) ;;
    ReserveUnits) flags+=(-DLAXORI_RESERVE_UNITS_CONTROL) ;;
    LogPublication) flags+=(-DLAXORI_LOG_PUBLICATION_CONTROL) ;;
    LogDecode) flags+=(-DLAXORI_LOG_DECODE_CONTROL) ;;
    LogCapacity) flags+=(-DLAXORI_LOG_CAPACITY_CONTROL) ;;
    LogReuse) flags+=(-DLAXORI_LOG_REUSE_CONTROL) ;;
    LogDrop) flags+=(-DLAXORI_LOG_DROP_CONTROL) ;;
    TraceBatchDrop) flags+=(-DLAXORI_TRACE_BATCH_DROP_CONTROL) ;;
    TraceBatchUnbatched) flags+=(-DLAXORI_TRACE_BATCH_UNBATCHED_CONTROL) ;;
    TraceBatchEarly) flags+=(-DLAXORI_TRACE_BATCH_EARLY_CONTROL) ;;
    PauseTraceMark) flags+=(-DLAXORI_PAUSE_TRACE_MARK_CONTROL) ;;
    PauseTraceLimit) flags+=(-DLAXORI_PAUSE_TRACE_LIMIT_CONTROL) ;;
    PauseTraceStore) flags+=(-DLAXORI_PAUSE_TRACE_REPLAY_STORE_CONTROL) ;;
    PreZeroTakeAsClean) flags+=(-DLAXORI_PREZERO_TAKE_AS_CLEAN_CONTROL) ;;
    PreZeroNoPauseGate) flags+=(-DLAXORI_PREZERO_NO_PAUSE_GATE_CONTROL) ;;
    WalkNoContinuationSkip) flags+=(-DLAXORI_OBJECT_START_WALK -DLAXORI_WALK_NO_CONTINUATION_SKIP_CONTROL) ;;
    WalkOneWord) flags+=(-DLAXORI_OBJECT_START_WALK -DLAXORI_WALK_ONE_WORD_CONTROL) ;;
    WalkNoExtent) flags+=(-DLAXORI_OBJECT_START_WALK -DLAXORI_WALK_NO_EXTENT_CONTROL) ;;
    WalkNoPinnedSpan) flags+=(-DLAXORI_OBJECT_START_WALK -DLAXORI_WALK_NO_PINNED_SPAN_CONTROL) ;;
    WalkTrustedResolve) flags+=(-DLAXORI_OBJECT_START_WALK -DLAXORI_WALK_TRUSTED_RESOLVE_CONTROL) ;;
    WalkEnumContinuation) flags+=(-DLAXORI_OBJECT_START_WALK -DLAXORI_WALK_ENUM_CONTINUATION_CONTROL) ;;
    *) echo "Unsupported control: $control" >&2; exit 1 ;;
esac
gc="$root/src/coreclr/gc"
LAXORI="$root/src/coreclr/gc_laxori"
sources=(
    laxori_side_metadata.cpp laxori_immix_block.cpp laxori_immix_allocation.cpp laxori_immix_zeroing.cpp laxori_reference_count.cpp
    laxori_large_object_space.cpp laxori_work_packet.cpp laxori_work_scheduler.cpp
    laxori_pause_schedule.cpp laxori_pause_coordinator.cpp laxori_completion_counter.cpp
    laxori_reference_counting.cpp
)
for index in "${!sources[@]}"; do
    sources[$index]="$LAXORI/${sources[$index]}"
done
sources+=(
    "$root/docs/design/laxori-port/P2.5/large-object-space-test-platform.cpp"
    "$root/docs/design/laxori-port/P4/laxori-rc-validation.cpp"
)
sha256sum "${sources[@]}" "$LAXORI"/*.h "$gc"/*.h > "$output/source-identities.txt"
command=(
    clang++ -std=c++17 -pthread -Wall -Wextra -Werror -Wno-unused-parameter -Wno-invalid-offsetof
    "${flags[@]}" -DBUILD_AS_STANDALONE -DTARGET_UNIX -DHOST_UNIX -DTARGET_LINUX
    -DTARGET_AMD64 -DHOST_AMD64 -DTARGET_64BIT -DHOST_64BIT
    -DLAXORI_SIDE_METADATA_TEST_PLATFORM -DLAXORI_ENABLE_LAZY_COMPLETION_COUNTER
    "-I$LAXORI" "-I$gc" "-I$gc/env" "-I$root/src/native" "-I$root/src/native/inc"
    "${sources[@]}" -o "$output/laxori-rc-validation"
)
printf '%q ' "${command[@]}" > "$output/compile-command.txt"
printf '\n' >> "$output/compile-command.txt"
"${command[@]}" > "$output/build.log" 2>&1
status=0
selectors=()
case "$control" in
    MatureStale|MatureReplay) selectors=(--mature-remset) ;;
    MatureShape) selectors=(--mature-remset-wrap) ;;
    MatureScan|MatureReaderCompletion) selectors=(--mature-reader) ;;
    MatureDeadScan) selectors=(--mature-completed-scan) ;;
    MatureEarlyRelease|MatureCount|MaturePredictor) selectors=(--mature) ;;
    ReserveUnits) selectors=(--p8-policy) ;;
    Log*) selectors=(--log-storage) ;;
    TraceBatch*) selectors=(--trace-batching) ;;
    PauseTrace*) selectors=(--pause-trace) ;;
    PreZero*) selectors=(--prezero) ;;
    Walk*) selectors=(--object-start) ;;
    MarkingWindow*) selectors=(--marking-window) ;;
    Select*) selectors=(--select-parallel) ;;
esac
"$output/laxori-rc-validation" "${selectors[@]}" > "$output/run.log" 2>&1 || status=$?
if [[ "$control" != None ]]; then
    if [[ "$status" == 0 ]] || ! grep -q 'FAIL:' "$output/run.log"; then
        echo "Failure control $control did not detect its injected violation." >&2
        exit 1
    fi
    echo "CONTROL $control detected: exit=$status"
    exit 0
fi
if [[ "$status" != 0 ]]; then
    cat "$output/run.log"
    exit "$status"
fi
cat "$output/run.log"
grep -qE '^PASS: [1-9][0-9]*/[1-9][0-9]* integrated P4 checks$' "$output/run.log"
