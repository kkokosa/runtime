#!/usr/bin/env python3
"""Markdown tables for the P46 README. usage: tables46.py counters <runs.jsonl> | bench <runs.jsonl>"""
import json, random, statistics as st, sys
from collections import defaultdict

kind, path = sys.argv[1], sys.argv[2]
recs = [json.loads(l) for l in open(path)]
data = defaultdict(dict)
for r in recs:
    if r.get("status") == "ok":
        data[(r["workload"], r["collector"])][r["rep"]] = r
workloads = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]


def med(v):
    return st.median(v)


if kind == "counters":
    for suffix, title in (("", "default trace threshold"), ("-tr1", "DOTNET_LXRTraceThreshold=1")):
        print(f"\n**{title}** (median of 3 runs; `old` = commit 6c19bb1919b, rule before the change; `new` = HEAD)\n")
        print("| Workload | rule | InitialMarks | deaths | first-epoch deaths | first-epoch marked | first-epoch children queued | later-epoch deaths | later-epoch marked | later-epoch children queued |")
        print("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|")
        for w in workloads:
            for lib, label in (("diag-c1", "old"), ("diag-c2", "new")):
                d = data.get((w, lib + suffix))
                rows = [x["window"] for x in d.values() if "window" in x] if d else []
                if not rows:
                    print(f"| {w} | {label} | 0 (no trace in {len(d) if d else 0} runs) | | | | | | | |")
                    continue
                g = lambda k: med([r.get(k, 0) for r in rows])
                print(f"| {w} | {label} | {g('initial'):.0f} | {g('deaths'):,.0f} | {g('first_deaths'):,.0f} | {g('first_marked'):,.0f} | "
                      f"{g('first_children'):,.0f} | {g('later_deaths'):,.0f} | {g('later_marked'):,.0f} | {g('later_children'):,.0f} |")
elif kind == "bench":
    rng = random.Random(7)

    def paired(w, a, b, m):
        da, db = data.get((w, a), {}), data.get((w, b), {})
        reps = sorted(set(da) & set(db))
        ratios = [(db[r][m] / da[r][m] - 1) * 100 for r in reps]
        meds = sorted(st.median([rng.choice(ratios) for _ in ratios]) for _ in range(4000))
        return st.median(ratios), meds[100], meds[3899], len(ratios)

    for suffix, title in (("", "default trace threshold"), ("-tr1", "DOTNET_LXRTraceThreshold=1 (traces forced)")):
        print(f"\n**{title}**: median of paired per-rep differences, new against base, with 95% bootstrap interval (negative = new is lower)\n")
        print("| Workload | n | base wall ms | new wall ms | wall diff | base CPU ms | new CPU ms | CPU diff | base pause ms | new pause ms | pause diff | collections base / new |")
        print("|---|--:|--:|--:|---|--:|--:|---|--:|--:|---|--:|")
        for w in workloads:
            a, b = "base" + suffix, "new" + suffix
            if not data.get((w, a)) or not data.get((w, b)):
                continue
            row = [w, str(paired(w, a, b, "wall_ms")[3])]
            for m in ("wall_ms", "cpu_ms", "pause_ms"):
                va = [x[m] for x in data[(w, a)].values()]
                vb = [x[m] for x in data[(w, b)].values()]
                p = paired(w, a, b, m)
                row += [f"{med(va):.0f}", f"{med(vb):.0f}", f"{p[0]:+.1f}% [{p[1]:+.1f}, {p[2]:+.1f}]"]
            ca = med([x["collections"] for x in data[(w, a)].values()])
            cb = med([x["collections"] for x in data[(w, b)].values()])
            row.append(f"{ca:.0f} / {cb:.0f}")
            print("| " + " | ".join(row) + " |")
