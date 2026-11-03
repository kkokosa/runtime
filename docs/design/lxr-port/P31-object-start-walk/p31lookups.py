#!/usr/bin/env python3
"""Interior lookups per run and per pause from the LXRLOOKUP lines (DOTNET_LXRLookupStats=1) that p31bench.py saved.
usage: p31lookups.py <outdir>"""
import glob, os, re, sys

rows = []
for path in sorted(glob.glob(sys.argv[1] + "/*/stderr.txt")):
    name = os.path.basename(os.path.dirname(path))
    last = None
    pauses_with = 0
    prev_calls = 0
    max_per_pause = 0
    for line in open(path, errors="replace"):
        m = re.match(r"LXRLOOKUP pause=(\d+) calls=(\d+) ticks=(\d+) spans=(\d+) checked=(\d+) freq=(\d+)", line)
        if not m:
            continue
        pause, calls, ticks, spans, checked, freq = map(int, m.groups())
        if calls > prev_calls:
            pauses_with += 1
            max_per_pause = max(max_per_pause, calls - prev_calls)
        prev_calls = calls
        last = (pause, calls, ticks, spans, checked, freq)
    if last:
        pause, calls, ticks, spans, checked, freq = last
        rows.append((name, pause, calls, ticks * 1e9 / freq / 1000.0, spans, checked, pauses_with, max_per_pause))
print("%-28s %6s %8s %10s %8s %8s %8s %8s" % ("run", "pauses", "lookups", "total us", "inSpans", "checked", "pausesW", "maxPerP"))
for r in rows:
    print("%-28s %6d %8d %10.1f %8d %8d %8d %8d" % r)