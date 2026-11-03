#!/usr/bin/env python3
"""Per-pause phase times (ms) from the pause timers (DOTNET_LAXORIPhaseTimers=1 / DOTNET_LXRPhaseTimers=1) in driver result.json files.
usage: pause-phases.py <label=result.json>..."""
import json, sys

NAMES = """Total LockWait PolicyDrain PreDrain SuspendRuntime SuspendEE SuspendPrepare RootCapture PrepareWork ReleaseEpoch RetireSources
ReclaimNursery SweepBlocks ReleaseFlip Scan0 Scan1 Scan2 Scan3 ScanBeforeRoots ScanLeaseFinalizers ScanRoots ScanHandles ScanProfilerHandles
ScanDependent ScanSyncBlock ScanFrozen ScanDhInitial ScanShortWeak ScanQueueFinalizers ScanTraceFinalizers ScanDhRescan ScanWeakPtr ScanWeakPtrSingle
ScanRelocateRoots ScanRelocateHandles ScanPromotionsGranted ScanHeapStatistics ResumeRuntime StwPause PostDrain ResumeGap PublishTrace Borrow GiveBack
ReleaseSetup ReleaseTail TraceSetup TraceRoots TraceReplay TraceFixup""".split()
rows = []
for arg in sys.argv[1:]:
    label, path = arg.split("=", 1)
    r = json.load(open(path))
    n = max(1, r["collections"])
    rows.append((label, n, r["timer_ns"], r["pause_ms"]))
print(f"{'phase':22s}" + "".join(f"{label:>22s}" for label, *_ in rows))
print(f"{'pauses':22s}" + "".join(f"{n:>22d}" for _, n, *_ in rows))
print(f"{'pause_ms (runtime)':22s}" + "".join(f"{p:>22.1f}" for _, _, _, p in rows))
for i, name in enumerate(NAMES):
    vals = [t[i] / 1e6 / n if i < len(t) else 0 for _, n, t, _ in rows]
    if max(vals) >= 0.05:
        print(f"{name:22s}" + "".join(f"{v:>19.2f} ms" for v in vals))
