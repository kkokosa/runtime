#!/usr/bin/env python3
"""Paired A/B tables from dl-run.py output. usage: dl-table.py <runs.jsonl> <baseline label> <label,label,...>"""
import json, random, statistics, sys, collections

path, base, others = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
rows = [json.loads(l) for l in open(path) if l.strip()]
METRICS = [("wall_ms", "wall ms"), ("cpu_ms", "CPU ms"), ("pause_ms", "pause ms"), ("collections", "collections"),
           ("peak_rss_mb", "peak RSS MB")]
by = collections.defaultdict(dict)  # (workload, rep) -> label -> rec
for r in rows:
    by[(r["workload"], r["rep"])][r["label"]] = r
workloads = sorted({w for w, _ in by})


def interval(diffs):
    rng = random.Random(1)
    meds = sorted(statistics.median(rng.choices(diffs, k=len(diffs))) for _ in range(4000))
    return meds[100], meds[3899]


print(f"| workload | metric | {base} median | " + " | ".join(f"{o} median | {o} - {base} (paired median, 95% interval)" for o in others) + " |")
print("|---|---|---|" + "---|---|" * len(others))
for w in workloads:
    pairs = [v for (ww, _), v in by.items() if ww == w]
    for key, name in METRICS:
        bvals = [v[base][key] for v in pairs if base in v and v[base].get("status") == "ok"]
        if not bvals:
            fails = sum(1 for v in pairs if base in v)
            print(f"| {w} | {name} | FAILED in {fails} of {len(pairs)} runs |" + " |" * (2 * len(others)))
            continue
        cells = []
        for o in others:
            ovals = [v[o][key] for v in pairs if o in v and base in v and v[o].get("status") == "ok" and v[base].get("status") == "ok"]
            diffs = [v[o][key] - v[base][key] for v in pairs if o in v and base in v and v[o].get("status") == "ok" and v[base].get("status") == "ok"]
            allo = [v[o][key] for v in pairs if o in v and v[o].get("status") == "ok"]
            if not allo:
                cells += ["FAILED", ""]
                continue
            lo, hi = interval(diffs) if diffs else (float("nan"),) * 2
            cells += [f"{statistics.median(allo):.1f}", f"{statistics.median(diffs):+.1f} [{lo:+.1f}, {hi:+.1f}]" if diffs else ""]
        print(f"| {w} | {name} | {statistics.median(bvals):.1f} | " + " | ".join(cells) + " |")
bad = [r for r in rows if r.get("status") != "ok"]
print(f"\nruns {len(rows)}, not ok {len(bad)}: " + ", ".join(sorted({"%s/%s:%s" % (r["label"], r["workload"], r.get("status")) for r in bad})))
