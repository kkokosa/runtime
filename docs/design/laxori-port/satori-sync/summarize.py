"""Median table of a workloads-*.ps1/.sh runs.csv: wall, CPU, pause, collections and peak RSS per collector and workload.
usage: python summarize.py <runs.csv> [<runs.csv> ...]"""
import csv
import statistics
import sys

ORDER = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays", "losmany"]
for path in sys.argv[1:]:
    rows = [r for r in csv.DictReader(open(path)) if r["ok"] == "True"]
    configs = list(dict.fromkeys(r["config"] for r in rows))
    print(f"\n{path}\n")
    print("| workload | " + " | ".join(f"{c} wall / CPU / pause ms (n)" for c in configs) + " | satori/laxori wall |")
    print("|---|" + "---|" * (len(configs) + 1))
    for w in ORDER:
        cells, wall = [], {}
        for c in configs:
            sel = [r for r in rows if r["config"] == c and r["workload"] == w]
            if not sel:
                cells.append("-")
                continue
            med = lambda k: statistics.median(float(r[k]) for r in sel)
            wall[c] = med("wall_ms")
            cells.append(f"{med('wall_ms'):.0f} / {med('cpu_ms'):.0f} / {med('pause_ms'):.0f} ({len(sel)})")
        ratio = f"{wall['satori'] / wall['laxori']:.2f}" if "satori" in wall and "laxori" in wall else "-"
        print(f"| {w} | " + " | ".join(cells) + f" | {ratio} |")
