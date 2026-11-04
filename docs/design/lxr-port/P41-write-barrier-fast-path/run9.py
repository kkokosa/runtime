#!/usr/bin/env python3
"""Interleaved runner for the write-barrier variants. Shuffled order per workload and repetition.
usage: run9.py <outdir> <reps> <variants,comma> <workloads,comma>
A variant name X is the library /root/wb/X/libclrlxrgc.so; "wks" and "svr" are the stock collectors."""
import json, os, random, subprocess, sys

FRAME = "/root/prof/frame-c4"
DRIVER = "/root/prof/drv/bin/CompareDriver.dll"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUM = {"binarytrees": 68332294, "requests": 27134172608, "listsuffix": 159636632672,
       "mediumarrays": 7032863679, "mixedmedium": 40586599707, "losarrays": 13936826922}


def config(name, workload):
    if name == "wks":
        return {"DOTNET_gcServer": "0"}
    if name == "svr":
        return {"DOTNET_gcServer": "1"}
    env = {"DOTNET_gcServer": "1", "DOTNET_GCPath": "/root/wb/%s/libclrlxrgc.so" % name}
    if workload == "mediumarrays":
        env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
    return env


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name, workload))
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, "%s-%s-%d" % (name, workload, rep))
    os.makedirs(rundir, exist_ok=True)
    cmd = [FRAME + "/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return {"collector": name, "workload": workload, "rep": rep, "status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"collector": name, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode, "tail": r.stdout[-300:]}
    rec = json.load(open(path))
    rec.update(collector=name, rep=rep, workload=workload)
    rec["status"] = "ok" if rec.get("checksum") == SUM[workload] else "BAD_CHECKSUM"
    return rec


def main():
    outdir, reps = sys.argv[1], int(sys.argv[2])
    configs, workloads = sys.argv[3].split(","), sys.argv[4].split(",")
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(9)
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(1, reps + 1):
            for w in workloads:
                order = configs[:]
                rng.shuffle(order)
                for c in order:
                    rec = run(c, w, rep, outdir)
                    f.write(json.dumps(rec) + "\n")
                    f.flush()
                    print(rep, w, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)), round(rec.get("pause_ms", 0)),
                          rec.get("collections"), rec.get("status", ""), flush=True)


main()
