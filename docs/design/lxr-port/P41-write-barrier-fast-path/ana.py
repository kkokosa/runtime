#!/usr/bin/env python3
"""Barrier share of the program thread from a perf.data of prof.sh.
usage: ana.py <perf.data> <libclrlxrgc.so.dbg> [perf-map-file]
Classifies the samples of the program thread (pid == tid) by the frames of the call chain:
  fast   leaf in the barrier block (LxrCheckedAssignRef / LxrAssignRef code), not the slow part
  slow   any other sample with LxrBarrierSlow (asm) or LxrGcHeap::BarrierSlowPath/LxrBarrierSlowPath in the chain
and prints per-offset counts of the fast path (offset in the block) to see where the time is."""
import bisect, collections, glob, os, re, subprocess, sys

PERF = "/usr/lib/linux-tools/5.15.0-202-generic/perf"
data, dbg = sys.argv[1], sys.argv[2]
mapfile = sys.argv[3] if len(sys.argv) > 3 else None

# function symbols of the library
syms = []
for l in subprocess.run(["nm", "-S", "-C", "--defined-only", dbg], stdout=subprocess.PIPE, text=True).stdout.splitlines():
    p = l.split(None, 3)
    if len(p) == 3 and p[1] in "tTwW":
        syms.append((int(p[0], 16), 0, p[2]))
    elif len(p) == 4 and p[2] in "tTwW":
        syms.append((int(p[0], 16), int(p[1], 16), p[3]))
syms.sort()
starts = [s[0] for s in syms]


def lib_sym(addr):
    i = bisect.bisect_right(starts, addr) - 1
    if i >= 0 and addr < syms[i][0] + max(syms[i][1], 1):
        return syms[i][2], addr - syms[i][0]
    return None, 0


def lib_addr(name):
    for a, s, n in syms:
        if n == name:
            return a
    return None


blk_start_lib = lib_addr("LxrCheckedAssignRef")
blk_end_lib = lib_addr("LxrWriteBarrierBlock_End")
blk_len = blk_end_lib - blk_start_lib
slow_off = lib_addr("LxrBarrierSlow") - blk_start_lib
assign_off = lib_addr("LxrAssignRef") - blk_start_lib

# the block copy in the JIT map
if mapfile is None:
    pids = subprocess.run([PERF, "script", "-i", data, "-F", "pid"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.split()
    if pids:
        pid = collections.Counter(pids).most_common(1)[0][0]
        mapfile = "/tmp/perf-%s.map" % pid
copy_start = None
if mapfile:
    for l in open(mapfile, errors="replace"):
        m = re.match(r"(?:0x)?([0-9a-f]+) ([0-9a-f]+) (.*)", l)
        nm = m.group(3).strip() if m else ""
        if m and nm.startswith("stub WriteBarrier<"):
            a = int(m.group(1), 16)
            off = assign_off if nm == "stub WriteBarrier<WriteBarrier>" else 0
            copy_start = a - off
            break
print("block copy start", hex(copy_start) if copy_start else None, "map", mapfile, "block len", blk_len, "assign_off", assign_off, "slow_off", slow_off)

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


def classify_frame(ip, sym, dso):
    """returns a name for the frame"""
    if copy_start and copy_start <= ip < copy_start + blk_len:
        off = ip - copy_start
        return ("WB.slow" if off >= slow_off else ("WB.assign" if off >= assign_off else "WB.checked")), off
    if "libclrlxrgc" in dso:
        for base, size, pg in maps:
            if base <= ip < base + size:
                n, _ = lib_sym(ip - base + pg)
                return (n or sym or "?"), 0
    return sym or "?", 0


total = collections.Counter()
cats = collections.Counter()
offs = collections.Counter()
slow_leaf = collections.Counter()
chain = None
main = False


def flush():
    global chain
    if not chain or not main:
        chain = None
        return
    total["main"] += 1
    names = [c[0] for c in chain]
    leaf, off = chain[0]
    if leaf in ("WB.assign", "WB.checked"):
        cats["fast"] += 1
        offs[(leaf, off)] += 1
    elif leaf == "WB.slow" or any(n in ("WB.slow",) or "BarrierSlowPath" in n or "LogOldValue" in n for n in names):
        cats["slow"] += 1
        slow_leaf[leaf if leaf != "WB.slow" else "WB.slow(asm)"] += 1
        if leaf == "WB.slow":
            offs[("WB.slow", off)] += 1
    chain = None


for line in out.splitlines():
    if not line.strip():
        flush()
        continue
    h = HDR.match(line)
    if h:
        flush()
        main = h.group(1) == h.group(2)
        chain = []
        continue
    m = FR.match(line)
    if m and chain is not None:
        ip = int(m.group(1), 16)
        chain.append(classify_frame(ip, m.group(2), m.group(3)))
flush()
ms = 0.25
print("main-thread samples %d (%.0f ms)" % (total["main"], total["main"] * ms))
for k in ("fast", "slow"):
    print("  %-5s %6d samples  %7.1f ms  %5.2f%% of main" % (k, cats[k], cats[k] * ms, 100.0 * cats[k] / max(1, total["main"])))
print("fast path samples by offset in the block (offset: count)")
for (leaf, off), c in sorted(offs.items(), key=lambda x: x[0][1]):
    print("   %-11s +0x%03x %6d" % (leaf, off, c))
print("slow path leaf functions")
for n, c in slow_leaf.most_common(14):
    print("   %-60s %6d" % (n[:60], c))
