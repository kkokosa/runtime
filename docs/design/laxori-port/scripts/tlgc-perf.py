#!/usr/bin/env python3
"""Inclusive time of the thread-local collector phases from a windowed perf profile (call chains).
usage: tlgc-perf.py <perf.data> <satori|laxori> [HZ]
Satori phases: SatoriRegion::ThreadLocalCollect/Mark/Plan/UpdatePointers/Compact. Laxori phases: LaxoriGcHeap::LocalCollect(Core)/Mark/Plan/Update/Compact.
The stack scan is GCToEEInterface::GcScanCurrentStackRoots below Mark or Update."""
import re, subprocess, sys, collections

PERF = "/usr/lib/linux-tools/5.15.0-202-generic/perf"
data, kind = sys.argv[1], sys.argv[2]
hz = float(sys.argv[3]) if len(sys.argv) > 3 else 10000.0
names = {
    "satori": dict(total="SatoriRegion::ThreadLocalCollect", mark="SatoriRegion::ThreadLocalMark", plan="SatoriRegion::ThreadLocalPlan",
                   update="SatoriRegion::ThreadLocalUpdatePointers", compact="SatoriRegion::ThreadLocalCompact"),
    "laxori": dict(total="LaxoriGcHeap::LocalCollectCore", mark="LaxoriGcHeap::LocalMark", plan="LaxoriGcHeap::LocalPlan",
                   update="LaxoriGcHeap::LocalUpdate", compact="LaxoriGcHeap::LocalCompact"),
}[kind]
out = subprocess.run([PERF, "script", "-i", data, "-F", "tid,ip,sym"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
samples = []
cur = None
for line in out.splitlines():
    if not line.strip():
        cur = None
        continue
    if re.match(r"^\s*\d+\s*$", line) or re.match(r"^\s*\d+/\d+\s*$", line):
        cur = []
        samples.append(cur)
        continue
    m = re.match(r"^\s+[0-9a-f]+\s+(.*)$", line)
    if m and cur is not None:
        cur.append(m.group(1).strip())
tot = len(samples)
ms = lambda n: 1000.0 * n / hz
inc = collections.Counter()
excl = collections.Counter()
scan = collections.Counter()
for s in samples:
    names_in = set()
    for k, v in names.items():
        for f in s:
            if f.startswith(v):
                inc[k] += 1
                names_in.add(k)
                break
    if s:
        for k, v in names.items():
            if s[0].startswith(v):
                excl[k] += 1
    if any(f.startswith("GCToEEInterface::GcScanCurrentStackRoots") for f in s):
        for k in ("mark", "update"):
            if k in names_in:
                scan[k] += 1
print(f"{data}: {tot} samples = {ms(tot):.0f} ms CPU in the window (all threads)")
for k in ("total", "mark", "plan", "update", "compact"):
    print(f"  {k:8s} inclusive {ms(inc[k]):8.1f} ms   exclusive {ms(excl[k]):8.1f} ms")
print(f"  stack scan inside mark   {ms(scan['mark']):8.1f} ms")
print(f"  stack scan inside update {ms(scan['update']):8.1f} ms")
