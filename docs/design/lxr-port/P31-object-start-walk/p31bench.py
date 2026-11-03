#!/usr/bin/env python3
"""P31 benchmark: the ValidObject variant (base) against the walk variant, interleaved.
usage: p31bench.py <outdir> <reps> <workloads> [configs=base,walk] [extra env KEY=VAL ...]
Frames: /root/p31/frame-base and /root/p31/frame-walk (libclrlxrgc.so in each). Run it under flock /tmp/lxr-bench.lock."""
import json, os, statistics, subprocess, sys

DRIVER = "/root/prof/drv/bin/CompareDriver.dll"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUMS = {"requests": "27134172608", "binarytrees": "68332294", "listsuffix": "159636632672",
        "mixedmedium": "40586599707", "losarrays": "13936826922", "mediumarrays": "7032863679"}


def run(config, workload, rep, outdir, extra):
    frame = "/root/p31/frame-" + config
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update({"DOTNET_gcServer": "1", "DOTNET_GCPath": frame + "/libclrlxrgc.so", "DOTNET_EnableWriteXorExecute": "0"})
    if workload == "mediumarrays":
        env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
    env.update(extra)
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{config}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [frame + "/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return {"config": config, "workload": workload, "rep": rep, "status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"config": config, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode,
                "tail": (r.stdout + r.stderr)[-300:]}
    rec = json.load(open(path))
    rec.update(config=config, workload=workload, rep=rep, status="ok")
    if "DOTNET_LXRLookupStats" in extra:
        open(os.path.join(rundir, "stderr.txt"), "w").write(r.stderr)
    return rec


def main():
    outdir, reps = sys.argv[1], int(sys.argv[2])
    workloads = sys.argv[3].split(",")
    configs = sys.argv[4].split(",") if len(sys.argv) > 4 and "=" not in sys.argv[4] else ["base", "walk"]
    extra = dict(a.split("=", 1) for a in sys.argv[4:] if "=" in a)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(1, reps + 1):
            for w in workloads:
                order = configs if rep % 2 == 1 else list(reversed(configs))
                for c in order:
                    rec = run(c, w, rep, outdir, extra)
                    if rec.get("status") == "ok" and str(rec.get("checksum")) != SUMS[w]:
                        rec["status"] = "BADSUM"
                    f.write(json.dumps(rec) + "\n")
                    f.flush()
                    print(rep, w, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)), round(rec.get("pause_ms", 0)),
                          rec.get("collections"), round(rec.get("peak_rss_mb", 0)), rec.get("checksum", ""), rec.get("status"), flush=True)


main()