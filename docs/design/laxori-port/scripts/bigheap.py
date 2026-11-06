#!/usr/bin/env python3
"""P49 bigheap InitialMark pause (item 8a of LXR) for two Laxori builds, interleaved, one flock per run.
usage: bigheap.py <outdir> <reps> <liveMB> <capMB> <seconds> <tagA> <tagB> ...     (tags: /root/laxori/v/libclrlaxorigc-count-<tag>.so)
The driver is docs/design/laxori-port/driver-scaling (the ScalingDriver of LXR P49), built in /root/laxori/drv-scale.
The Laxori library has no per-pause kind record, so the pauses of the measured window are taken from the runtime events
(pauses.csv). With a trace threshold of 2 and this workload, a pause of 30 ms or more is an InitialMark or Full pause
(the other pauses are reference-counting pauses of a few ms); the script prints their count, median and maximum, and the median of all pauses."""
import fcntl, json, os, statistics, subprocess, sys

FRAME = "/root/prof/frame-c4"
DRV = os.environ.get("SCALE_DRV", "/root/laxori/drv-scale/bin/ScalingDriver.dll")
LONG_MS = float(os.environ.get("LONG_MS", "30"))


def main():
    out, reps, live, cap, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    tags = sys.argv[6:]
    os.makedirs(out, exist_ok=True)
    res = {t: [] for t in tags}
    for rep in range(reps):
        for tag in tags:
            rundir = os.path.join(out, f"{tag}-{rep}")
            os.makedirs(rundir, exist_ok=True)
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
            lib_tag = tag.split("+")[0]
            env.update({"DOTNET_gcServer": "1", "DOTNET_GCPath": f"/root/laxori/v/libclrlaxorigc-count-{lib_tag}.so",
                        "DOTNET_LAXORIImmixInitialMB": str(cap), "DOTNET_LAXORIImmixReserveMB": str(cap),
                        "DOTNET_LAXORINativePlaneLimitMB": "200000", "DOTNET_LAXORITraceThreshold": "2"})
            if tag.endswith("+serial"):
                env["DOTNET_LAXORISelectParallelBlocks"] = "4294967295"    # the selection stays serial at any heap size
            cmd = [f"{FRAME}/corerun", DRV, rundir, "bigheap", str(live), str(secs), "2", "30", "300"]
            with open("/tmp/lxr-bench.lock", "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800)
            path = os.path.join(rundir, "pauses.csv")
            if r.returncode != 0 or not os.path.exists(path):
                print(rep, tag, "FAILED rc", r.returncode, r.stdout[-300:], flush=True)
                continue
            d = [float(l.split(",")[1]) for l in open(path).read().split("\n")[1:] if l]
            long_ = [x for x in d if x >= LONG_MS]
            rec = dict(n=len(d), longn=len(long_), longmed=statistics.median(long_) if long_ else 0, longmax=max(long_) if long_ else 0,
                       med=statistics.median(d) if d else 0)
            res[tag].append(rec)
            print(rep, tag, rec, flush=True)
    print("\nmedians over runs: pauses / long pauses (>= %g ms) / median of long ms / max ms / median of all ms" % LONG_MS)
    for tag in tags:
        rs = res[tag]
        if rs:
            m = lambda k: statistics.median(r[k] for r in rs)
            print(f"{tag:6} n={len(rs)} {m('n'):6.0f} {m('longn'):5.0f} {m('longmed'):8.1f} {m('longmax'):8.1f} {m('med'):6.2f}")


main()
