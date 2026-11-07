#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Interleaved Windows benchmark with paired differences (the Windows twin of scripts/bench3.py).

usage: python bench-windows.py <outdir> <reps> <configs,comma> <workloads,comma> [<pairA>:<pairB>,...] [--block N] [--nolock]

Configs: wks, svr, lxr, laxori, laxori-l1 (DOTNET_LAXORIEscapedInPlace=0), laxori-np (DOTNET_LAXORIPrivate=0),
         or any <library>[+NAME=VALUE]* with <library> a dll name in the frame (e.g. clrlaxorigc.dll+DOTNET_LAXORIRegionKB=128).
Laxori and LXR runs use DOTNET_gcServer=1 and DOTNET_GCPath, like the Linux runs (bench3.py). wks is DOTNET_gcServer=0, svr is
DOTNET_gcServer=1 without GCPath.

The shared benchmark lock lives in WSL2 (/tmp/lxr-bench.lock) because WSL2 and Windows share one VM. The runs are cut into blocks
(--block units of one workload and one repetition for all configs, default 2); each block runs under
    wsl.exe -d Ubuntu-22.04 -- flock /tmp/lxr-bench.lock cmd.exe /c <python> <this script> --worker <plan> <outdir>
so a block is never disturbed by a timed WSL2 run of another session. --nolock runs without the lock (correctness runs).
(wsl.exe needs --exec: with "--" the command goes through a shell that eats the backslashes of the Windows paths.)
Every run is checked against the known checksum. Prints the medians and, for every pair A:B, the paired difference (A - B) / B."""
import json, os, random, statistics, subprocess, sys, time

FRAME = os.environ.get("FRAME", r"C:\lx-run\frame")
DRIVER = os.environ.get("DRIVER", r"C:\lx-run\drv2\out\CompareDriver.dll")
PYTHON = os.environ.get("PYTHON", sys.executable)
WSL_DISTRO = os.environ.get("WSL_DISTRO", "Ubuntu-22.04")
LOCK = "/tmp/lxr-bench.lock"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000), "losmany": (2000, 60000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUMS = {"requests": 27134172608, "binarytrees": 68332294, "listsuffix": 159636632672, "mixedmedium": 40586599707,
        "losarrays": 13936826922, "mediumarrays": 7032863679, "losmany": 42674603309}
METRICS = [("wall_ms", "wall ms"), ("cpu_ms", "cpu ms"), ("pause_ms", "pause ms"), ("peak_rss_mb", "peak WS MB")]


def config(name, workload):
    if name == "wks":
        return {"DOTNET_gcServer": "0"}
    if name == "svr":
        return {"DOTNET_gcServer": "1"}
    if name == "satori":
        return {"DOTNET_gcServer": "0", "DOTNET_GCPath": os.path.join(FRAME, "satorigc.dll")}
    extra = {}
    if name == "lxr":
        lib = "clrlxrgc.dll"
    elif name == "lxr-fix":
        lib = "clrlxrgc-copylogfix.dll"   # LXR + CopyLog::Chunk fix (lxr-copylog-fix.patch), reported as LXR+copylog-fix
    elif name == "laxori":
        lib = "clrlaxorigc.dll"
    elif name == "laxori-l1":
        lib, extra = "clrlaxorigc.dll", {"DOTNET_LAXORIEscapedInPlace": "0"}
    elif name == "laxori-np":
        lib, extra = "clrlaxorigc.dll", {"DOTNET_LAXORIPrivate": "0"}
    else:
        parts = name.split("+")
        lib = parts[0]
        extra = dict(p.split("=", 1) for p in parts[1:])
    prefix = "LAXORI" if "laxori" in lib else "LXR"
    e = {"DOTNET_gcServer": "1", "DOTNET_GCPath": os.path.join(FRAME, lib)}
    if workload == "mediumarrays":
        e.update({f"DOTNET_{prefix}ImmixInitialMB": "200", f"DOTNET_{prefix}ImmixReserveMB": "400"})
    if workload == "losmany":
        e.update({f"DOTNET_{prefix}LOSInitialMB": "1000", f"DOTNET_{prefix}LOSReserveMB": "1600", f"DOTNET_{prefix}NativePlaneLimitMB": "16000"})
    e.update(extra)
    return e


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name, workload))
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name.replace('+', '_').replace('=', '-')}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [os.path.join(FRAME, "corerun.exe"), DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"status": "failed", "rc": r.returncode, "tail": r.stdout[-300:]}
    rec = json.load(open(path))
    if rec["checksum"] != SUMS[workload]:
        rec["status"] = "WRONG CHECKSUM"
    return rec


def worker(plan_path, outdir):
    plan = json.load(open(plan_path))
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep, w, c in plan:
            rec = run(c, w, rep, outdir)
            rec.update(collector=c, workload=w, rep=rep)
            f.write(json.dumps(rec) + "\n")
            f.flush()
            print(rep, w, c, round(rec.get("wall_ms", 0)), rec.get("checksum", ""), rec.get("status", ""), flush=True)


def main():
    argv = [a for a in sys.argv[1:]]
    if argv and argv[0] == "--worker":
        worker(argv[1], argv[2])
        return
    block = 2
    lock = True
    if "--block" in argv:
        i = argv.index("--block")
        block = int(argv[i + 1])
        del argv[i:i + 2]
    sleep_s = 8.0
    if "--sleep" in argv:
        i = argv.index("--sleep")
        sleep_s = float(argv[i + 1])
        del argv[i:i + 2]
    if "--nolock" in argv:
        argv.remove("--nolock")
        lock = False
    outdir, reps, configs, workloads = argv[0], int(argv[1]), argv[2].split(","), argv[3].split(",")
    pairs = [p.split(":") for p in argv[4].split(",")] if len(argv) > 4 else []
    os.makedirs(outdir, exist_ok=True)
    units = [[(rep, w, c) for c in configs] for rep in range(reps) for w in workloads]
    for i in range(0, len(units), block):
        plan = [t for u in units[i:i + block] for t in u]
        plan_path = os.path.join(outdir, f"plan-{i}.json")
        json.dump(plan, open(plan_path, "w"))
        inner = [PYTHON, os.path.abspath(__file__), "--worker", plan_path, outdir]
        cmd = inner if not lock else ["wsl.exe", "-d", WSL_DISTRO, "--exec", "flock", LOCK, "/mnt/c/Windows/System32/cmd.exe", "/c"] + inner
        subprocess.run(cmd, check=False)
    rows = {}
    for line in open(os.path.join(outdir, "runs.jsonl")):
        rec = json.loads(line)
        rows.setdefault((rec["workload"], rec["collector"]), {})[rec["rep"]] = rec
    summarize(rows, configs, workloads, pairs)


def good(rec):
    return "wall_ms" in rec and rec.get("status") is None


def summarize(rows, configs, workloads, pairs):
    print("\nmedians: wall ms / cpu ms / pause ms / peak working set MB / collections")
    for w in workloads:
        for c in configs:
            ok = [r for r in rows.get((w, c), {}).values() if good(r)]
            bad = len(rows.get((w, c), {})) - len(ok)
            if not ok:
                print(f"{w:12} {c:14} no successful run ({bad} failed)")
                continue
            m = lambda k: statistics.median(r[k] for r in ok)
            print(f"{w:12} {c:14} {m('wall_ms'):7.0f} {m('cpu_ms'):7.0f} {m('pause_ms'):6.0f} {m('peak_rss_mb'):6.0f} "
                  f"{m('total_collections'):5.0f} n={len(ok)} bad={bad}")
    for a, b in pairs:
        print(f"\npaired difference (A-B)/B in percent, A={a} B={b}: median CI95 [min..max], reps where A is lower")
        for w in workloads:
            line = f"{w:12}"
            for key, label in METRICS:
                d = []
                for rep, ra in rows.get((w, a), {}).items():
                    rb = rows.get((w, b), {}).get(rep)
                    if rb and good(ra) and good(rb) and rb[key]:
                        d.append((ra[key] - rb[key]) * 100.0 / rb[key])
                if d:
                    lower = sum(1 for x in d if x < 0)
                    lo, hi = bootstrap(d)
                    line += f" | {label} {statistics.median(d):+6.1f} CI95 [{lo:+5.1f}, {hi:+5.1f}] [{min(d):+5.1f}..{max(d):+5.1f}] {lower}/{len(d)}"
            print(line)


def bootstrap(values, rounds=4000, seed=12345):
    rng = random.Random(seed)
    n = len(values)
    meds = sorted(statistics.median(rng.choices(values, k=n)) for _ in range(rounds))
    return meds[int(rounds * 0.025)], meds[int(rounds * 0.975)]


if __name__ == "__main__":
    main()
