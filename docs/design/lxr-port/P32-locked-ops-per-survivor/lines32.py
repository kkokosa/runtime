#!/usr/bin/env python3
"""P32. Source-line histogram of leaf samples of the libclrlxrgc library in a perf profile (worker threads, not the main thread).
usage: lines32.py <perf.data> <dbg dir with libclrlxrgc.so.dbg> <lib tag in the mapped path> [topN] [function regex]
Leaf samples only (record without -g, or the first frame of each sample)."""
import collections, re, subprocess, sys

PERF = "/usr/lib/linux-tools/5.15.0-202-generic/perf"
data, dbgdir, tag = sys.argv[1], sys.argv[2], sys.argv[3]
topn = int(sys.argv[4]) if len(sys.argv) > 4 else 40
rx = re.compile(sys.argv[5] if len(sys.argv) > 5 else ".")
DBG = dbgdir + "/libclrlxrgc.so.dbg"
mm = subprocess.run([PERF, "script", "-i", data, "--show-mmap-events", "-F", "pid"], stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True).stdout
maps = []
for l in mm.splitlines():
    if tag in l and "r-xp" in l:
        m = re.search(r"\[0x([0-9a-f]+)\(0x([0-9a-f]+)\) @ (?:0x)?([0-9a-f]+) ", l)
        if m:
            maps.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)))
out = subprocess.run([PERF, "script", "-i", data, "-F", "pid,tid,ip,sym,dso", "-G"], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True).stdout
LINE = re.compile(r"^\s*(\d+)/(\d+)\s+([0-9a-f]+)\s+(.*?)\s+\((.*)\)\s*$")
offs = collections.Counter()
total = 0
for line in out.splitlines():
    m = LINE.match(line)
    if not m:
        continue
    total += 1
    if m.group(1) == m.group(2) or tag not in m.group(5):
        continue
    ip = int(m.group(3), 16)
    for base, size, pg in maps:
        if base <= ip < base + size:
            offs[ip - base + pg] += 1
            break
keys = sorted(offs)
res = subprocess.run(["addr2line", "-a", "-f", "-C", "-i", "-e", DBG] + [hex(k) for k in keys], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True).stdout.splitlines()
frames = {}
cur = None
i = 0
while i < len(res):
    if res[i].startswith("0x"):
        cur = int(res[i], 16)
        frames[cur] = []
        i += 1
    else:
        frames[cur].append((res[i], res[i + 1]))
        i += 2
lines, funcs = collections.Counter(), collections.Counter()
for k in keys:
    fr = frames.get(k)
    if not fr:
        continue
    outer = fr[-1][0]
    if not rx.search(outer):
        continue
    inner_fn, inner_ln = fr[0]
    lines[(outer[:46], inner_fn[:46], re.sub(r".*/gc_lxr/", "", inner_ln))] += offs[k]
    funcs[outer[:70]] += offs[k]
tot = sum(funcs.values())
print("all samples", total, " worker samples in the library (matching):", tot)
for f, n in funcs.most_common(14):
    print("  %6d %5.1f%%  %s" % (n, 100 * n / tot, f))
print("--- top source lines (outer | innermost inlined | file:line)")
for (o, i2, l), n in lines.most_common(topn):
    print("  %6d %5.1f%%  %s | %s | %s" % (n, 100 * n / tot, o, i2, l))
