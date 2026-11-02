#!/usr/bin/env python3
"""Pause statistics (count, p50, p99, max, sum) from the GC suspend/restart events of the runtime (DRV_PAUSES=1 in the driver).
usage: pause.py <outdir> <reps> <configs,comma> <workloads,comma>      (configs as in bench2.py; run it under flock /tmp/lxr-bench.lock)"""
import csv, json, os, statistics, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location("bench2", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench2.py"))
src = open(spec.origin).read().replace("\nmain()\n", "\n")
ns = {}
exec(compile(src, "bench2.py", "exec"), ns)
config, WORK, SUMS, FRAME, DRIVER = ns["config"], ns["WORK"], ns["SUMS"], ns["FRAME"], ns["DRIVER"]


def one(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name, workload))
    env["DRV_PAUSES"] = "1"
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name.replace(':', '_')}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    r = subprocess.run([f"{FRAME}/corerun", DRIVER, rundir, workload, str(size), str(ops)], env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=300)
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return None
    res = json.load(open(path))
    pauses = []
    p = os.path.join(rundir, "pauses.csv")
    if os.path.exists(p):
        pauses = [float(row["duration_ms"]) for row in csv.DictReader(open(p))]
    return res, pauses


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))] if values else float("nan")


def main():
    outdir, reps, configs, workloads = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(","), sys.argv[4].split(",")
    print(f"{'workload':12} {'config':14} {'pauses/run':>10} {'p50 ms':>8} {'p99 ms':>8} {'max ms':>8} {'sum ms':>8} {'wall ms':>8} checksum")
    for w in workloads:
        for c in configs:
            allp, counts, sums, walls, ok = [], [], [], [], True
            for rep in range(reps):
                r = one(c, w, rep, outdir)
                if r is None:
                    ok = False
                    continue
                res, pauses = r
                ok = ok and res["checksum"] == SUMS[w]
                allp += pauses
                counts.append(len(pauses))
                sums.append(sum(pauses))
                walls.append(res["wall_ms"])
            if not counts:
                print(f"{w:12} {c:14} FAILED")
                continue
            print(f"{w:12} {c:14} {statistics.mean(counts):10.1f} {pct(allp, .5):8.3f} {pct(allp, .99):8.3f} {max(allp) if allp else float('nan'):8.3f} "
                  f"{statistics.mean(sums):8.1f} {statistics.median(walls):8.0f} {'OK' if ok else 'WRONG'}", flush=True)


main()
