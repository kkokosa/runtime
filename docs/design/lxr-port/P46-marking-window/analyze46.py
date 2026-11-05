#!/usr/bin/env python3
"""P46 analysis. usage: analyze46.py <runs.jsonl> <base> <new> [suffixes: "" and -tr1 ...]
Prints medians and paired differences new vs base (median of per-rep percent difference, 95% bootstrap interval, count of reps where new is lower)."""
import json, random, statistics as st, sys
from collections import defaultdict

path, base, new = sys.argv[1], sys.argv[2], sys.argv[3]
suffixes = sys.argv[4].split(",") if len(sys.argv) > 4 else ["", "-tr1"]
recs = [json.loads(l) for l in open(path)]
bad = [r for r in recs if r.get("status") != "ok"]
print(f"runs={len(recs)} not-ok={len(bad)}")
for r in bad[:10]:
    print("  BAD", r.get("collector"), r.get("workload"), r.get("rep"), r.get("status"), r.get("tail", "")[:120])
data = defaultdict(dict)
for r in recs:
    if r.get("status") == "ok":
        data[(r["workload"], r["collector"])][r["rep"]] = r
workloads = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]
M = ["wall_ms", "cpu_ms", "pause_ms", "peak_rss_mb", "collections"]


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * (len(v) - 1) + 0.5))]


def paired(w, a, b, m, rng):
    da, db = data.get((w, a), {}), data.get((w, b), {})
    reps = sorted(set(da) & set(db))
    if len(reps) < 3:
        return None
    ratios = [(db[r][m] / da[r][m] - 1) * 100 if da[r][m] else 0.0 for r in reps]
    meds = []
    for _ in range(4000):
        meds.append(st.median([rng.choice(ratios) for _ in ratios]))
    meds.sort()
    return st.median(ratios), meds[100], meds[3899], sum(1 for x in ratios if x < 0), len(ratios)


rng = random.Random(1)
for s in suffixes:
    a, b = base + s, new + s
    print(f"\n===== threshold suffix '{s}': medians (IQR) =====")
    for w in workloads:
        print(f"[{w}]")
        for c in (a, b):
            d = data.get((w, c))
            if not d:
                continue
            cells = []
            for m in M:
                v = [x[m] for x in d.values()]
                cells.append(f"{st.median(v):8.0f} ({q(v, .25):.0f}-{q(v, .75):.0f})")
            print(f"  {c:14s} n={len(d):2d}  " + " | ".join(cells))
    print(f"\n== paired {b} vs {a}: median % [95% bootstrap CI] lower/n (negative = new better) : " + " | ".join(M))
    for w in workloads:
        cells = []
        for m in M:
            r = paired(w, a, b, m, rng)
            cells.append("n/a" if r is None else f"{r[0]:+6.1f}% [{r[1]:+.1f},{r[2]:+.1f}] {r[3]}/{r[4]}")
        print(f"  {w:13s} " + " | ".join(cells))

# counters
print("\n===== LXRWINDOW counters (last line of each run, medians over reps; per-trace = divided by InitialMark count) =====")
keys = ["initial", "final", "full", "tracePauses", "deaths", "first_deaths", "first_marked", "first_children",
        "later_deaths", "later_marked", "later_children", "deletion_marks", "satb"]
for (w, c), d in sorted(data.items()):
    rows = [x["window"] for x in d.values() if "window" in x]
    if not rows:
        continue
    print(f"[{w}] {c} n={len(rows)}  " + " ".join(f"{k}={st.median([r.get(k, 0) for r in rows]):.0f}" for k in keys))
    per = lambda k: st.median([r.get(k, 0) / max(1, r.get("initial", 1)) for r in rows])
    share = st.median([r.get("first_marked", 0) / max(1, r.get("first_marked", 0) + r.get("later_marked", 0)) for r in rows])
    print(f"      per trace: first_deaths={per('first_deaths'):.0f} first_marked={per('first_marked'):.0f} first_children={per('first_children'):.0f} "
          f"later_deaths={per('later_deaths'):.0f} later_marked={per('later_marked'):.0f} later_children={per('later_children'):.0f} "
          f"pauses/trace={per('tracePauses'):.1f} first-epoch share of marked={share:.2f}")
