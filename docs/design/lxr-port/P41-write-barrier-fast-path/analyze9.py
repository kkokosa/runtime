#!/usr/bin/env python3
"""Summary of run9 results: medians (IQR) per variant and paired differences to a baseline with a bootstrap interval.
usage: analyze9.py <runs.jsonl> <baseline> [variants,comma]"""
import json, random, statistics as st, sys
from collections import defaultdict

path, base = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(path)]
bad = [r for r in recs if r.get("status") != "ok"]
print("runs=%d not-ok=%d" % (len(recs), len(bad)))
for r in bad[:10]:
    print("  BAD", r.get("collector"), r.get("workload"), r.get("rep"), r.get("status"))
data = defaultdict(dict)
for r in recs:
    if r.get("status") == "ok":
        data[(r["workload"], r["collector"])][r["rep"]] = r
workloads = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]
names = sorted({c for (_, c) in data})
variants = sys.argv[3].split(",") if len(sys.argv) > 3 else [n for n in names if n != base]
M = ["wall_ms", "cpu_ms", "pause_ms"]


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * (len(v) - 1) + 0.5))]


print("\n== medians (IQR): wall ms | cpu ms | pause ms ==")
for w in workloads:
    print("[%s]" % w)
    for c in [base] + variants:
        d = data.get((w, c))
        if d:
            print("  %-10s n=%2d  " % (c, len(d)) + " | ".join("%7.0f (%.0f-%.0f)" % (st.median([x[m] for x in d.values()]), q([x[m] for x in d.values()], .25), q([x[m] for x in d.values()], .75)) for m in M))


def paired(w, a, b, m, rng):
    da, db = data.get((w, a), {}), data.get((w, b), {})
    reps = sorted(set(da) & set(db))
    if len(reps) < 3:
        return None
    ratios = [(db[r][m] / da[r][m] - 1) * 100 for r in reps]
    meds = sorted(st.median([rng.choice(ratios) for _ in ratios]) for _ in range(3000))
    better = sum(1 for x in ratios if x < 0)
    return st.median(ratios), meds[75], meds[2924], better, len(ratios)


rng = random.Random(1)
for v in variants:
    print("\n== %s vs %s: median paired %% [95%% bootstrap CI], variant-faster count (negative = variant better) ==" % (v, base))
    for w in workloads:
        cells = []
        for m in M:
            r = paired(w, base, v, m, rng)
            cells.append("n/a" if r is None else "%+6.1f%% [%+.1f,%+.1f] %d/%d" % r)
        print("  %-13s " % w + " | ".join(cells))
