#!/usr/bin/env python3
"""usage: pause-survivors.py <dir> : pause time per pause against promoted objects and copied MB per pause (dirs lxr-<w>, l1-<w>, l2-<w> with result.json and pauses.csv)"""
import csv, json, statistics, sys
d = sys.argv[1]
for w in ("requests", "binarytrees"):
    for c in ("lxr", "l1", "l2"):
        r = json.load(open(f"{d}/{c}-{w}/result.json"))
        n = max(1, r["collections"])
        p = [float(x["duration_ms"]) for x in csv.DictReader(open(f"{d}/{c}-{w}/pauses.csv"))]
        prom = r.get("promotions", 0)
        print(f"{w:12s} {c:3s} pauses={n:3d} pause_ms/pause={r['pause_ms']/n:6.2f} p50={statistics.median(p):5.2f} "
              f"promotions/pause={prom/n:9.0f} copied_MB/pause={r['lxr_copied_mb']/n:5.2f} wall={r['wall_ms']:.0f}")
