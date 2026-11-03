#!/usr/bin/env python3
"""Prints the thread-local collector diagnostics of Laxori runs (LAXORITlTimers=1) per collection.
usage: tl-report.py <result.json>...   (result.json of the driver; the `region` array holds the counters)"""
import json, sys

CYC = ["total", "esc-scan", "stack-mark", "sync-walk", "propagate", "plan", "stack-update", "obj-update", "compact", "failed-attempts"]
CNT = ["stack-scans", "roots", "roots-in-region", "esc-objs", "esc-bytes", "sync-walk-objs", "prop-objs", "plan-objs", "moved-bytes", "upd-objs"]
for path in sys.argv[1:]:
    r = json.load(open(path))
    g = r["region"]
    if not g[17]:
        print(path, "no timers"); continue
    khz = g[43]
    calls, colls = g[17], g[5]
    cyc = g[18:28]; cnt = g[28:38]
    us = lambda c, n: c / khz * 1000.0 / n if n else 0.0     # microseconds per n
    print(f"== {path}: wall {r['wall_ms']:.0f} ms, TSC {khz/1e6:.2f} GHz")
    print(f"   LocalCollect calls {calls}, collections done {colls}, skipped {g[6]}, mark aborted {g[7]}, not worth {g[8]}, escaped MB {g[13]/1048576:.1f}")
    print(f"   total TLGC {cyc[0]/khz:.1f} ms = {us(cyc[0], calls):.1f} us/call, {us(cyc[0], colls):.1f} us/successful collection")
    for i in range(1, 9):
        print(f"     {CYC[i]:15s} {cyc[i]/khz:8.1f} ms  {100.0*cyc[i]/max(1,cyc[0]):5.1f}%  {us(cyc[i], colls):7.2f} us/collection")
    print(f"     {'failed attempts':15s} {cyc[9]/khz:8.1f} ms (calls that did not collect)")
    print(f"   per collection: stack scans {cnt[0]/colls:.2f}, roots {cnt[1]/max(1,cnt[0]):.0f} per scan ({cnt[2]/max(1,cnt[0]):.1f} in region), "
          f"escaped objs rescanned {cnt[3]/colls:.1f} ({cnt[4]/colls/1024:.1f} KB), sync-walk objs {cnt[5]/colls:.0f}, propagated {cnt[6]/colls:.1f}, "
          f"planned {cnt[7]/colls:.0f}, moved {cnt[8]/colls/1024:.1f} KB")
    print(f"   survivor KB/collection {g[9]/colls/1024:.1f}, reclaimed MB total {g[10]/1048576:.0f}")
    print(f"   dissolve: {g[39]} regions, {g[38]/khz:.1f} ms total ({us(g[38], g[39]):.1f} us each); at pauses {g[42]/khz:.1f} ms; gap zeroing {g[40]/khz:.1f} ms for {g[41]/1048576:.0f} MB")
