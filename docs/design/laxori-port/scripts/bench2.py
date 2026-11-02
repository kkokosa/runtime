#!/usr/bin/env python3
"""Interleaved benchmark on frame-c4.
usage: bench2.py <outdir> <reps> <configs,comma> <workloads,comma>      (run it under: flock /tmp/lxr-bench.lock)
configs: wks, svr, satori, lxr, laxori:<mode>:<regionKB>   mode 0 = private tier off (the LXR engine of Laxori),
         1 = L1 (a region with an escaped object is not collected), 2 = L2 (escaped objects stay in place).
Prints the median of wall, CPU, pause, peak RSS and the private-tier counters. Every run is checked against the known checksum."""
import json, os, statistics, subprocess, sys

FRAME = os.environ.get("FRAME", "/root/prof/frame-c4")
DRIVER = os.environ.get("DRIVER", "/root/laxori/drv2/bin/CompareDriver.dll")
LAXORI = os.environ.get("LAXORI_SO", "/root/laxori/l1/libclrlaxorigc.so")
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUMS = {"requests": 27134172608, "binarytrees": 68332294, "listsuffix": 159636632672, "mixedmedium": 40586599707,
        "losarrays": 13936826922, "mediumarrays": 7032863679}
REGION = ["acquired", "dissolvedPause", "dissolvedFull", "dissolvedEscape", "dissolvedExit", "localCollections", "localSkipped",
          "markAborted", "notWorth", "survivorBytes", "reclaimedBytes", "escapeCalls", "escapedObjects", "escapedBytes", "foreign",
          "acquireFailures", "bulkEscapes"]


def config(name, workload):
    if name == "wks":
        return {"DOTNET_gcServer": "0"}
    if name == "svr":
        return {"DOTNET_gcServer": "1"}
    if name == "satori":
        return {"DOTNET_gcServer": "0", "DOTNET_GCPath": FRAME + "/libsatorigc.so"}
    if name == "lxr":
        e = {"DOTNET_gcServer": "1", "DOTNET_GCPath": FRAME + "/libclrlxrgc.so"}
        if workload == "mediumarrays":
            e.update({"DOTNET_LXRImmixInitialMB": "200", "DOTNET_LXRImmixReserveMB": "400"})
        return e
    if name.startswith("laxori:"):
        _, mode, kb = name.split(":")
        e = {"DOTNET_gcServer": "1", "DOTNET_GCPath": LAXORI, "DOTNET_LAXORIRegionKB": kb}
        if mode == "0":
            e["DOTNET_LAXORIPrivate"] = "0"
        else:
            e["DOTNET_LAXORIEscapedInPlace"] = "1" if mode == "2" else "0"
        if workload == "mediumarrays":
            e.update({"DOTNET_LAXORIImmixInitialMB": "200", "DOTNET_LAXORIImmixReserveMB": "400"})
        return e
    raise SystemExit("bad config " + name)


def run(name, workload, rep, outdir):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
    env.update(config(name, workload))
    size, ops = WORK[workload]
    rundir = os.path.join(outdir, f"{name.replace(':', '_')}-{workload}-{rep}")
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
    print("\nmedians: wall ms / cpu ms / pause ms / peak RSS MB / GCs / copied MB | TLGC / escaped MB / acquire failures")
    for w in workloads:
        for c in configs:
            ok = [r for r in rows[(w, c)] if "wall_ms" in r and r.get("status") is None]
            bad = len(rows[(w, c)]) - len(ok)
            if not ok:
                print(f"{w:12} {c:14} no successful run ({bad} failed)")
                continue
            m = lambda k: statistics.median(r[k] for r in ok)
            extra = ""
            if "region" in ok[0] and any(r["region"][0] for r in ok):
                tl = statistics.median(r["region"][5] for r in ok)
                esc = statistics.median(r["region"][13] for r in ok) / 1048576
                af = statistics.median(r["region"][15] for r in ok)
                extra = f" | {tl:7.0f} {esc:7.1f} {af:8.0f}"
            print(f"{w:12} {c:14} {m('wall_ms'):7.0f} {m('cpu_ms'):7.0f} {m('pause_ms'):6.0f} {m('peak_rss_mb'):6.0f} "
                  f"{m('total_collections'):5.0f} {m('lxr_copied_mb'):6.1f}{extra} n={len(ok)} bad={bad}")


main()
