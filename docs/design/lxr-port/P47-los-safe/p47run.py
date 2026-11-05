#!/usr/bin/env python3
"""P47 benchmark runner (from P44's p44run.py). Interleaved runs, shuffled order of the configurations in every repetition. Every
single run takes the shared lock /tmp/lxr-bench.lock, so no other session runs a benchmark at the same time.

usage: p47run.py <outdir> <reps> "<config>;<config>;..." <workloads,comma> [seed]

A config is  <lib>[:VAR=value[,VAR=value...]]  where <lib> is a directory name under P47_LIBS that holds a libclrlxrgc.so
(base: the library of lxr-gc-review 9664cfe78cb, new: this change). The variables are set in the environment of the run. Examples:
base   new   new:LXR_LOS_LEGACY_WALKS=1   new:LXR_LOS_VALIDATE=1
Environment: P47_ENV=VAR=value,... adds variables to every run.
"""
import fcntl, json, os, random, subprocess, sys

FRAME = "/root/prof/frame-c4"
DRIVER = os.environ.get("P47_DRIVER", "/root/los-safe/drv/bin/CompareDriver.dll")
LIBROOT = os.environ.get("P47_LIBS", "/root/los-safe/libs")
class _Libs(dict):
    def __missing__(self, key):
        return LIBROOT + "/" + key + "/libclrlxrgc.so"


LIBS = _Libs()
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000),
        "losmany": (2000, 60000)}
SUM = {"binarytrees": 68332294, "requests": 27134172608, "listsuffix": 159636632672,
       "mediumarrays": 7032863679, "mixedmedium": 40586599707, "losarrays": 13936826922, "losmany": 42674603309}
LOCK = "/tmp/lxr-bench.lock"
# P47_HOLD_LOCK=1: the caller holds the lock for the whole batch (flock /tmp/lxr-bench.lock python3 p47run.py ...), so a batch
# is not interleaved with the runs of other sessions.
HOLD_LOCK = bool(os.environ.get("P47_HOLD_LOCK"))


def parse(name):
    lib, _, rest = name.partition(":")
    extra = {}
    if rest:
        for kv in rest.split(","):
            k, _, v = kv.partition("=")
            extra[k] = v
    return lib, extra


def run(name, workload, rep, outdir, extra_env):
    lib, extra = parse(name)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_", "LXR_EXP_", "LXR_LOS_", "DRV_", "P47_"))}
    env.update({"DOTNET_gcServer": "1", "DOTNET_GCPath": LIBS[lib]})
    if workload == "mediumarrays":
        env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
    if workload == "losmany":
        env["DOTNET_LXRLOSInitialMB"], env["DOTNET_LXRLOSReserveMB"] = "1000", "1600"; env["DOTNET_LXRNativePlaneLimitMB"] = "16000"
    env.update(extra)
    env.update(extra_env)
    size, ops = WORK[workload]
    tag = name.replace(":", "_").replace("=", "").replace(",", "_")
    rundir = os.path.join(outdir, f"{tag}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [FRAME + "/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    with open(LOCK, "w") as lock:
        if not HOLD_LOCK:
            fcntl.flock(lock, fcntl.LOCK_EX)
        load1 = os.getloadavg()[0]
        try:
            r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            return {"collector": name, "workload": workload, "rep": rep, "status": "timeout"}
        finally:
            if not HOLD_LOCK:
                fcntl.flock(lock, fcntl.LOCK_UN)
    open(os.path.join(rundir, "stderr.txt"), "w").write(r.stderr)
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"collector": name, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode,
                "tail": (r.stdout + r.stderr)[-300:]}
    rec = json.load(open(path))
    rec.update(collector=name, rep=rep, workload=workload, load1=load1)
    want = SUM.get(workload)
    rec["status"] = "ok" if (want is None or rec.get("checksum") == want) else "BAD_CHECKSUM"
    return rec


def main():
    outdir, reps = sys.argv[1], int(sys.argv[2])
    configs, workloads = sys.argv[3].split(";"), sys.argv[4].split(",")
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 44
    extra_env = {}
    for kv in os.environ.get("P47_ENV", "").split(","):
        if kv:
            k, _, v = kv.partition("=")
            extra_env[k] = v
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(seed)
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(1, reps + 1):
            for w in workloads:
                order = configs[:]
                rng.shuffle(order)
                for c in order:
                    rec = run(c, w, rep, outdir, extra_env)
                    f.write(json.dumps(rec) + "\n")
                    f.flush()
                    print(rep, w, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)), round(rec.get("pause_ms", 0)),
                          rec.get("collections"), rec.get("status", ""), flush=True)


main()
