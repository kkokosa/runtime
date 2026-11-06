#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""P50 A/B of the six standard workloads: the baseline library (lxr-gc-review head) against the library with the parallel
selection. Interleaved, the order of the two libraries shuffled in every repetition. The shared lock is held for a block
(one repetition of one workload: both libraries), as the runs are short.

usage: p50ab.py <outdir> <reps> [workloads,comma]
"""
import fcntl, json, os, random, subprocess, sys

FRAME = "/root/prof/frame-c4"
DRIVER = "/root/prof/drv/bin/CompareDriver.dll"
LIBS = {"base": os.environ.get("P50_BASE", "/root/p50/lib/libclrlxrgc-base.so"),
        "p50": os.environ.get("P50_NEW", "/root/p50/lib/libclrlxrgc-p50.so")}
# Arms: (library, extra settings). "p50s" is the new library with the parallel selection switched off (the serial path only).
ARMS = {"base": ("base", {}), "p50": ("p50", {}),
        "p50s": ("p50", {"DOTNET_LXRSelectParallelBlocks": "4294967295"})}
ACTIVE = os.environ.get("P50_ARMS", "base,p50").split(",")
LOCK = "/tmp/lxr-bench.lock"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUM = {"binarytrees": 68332294, "requests": 27134172608, "listsuffix": 159636632672,
       "mediumarrays": 7032863679, "mixedmedium": 40586599707, "losarrays": 13936826922}


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update({"DOTNET_gcServer": "1", "DOTNET_GCPath": LIBS[ARMS[name][0]]})
    env.update(ARMS[name][1])
    env.update(json.loads(os.environ.get("P50_EXTRA_ENV", "{}")))
    if workload == "mediumarrays":
        env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [FRAME + "/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return {"collector": name, "workload": workload, "rep": rep, "status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"collector": name, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode,
                "tail": r.stdout[-300:]}
    rec = json.load(open(path))
    rec.update(collector=name, rep=rep, workload=workload)
    rec["status"] = "ok" if rec.get("checksum") == SUM[workload] else "BAD_CHECKSUM"
    return rec


def main():
    outdir, reps = sys.argv[1], int(sys.argv[2])
    workloads = sys.argv[3].split(",") if len(sys.argv) > 3 else list(WORK)
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(50)
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(1, reps + 1):
            order = workloads[:]
            rng.shuffle(order)
            for w in order:
                names = list(ACTIVE)
                rng.shuffle(names)
                with open(LOCK, "a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    for c in names:
                        rec = run(c, w, rep, outdir)
                        f.write(json.dumps(rec) + "\n")
                        f.flush()
                        print(rep, w, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)),
                              round(rec.get("pause_ms", 0)), rec.get("collections"), rec.get("status", ""), flush=True)


main()
