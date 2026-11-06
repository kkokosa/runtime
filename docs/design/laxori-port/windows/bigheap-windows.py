#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""P49 "bigheap" on Windows (the Windows twin of scripts/bigheap.py, with the ScalingDriver of docs/design/laxori-port/driver-scaling).
A large live heap of small linked objects with churn; the pauses of the measured window come from the runtime events (pauses.csv).

usage: python bigheap-windows.py <outdir> <reps> <liveMB> <capMB> <seconds> <config> [<config> ...]
Configs: laxori, lxr, wks, svr (laxori and lxr: DOTNET_gcServer=1, fixed heap capMB, trace threshold 2, like the Linux runs).
Sizes are DECIMAL MB. Every run (a build of the live heap, then <seconds> of churn) runs under the shared benchmark lock of WSL2.
Prints, for every config: the number of pauses, long pauses (>= LONG_MS, default 30), the median and maximum of the long pauses,
the median of all pauses, wall and CPU of the window, the peak working set, and the setup time."""
import json, os, statistics, subprocess, sys

FRAME = os.environ.get("FRAME", r"C:\lx-run\frame")
DRIVER = os.environ.get("SCALE_DRV", r"C:\lx-run\drv-scale\out\ScalingDriver.dll")
PYTHON = os.environ.get("PYTHON", sys.executable)
LONG_MS = float(os.environ.get("LONG_MS", "30"))
LOCK = "/tmp/lxr-bench.lock"


def env_for(name, cap):
    if name == "wks":
        return {"DOTNET_gcServer": "0"}
    if name == "svr":
        return {"DOTNET_gcServer": "1"}
    lib, prefix = ("clrlaxorigc.dll", "LAXORI") if name == "laxori" else ("clrlxrgc.dll", "LXR")
    return {"DOTNET_gcServer": "1", "DOTNET_GCPath": os.path.join(FRAME, lib),
            f"DOTNET_{prefix}ImmixInitialMB": str(cap), f"DOTNET_{prefix}ImmixReserveMB": str(cap),
            f"DOTNET_{prefix}NativePlaneLimitMB": "200000", f"DOTNET_{prefix}TraceThreshold": "2"}


def one(spec_path):
    spec = json.load(open(spec_path))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(env_for(spec["config"], spec["cap"]))
    cmd = [os.path.join(FRAME, "corerun.exe"), DRIVER, spec["rundir"], "bigheap", str(spec["live"]), str(spec["seconds"]), "2", "30", "300"]
    r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800)
    open(os.path.join(spec["rundir"], "driver.log"), "w").write(r.stdout)
    print("rc", r.returncode, flush=True)


def main():
    if sys.argv[1] == "--one":
        one(sys.argv[2])
        return
    out, reps, live, cap, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    configs = sys.argv[6:]
    os.makedirs(out, exist_ok=True)
    res = {c: [] for c in configs}
    for rep in range(reps):
        for c in configs:
            rundir = os.path.join(out, f"{c}-{rep}")
            os.makedirs(rundir, exist_ok=True)
            spec = os.path.join(rundir, "spec.json")
            json.dump({"config": c, "cap": cap, "live": live, "seconds": secs, "rundir": rundir}, open(spec, "w"))
            inner = [PYTHON, os.path.abspath(__file__), "--one", spec]
            subprocess.run(["wsl.exe", "-d", "Ubuntu-22.04", "--exec", "flock", LOCK, "/mnt/c/Windows/System32/cmd.exe", "/c"] + inner)
            pc, rj = os.path.join(rundir, "pauses.csv"), os.path.join(rundir, "result.json")
            if not (os.path.exists(pc) and os.path.exists(rj)):
                print(rep, c, "FAILED", flush=True)
                continue
            d = [float(l.split(",")[1]) for l in open(pc).read().split("\n")[1:] if l]
            long_ = [x for x in d if x >= LONG_MS]
            r = json.load(open(rj))
            rec = dict(n=len(d), longn=len(long_), longmed=statistics.median(long_) if long_ else 0, longmax=max(long_) if long_ else 0,
                       med=statistics.median(d) if d else 0, wall=r["wall_ms"], cpu=r["cpu_ms"], rss=r["peak_rss_mb"], setup=r["setup_ms"])
            res[c].append(rec)
            print(rep, c, rec, flush=True)
    print("\nmedians over runs: pauses / long (>= %g ms) / median long ms / max ms / median all ms / wall ms / cpu ms / peak WS MB / setup ms" % LONG_MS)
    for c in configs:
        rs = res[c]
        if rs:
            m = lambda k: statistics.median(r[k] for r in rs)
            print(f"{c:7} n={len(rs)} {m('n'):6.0f} {m('longn'):5.0f} {m('longmed'):8.1f} {m('longmax'):8.1f} {m('med'):6.2f} "
                  f"{m('wall'):8.0f} {m('cpu'):8.0f} {m('rss'):8.0f} {m('setup'):8.0f}")


main()
