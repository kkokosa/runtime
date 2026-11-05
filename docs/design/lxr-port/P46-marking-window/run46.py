#!/usr/bin/env python3
"""P46 benchmark runner. Interleaved, shuffled order per rep. One rep (all workloads and configs) runs while the process holds /tmp/lxr-bench.lock
(flock), so no run of another session overlaps with a run of this one.
usage: run46.py <outdir> <reps> <configs,comma> <workloads,comma>
config = <lib>[-tr<N>]  lib: a name in LIBS; -tr<N> sets DOTNET_LXRTraceThreshold=<N> (decimal, forces traces when N is low).
A config that starts with 'diag' also sets DOTNET_LXRWindowStats=1 and keeps the last LXRWINDOW line of stderr."""
import fcntl, json, os, random, re, subprocess, sys

FRAME = "/root/prof/frame-c4"
DRIVER = "/root/prof/drv/bin/CompareDriver.dll"
LIBDIR = "/root/p46/libs"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUM = {"binarytrees": 68332294, "requests": 27134172608, "listsuffix": 159636632672,
       "mediumarrays": 7032863679, "mixedmedium": 40586599707, "losarrays": 13936826922}


def config(name, workload):
    lib, _, tr = name.partition("-tr")
    env = {"DOTNET_gcServer": "1", "DOTNET_GCPath": f"{LIBDIR}/{lib}.so"}
    if workload == "mediumarrays":
        env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
    if tr:
        env["DOTNET_LXRTraceThreshold"] = tr
    if lib.startswith("diag"):
        env["DOTNET_LXRWindowStats"] = "1"
    return env


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name, workload))
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [FRAME + "/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return {"collector": name, "workload": workload, "rep": rep, "status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"collector": name, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode,
                "tail": (r.stdout + r.stderr)[-300:]}
    rec = json.load(open(path))
    rec.update(collector=name, rep=rep, workload=workload)
    rec["status"] = "ok" if rec.get("checksum") == SUM[workload] else "BAD_CHECKSUM"
    lines = [l for l in r.stderr.splitlines() if l.startswith("LXRWINDOW")]
    if lines:
        rec["window"] = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", lines[-1])}
        rec["window_lines"] = len(lines)
    return rec


def main():
    outdir, reps = sys.argv[1], int(sys.argv[2])
    configs, workloads = sys.argv[3].split(","), sys.argv[4].split(",")
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(46)
    lock = open("/tmp/lxr-bench.lock", "a")
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(1, reps + 1):
            plan = []
            for w in workloads:
                order = configs[:]
                rng.shuffle(order)
                plan += [(w, c) for c in order]
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                for w, c in plan:
                    rec = run(c, w, rep, outdir)
                    f.write(json.dumps(rec) + "\n")
                    f.flush()
                    print(rep, w, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)), round(rec.get("pause_ms", 0)),
                          rec.get("collections"), round(rec.get("peak_rss_mb", 0)), rec.get("status", ""), flush=True)
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)


main()
