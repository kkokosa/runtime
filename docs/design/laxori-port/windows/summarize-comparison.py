#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Tables for the Windows comparison: medians per cell, paired differences, and Windows against WSL2.

usage: python summarize-comparison.py <windows runs.jsonl> [<wsl2 root with rep*/runs.jsonl>]
Prints markdown tables. Windows collectors: wks svr lxr laxori satori. WSL2 collectors (bench3.py names) are mapped:
lxr-walk -> lxr, laxori-count-c -> laxori."""
import glob, json, os, random, statistics, sys

LINUX_MAP = {"lxr-walk": "lxr", "laxori-count-c": "laxori"}
WORK = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays", "losmany"]
COLL = ["wks", "svr", "lxr", "laxori", "satori"]


def load_windows(path):
    rows = {}
    for line in open(path):
        r = json.loads(line)
        if "wall_ms" in r and r.get("status") is None:
            rows.setdefault((r["workload"], r["collector"]), {})[r["rep"]] = r
    return rows


def load_linux(root):
    rows = {}
    dirs = [p for p in glob.glob(os.path.join(root, "rep*")) if os.path.isdir(p)]
    for rep_dir in sorted(dirs, key=lambda p: int(os.path.basename(p)[3:])):
        if not os.path.isdir(rep_dir):
            continue
        rep = int(os.path.basename(rep_dir)[3:])
        path = os.path.join(rep_dir, "runs.jsonl")
        if not os.path.exists(path):
            continue
        for line in open(path):
            r = json.loads(line)
            if "wall_ms" in r and r.get("status") is None:
                rows.setdefault((r["workload"], LINUX_MAP.get(r["collector"], r["collector"])), {})[rep] = r
    return rows


def med(rows, w, c, key):
    v = [r[key] for r in rows.get((w, c), {}).values()]
    return statistics.median(v) if v else None


def boot(values, rounds=4000):
    rng = random.Random(7)
    n = len(values)
    m = sorted(statistics.median(rng.choices(values, k=n)) for _ in range(rounds))
    return m[int(rounds * 0.025)], m[int(rounds * 0.975)]


def fmt(x, d=0):
    return "[N]" if x is None else f"{x:,.{d}f}"


def medians(rows, title):
    print(f"\n### {title}: median of wall ms / CPU ms / pause ms / peak working set MB (n = runs)\n")
    print("| workload | " + " | ".join(COLL) + " |")
    print("|---|" + "---|" * len(COLL))
    for w in WORK:
        cells = []
        for c in COLL:
            n = len(rows.get((w, c), {}))
            if n == 0:
                cells.append("[N]")
            else:
                cells.append(" / ".join(fmt(med(rows, w, c, k)) for k in ("wall_ms", "cpu_ms", "pause_ms", "peak_rss_mb")) + f" (n={n})")
        print(f"| {w} | " + " | ".join(cells) + " |")


def paired(rows, a, b, title):
    print(f"\n### {title}: paired difference ({a} - {b}) / {b} in percent, median and 95% bootstrap interval\n")
    print("| workload | wall | CPU | pause | peak WS |")
    print("|---|---|---|---|---|")
    for w in WORK:
        cells = []
        for key in ("wall_ms", "cpu_ms", "pause_ms", "peak_rss_mb"):
            d = []
            for rep, ra in rows.get((w, a), {}).items():
                rb = rows.get((w, b), {}).get(rep)
                if rb and rb[key]:
                    d.append((ra[key] - rb[key]) * 100.0 / rb[key])
            if len(d) >= 3:
                lo, hi = boot(d)
                cells.append(f"{statistics.median(d):+.1f} [{lo:+.1f}, {hi:+.1f}]")
            else:
                cells.append("[N]")
        print(f"| {w} | " + " | ".join(cells) + " |")


def windows_vs_linux(win, lin):
    print("\n### Windows against WSL2 (same VM): ratio of the medians, Windows / WSL2 (wall, CPU, pause)\n")
    print("| workload | " + " | ".join(COLL) + " |")
    print("|---|" + "---|" * len(COLL))
    for w in WORK:
        cells = []
        for c in COLL:
            parts = []
            for key in ("wall_ms", "cpu_ms", "pause_ms"):
                a, b = med(win, w, c, key), med(lin, w, c, key)
                parts.append("[N]" if not a or not b else f"{a / b:.2f}")
            cells.append(" / ".join(parts))
        print(f"| {w} | " + " | ".join(cells) + " |")
    print("\n### Collector against stock WKS on each OS: median wall ratio (collector / WKS), Windows | WSL2\n")
    print("| workload | " + " | ".join(c for c in COLL if c != "wks") + " |")
    print("|---|" + "---|" * (len(COLL) - 1))
    for w in WORK:
        cells = []
        for c in COLL:
            if c == "wks":
                continue
            r = []
            for rows in (win, lin):
                a, b = med(rows, w, c, "wall_ms"), med(rows, w, "wks", "wall_ms")
                r.append("[N]" if not a or not b else f"{a / b:.2f}")
            cells.append(" \\| ".join(r))
        print(f"| {w} | " + " | ".join(cells) + " |")


def main():
    win = load_windows(sys.argv[1])
    medians(win, "Windows")
    for a, b in (("laxori", "lxr"), ("laxori", "wks"), ("lxr", "wks"), ("laxori", "svr"), ("laxori", "satori")):
        paired(win, a, b, "Windows")
    if len(sys.argv) > 2:
        lin = load_linux(sys.argv[2])
        medians(lin, "WSL2")
        windows_vs_linux(win, lin)


main()
