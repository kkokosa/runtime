#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Interleaved A/B runner and paired analysis for the locality-batching-2 study (task 3).
usage: run-ab2.py run <outdir> <reps> <configs.json> <workload,workload,...> [--seed N] [--timeout S]
       run-ab2.py analyze <ref-config> <outdir> [<outdir> ...] [--cfgs a,b,c] [--tsv]

configs.json: {"off": {"so": "/root/k2/lib/exp.so", "env": {}}, "S2": {"so": ..., "env": {"LAXORI_EXP_PF": "S2"}}, ...}
Each repetition of each workload runs every configuration once, in a shuffled order, under one hold of `flock /tmp/lxr-bench.lock`.
analyze: for every workload, configuration and metric the paired difference (variant - ref) / ref in percent for each repetition; the median of
the pairs and the 95 percent bootstrap interval of the median (10 000 resamples)."""
import json, os, random, statistics, subprocess, sys, time
try:
    import fcntl
except ImportError:     # the analyzer also runs on Windows
    fcntl = None

FRAME = "/root/prof/frame-c4"
DRIVER = "/root/laxori/drv2/bin/CompareDriver.dll"
WORK = {"requests": (8192, 200000), "binarytrees": (18, 1), "listsuffix": (8192, 600000), "mixedmedium": (12000, 200000),
        "losarrays": (1500, 100000), "mediumarrays": (20000, 300000),
        "listsuffix-big": (32768, 300000), "binarytrees-20": (20, 1)}
SUM = {"requests": 27134172608, "binarytrees": 68332294, "listsuffix": 159636632672, "mixedmedium": 40586599707,
       "losarrays": 13936826922, "mediumarrays": 7032863679}
LOCK = "/tmp/lxr-bench.lock"


def workload_env(workload):
    env = {}
    if workload == "mediumarrays":
        env["DOTNET_LAXORIImmixInitialMB"], env["DOTNET_LAXORIImmixReserveMB"] = "200", "400"
    if workload == "binarytrees-20":
        env["DOTNET_LAXORIImmixInitialMB"], env["DOTNET_LAXORIImmixReserveMB"] = "800", "2000"
    return env


def run_one(name, cfg, workload, outdir, rep, timeout):
    env = {"HOME": "/root", "PATH": "/usr/bin:/bin", "DOTNET_gcServer": "1", "DOTNET_GCPath": cfg["so"]}
    env.update(workload_env(workload))
    env.update(cfg.get("env", {}))
    base = workload.split("-")[0]
    size, ops = WORK[workload]
    d = os.path.join(outdir, f"{name}-{workload}-{rep}")
    os.makedirs(d, exist_ok=True)
    try:
        r = subprocess.run([FRAME + "/corerun", DRIVER, d, base, str(size), str(ops)], env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"cfg": name, "workload": workload, "rep": rep, "status": "timeout"}
    path = os.path.join(d, "result.json")
    if r.returncode != 0 or not os.path.exists(path):
        open(os.path.join(d, "stdout.txt"), "w").write(r.stdout[-4000:])
        return {"cfg": name, "workload": workload, "rep": rep, "status": "failed", "rc": r.returncode}
    rec = json.load(open(path))
    rec = {k: rec[k] for k in ("wall_ms", "cpu_ms", "pause_ms", "checksum", "collections") if k in rec}
    rec.update(cfg=name, workload=workload, rep=rep, status="ok")
    if workload in SUM and rec["checksum"] != SUM[workload]:
        rec["status"] = "BAD_CHECKSUM"
    return rec


def run(outdir, reps, configs, workloads, seed, timeout, start=1):
    os.makedirs(outdir, exist_ok=True)
    rng = random.Random(seed + start)
    names = list(configs)
    fd = open(LOCK, "a")
    first_sum = {}
    done = {}
    path = os.path.join(outdir, "runs.jsonl")
    if os.path.exists(path):
        for l in open(path):
            try:
                r = json.loads(l)
            except ValueError:
                continue    # a truncated line of an interrupted run: the block is redone
            done.setdefault((r["workload"], r["rep"]), set()).add(r["cfg"])
    with open(path, "a") as f:
        for rep in range(start, reps + 1):
            for w in workloads:
                if done.get((w, rep), set()) >= set(names):
                    continue    # resume: a finished block stays
                if (w, rep) in done:
                    # a partly finished block is redone as a whole (its configurations must be interleaved): drop its records
                    f.close()
                    keep = [l for l in open(path) if not (json.loads(l)["workload"] == w and json.loads(l)["rep"] == rep)]
                    open(path, "w").writelines(keep)
                    f = open(path, "a")
                # one lock hold for one block (one repetition of one workload, all configurations shuffled), then a pause so that
                # waiting jobs can take the lock (flock is not FIFO: a tight re-acquire loop starves them)
                order = names[:]
                rng.shuffle(order)
                fcntl.flock(fd, fcntl.LOCK_EX)
                try:
                    for c in order:
                        rec = run_one(c, configs[c], w, outdir, rep, timeout)
                        if rec.get("status") == "ok" and w not in SUM:
                            if w not in first_sum:
                                first_sum[w] = rec["checksum"]
                            elif first_sum[w] != rec["checksum"]:
                                rec["status"] = "BAD_CHECKSUM"
                        f.write(json.dumps(rec) + "\n")
                        f.flush()
                        print(rep, w, c, round(rec.get("wall_ms", 0)), round(rec.get("cpu_ms", 0)), round(rec.get("pause_ms", 0)),
                              rec.get("status"), flush=True)
                finally:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                time.sleep(8)


def bootstrap_median(values, rng, n=10000):
    meds = []
    for _ in range(n):
        meds.append(statistics.median(rng.choices(values, k=len(values))))
    meds.sort()
    return meds[int(0.025 * n)], meds[int(0.975 * n)]


def analyze(ref, outdirs, only=None, tsv=False):
    recs = []
    for i, outdir in enumerate(outdirs):
        for l in open(os.path.join(outdir, "runs.jsonl")):
            r = json.loads(l)
            r["rep"] = f"{i}:{r['rep']}"
            recs.append(r)
    rng = random.Random(7)
    by = {}
    for r in recs:
        by.setdefault((r["workload"], r["rep"]), {})[r["cfg"]] = r
    bad = [r for r in recs if r.get("status") not in ("ok",)]
    for r in bad:
        print(f"# NOT OK: {r['workload']} {r['cfg']} rep {r['rep']}: {r.get('status')}", file=sys.stderr)
    cfgs = sorted({r["cfg"] for r in recs} - {ref}) if only is None else only
    if not tsv:
        print("| workload | variant | metric | median paired difference % against " + ref +
              " | 95% bootstrap interval of the median | runs with the variant lower | pairs | median " + ref + " | median variant |")
        print("|---|---|---|---|---|---|---|---|---|")
    for w in sorted({r["workload"] for r in recs}):
        for v in cfgs:
            for metric in ("wall_ms", "cpu_ms", "pause_ms"):
                diffs, refs, vals = [], [], []
                for (ww, rep), c in by.items():
                    if ww != w or v not in c or ref not in c or c[v].get("status") != "ok" or c[ref].get("status") != "ok":
                        continue
                    a, b = c[ref][metric], c[v][metric]
                    if a > 0:
                        diffs.append(100.0 * (b - a) / a)
                        refs.append(a)
                        vals.append(b)
                if len(diffs) < 3:
                    continue
                lo, hi = bootstrap_median(diffs, rng)
                lower = sum(1 for x in diffs if x < 0)
                row = (w, v, metric[:-3], statistics.median(diffs), lo, hi, lower, len(diffs), statistics.median(refs), statistics.median(vals))
                if tsv:
                    print("\t".join(str(x) for x in row))
                else:
                    print(f"| {w} | {v} | {row[2]} | {row[3]:+.1f} | [{lo:+.1f}, {hi:+.1f}] | {lower}/{len(diffs)} | {len(diffs)} | "
                          f"{row[8]:.0f} | {row[9]:.0f} |")


if __name__ == "__main__":
    if sys.argv[1] == "run":
        args = [a for a in sys.argv[2:] if not a.startswith("--")]
        seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 51
        timeout = int(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 600
        start = int(sys.argv[sys.argv.index("--start") + 1]) if "--start" in sys.argv else 1
        for opt in ("--seed", "--timeout", "--start"):
            if opt in sys.argv:
                args.remove(sys.argv[sys.argv.index(opt) + 1])
        cfgs = json.load(open(args[2]))
        wl = args[3].split(",") if len(args) > 3 else ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]
        run(args[0], int(args[1]), cfgs, wl, seed, timeout, start)
    else:
        args = [a for a in sys.argv[2:] if not a.startswith("--")]
        only = None
        if "--cfgs" in sys.argv:
            only = sys.argv[sys.argv.index("--cfgs") + 1].split(",")
            args.remove(sys.argv[sys.argv.index("--cfgs") + 1])
        analyze(args[0], args[1:], only, "--tsv" in sys.argv)
