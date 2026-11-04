#!/usr/bin/env python3
"""Line-level histogram of main-thread leaf samples inside selected libclrlxrgc functions.
usage: lines9.py <perf.data> <dbg> <func-regex> [topN]"""
import collections, re, subprocess, sys

PERF = "/usr/lib/linux-tools/5.15.0-202-generic/perf"
data, dbg, rx = sys.argv[1], sys.argv[2], re.compile(sys.argv[3])
topn = int(sys.argv[4]) if len(sys.argv) > 4 else 20
mm = subprocess.run([PERF, "script", "-i", data, "--show-mmap-events", "-F", "pid"], stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True).stdout
maps = []
for l in mm.splitlines():
    if "libclrlxrgc" in l and "r-xp" in l:
        m = re.search(r"\[0x([0-9a-f]+)\(0x([0-9a-f]+)\) @ (?:0x)?([0-9a-f]+) ", l)
        if m:
            maps.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)))
out = subprocess.run([PERF, "script", "-i", data, "-F", "pid,tid,ip,sym,dso"], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True).stdout
HDR = re.compile(r"^\s*(\d+)/(\d+)\s*$")
FR = re.compile(r"^\s+([0-9a-f]+)\s+(.*?)\s+\((.*)\)\s*$")
offs, first, main = collections.Counter(), False, False
for line in out.splitlines():
    if not line.strip():
        first = False
        continue
    h = HDR.match(line)
    if h:
        main = h.group(1) == h.group(2)
        first = True
        continue
    if first:
        first = False
        m = FR.match(line)
        if m and main and "libclrlxrgc" in m.group(3):
            ip = int(m.group(1), 16)
            for base, size, pg in maps:
                if base <= ip < base + size:
                    offs[ip - base + pg] += 1
                    break
cnt = collections.Counter()
for k in sorted(offs):
    r = subprocess.run(["addr2line", "-f", "-C", "-i", "-e", dbg, hex(k)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.splitlines()
    frames = list(zip(r[0::2], r[1::2]))
    if not frames or not rx.search(frames[-1][0]):
        continue
    fn, ln = frames[0]
    cnt[(frames[-1][0][:40], fn[:50], re.sub(r".*/gc_lxr/", "", ln), hex(k))] += offs[k]
for (outer, fn, ln, a), c in cnt.most_common(topn):
    print("%5d  %-40s %-50s %s %s" % (c, outer, fn, ln, a))
