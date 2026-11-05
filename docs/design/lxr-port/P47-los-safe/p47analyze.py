#!/usr/bin/env python3
"""P47 analysis (from p44analyze.py). usage: p47analyze.py <runs.jsonl> <reference-config> <config> [<config> ...]
Per workload: medians (IQR) of wall, cpu and pause for every config, then the paired difference (config - reference) per repetition:
median % and median ms with a 95 % bootstrap interval (2000 resamples) and the count of repetitions in which the config is lower."""
import json, random, statistics as st, sys
from collections import defaultdict

path, ref, cfgs = sys.argv[1], sys.argv[2], sys.argv[3:]
recs = [json.loads(l) for l in open(path)]
ALLOW = [a for a in __import__('os').environ.get('P47_ALLOW_BAD', '').split(',') if a]
okay = lambda r: r.get('status') == 'ok' or (r.get('status') == 'BAD_CHECKSUM' and any(a in r.get('collector', '') for a in ALLOW))
bad = [r for r in recs if not okay(r)]
print(f"runs={len(recs)} not-ok={len(bad)}")
for r in bad[:12]:
    print("  BAD", r.get("collector"), r.get("workload"), r.get("rep"), r.get("status"), r.get("tail", "")[-120:].replace("\n", " "))
data = defaultdict(dict)
for r in recs:
    if okay(r):
        data[(r["workload"], r["collector"])][r["rep"]] = r
workloads = [w for w in ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays", "losmany"]
             if any(k[0] == w for k in data)]
M = ["wall_ms", "cpu_ms", "pause_ms"]


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * (len(v) - 1) + 0.5))]


print("\n== medians (IQR): wall ms | cpu ms | pause ms | collections ==")
for w in workloads:
    print(f"[{w}]")
    for c in [ref] + cfgs:
        d = data.get((w, c))
        if not d:
            continue
        cells = []
        for m in M:
            v = [x[m] for x in d.values()]
            cells.append(f"{st.median(v):7.0f} ({q(v,.25):.0f}-{q(v,.75):.0f})")
        cells.append(f"{st.median([x['collections'] for x in d.values()]):.0f}")
        print(f"  {c[:46]:46s} n={len(d):2d}  " + " | ".join(cells))


def paired(w, a, b, m, rng):
    da, db = data.get((w, a), {}), data.get((w, b), {})
    reps = sorted(set(da) & set(db))
    if len(reps) < 3:
        return None
    pct = [(db[r][m] / da[r][m] - 1) * 100 for r in reps]
    ab = [db[r][m] - da[r][m] for r in reps]
    out = []
    for xs in (pct, ab):
        meds = sorted(st.median([rng.choice(xs) for _ in xs]) for _ in range(2000))
        out.append((st.median(xs), meds[50], meds[1949]))
    lower = sum(1 for x in ab if x < 0)
    return out[0], out[1], lower, len(reps)


rng = random.Random(1)
for c in cfgs:
    print(f"\n== {c}  vs  {ref}: median paired difference [95% bootstrap CI]; (negative = config lower); lower-count ==")
    for w in workloads:
        cells = []
        for m in M:
            r = paired(w, ref, c, m, rng)
            if r is None:
                cells.append(f"{m[:-3]}: n/a")
            else:
                (p, pl, ph), (a, al, ah), lower, n = r
                sig = "*" if (pl > 0 or ph < 0) else " "
                cells.append(f"{m[:-3]} {p:+6.1f}% [{pl:+.1f},{ph:+.1f}] {a:+7.0f} ms [{al:+.0f},{ah:+.0f}] {lower}/{n}{sig}")
        print(f"  {w:12s} " + " | ".join(cells))
print("\n('*' = the 95% interval of the % difference excludes zero)")
