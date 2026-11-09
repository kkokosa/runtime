#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Reduced crash hunt of Laxori on Windows (the Windows twin of scripts/hunt3.sh).

usage: python hunt-windows.py <runs> <log> <offset> [NAME=VALUE ...]
Cycles 6 jobs (5 scaled workloads and PrivateTests) x 3 worker configurations (default, 4/2, 1/1 GC threads and concurrent threads).
The expected checksums come from a workstation-GC run of the same size. A run passes when the exit code is 0 and the checksum
is right (PrivateTests: exit code 0). The extra NAME=VALUE words go to the environment of every run (for example
DOTNET_LAXORIVerifyPrivate=1, DOTNET_GCPath=...). Runs without the benchmark lock; they are correctness runs."""
import json, os, subprocess, sys, tempfile

FRAME = os.environ.get("FRAME", r"C:\lx-run\frame")
DRIVER = os.environ.get("DRIVER", r"C:\lx-run\drv2\out\CompareDriver.dll")
PT = os.environ.get("PT", r"C:\lx-run\pt\out\PrivateTests.dll")
SZ = {"requests": (8192, 40000), "binarytrees": (16, 1), "listsuffix": (8192, 120000), "mixedmedium": (12000, 40000), "losarrays": (1500, 20000)}
JOBS = ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "private"]
CFG = [{}, {"DOTNET_LAXORIGCThreads": "4", "DOTNET_LAXORIConcGCThreads": "2"}, {"DOTNET_LAXORIGCThreads": "1", "DOTNET_LAXORIConcGCThreads": "1"}]
CFGNAME = ["13/3", "4/2", "1/1"]


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}


def drive(env, out, w, size, ops, timeout):
    return subprocess.run([os.path.join(FRAME, "corerun.exe"), DRIVER, out, w, str(size), str(ops)], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)


def main():
    runs, log, off = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    extra = dict(a.split("=", 1) for a in sys.argv[4:])
    sums = {}
    tmp = tempfile.mkdtemp(prefix="hunt-")
    for w, (size, ops) in SZ.items():
        env = clean_env()
        env["DOTNET_gcServer"] = "0"
        d = os.path.join(tmp, "sum-" + w)
        drive(env, d, w, size, ops, 300)
        sums[w] = json.load(open(os.path.join(d, "result.json")))["checksum"]
    ok = bad = 0
    with open(log, "w") as f:
        for j in range(runs):
            i = j + off
            w, ci = JOBS[i % 6], (i // 6) % 3
            env = clean_env()
            env.update({"DOTNET_gcServer": "1"})
            env.update(CFG[ci])
            env.update(extra)
            out = os.path.join(tmp, f"r{j}")
            os.makedirs(out, exist_ok=True)
            try:
                if w == "private":
                    r = subprocess.run([os.path.join(FRAME, "corerun.exe"), PT, "all", "1", "4"], env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, timeout=300)
                    passed, got, want = r.returncode == 0, "-", "-"
                else:
                    r = drive(env, out, w, *SZ[w], 150)
                    rp = os.path.join(out, "result.json")
                    got = json.load(open(rp))["checksum"] if os.path.exists(rp) else None
                    want = sums[w]
                    passed = r.returncode == 0 and got == want
            except subprocess.TimeoutExpired:
                r, passed, got, want = None, False, "timeout", "-"
            if passed:
                ok += 1
                f.write(f"{i} OK {w} [{CFGNAME[ci]}] {got}\n")
            else:
                bad += 1
                f.write(f"{i} FAIL rc={getattr(r, 'returncode', 'timeout')} {w} [{CFGNAME[ci]}] got={got} want={want}\n")
                if r is not None:
                    f.write("\n".join(r.stdout.splitlines()[-5:]) + "\n")
            f.flush()
        f.write(f"DONE ok={ok} bad={bad}\n")
    print(f"DONE ok={ok} bad={bad}")


main()
