#!/usr/bin/env python3
"""P32. Hottest instruction addresses of the library in a perf profile, with the instructions before them.
usage: ips32.py <perf.data> <dbg dir with libclrlxrgc.so and .dbg> <lib tag> [topN] [ctx] [function regex]"""
import collections, re, subprocess, sys

PERF = "/usr/lib/linux-tools/5.15.0-202-generic/perf"
data, dbgdir, tag = sys.argv[1], sys.argv[2], sys.argv[3]
topn = int(sys.argv[4]) if len(sys.argv) > 4 else 14
ctx = int(sys.argv[5]) if len(sys.argv) > 5 else 7
rx = re.compile(sys.argv[6] if len(sys.argv) > 6 else ".")
SO, DBG = dbgdir + "/libclrlxrgc.so", dbgdir + "/libclrlxrgc.so.dbg"
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
cnt = collections.Counter()
for line in out.splitlines():
    m = LINE.match(line)
    if not m or m.group(1) == m.group(2) or tag not in m.group(5):
        continue
    ip = int(m.group(3), 16)
    for base, size, pg in maps:
        if base <= ip < base + size:
            cnt[ip - base + pg] += 1
            break
keys = sorted(cnt)
res = subprocess.run(["addr2line", "-f", "-C", "-e", DBG] + [hex(k) for k in keys], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True).stdout.splitlines()
fn = {k: res[2 * i] for i, k in enumerate(keys)}
sel = {k: n for k, n in cnt.items() if rx.search(fn[k])}
tot = sum(sel.values())
dis = subprocess.run(["objdump", "-d", "-C", "--no-show-raw-insn", "-M", "intel", SO], stdout=subprocess.PIPE, text=True).stdout.splitlines()
idx = {}
for i, l in enumerate(dis):
    m = re.match(r"\s*([0-9a-f]+):\s", l)
    if m:
        idx[int(m.group(1), 16)] = i
print("samples", tot)
for off, n in sorted(sel.items(), key=lambda x: -x[1])[:topn]:
    print("\n== %d (%.1f%%) %s @0x%x" % (n, 100 * n / tot, fn[off][:70], off))
    i = idx.get(off)
    if i is None:
        print("   (no disasm)")
        continue
    for j in range(max(0, i - ctx), i + 2):
        print(("-> " if j == i else "   ") + dis[j][:120])
