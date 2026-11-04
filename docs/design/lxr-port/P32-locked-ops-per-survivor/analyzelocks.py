#!/usr/bin/env python3
"""Summary of runlocks.py results: medians (IQR) per cell and paired differences against a reference config with a
bootstrap interval of the median.
usage: analyzelocks.py <runs.jsonl> <reference config> [other configs...]   (default: all other configs)"""
import json, random, statistics as st, sys
from collections import defaultdict

recs = [json.loads(l) for l in open(sys.argv[1])]
ref = sys.argv[2]
bad = [r for r in recs if r.get("status") != "ok"]
print(f"runs={len(recs)} not-ok={len(bad)}")
for r in bad[:10]:
    print("  BAD", r.get("collector"), r.get("workload"), r.get("rep"), r.get("status"))
data = defaultdict(dict)
for r in recs:
    if r.get("status") == "ok":
        data[(r["workload"], r["collector"])][r["rep"]] = r
workloads = [w for w in ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]
             if any(k[0] == w for k in data)]
configs = [c for c in dict.fromkeys(r["collector"] for r in recs)]
others = sys.argv[3:] or [c for c in configs if c != ref]
M = ["wall_ms", "cpu_ms", "pause_ms"]


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * (len(v) - 1) + 0.5))]


print("\n== medians (IQR): wall ms | cpu ms | pause ms ==")
for w in workloads:
    print(f"[{w}]")
    for c in [ref] + others:
        d = data.get((w, c))
        if not d:
            continue
        cells = []
        for m in M:
            v = [x[m] for x in d.values()]
            cells.append(f"{st.median(v):7.0f} ({q(v,.25):.0f}-{q(v,.75):.0f})")
        print(f"  {c:16s} n={len(d):2d}  " + " | ".join(cells))

rng = random.Random(1)
for c in others:
    print(f"\n== {c} vs {ref}: paired median % difference [95% bootstrap interval], runs better/total (negative = {c} better) ==")
    for w in workloads:
        da, db = data.get((w, ref), {}), data.get((w, c), {})
        reps = sorted(set(da) & set(db))
        cells = []
        for m in M:
            if len(reps) < 3:
                cells.append("n/a")
                continue
            ratios = [(db[r][m] / da[r][m] - 1) * 100 for r in reps]
            meds = sorted(st.median([rng.choice(ratios) for _ in ratios]) for _ in range(4000))
            cells.append(f"{st.median(ratios):+6.1f}% [{meds[100]:+.1f},{meds[3899]:+.1f}] {sum(1 for x in ratios if x < 0)}/{len(ratios)}")
        print(f"  {w:13s} " + " | ".join(cells))
