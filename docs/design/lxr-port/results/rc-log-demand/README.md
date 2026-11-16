# RC logs: commit on use

Base: `443e767fecc` (`kkokosa-lxr-windows-memory-limit-failures`).
Windows x64 and Linux x64 (WSL2), Release. No push or pull request.

## Result

The four RC streams still reserve their full address ranges, but no longer
commit one pointer for each admitted heap slot. Heap admission changes the
logical log limit, not the committed log size.

Windows startup private commit fell from **133.8 to 36.9 MiB** (five runs,
medians). Both `binarytrees 18 1` and `mediumarrays 20000 300000` now pass under
a 512 MiB process commit limit in a Windows job object. Both failed with the
baseline in this batch. The checksums are correct.

Ten paired Linux runs per standard workload found no wall-time, CPU-time,
or pause-time change whose 95% interval excludes zero. These intervals do
not prove zero cost, and some are wide.

## Change and safety

`LogStream::EnsureCommitted` backs the required prefix **before** the CAS
advances `reserved`. A reader therefore cannot receive an uncommitted range.
Already backed ranges need one acquire load on the buffer-publication path.
The assembly write barriers and the thread-local append path are unchanged.

Growth starts with at most 64 KiB of payload, doubles the increment up to
1 MiB, then uses increments of at most 1 MiB. If the admission check refuses
the preferred increment, the stream tries the minimum required page range.
All streams share a growth lock, so concurrent publishers cannot spend the
same native-plane allowance. Both the native-plane limit and the Windows
commit-headroom check also apply to log growth. Failed backing or admission
does not advance `reserved`; it returns the existing explicit OOM failure.
This does not add a new recovery path for write-barrier log exhaustion.

Observer streams use the same rule for their separate atomic publication
array. Its entries are initialized before their range becomes available.

`ResetBank` trims only a bank whose readers have finished. It keeps the
previous use rounded up to 64 KiB of payload, with a 64 KiB minimum for a
used stream, and decommits only when at least half the committed prefix can
be released. An unused stream stays at zero. Thus a large log can shrink
after a later quiet use without a commit/decommit call for every flush.
Payload and observer publication pages shrink together.

## Windows commit

`corerun` from `C:\lx-run\frame`, driver
`C:\lx-run\dl\drvlm\out\CompareDriver.dll`. No heap settings;
`DOTNET_gcServer=1`, `DOTNET_GCPath=<baseline or changed DLL>`.
The shared `run-in-job.ps1` test harness sets
`JOB_OBJECT_LIMIT_PROCESS_MEMORY`; these are per-process limits, not a
multi-process job/ballast test. One run per workload/limit/build, under the
shared benchmark lock for the whole batch. Values below are MiB, although
the harness prints "MB".

| Workload | Limit | Baseline result / peak commit | Changed result / peak commit |
|---|---:|---|---|
| binarytrees | 512 | OOM / 466 | pass / 222 |
| mediumarrays | 512 | OOM / 452 | pass / 242 |
| binarytrees | 1024 | pass / 646 | pass / 161 |
| mediumarrays | 1024 | pass / 897 | pass / 243 |

`binarytrees` checksum: `68332294`; `mediumarrays`: `7032863679`.
The baseline had also passed binarytrees at 512 MiB in earlier work; it
failed in this batch. Collection counts and peak commit vary between runs.
Other changed-build checks in this session had binarytrees peaks of 188
and 202 MiB at 512 MiB. The table uses the final batch, not the best run.

Startup, five runs after `GC.Collect()`:

| Metric | Baseline median [min, max] | Changed median [min, max] |
|---|---|---|
| Private commit, MiB | 133.8 [133.3, 134.3] | 36.9 [36.9, 37.2] |
| Working set, MiB | 44.9 [44.7, 45.7] | 44.6 [44.5, 44.6] |

The baseline's four largest private committed regions were 24 MiB each.
They are absent from the changed startup probe. Untouched committed pages
explain why the commit reduction is much larger than the working-set change.

Raw Windows output: `data/windows-memory-baseline.txt`,
`data/windows-checksums-and-memory.txt`, and `data/startup-*.txt`.

## Paired timing

Six standard workloads, ten pairs each, 120 successful processes with
checked checksums. Default heap settings, same frame and driver for both
libraries, deterministic shuffled old/new order within each pair. The
entire batch held `/tmp/lxr-bench.lock`, not one lock per process. No build
was run by this session during the paired batch.

The table gives paired median changes, with 95% percentile bootstrap
intervals from 10,000 resamples. A paired median difference need not equal
the difference between the two separate medians. Times are milliseconds.

| Workload | Wall medians old / new | Wall delta [95% interval] | CPU delta [95% interval] | Pause delta [95% interval] | Collection medians old / new |
|---|---|---|---|---|---|
| requests | 379.5 / 377.0 | -2.6 [-30.3, +8.4] | -4.5 [-34.8, +10.1] | -0.9 [-3.9, +1.2] | 9 / 9 |
| binarytrees | 1086.2 / 1096.1 | +9.3 [-53.5, +37.2] | +330.4 [-1098.4, +949.2] | +5.9 [-57.4, +41.3] | 26 / 24 |
| listsuffix | 1347.0 / 1376.0 | +18.5 [-23.9, +91.1] | +137.2 [-149.2, +426.6] | +7.7 [-8.3, +27.1] | 6 / 6.5 |
| mixedmedium | 1423.4 / 1442.3 | +2.2 [-63.3, +49.2] | -8.6 [-72.6, +137.6] | +4.9 [-3.9, +16.4] | 216 / 215.5 |
| losarrays | 1128.5 / 1145.2 | -4.6 [-66.2, +32.8] | +15.0 [-93.8, +30.7] | -10.3 [-18.3, +4.9] | 49 / 49 |
| mediumarrays | 1309.4 / 1346.2 | +13.8 [-3.7, +85.1] | +33.8 [-2.5, +105.2] | +5.0 [-5.7, +13.8] | 97.5 / 97 |

Full medians, CPU values, collection counts, RSS and intervals:
`data/linux-summary.txt`. Raw process records: `data/linux-runs.jsonl`.
`data/binary-identities.csv` identifies the exact libraries.

The native `--copy-study` was also run, seven samples per width, baseline
then changed. Excluding the first cold sample, median time per one-entry
publication was 18.2 -> 21.1 ns; per 64-entry publication, 69.3 -> 91.4 ns.
These small, unpaired samples are not a throughput estimate or evidence of
zero publication cost. Raw data is in `data/copy-study-*.csv`.

Reproduce the paired batch with libraries built from the same configuration:

```sh
flock /tmp/lxr-bench.lock python3 \
  docs/design/lxr-port/results/rc-log-demand/benchmark.py \
  /tmp/rc-log-results /absolute/old/libclrlxrgc.so /absolute/new/libclrlxrgc.so 10
```

`FRAME` and `DRIVER` select the runtime and CompareDriver paths. The output
directory must be new. The runner needs only Python's standard library.

## Validation and limits of the evidence

* Linux Release P2.1-P2.5 and P3.1-P3.4: passed for both object-start variants.
* Linux Release P4 default run and all selectors from
  `P31-object-start-walk/run-p4-selectors.sh`: passed for both variants in
  the final full pass, except `--zero-rc-control`, which correctly exits 1
  for its injected error. The final selector logs are preserved in `data/`.
* The added log tests pass **2121/2121** on Linux (both variants) and Windows
  (count-plane variant). They cover empty streams, concurrent partial
  publications across commit boundaries, trim/recommit, observer publication
  storage, failed payload/publication commit, native-budget refusal, minimum
  page fallback, exact payload decoding, and old-bank reader ownership.
  The new zero-startup-commit assertion failed against the original engine.
* Windows count-plane native growth selector: **1433/1433**. Its test-only
  wrapper undefines the Windows `small` macro and suppresses existing
  C4456/C4701/C4703 test warnings. The unmodified Windows P4 build script
  does not compile this existing test file without those local measures.
* PrivateTests `all 2 13`: **20/20 for each variant on each OS** (80 runs).
  Linux reused the portable built PrivateTests assembly because the SDK
  path in `repeat.sh` did not contain an SDK. No dependency was installed.
* All six standard-workload checksums also passed once for each changed
  library variant on Linux and Windows.
  In `data/smoke-*-variants.jsonl`, the runner's `baseline` label means the
  changed count-plane library and `demand` means the changed bitmap library;
  these files are checksum checks, not baseline performance comparisons.

An intermediate run of `--mature-released-candidate` failed intermittently.
The untouched baseline executable reproduced the same two failed checks
in **1 of 10 runs**. It passed in the final full pass for both changed
variants. This existing test failure is not fixed here; see
`data/baseline-selector-flake.txt`.

Not run: a paired Windows timing study, the full Windows native selector
matrix, Debug suites, multi-process job/ballast limits, or long-duration
stress. Ten pairs do not exclude a small throughput regression. The change
does not alter collection policy or make arbitrary log exhaustion recoverable.
