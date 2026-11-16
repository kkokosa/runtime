# RC logs: commit on use

Base: `a93a52045fb324388df4fd3a7c3396ce8e2f0869`
(`kkokosa-laxori-job-limit-check`). This is the Laxori port of the LXR
change in local commit `2499e220465`. No push or pull request.

## Result

Unused reference-count (RC) log streams now reserve address space without
committing pages. Heap growth changes their logical capacity, not their
committed size. Pages are committed before entries can use them.

Windows startup private commit fell from **151.0 to 54.8 MiB** in five runs
per build. At 32 MiB retained under a 1 GiB job limit, the probe reported
**352.4 to 0.2 MiB** of RC-log commitment, with 88 MiB admitted in both runs.
Private commit at that point fell from **479.3 to 126.7 MiB**.

Ten paired Linux runs per standard workload found no wall-time, CPU-time,
or pause-time regression whose 95% interval excludes zero. The
mediumarrays wall-time interval is below zero. This finite, partly noisy
batch does not prove zero overhead or a general speed gain.

The 40 MiB retained-small-array probe now passes under both whole-job and
per-process 512 MiB limits. The baseline catches an out-of-memory exception
after about 33 MiB. The changed library also passes a 512 MiB whole-job
test with a second, suspended process holding 64 MiB of commit.

## Change and safety

The four streams retain their stable reserved addresses and logical limits.
`EnsureCommitted` commits a prefix before the atomic reservation operation
can expose it. The assembly barriers and thread-local append path do not
change. Publication of a buffer into an already committed range adds one
atomic load.

Growth starts with at most 64 KiB of payload. Its increment doubles up to
1 MiB, then stays at most 1 MiB. All streams share a growth lock, so their
admission checks cannot spend the same native-memory allowance. The native
limit and the existing Windows process/job commit-headroom checks apply.
If the preferred increment does not fit, the stream tries the minimum
required page range.

Observer streams commit and initialize their separate publication array
before the range becomes available. A failed admission or commit returns
the existing explicit out-of-memory result without advancing the reserved
entry count. This does not add recovery for arbitrary write-barrier log
exhaustion.

After a bank's readers finish, reset keeps its recent use rounded up to
64 KiB of payload, with a 64 KiB minimum for a used stream. It releases a
tail only when at least half the committed prefix can be released. An
unused stream stays at zero. Observer payload and publication pages are
trimmed together. A later quiet use can therefore release a previous peak
without committing and releasing pages on every buffer publication.

## Windows memory

Both GC libraries were built here from the same configuration. The runtime
and managed assemblies were copied from the preceding Laxori memory work.
The source runtime folder is named `frame-release`, but the copied
`coreclr.dll` has its file-version **Debug flag set**; this is not evidence
from a newly built full Release runtime. All GC and native validation
builds in this report are Release.

No heap settings were used: `DOTNET_gcServer=1` and an absolute
`DOTNET_GCPath` select the library. Sizes below are MiB. The probe prints
commit values to one decimal place.

Startup after `GC.Collect()`, five processes per build:

| Metric | Baseline median [min, max] | Changed median [min, max] |
|---|---|---|
| Private commit, MiB | 151.0 [150.8, 151.1] | 54.8 [54.6, 55.0] |
| Working set, MiB | 82.5 [82.2, 82.5] | 82.5 [82.4, 82.6] |

Retained-small-array probe, one process per case:

| Limit and scope | Baseline at 32 MiB retained: log / private commit | Changed at 32 MiB retained: log / private commit | Final result, baseline / changed |
|---|---|---|---|
| 512 MiB whole job | 328.9 / 450.0 | 0.2 / 127.9 | caught OOM / retained 40 MiB |
| 512 MiB per process | 328.8 / 449.9 | 0.2 / 127.3 | caught OOM / retained 40 MiB |
| 1024 MiB whole job | 352.4 / 479.3 | 0.2 / 126.7 | retained 40 MiB / retained 40 MiB |
| 1024 MiB per process | 349.5 / 475.1 | 0.2 / 126.7 | retained 40 MiB / retained 40 MiB |

The changed whole-job case with a 64 MiB companion reports 0.2 MiB of logs
and 127.8 MiB of process private commit at 32 MiB retained, then retains
40 MiB. All successful probes check the retained contents and process exit.
These are not peak measurements.

Standard workloads inside whole-job limits, one run per case. The values
are the driver's process peak commit, not a separately sampled whole-job
peak:

| Workload | Job limit | Baseline result / peak commit | Changed result / peak commit |
|---|---:|---|---|
| binarytrees | 512 | pass / 464.3 | pass / 161.0 |
| mediumarrays | 512 | OOM / no completed result | pass / 258.3 |
| binarytrees | 1024 | pass / 579.6 | pass / 176.9 |
| mediumarrays | 1024 | pass / 897.3 | pass / 259.3 |

The baseline mediumarrays diagnostic reports about 449 MiB job commit
before the managed exception. Successful binarytrees checksums are
`68332294`; mediumarrays checksums are `7032863679`. Peak commit and
collection counts vary between runs. This table is memory evidence, not
a controlled timing comparison.

The tables use the final captured job batch. An earlier check produced
different peaks, for example 202.9 MiB for changed binarytrees at 512 MiB.
The startup table uses the first five-run batch, not a selection of the
lowest samples.

## Paired timing

Linux x64 under WSL2, Release GC libraries, the same copied runtime and
driver for both builds, and default heap settings. There are ten pairs for
each of the six workloads: **120 successful processes**, each with its
expected checksum. Old/new order is deterministically shuffled within
each pair. The whole batch holds `/tmp/lxr-bench.lock` once. This session's
builds, native tests, private verifiers, and other workload runs finish
before the timing batch starts.

The table gives paired median changes and 95% percentile bootstrap
intervals from 10,000 resamples. A paired median difference need not equal
the difference of the two separate medians. Times are milliseconds.

| Workload | Wall medians old / new | Wall delta [95% interval] | CPU delta [95% interval] | Pause delta [95% interval] | Collection medians old / new |
|---|---|---|---|---|---|
| requests | 353.0 / 352.0 | -1.0 [-23.3, +18.2] | +1.7 [-20.2, +22.5] | +0.2 [-0.7, +0.8] | 2 / 2 |
| binarytrees | 1122.6 / 1111.7 | -9.4 [-37.1, +35.7] | +79.3 [-425.1, +353.7] | +2.7 [-11.2, +15.5] | 16.5 / 15 |
| listsuffix | 1595.2 / 1591.3 | +9.8 [-84.5, +51.9] | -25.2 [-248.8, +118.0] | -0.8 [-13.9, +9.6] | 8 / 8 |
| mixedmedium | 1478.6 / 1494.6 | +10.2 [-19.8, +34.5] | +10.0 [-41.3, +54.3] | -1.4 [-9.6, +7.9] | 213 / 214 |
| losarrays | 1143.2 / 1134.0 | +22.9 [-78.9, +46.1] | -9.6 [-157.5, +73.0] | -5.0 [-16.1, +13.1] | 49 / 49 |
| mediumarrays | 1403.8 / 1363.1 | -17.0 [-67.1, -3.8] | -61.4 [-116.7, +2.5] | -4.8 [-15.2, +4.7] | 97.5 / 98 |

Full results, including collection counts and RSS, are in
`data/linux-summary.txt` and `data/linux-runs.jsonl`. Some intervals are
wide. The mediumarrays result is not a claim that all programs get faster.

To repeat with matched libraries and a new output directory:

```sh
flock /tmp/lxr-bench.lock python3 \
  docs/design/laxori-port/results/rc-log-demand/benchmark.py \
  /tmp/laxori-rc-results /absolute/old/libclrlaxorigc.so /absolute/new/libclrlaxorigc.so 10
```

`FRAME` selects the directory containing `corerun`; `DRIVER` selects the
CompareDriver assembly. The runner uses only Python's standard library.

## Native checks

Linux P2.1-P2.5, P3.1-P3.4, and P4 default plus every normal selector pass
for both object-start variants. The intentional `--zero-rc-control`
failure is detected for both variants.

Windows P2.1-P2.5, P3.2-P3.4, and all P4 selectors pass for both variants.
P3.1 passes for the count variant. In the bitmap batch it fails only
`non-owner work stealing observed`; 2 of 10 immediate reruns of that same
executable fail the same check. Its test, packet, and scheduler sources
are unchanged from `a93a52045fb`. This existing scheduling-dependent
test is not fixed or hidden by this change.

The focused log checks pass **2121/2121** on both operating systems and
both variants. They check empty streams, concurrent partial publication
across commit boundaries, trim and recommit, observer storage, failed
payload/publication commits, native-budget refusal, minimum-page fallback,
payload decoding, and reader ownership. Against the untouched baseline
engine, the new tests report **2114/2121**, including the expected failure
of the zero-startup-commit assertion.

## Workload and private checks

PrivateTests `all 2 T` passes **200 processes**: both operating systems,
both object-start variants, and both L1 and L2 modes, with
`DOTNET_LAXORIVerifyPrivate=1`. Each combination runs once at 1, 2, 4, 8,
and 13 threads, then 20 more times at 13 threads. The runners check both
the process exit and the final `PASS`. The already built portable test
assembly is reused on Linux; no SDK or dependency was installed.

All six standard workloads also pass once with each changed variant on
each OS, with the expected checksums. In `data/smoke-*-variants.jsonl`,
the runner's `baseline` label means the changed count-plane library and
`demand` means the changed bitmap library. These are checksum checks under
verification load, not controlled timing comparisons.

## Evidence and reproduction

`data/binary-identities.csv` records the baseline and changed GC hashes.
`data/frame-identities.csv` records the copied runtimes, drivers, memory
probe, and private-test assembly. `data/private-runs.csv` lists all 200
successful verifier processes. Native suite/selector summaries, the failed
baseline log test, scheduler reruns, startup samples, and final Windows
job output and result JSON are also retained in `data/`.

The Windows job tests use
`docs/design/laxori-port/MemoryLimits/run-in-job.ps1`. It assigns the child
to the job while the child is suspended, before starting the runtime.
For example, with copies of the frame and probe in an owned folder:

```powershell
$env:DOTNET_GCPath = 'C:\your-output\clrlaxorigc.dll'
$env:DOTNET_gcServer = '1'
powershell -NoProfile -File "$repo\docs\design\laxori-port\MemoryLimits\run-in-job.ps1" `
    -LimitMB 512 -FilePath 'C:\your-output\frame\corerun.exe' `
    -Arguments 'C:\your-output\probe\MemoryLimits.dll 1024 350 40 small' *> job.txt
```

Add `-ProcessLimit` for the process limit or `-CompanionCommitMB 64` for
the whole-job companion check. The baseline 512 MiB probe needs `oom`
after `small` to expect its caught exception. Use expected reserve 2048
for a 1024 MiB limit.

Run the harness in a separate PowerShell process when capturing output.
Its native child inherits `GetStdHandle` handles and can bypass an
in-process PowerShell redirection. The initial job runs were repeated
with this capture method; the tables use that final, retained evidence.

Not run: Debug GC/native suites, a newly built full Release Windows
runtime, paired Windows timing, full framework suites, or dedicated
long-duration stress. The unchanged P3.1 work-stealing check is not clean
on Windows. Finite workload measurements cannot prove zero overhead or
that every application will fit a given job limit.
