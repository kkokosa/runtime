#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""P50 runner for the scaling cells: serial against parallel evacuation-set selection in one library.

usage: p50run.py <outdir> <reps> <set> [name-filter-substring ...]
sets: smoke 8a thr
A cell name is <set>-<mode>-live<MB>-cap<MB>; mode ser sets DOTNET_LXRSelectParallelBlocks=4294967295 (never parallel) and mode
par sets it to 0 (always parallel). Both run the same library (the P49 experiment build with the SelectMature phase timers).
Every run writes <outdir>/<cell>/<rep>/{result.json,pauses.csv,lxr-pauses.csv,stderr.txt,meta.json}.
Runs hold the shared lock /tmp/lxr-bench.lock one run at a time (the runs are long). The cells of one repetition are shuffled
and a serial cell and a parallel cell of the same size are always adjacent in the repetition (order inside the pair is random).
"""
import fcntl, json, os, random, subprocess, sys, time

FRAME = "/root/prof/frame-c4"
DRV = os.environ.get("P50_DRV", "/root/p49/drv/bin/ScalingDriver.dll")
LIB = os.environ.get("P50_LIB", "/root/p50/lib/libclrlxrgc-p50t.so")
LOCK = "/tmp/lxr-bench.lock"
MIX = ["2", "30", "300"]  # 0.2% range kills, 3% single replacements, spin 300 (as in P49)


def heap_env(cap_mb, mode, extra=None):
    env = {"DOTNET_LXRImmixInitialMB": str(cap_mb), "DOTNET_LXRImmixReserveMB": str(cap_mb),
           "DOTNET_LXRNativePlaneLimitMB": "200000", "DOTNET_LXRTraceThreshold": "2",
           "DOTNET_LXRSelectParallelBlocks": "4294967295" if mode == "ser" else "0",
           "DOTNET_gcServer": "1", "DOTNET_GCPath": LIB, "LXR_P49_TRACE": "1"}
    env.update(extra or {})
    return env


def cell(name, args, env, timeout, min_free_mb):
    return dict(name=name, args=[str(a) for a in args], env=env, timeout=timeout, min_free_mb=min_free_mb)


def pair(setname, live, cap, secs):
    """The serial and the parallel cell of one size (same seed, same workload)."""
    return [cell(f"{setname}-{mode}-live{live}-cap{cap}", ["bigheap", live, secs] + MIX, heap_env(cap, mode),
                 1800, cap + 3500) for mode in ("ser", "par")]


def groups_for(name):
    """List of groups; the two cells of a group run next to each other, the groups are shuffled."""
    if name == "smoke":
        return [pair("smoke", 200, 500, 8)]
    if name == "8a":
        return [pair("8a", live, cap, secs) for live, cap, secs in
                [(1000, 2400, 30), (4000, 8000, 45), (8000, 14500, 60), (16000, 21000, 90)]]
    if name == "thr":
        # small heaps: where does the hand-over to the workers start to pay (blocks in use about 3 000 to 80 000)
        return [pair("thr", live, cap, 20) for live, cap in
                [(40, 400), (80, 500), (150, 700), (250, 900), (500, 1500), (800, 2200)]]
    if name == "thr2":
        # very small heaps (capacity 3 000 to 7 600 blocks)
        return [pair("thr", live, cap, 20) for live, cap in [(5, 100), (10, 150), (20, 250)]]
    raise SystemExit("unknown set " + name)


def mem_available_mb():
    for line in open("/proc/meminfo"):
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) // 1024
    return 0


def run_one(c, outdir, rep):
    d = os.path.join(outdir, c["name"], str(rep))
    if os.path.exists(os.path.join(d, "result.json")):
        return
    os.makedirs(d, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_", "LXR_"))}
    env.update(c["env"])
    env["LXR_P49_TRACE_FILE"] = os.path.join(d, "lxr-pauses.csv")
    cmd = ["timeout", str(c["timeout"]), FRAME + "/corerun", DRV, d] + c["args"]
    waited = 0
    while c["min_free_mb"] and mem_available_mb() < c["min_free_mb"] and waited < 3600:
        time.sleep(30)
        waited += 30
    t_lock = time.time()
    with open(LOCK, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        meta = dict(cmd=cmd, load=open("/proc/loadavg").read().strip(), avail_mb=mem_available_mb(), waited_s=waited,
                    lock_wait_s=time.time() - t_lock,
                    env={k: v for k, v in env.items() if k.startswith(("DOTNET_", "LXR_"))}, started=time.time())
        t0 = time.time()
        with open(os.path.join(d, "stderr.txt"), "w") as err:
            p = subprocess.run(cmd, env=env, stdout=err, stderr=subprocess.STDOUT)
        meta.update(rc=p.returncode, elapsed_s=time.time() - t0)
    json.dump(meta, open(os.path.join(d, "meta.json"), "w"))
    status = "ok" if os.path.exists(os.path.join(d, "result.json")) else f"FAIL rc={p.returncode}"
    print(f"{time.strftime('%H:%M:%S')} {c['name']} rep{rep} {status} {meta['elapsed_s']:.0f}s", flush=True)
    time.sleep(2)


def main():
    outdir, reps, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    filters = sys.argv[4:]
    groups = [g for g in groups_for(name) if not filters or any(f in g[0]["name"] for f in filters)]
    rng = random.Random(int(os.environ.get("P50_SEED", "50")))
    for rep in range(reps):
        order = groups[:]
        rng.shuffle(order)
        for g in order:
            g = g[:]
            rng.shuffle(g)
            for c in g:
                run_one(c, outdir, rep)


main()
