#!/usr/bin/env python3
"""Interleaved benchmark with paired differences, on a frame such as /root/prof/frame-c4 (run it under: flock /tmp/lxr-bench.lock).
usage: bench3.py <outdir> <reps> <configs,comma> <workloads,comma> [<pairA>:<pairB>,...]
configs (the .so paths come from the environment, see SO below):
  laxori-walk   the Laxori count-plane build (default variant)     LAXORI_SO_WALK
  laxori-bitmap the Laxori ValidObject-bitmap build                LAXORI_SO_BITMAP
  lxr-walk      the LXR count-plane build (P31)                    LXR_SO_WALK
  lxr-bitmap    the LXR ValidObject-bitmap build                   LXR_SO_BITMAP
  wks, svr, satori
Laxori runs use the default private tier (L2, 256 KiB regions, server GC mode like the LXR runs).
Every run is checked against the known checksum. After the runs the script prints the median of every metric, and for every pair A:B
the median of the paired difference (A - B) / B per repetition, the number of repetitions in which A is lower, and the range."""
import json, os, random, statistics, subprocess, sys

FRAME = os.environ.get("FRAME", "/root/prof/frame-c4")
DRIVER = os.environ.get("DRIVER", "/root/laxori/drv2/bin/CompareDriver.dll")
SO = {
    "laxori-walk": os.environ.get("LAXORI_SO_WALK", "/root/laxori/v/libclrlaxorigc-count.so"),
    "laxori-bitmap": os.environ.get("LAXORI_SO_BITMAP", "/root/laxori/v/libclrlaxorigc-bitmap.so"),
    "laxori-walk-i1": os.environ.get("LAXORI_SO_WALK_I1", "/root/laxori/v/libclrlaxorigc-count-i1.so"),
    "laxori-bitmap-i1": os.environ.get("LAXORI_SO_BITMAP_I1", "/root/laxori/v/libclrlaxorigc-bitmap-i1.so"),
    "lxr-walk": os.environ.get("LXR_SO_WALK", "/root/p31/so/libclrlxrgc-walk.so"),
    "lxr-bitmap": os.environ.get("LXR_SO_BITMAP", "/root/p31/so/libclrlxrgc-base.so"),
}
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000), "losmany": (2000, 60000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUMS = {"requests": 27134172608, "binarytrees": 68332294, "listsuffix": 159636632672, "mixedmedium": 40586599707,
        "losarrays": 13936826922, "mediumarrays": 7032863679, "losmany": 42674603309}
METRICS = [("wall_ms", "wall ms"), ("cpu_ms", "cpu ms"), ("pause_ms", "pause ms"), ("peak_rss_mb", "rss MB")]


def so_path(name):
    """A name like laxori-count-b or laxori-bitmap-c is /root/laxori/v/libclrlaxorigc-<variant>-<tag>.so (a tagged build copy)."""
    if name in SO:
        return SO[name]
    parts = name.split("-")
    if len(parts) == 3 and parts[0] == "laxori":
        return f"/root/laxori/v/libclrlaxorigc-{parts[1]}-{parts[2]}.so"
    raise SystemExit("bad config " + name)


def config(name, workload):
    if name == "wks":
        return {"DOTNET_gcServer": "0"}
    if name == "svr":
        return {"DOTNET_gcServer": "1"}
    if name == "satori":
        return {"DOTNET_gcServer": "0", "DOTNET_GCPath": FRAME + "/libsatorigc.so"}
    prefix = "LAXORI" if name.startswith("laxori") else "LXR"
    e = {"DOTNET_gcServer": "1", "DOTNET_GCPath": so_path(name)}
    if workload == "mediumarrays":
        e.update({f"DOTNET_{prefix}ImmixInitialMB": "200", f"DOTNET_{prefix}ImmixReserveMB": "400"})
    if workload == "losmany":
        e.update({f"DOTNET_{prefix}LOSInitialMB": "1000", f"DOTNET_{prefix}LOSReserveMB": "1600", f"DOTNET_{prefix}NativePlaneLimitMB": "16000"})
    return e


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name, workload))
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name}-{workload}-{rep}")
    os.makedirs(rundir, exist_ok=True)
    cmd = [f"{FRAME}/corerun", DRIVER, rundir, workload, str(size), str(ops)]
    try:
        r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    path = os.path.join(rundir, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        return {"status": "failed", "rc": r.returncode, "tail": r.stdout[-300:]}
    rec = json.load(open(path))
    if rec["checksum"] != SUMS[workload]:
        rec["status"] = "WRONG CHECKSUM"
    return rec


def main():
    outdir, reps, configs, workloads = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(","), sys.argv[4].split(",")
    pairs = [p.split(":") for p in sys.argv[5].split(",")] if len(sys.argv) > 5 else []
    os.makedirs(outdir, exist_ok=True)
    rows = {}
    with open(os.path.join(outdir, "runs.jsonl"), "a") as f:
        for rep in range(reps):
            for w in workloads:
                for c in configs:
                    rec = run(c, w, rep, outdir)
                    rec.update(collector=c, workload=w, rep=rep)
                    f.write(json.dumps(rec) + "\n"); f.flush()
                    rows.setdefault((w, c), {})[rep] = rec
                    print(rep, w, c, round(rec.get("wall_ms", 0)), rec.get("checksum", ""), rec.get("status", ""), flush=True)
    summarize(rows, configs, workloads, pairs)


def good(rec):
    return "wall_ms" in rec and rec.get("status") is None


def summarize(rows, configs, workloads, pairs):
    print("\nmedians: wall ms / cpu ms / pause ms / peak RSS MB / collections")
    for w in workloads:
        for c in configs:
            ok = [r for r in rows[(w, c)].values() if good(r)]
            bad = len(rows[(w, c)]) - len(ok)
            if not ok:
                print(f"{w:12} {c:14} no successful run ({bad} failed)")
                continue
            m = lambda k: statistics.median(r[k] for r in ok)
            print(f"{w:12} {c:14} {m('wall_ms'):7.0f} {m('cpu_ms'):7.0f} {m('pause_ms'):6.0f} {m('peak_rss_mb'):6.0f} "
                  f"{m('total_collections'):5.0f} n={len(ok)} bad={bad}")
    for a, b in pairs:
        print(f"\npaired difference (A-B)/B in percent, A={a} B={b}: median [min .. max], reps where A is lower")
        for w in workloads:
            line = f"{w:12}"
            for key, label in METRICS:
                d = []
                for rep, ra in rows[(w, a)].items():
                    rb = rows[(w, b)].get(rep)
                    if rb and good(ra) and good(rb) and rb[key]:
                        d.append((ra[key] - rb[key]) * 100.0 / rb[key])
                if d:
                    lower = sum(1 for x in d if x < 0)
                    lo, hi = bootstrap(d)
                    line += (f" | {label} {statistics.median(d):+6.1f} CI95 [{lo:+5.1f}, {hi:+5.1f}] "
                             f"[{min(d):+5.1f}..{max(d):+5.1f}] {lower}/{len(d)}")
            print(line)


def bootstrap(values, rounds=4000, seed=12345):
    """95 percent bootstrap interval of the median of the paired differences."""
    rng = random.Random(seed)
    n = len(values)
    meds = sorted(statistics.median(rng.choices(values, k=n)) for _ in range(rounds))
    return meds[int(rounds * 0.025)], meds[int(rounds * 0.975)]


main()
