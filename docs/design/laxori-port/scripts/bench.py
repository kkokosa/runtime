#!/usr/bin/env python3
"""Interleaved benchmark: bench.py <outdir> <reps> <configs,comma> <workloads,comma>. Run it under flock /tmp/lxr-bench.lock."""
import json, os, statistics, subprocess, sys

FRAME = "/root/prof/frame-p"
DRIVER = "/root/laxori/drv/bin/CompareDriver.dll"
LAXORI = os.environ.get("LAXORI_SO", "/root/laxori/m1/libclrlaxorigc.so")
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}


def config(name):
    if name == "wks":
        return {"DOTNET_gcServer": "0"}
    if name == "svr":
        return {"DOTNET_gcServer": "1"}
    if name == "satori":
        return {"DOTNET_gcServer": "0", "DOTNET_GCPath": FRAME + "/libsatorigc.so"}
    if name == "lxr":
        return {"DOTNET_gcServer": "1", "DOTNET_GCPath": FRAME + "/libclrlxrgc.so"}
    if name == "laxori0":   # Laxori engine, requests off (the hooks are no-ops)
        return {"DOTNET_gcServer": "1", "DOTNET_GCPath": LAXORI, "DOTNET_LAXORIRequests": "0"}
    if name == "laxori1":   # Laxori with request regions
        return {"DOTNET_gcServer": "1", "DOTNET_GCPath": LAXORI, "DOTNET_LAXORIRequests": "1"}
    raise SystemExit("bad config " + name)


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name))
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [f"{FRAME}/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"status": "failed", "rc": r.returncode, "tail": r.stdout[-200:]}
    return json.load(open(path))


def main():
    outdir, reps, configs, workloads = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(","), sys.argv[4].split(",")
    os.makedirs(outdir, exist_ok=True)
    rows = {}
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(reps):
            for w in workloads:
                for c in configs:
                    rec = run(c, w, rep, outdir)
                    rec.update(collector=c, workload=w, rep=rep)
                    f.write(json.dumps(rec) + "\n"); f.flush()
                    rows.setdefault((w, c), []).append(rec)
                    print(rep, w, c, round(rec.get("wall_ms", 0)), rec.get("checksum", ""), rec.get("status", ""), flush=True)
    print("\nmedians (wall ms / cpu ms / pause ms / peak RSS MB / checksum)")
    for w in workloads:
        for c in configs:
            ok = [r for r in rows[(w, c)] if "wall_ms" in r]
            if not ok:
                print(f"{w:12} {c:8} no successful run ({len(rows[(w, c)])} failed)")
                continue
            m = lambda k: statistics.median(r[k] for r in ok)
            sums = {r["checksum"] for r in ok}
            print(f"{w:12} {c:8} {m('wall_ms'):8.0f} {m('cpu_ms'):8.0f} {m('pause_ms'):7.0f} {m('peak_rss_mb'):7.0f} {sorted(sums)} n={len(ok)}/{len(rows[(w, c)])}")


main()
