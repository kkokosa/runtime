# Benchmark result files

Agents write one JSON file per benchmark checkpoint into this directory. The canvas loads every
`*.json` file, merges its `checkpoints` array, and orders checkpoints by date.

```json
{
    "schemaVersion": 1,
    "checkpoints": [
        {
            "id": "p4-4-stw-sweep-removed",
            "date": "2026-08-07",
            "stepId": "P4.4",
            "notes": "Controlled A/B/C run details and interpretation.",
            "results": [
                {
                    "scenario": "webapi",
                    "collector": "lxr",
                    "operationsPerSecond": 250.0,
                    "pauseAverageMs": 5.0,
                    "pauseP99Ms": 12.0,
                    "pauseMaxMs": 20.0,
                    "workingSetMb": 250.0,
                    "committedMb": 220.0,
                    "notes": "Run count, duration, configuration, and failures."
                }
            ]
        }
    ]
}
```

Use the same checkpoint ID, date, step ID, workload inputs, runtime build, duration, warmup, and run
count for LXR, Workstation GC, and Server GC results. Use `null` for unavailable metrics.

## `archive/`

The canvas reads only the top level of this directory, so anything moved into `archive/` disappears
from the charts while remaining on disk for provenance. `archive/baseline-2026-08-03.json` holds the
checkpoint from the abandoned `C:\github\runtimelab` prototype: its `lxr` rows measure a collector
that no longer exists and its baseline rows came from a different harness, so it must not be compared
against results produced by the current roadmap. Fresh baselines come from step P0.5.
