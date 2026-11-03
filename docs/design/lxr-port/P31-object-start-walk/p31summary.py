#!/usr/bin/env python3
"""Medians per workload and config from the runs.jsonl files of p31bench.py. usage: p31summary.py <outdir> [<outdir> ...]"""
import json, statistics, sys, collections

rows = collections.defaultdict(list)
bad = collections.Counter()
for d in sys.argv[1:]:
    for line in open(d + "/runs.jsonl"):
        r = json.loads(line)
        if r.get("status") != "ok":
            bad[(r["workload"], r["config"], r.get("status"))] += 1
            continue
        rows[(r["workload"], r["config"])].append(r)
metrics = [("wall_ms", "wall ms"), ("cpu_ms", "cpu ms"), ("pause_ms", "pause ms"), ("peak_rss_mb", "rss MB"), ("collections", "gcs")]
print("%-13s %-5s %3s " % ("workload", "cfg", "n") + " ".join("%10s" % m[1] for m in metrics))
for w in ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]:
    base = {}
    for c in ["base", "walk"]:
        rs = rows.get((w, c), [])
        if not rs:
            continue
        med = {k: statistics.median(r[k] for r in rs) for k, _ in metrics}
        base[c] = med
        print("%-13s %-5s %3d " % (w, c, len(rs)) + " ".join("%10.1f" % med[k] for k, _ in metrics))
    if "base" in base and "walk" in base:
        print("%-13s %-5s %3s " % ("", "d%", "") + " ".join(
            "%9.1f%%" % (100.0 * (base["walk"][k] - base["base"][k]) / base["base"][k]) if base["base"][k] else "%10s" % "-"
            for k, _ in metrics))
for k, v in sorted(bad.items()):
    print("NOT OK:", k, v)