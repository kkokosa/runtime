#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Thread suspension and stack scanning cost, on Windows and WSL2 (same VM): the "alloc" mode of the ScalingDriver (P49 item 8c).
T threads allocate at the same time, every one at <depth> stack frames; the pauses of the window come from the runtime events.
A pause has to stop all T threads and scan their stacks.

usage: python suspend.py win|lin <outdir> <rep> [T] [depth] [seconds]
Run both under one lock: see suspend-run.sh. Prints one line per collector: pauses, median and p90 of the pause in ms, wall and CPU."""
import json, os, statistics, subprocess, sys

osname, out, rep = sys.argv[1], sys.argv[2], sys.argv[3]
T = sys.argv[4] if len(sys.argv) > 4 else "32"
depth = sys.argv[5] if len(sys.argv) > 5 else "100"
secs = sys.argv[6] if len(sys.argv) > 6 else "8"
if osname == "win":
    frame, driver, exe = r"C:\lx-run\frame", r"C:\lx-run\drv-scale\out\ScalingDriver.dll", "corerun.exe"
    libs = {"lxr": r"C:\lx-run\frame\clrlxrgc.dll", "laxori": r"C:\lx-run\frame\clrlaxorigc.dll"}
    sep = "\\"
else:
    frame, driver, exe = "/root/prof/frame-c4", "/root/laxori/drv-scale/bin/ScalingDriver.dll", "corerun"
    libs = {"lxr": "/root/p31/so/libclrlxrgc-walk.so", "laxori": "/root/laxori/v/libclrlaxorigc-count-c.so"}
    sep = "/"
for name in ("wks", "svr", "lxr", "laxori"):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env["DOTNET_gcServer"] = "0" if name == "wks" else "1"
    if name in libs:
        env["DOTNET_GCPath"] = libs[name]
    rundir = os.path.join(out, f"{osname}-{name}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    r = subprocess.run([frame + sep + exe, driver, rundir, "alloc", T, depth, secs, "30"], env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=600)
    try:
        d = sorted(float(l.split(",")[1]) for l in open(os.path.join(rundir, "pauses.csv")).read().split("\n")[1:] if l)
        res = json.load(open(os.path.join(rundir, "result.json")))
        print(f"{osname} {name} rep{rep} T={T} depth={depth} pauses={len(d)} median_ms={statistics.median(d):.2f} "
              f"p90_ms={d[int(len(d) * 0.9)]:.2f} wall_ms={res['wall_ms']:.0f} cpu_ms={res['cpu_ms']:.0f}", flush=True)
    except Exception as e:
        print(f"{osname} {name} rep{rep} FAILED rc={r.returncode} {e}", flush=True)
