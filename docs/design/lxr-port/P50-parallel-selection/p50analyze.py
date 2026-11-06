#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""P50 analysis of the scaling cells: serial against parallel selection (markdown tables).

usage: p50analyze.py <resultsdir> [pattern]      (pattern default "8a-*"; "thr-*" for the threshold cells)
Reads <resultsdir>/<cell>/<rep>/{result.json,lxr-pauses.csv}. Needs the library of the experiment build (P49 per-pause record).
"""
import csv, glob, json, os, re, statistics, sys

BASE_PHASES = ("Total LockWait PolicyDrain PreDrain SuspendRuntime SuspendEE SuspendPrepare RootCapture PrepareWork ReleaseEpoch "
               "RetireSources ReclaimNursery SweepBlocks ReleaseFlip Scan0 Scan1 Scan2 Scan3 ScanBeforeRoots ScanLeaseFinalizers ScanRoots "
               "ScanHandles ScanProfilerHandles ScanDependent ScanSyncBlock ScanFrozen ScanDhInitial ScanShortWeak ScanQueueFinalizers "
               "ScanTraceFinalizers ScanDhRescan ScanWeakPtr ScanWeakPtrSingle ScanRelocateRoots ScanRelocateHandles ScanPromotionsGranted "
               "ScanHeapStatistics ResumeRuntime StwPause PostDrain ResumeGap PublishTrace Borrow GiveBack ReleaseSetup ReleaseTail "
               "TraceSetup TraceRoots TraceReplay TraceFixup").split()
PHASES = BASE_PHASES + "SelectMature SelectScan SelectGather SelectTail SelectBusy".split()
GROUPS = "Increments Decrements Satb PrepareTrace WeakClosure EpochClosure NurserySweep MatureSweep TracePackets".split()
COUNTERS = ("VisitStacks VisitHandles VisitProfilerHandles VisitDependent VisitSyncBlock VisitFrozenRoots VisitRelocateStacks "
            "VisitRelocateHandles FrozenObjects FrozenFields SelectBlocks SelectCandidates SelectEligible SelectSelected").split()
KINDS = {0: "Full", 1: "RefCount", 2: "InitialMark", 3: "FinalMark"}
COLUMNS = PHASES + [f"{g}.{s}" for g in GROUPS for s in ("wall", "busy", "packets")]
WORKERS = 13  # 16 processors; the pause thread takes part too, so 14 threads


def load_lxr(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path) as f:
        header = f.readline()
        m = re.match(r"# published=(\d+) counters=(\d+)", header)
        if not m or int(m.group(1)) != len(COLUMNS) or int(m.group(2)) != len(COUNTERS):
            raise SystemExit(f"{path}: {header.strip()} differs from the script ({len(COLUMNS)} timers, {len(COUNTERS)} counters)")
        for line in f:
            parts = line.strip().split(",")
            row = dict(zip(COLUMNS, map(int, parts[1:1 + len(COLUMNS)])))
            row.update(dict(zip(COUNTERS, map(int, parts[1 + len(COLUMNS):]))))
            row["kind"] = int(parts[0])
            rows.append(row)
    return rows


def load_cell(celldir):
    runs = []
    for d in sorted(glob.glob(os.path.join(celldir, "*")), key=lambda p: int(os.path.basename(p))):
        if not os.path.exists(os.path.join(d, "result.json")):
            continue
        runs.append(dict(result=json.load(open(os.path.join(d, "result.json"))),
                         lxr=load_lxr(os.path.join(d, "lxr-pauses.csv")), dir=d))
    return runs


def med(v):
    v = list(v)
    return statistics.median(v) if v else float("nan")


def rng(v):
    v = list(v)
    return (min(v), max(v)) if v else (float("nan"), float("nan"))


def selection_rows(run, kinds, first_only=False):
    """Pauses that ran the selection (InitialMark and Full) with a real heap (the build phase included, as in P49)."""
    return [r for r in run["lxr"] if r["kind"] in kinds and r["SelectMature"] > 0 and r["SelectBlocks"] > 0]


def per_run(runs, fn, kinds):
    out = []
    for r in runs:
        rows = selection_rows(r, kinds)
        if rows:
            out.append(med(fn(x) for x in rows))
    return out


def stat(vals, scale, nd=1):
    if not vals:
        return "-"
    lo, hi = rng(vals)
    return f"{med(vals) / scale:.{nd}f} [{lo / scale:.{nd}f}-{hi / scale:.{nd}f}]"


def main():
    res = sys.argv[1]
    pattern = sys.argv[2] if len(sys.argv) > 2 else "8a-*"
    cells = {os.path.basename(p): load_cell(p) for p in sorted(glob.glob(os.path.join(res, pattern)))}
    sizes = sorted({n.split("-", 1)[1].split("-", 1)[1] for n in cells},
                   key=lambda s: int(s.split("live")[1].split("-")[0]))
    prefix = pattern.split("-")[0]
    for kind, label in ((2, "InitialMark"), (0, "Full")):
        print(f"\n#### {label} pauses (medians of the per-run medians, [min-max] over runs; times in ms)\n")
        print("| size | mode | runs | pauses | blocks in use | occupied | SelectMature | scan | gather | tail | StwPause | share | "
              "threads/pause | busy/(scan x threads) |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        summary = {}
        for size in sizes:
            for mode in ("ser", "par"):
                runs = cells.get(f"{prefix}-{mode}-{size}", [])
                rows = [x for r in runs for x in selection_rows(r, (kind,))]
                if not rows:
                    continue
                sel = per_run(runs, lambda x: x["SelectMature"], (kind,))
                stw = per_run(runs, lambda x: x["StwPause"], (kind,))
                share = per_run(runs, lambda x: x["SelectMature"] / x["StwPause"], (kind,))
                scan = per_run(runs, lambda x: x["SelectScan"], (kind,))
                gather = per_run(runs, lambda x: x["SelectGather"], (kind,))
                tail = per_run(runs, lambda x: x["SelectTail"], (kind,))
                occupied = med(x["SelectCandidates"] for x in rows)
                summary[(size, mode)] = (med(sel), med(stw), occupied)
                busy = med(x["SelectBusy"] / (x["SelectScan"] * (WORKERS + 1)) for x in rows if x["SelectScan"] and mode == "par") \
                    if mode == "par" else float("nan")
                print(f"| {size} | {mode} | {len(runs)} | {len(rows)} | {med(x['SelectBlocks'] for x in rows):.0f} | {occupied:.0f} | "
                      f"{stat(sel, 1e6, 2)} | {stat(scan, 1e6, 2)} | {stat(gather, 1e6, 2)} | {stat(tail, 1e6, 2)} | "
                      f"{stat(stw, 1e6, 1)} | {med(share) * 100:.0f}% | - | {busy * 100:.0f}% |")
        print("\n| size | SelectMature serial -> parallel (ms) | speed-up | speed-up per thread (14) | InitialMark/Full pause serial -> parallel (ms) |")
        print("|---|---|---|---|---|")
        for size in sizes:
            if (size, "ser") in summary and (size, "par") in summary:
                s, p = summary[(size, "ser")], summary[(size, "par")]
                print(f"| {size} | {s[0] / 1e6:.2f} -> {p[0] / 1e6:.2f} | {s[0] / p[0]:.1f}x | {s[0] / p[0] / (WORKERS + 1):.2f} | "
                      f"{s[1] / 1e6:.1f} -> {p[1] / 1e6:.1f} |")


main()
