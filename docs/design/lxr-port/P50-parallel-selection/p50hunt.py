#!/usr/bin/env python3
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
"""Crash hunt for the parallel selection: many short runs of the six workloads and of the interior-pointer stress test at several
worker counts (the program of docs/design/lxr-port/P31-object-start-walk/p31hunt.py, with the library and the extra settings as
arguments).
usage: p50hunt.py <frame directory> <runs per config> <out.jsonl> [configs=13:3,4:2,1:1]
  P50_EXTRA_ENV='{"DOTNET_LXRSelectParallelBlocks":"0","DOTNET_LXRSelectValidate":"1","DOTNET_LXRTraceThreshold":"1"}'
  HUNT_PROGRAMS=stress,requests restricts the programs.
The frame directory holds corerun and libclrlxrgc.so. A run fails on a nonzero exit code, a wrong checksum, a failure line of the
stress test, or a timeout."""
import json, os, subprocess, sys, time

frame, runs, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
configs = (sys.argv[4] if len(sys.argv) > 4 else "13:3,4:2,1:1").split(",")
driver = "/root/prof/drv/bin/CompareDriver.dll"
stress = "/root/p31/InteriorStress/bin/InteriorStress.dll"
WORK = {"binarytrees": (18, 1), "requests": (8192, 200000), "listsuffix": (8192, 600000),
        "mediumarrays": (20000, 300000), "mixedmedium": (12000, 200000), "losarrays": (1500, 100000)}
SUMS = {"requests": "27134172608", "binarytrees": "68332294", "listsuffix": "159636632672",
        "mixedmedium": "40586599707", "losarrays": "13936826922", "mediumarrays": "7032863679"}
programs = os.environ.get("HUNT_PROGRAMS", ",".join(list(WORK) + ["stress"])).split(",")
extra = json.loads(os.environ.get("P50_EXTRA_ENV", "{}"))
failures = 0
with open(out, "a") as f:
    for config in configs:
        workers, conc = config.split(":")
        for i in range(runs):
            program = programs[i % len(programs)]
            env = {k: v for k, v in os.environ.items() if not k.startswith(("DOTNET_", "COMPlus_"))}
            env.update({"DOTNET_gcServer": "1", "DOTNET_GCPath": frame + "/libclrlxrgc.so", "DOTNET_EnableWriteXorExecute": "0",
                        "DOTNET_LXRGCThreads": workers, "DOTNET_LXRConcGCThreads": conc})
            env.update(extra)
            rundir = "/root/p50/hunt-run"
            os.makedirs(rundir, exist_ok=True)
            if program == "stress":
                cmd = [frame + "/corerun", stress, "6", "250", str(1000 + i)]
            else:
                if program == "mediumarrays":
                    env["DOTNET_LXRImmixInitialMB"], env["DOTNET_LXRImmixReserveMB"] = "200", "400"
                size, ops = WORK[program]
                cmd = [frame + "/corerun", driver, rundir, program, str(size), str(ops)]
            status, detail = "ok", ""
            start = time.time()
            try:
                r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
                text = r.stdout
                if r.returncode != 0:
                    status, detail = "rc%d" % r.returncode, text[-400:]
                elif program == "stress":
                    if "InteriorStress PASS" not in text:
                        status, detail = "stressfail", text[-400:]
                else:
                    result = json.load(open(os.path.join(rundir, "result.json")))
                    if str(result.get("checksum")) != SUMS[program]:
                        status, detail = "badsum", str(result.get("checksum"))
            except subprocess.TimeoutExpired:
                status = "timeout"
            if status != "ok":
                failures += 1
            f.write(json.dumps({"config": config, "i": i, "program": program, "status": status,
                                "seconds": round(time.time() - start, 1), "detail": detail}) + "\n")
            f.flush()
print("hunt", frame, "runs per config", runs, "configs", configs, "failures", failures)
