# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

"""Paired RC log measurements. The caller holds /tmp/lxr-bench.lock for the entire batch."""
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys


WORKLOADS = {
    "requests": (8192, 200000, 27134172608),
    "binarytrees": (18, 1, 68332294),
    "listsuffix": (8192, 600000, 159636632672),
    "mixedmedium": (12000, 200000, 40586599707),
    "losarrays": (1500, 100000, 13936826922),
    "mediumarrays": (20000, 300000, 7032863679),
}


def main():
    output = Path(sys.argv[1]).resolve()
    libraries = dict(baseline=sys.argv[2], demand=sys.argv[3])
    repetitions = int(sys.argv[4])
    frame = os.environ.get("FRAME", "/root/prof/frame-c4")
    driver = os.environ.get("DRIVER", "/root/prof/drv/bin/CompareDriver.dll")
    output.mkdir(parents=True, exist_ok=True)
    randomizer = random.Random(1903)
    records = []
    with (output / "runs.jsonl").open("w") as results:
        for repetition in range(repetitions):
            for workload, (size, operations, checksum) in WORKLOADS.items():
                labels = list(libraries)
                randomizer.shuffle(labels)
                for label in labels:
                    directory = output / f"{repetition}-{workload}-{label}"
                    directory.mkdir()
                    environment = {
                        key: value for key, value in os.environ.items()
                        if not key.startswith(("DOTNET_", "COMPlus_"))
                    }
                    environment.update(DOTNET_gcServer="1", DOTNET_GCPath=libraries[label])
                    result = subprocess.run(
                        [str(Path(frame) / ("corerun.exe" if os.name == "nt" else "corerun")), driver, str(directory), workload,
                         str(size), str(operations)],
                        env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, timeout=300,
                    )
                    (directory / "console.txt").write_text(result.stdout)
                    record = dict(label=label, workload=workload, repetition=repetition,
                                  exit=result.returncode)
                    if result.returncode == 0:
                        record.update(json.loads((directory / "result.json").read_text()))
                        assert record["checksum"] == checksum, record
                    records.append(record)
                    results.write(json.dumps(record) + "\n")
                    results.flush()
                    print(repetition, workload, label, record.get("wall_ms"),
                          record.get("collections"), result.returncode, flush=True)
    assert all(record["exit"] == 0 for record in records), "Some workload runs failed"
    with (output / "summary.txt").open("w") as report:
        for workload in WORKLOADS:
            for metric in ("wall_ms", "cpu_ms", "pause_ms", "collections", "peak_rss_mb"):
                paired = {}
                for label in libraries:
                    paired[label] = [record[metric] for record in records
                                     if record["workload"] == workload and record["label"] == label]
                differences = [new - old for old, new in zip(paired["baseline"], paired["demand"])]
                samples = sorted(statistics.median(randomizer.choices(differences, k=repetitions))
                                 for _ in range(10000))
                line = (f"{workload} {metric}: {statistics.median(paired['baseline']):.3f} -> "
                        f"{statistics.median(paired['demand']):.3f}; "
                        f"paired median {statistics.median(differences):+.3f} "
                        f"95% bootstrap [{samples[249]:+.3f}, {samples[9749]:+.3f}]")
                print(line, file=report)
                print(line)


if __name__ == "__main__":
    main()
