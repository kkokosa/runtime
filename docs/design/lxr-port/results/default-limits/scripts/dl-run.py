#!/usr/bin/env python3
"""Default-limits A/B runner. One block = one repetition of one workload with all configs (shuffled), under one flock.
usage: dl-run.py <outdir> <rep> <workload> <config,config,...>
config = <label>  with entries in CONFIGS below (library + extra environment)."""
import json, os, random, subprocess, sys, time, fcntl

FRAME = "/root/prof/frame-c4"
DRIVER = "/root/prof/drv/bin/CompareDriver.dll"
LIBS = "/root/dl/libs"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000),
        "losmany": (2000, 60000)}
SUM = {"binarytrees": 68332294, "requests": 27134172608, "listsuffix": 159636632672,
       "mediumarrays": 7032863679, "mixedmedium": 40586599707, "losarrays": 13936826922,
       "losmany": 42674603309}
# label -> (library file, extra env)
CONFIGS = {
    "old": ("libclrlxrgc-old.so", {}),
    "new": ("libclrlxrgc-new.so", {}),
    "prev": ("libclrlxrgc-prev.so", {}),
    "fix": ("libclrlxrgc-fix.so", {}),
    "newbig": ("libclrlxrgc-new.so", {"DOTNET_LXRImmixReserveMB": "60000", "DOTNET_LXRNativePlaneLimitMB": "250000"}),
    "oldbig": ("libclrlxrgc-old.so", {"DOTNET_LXRImmixReserveMB": "60000", "DOTNET_LXRNativePlaneLimitMB": "250000"}),
    "newlos256": ("libclrlxrgc-new.so", {"DOTNET_LXRLOSReserveMB": "256"}),
    "newr128": ("libclrlxrgc-new.so", {"DOTNET_LXRImmixReserveMB": "128"}),
}
MEDIUM = {"DOTNET_LXRImmixInitialMB": "200", "DOTNET_LXRImmixReserveMB": "400"}
LOSMANY = {"DOTNET_LXRLOSInitialMB": "1000", "DOTNET_LXRLOSReserveMB": "1600", "DOTNET_LXRNativePlaneLimitMB": "16000"}


def run(label, workload, rep, outdir, extra):
    lib, env_extra = CONFIGS[label]
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env["DOTNET_gcServer"] = "1"
    env["DOTNET_GCPath"] = os.path.join(LIBS, lib)
    if workload == "mediumarrays" and extra == "asrun":
        env.update(MEDIUM)
    if workload == "losmany" and extra == "asrun":
        env.update(LOSMANY)
    env.update(env_extra)
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{label}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    driver = "/root/p44/drv/bin/CompareDriver.dll" if workload == "losmany" else DRIVER
    cmd = [FRAME + "/corerun", driver, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return {"label": label, "workload": workload, "rep": rep, "status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"label": label, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode,
                "tail": r.stdout[-300:]}
    rec = json.load(open(path))
    rec.update(label=label, rep=rep, workload=workload)
    rec["status"] = "ok" if rec.get("checksum") == SUM[workload] else "BAD_CHECKSUM"
    return rec


def main():
    outdir, rep, workload, configs = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4].split(",")
    extra = sys.argv[5] if len(sys.argv) > 5 else "asrun"
    os.makedirs(outdir, exist_ok=True)
    order = configs[:]
    random.Random(rep * 1000 + hash(workload) % 1000).shuffle(order)
    with open("/tmp/lxr-bench.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
                for c in order:
                    rec = run(c, workload, rep, outdir, extra)
                    f.write(json.dumps(rec) + "\n")
                    f.flush()
                    print(rep, workload, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)),
                          round(rec.get("pause_ms", 0)), rec.get("collections"), round(rec.get("peak_rss_mb", 0)),
                          rec.get("status", ""), flush=True)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
    time.sleep(8)


main()
