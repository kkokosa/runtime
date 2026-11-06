#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""How often the six standard workloads run the evacuation-set selection, and in which mode (serial or parallel).
Runs each workload once with the experiment library (per-pause record written at exit) and counts the InitialMark and Full
pauses. A pause used the parallel path when its SelectScan timer is not zero.
usage: p50count.py <library> <outdir> [settings as KEY=VALUE ...]
"""
import json, os, re, subprocess, sys

lib, outdir = sys.argv[1], sys.argv[2]
extra = dict(arg.split("=", 1) for arg in sys.argv[3:])
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
FRAME = "/root/prof/frame-c4"
DRIVER = "/root/prof/drv/bin/CompareDriver.dll"
WORK = {"requests": (8192, 200000), "binarytrees": (18, 1), "listsuffix": (8192, 600000),
        "mixedmedium": (12000, 200000), "losarrays": (1500, 100000), "mediumarrays": (20000, 300000)}
PHASES = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "p50analyze.py")).read()
# The column names come from the source of p50analyze.py (it runs its main() when it is imported).
names = re.search(r'BASE_PHASES = \((.*?)\)\.split\(\)', PHASES, re.S).group(1)
base = re.findall(r'"([^"]*)"', names)
phases = " ".join(base).split() + "SelectMature SelectScan SelectGather SelectTail SelectBusy".split()
groups = "Increments Decrements Satb PrepareTrace WeakClosure EpochClosure NurserySweep MatureSweep TracePackets".split()
columns = phases + [f"{g}.{s}" for g in groups for s in ("wall", "busy", "packets")]
os.makedirs(outdir, exist_ok=True)
print("| workload | pauses | InitialMark | Full | selections serial | selections parallel | SelectMature ms (all selections) |")
print("|---|---|---|---|---|---|---|")
for workload, (size, ops) in WORK.items():
    rundir = os.path.join(outdir, workload)
    os.makedirs(rundir, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_", "LXR_"))}
    env.update({"DOTNET_gcServer": "1", "DOTNET_GCPath": lib, "LXR_P49_TRACE": "1", "LXR_P49_TRACE_AT_EXIT": "1",
                "LXR_P49_TRACE_FILE": os.path.join(rundir, "pauses.csv")})
    if workload == "mediumarrays":
        env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
    env.update(extra)
    subprocess.run([FRAME + "/corerun", DRIVER, rundir, workload, str(size), str(ops)], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
    rows = []
    path = os.path.join(rundir, "pauses.csv")
    if os.path.exists(path):
        with open(path) as f:
            header = f.readline()
            published = int(re.match(r"# published=(\d+)", header).group(1))
            for line in f:
                parts = line.strip().split(",")
                rows.append((int(parts[0]), dict(zip(columns, map(int, parts[1:1 + published])))))
    selecting = [r for kind, r in rows if kind in (0, 2) and r["SelectMature"] > 0]
    parallel = [r for r in selecting if r["SelectScan"] > 0]
    print(f"| {workload} | {len(rows)} | {sum(1 for k, _ in rows if k == 2)} | {sum(1 for k, _ in rows if k == 0)} | "
          f"{len(selecting) - len(parallel)} | {len(parallel)} | {sum(r['SelectMature'] for r in selecting) / 1e6:.1f} |")
