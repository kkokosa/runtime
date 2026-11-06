#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Summary of p50ab.py results: medians and paired differences with a 95% bootstrap interval.

usage: p50abanalyze.py <runs.jsonl> [more runs.jsonl ...]
Arms: base (lxr-gc-review head), p50s (the new library with the parallel selection off), p50 (the new library, defaults).
A paired difference new/ref - 1 in percent is taken for the same repetition of the same workload (the runs are adjacent in time).
"""
import json, random, statistics as st, sys
from collections import defaultdict

recs = []
for path in sys.argv[1:]:
    recs += [json.loads(line) for line in open(path)]
bad = [r for r in recs if r.get("status") != "ok"]
print(f"runs={len(recs)} not-ok={len(bad)}")
for r in bad[:10]:
    print("  BAD", r.get("collector"), r.get("workload"), r.get("rep"), r.get("status"))
data = defaultdict(dict)
for r in recs:
    if r.get("status") == "ok":
        data[(r["workload"], r["collector"])][r["rep"]] = r
workloads = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]
metrics = ["wall_ms", "cpu_ms", "pause_ms", "peak_rss_mb"]
arms = [a for a in ("base", "p50s", "p50") if any(k[1] == a for k in data)]
pairs = [(ref, new) for ref, new in (("base", "p50s"), ("base", "p50"), ("p50s", "p50")) if ref in arms and new in arms]
rng = random.Random(1)


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * (len(v) - 1) + 0.5))]


print("\nMedian (quartiles) of each arm\n")
print("| workload | arm | n | wall ms | cpu ms | pause ms | rss MB |")
print("|---|---|---|---|---|---|---|")
for w in workloads:
    for c in arms:
        d = data.get((w, c))
        if d:
            cells = [f"{st.median(x[m] for x in d.values()):.0f} ({q([x[m] for x in d.values()], .25):.0f}-{q([x[m] for x in d.values()], .75):.0f})"
                     for m in metrics]
            print(f"| {w} | {c} | {len(d)} | " + " | ".join(cells) + " |")

for ref, new in pairs:
    print(f"\nPaired difference {new} against {ref}, % (negative = {new} is better); median [95% bootstrap CI of the median]; runs with {new} better\n")
    print("| workload | n | wall | cpu | pause | rss |")
    print("|---|---|---|---|---|---|")
    for w in workloads:
        da, db = data.get((w, ref), {}), data.get((w, new), {})
        reps = sorted(set(da) & set(db))
        if len(reps) < 3:
            continue
        cells = []
        for m in metrics:
            ratios = [(db[r][m] / da[r][m] - 1) * 100 for r in reps]
            meds = sorted(st.median([rng.choice(ratios) for _ in ratios]) for _ in range(4000))
            cells.append(f"{st.median(ratios):+.1f}% [{meds[100]:+.1f}, {meds[3899]:+.1f}] {sum(1 for x in ratios if x < 0)}/{len(ratios)}")
        print(f"| {w} | {len(reps)} | " + " | ".join(cells) + " |")
