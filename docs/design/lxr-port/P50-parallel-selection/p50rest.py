#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""What else changes in the InitialMark pause between the serial and the parallel cells of p50run.py: the median of the per-run
medians of the other phases (ms). usage: p50rest.py <resultsdir> [pattern]"""
import glob, os, re, statistics, sys

res = sys.argv[1]
pattern = sys.argv[2] if len(sys.argv) > 2 else "8a-*"
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "p50analyze.py")).read()
base = re.findall(r'"([^"]*)"', re.search(r'BASE_PHASES = \((.*?)\)\.split\(\)', src, re.S).group(1))
phases = " ".join(base).split() + "SelectMature SelectScan SelectGather SelectTail SelectBusy".split()
groups = "Increments Decrements Satb PrepareTrace WeakClosure EpochClosure NurserySweep MatureSweep TracePackets".split()
columns = phases + [f"{g}.{s}" for g in groups for s in ("wall", "busy", "packets")]
show = ["StwPause", "SuspendEE", "RootCapture", "PrepareWork", "SelectMature", "Increments.wall", "Satb.wall", "PrepareTrace.wall",
        "NurserySweep.wall", "ReleaseEpoch", "ScanRoots", "ScanRelocateRoots"]
cells = {}
for celldir in sorted(glob.glob(os.path.join(res, pattern))):
    runs = []
    for d in glob.glob(os.path.join(celldir, "*")):
        path = os.path.join(d, "lxr-pauses.csv")
        if not os.path.exists(path):
            continue
        rows = []
        with open(path) as f:
            published = int(re.match(r"# published=(\d+)", f.readline()).group(1))
            for line in f:
                p = line.strip().split(",")
                if int(p[0]) == 2:
                    rows.append(dict(zip(columns, map(int, p[1:1 + published]))))
        rows = [r for r in rows if r["SelectMature"] > 0]
        if rows:
            runs.append({c: statistics.median(r[c] for r in rows) for c in show})
    cells[os.path.basename(celldir)] = runs
print("| cell | " + " | ".join(show) + " |")
print("|---|" + "---|" * len(show))
for name, runs in cells.items():
    if runs:
        print(f"| {name} | " + " | ".join(f"{statistics.median(r[c] for r in runs) / 1e6:.2f}" for c in show) + " |")
