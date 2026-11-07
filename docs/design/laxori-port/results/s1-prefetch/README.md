# Laxori S1 prefetch in ProcessChildIncrements: result

Status: implemented, validated, measured. Not pushed.

## 1. Result in short

* The change is one commit: `24a2706732c` on branch `kkokosa-laxori-s1-prefetch` (base `9c88b2681b6`, branch `kkokosa-laxori-gc`).
  Files: `src/coreclr/gc_laxori/laxori_prefetch.h`, `src/coreclr/gc_laxori/laxori_reference_counting.cpp`, and a unit test in `docs/design/laxori-port/P2.4/immix-allocation-validation.cpp`.
* Against the library of the base commit (same toolchain, same build directory), `listsuffix` (30 pairs) gets **CPU -9.6 % [-11.7, -7.1]** and **pause -17.4 % [-19.7, -14.6]**.
  `mixedmedium` pause is -7.7 % [-9.5, -1.5] (15 pairs). The wall time of `listsuffix` does not change in a significant way (-1.5 % [-5.5, +0.5]).
* `losarrays` is slower: **CPU +2.1 % [+0.2, +2.9], wall +2.8 % [+0.6, +3.9]** (30 pairs). This is a small real loss in this data.
* `binarytrees` (30 pairs): CPU -2.6 % [-8.9, +5.3], pause -3.2 % [-6.2, +3.4], wall -0.9 % [-2.8, +1.1]. No significant change.
  A CPU loss of more than 5.3 % is excluded at the 95 % level. A loss of about 5 % is not excluded.
* All validation steps pass (section 4). The layout of the hot classes is unchanged (section 3).

## 2. What the code does

`ProcessChildIncrements` works on a buffer of slots (`slots[0..count)`). The old loop called `LaxoriPrefetch::Ahead(slots, count, index, true)`.
That call loads the slot of entry `index + 8` to find the target. The line of that slot is cold, so the load waits for memory.

The new loop has two stages:

1. Stage 0. At entry `i`, the line of the slot of entry `i + 16` is prefetched. The address is known, so nothing is loaded (`LaxoriPrefetch::SlotLineAhead`).
2. Stage 1. At entry `i`, the slot of entry `i + 8` is loaded. Its line is warm now, because stage 0 prefetched it 8 entries earlier.
   The header line and the count byte (`m_rc_metadata.LocateByte`) of the target are prefetched. A local lambda `prefetchTarget` does this.
3. Before the loop of a buffer, the first 16 slot lines and the targets of the first 8 entries are prefetched, because no earlier iteration did it.

Other facts:

* No environment switch. No experiment counter. One code path. Distances: `Step` = 8 (already in the file), `SlotStep` = 16 (new).
* All prefetches use `LaxoriPrefetch::Read`. So `-DLAXORI_NO_PREFETCH` removes them and the P2.4 test hook sees them.
* `Ahead` stays. The other loops use it (`ProcessIncrementWork`, the decrement loops, the trace loops). This commit does not change them.
* The children stage, the read pass, the other places and the trace variant of the study are not ported.

## 3. Layout

No data member is added. `scripts/layout-check.sh` dumps `-Xclang -fdump-record-layouts` of `LaxoriReferenceCounting`, `LaxoriRcConfiguration`, `LaxoriPauseTimers`,
`LaxoriLargeObjectSpace`, `Span` and `SideState` for the sources of the base commit (`ref`) and for the working tree (`cur`), with the compile command of the product build.
Result: `rc cur: IDENTICAL to ref`, `los cur: IDENTICAL to ref` (`data/layout/`).

## 4. Validation

All steps used the library built from commit `24a2706732c` (`s1.so`). Every step held the benchmark lock alone (`scripts/validate-s1.sh`; output in `data/val/`).

| check | result |
|---|---|
| native suites P2.1 to P2.5, P3.1 to P3.4, P4 release (`run-native-all.sh`; it compiles the sources of the worktree) | all pass; P4: 105881 / 105881 checks; P2.4: 277863 / 277863 (it includes the two new checks of `SlotLineAhead`) |
| PrivateTests `all 2` with the verifier, 1/2/4/8/13 threads, L2 (default) and L1 (`DOTNET_LAXORIEscapedInPlace=0`) | 10 / 10 pass |
| PrivateTests `all 2 13`, 20 runs each, interleaved: base L2, s1 L2, s1 L1 | 0 / 20, 0 / 20, 0 / 20 failed |
| crash hunt (`hunt3.sh`: five workloads and PrivateTests, three worker configurations, verifier on), L2 | 54 of 54 pass, checksums right |
| the same, L1 | 36 of 36 pass |
| the same with forced trace (`DOTNET_LAXORITraceThreshold=1`) | 30 of 30 pass |
| checksums of the six standard workloads in the A/B (runner compares with fixed sums) | 300 of 300 runs right (section 5) |

## 5. A/B against the base commit

Method. `scripts/run-ab2.py` (the runner and analyzer of the locality-batching-2 study). Configurations: `base` (library from the sources of `9c88b2681b6`) and `s1` (commit `24a2706732c`).
Both were built in the same build directory with the same toolchain (clang 14, Release): first `s1`, then `base` after a checkout of the base sources, and the worktree was restored afterwards.
For each pair and workload, both configurations run in a shuffled order inside one hold of `flock /tmp/lxr-bench.lock` (one block for each lock grant), then the lock is released and the runner sleeps 8 s.
`DOTNET_gcServer=1`. Difference = (s1 - base) / base for each pair. The table shows the median of the pairs and the 95 % bootstrap interval of the median (10 000 resamples). Bold = interval excludes 0.
Pairs: 30 for `listsuffix`, `binarytrees`, `losarrays`, `mediumarrays`; 15 for `requests` and `mixedmedium`.
The first 15 pairs of `losarrays` and `mediumarrays` showed a loss (losarrays CPU +2.4 %, mediumarrays pause +5.9 %), so 15 more pairs were taken for them.
The other jobs of the machine (Windows benchmarks of another session) used the lock between the blocks of this A/B.

| workload | pairs | CPU % | pause % | wall % | median base CPU / pause / wall (ms) |
|---|---|---|---|---|---|
| requests | 15 | -0.0 [-6.4, +4.0] | +2.4 [-4.1, +5.8] | -0.4 [-1.0, +4.8] | 386 / 10 / 318 |
| binarytrees | 30 | -2.6 [-8.9, +5.3] | -3.2 [-6.2, +3.4] | -0.9 [-2.8, +1.1] | 2553 / 118 / 1094 |
| listsuffix | 30 | **-9.6 [-11.7, -7.1]** | **-17.4 [-19.7, -14.6]** | -1.5 [-5.5, +0.5] | 4120 / 208 / 1443 |
| mixedmedium | 15 | -2.3 [-3.9, +1.0] | **-7.7 [-9.5, -1.5]** | -0.8 [-3.0, +1.4] | 2284 / 180 / 1350 |
| losarrays | 30 | **+2.1 [+0.2, +2.9]** | +0.7 [-0.2, +3.4] | **+2.8 [+0.6, +3.9]** | 2324 / 412 / 1062 |
| mediumarrays | 30 | +0.8 [-0.6, +2.6] | +1.0 [-2.4, +5.1] | +0.9 [-0.2, +1.6] | 1696 / 96 / 1002 |

Full table with the count of pairs in which `s1` is lower: `tables/ab-full.md` and `tables/ab-full.tsv`. Raw runs: `data/ab/runs.jsonl` (300 runs, all status `ok`).

Reading of the table:

* The gain is where the study said it would be: long chains of child increments (`listsuffix`) and some of `mixedmedium`. The size of the gain agrees with the study (all places: CPU -6.8 %, pause -14.6 % against its `base`; P1 only: CPU -6.4 %, pause -15.8 % against `off`).
  The CPU gain here (-9.6 %) is larger than in the study. The run-to-run variation of this machine is of this size, so use the interval, not the median.
* `losarrays` loses about 2 % of CPU and 3 % of wall time. Only 9 or 10 of 30 pairs are lower. The cause was not measured [N].
  A likely cause is the extra work for each entry (Start, `IsImmix`, `LocateByte`, two prefetches and one more slot-line prefetch) in a loop whose targets the hardware already handles well [N].
  The study (with all places on, against its `off`) did not see this loss: +0.3 % [-0.7, +1.9] CPU. That is a different baseline and a different data set.
* `binarytrees`: no significant change. The study could not exclude +7 %; with 30 pairs the upper bound of the CPU interval is +5.3 %.
  The CPU interval of this workload is wide (about 14 points), so 30 pairs do not show an effect smaller than about 5 %.
* The bootstrap interval moves a little between two runs of the analyzer (for `mixedmedium` CPU the upper bound was -0.6 and +1.0), because the analyzer shares one random generator. A borderline interval is not firm.

## 6. What was not verified

* One machine: a WSL2 VM on Windows, shared with other jobs. No second machine. No Windows run (the engine does not build there; another session does that bring-up). No ARM64 run (the code uses `__builtin_prefetch` via `LaxoriPrefetch::Read`).
* No hardware counter. "Why it is faster" and "why `losarrays` is slower" are inferences, not measurements of cache misses [N].
* `base.so` and `s1.so` differ in the machine code of more than the loop (alignment, inlining). A part of a small difference (the `losarrays` loss) may come from code layout, not from the extra instructions [N]. This was not tested.
* The unit test covers `SlotLineAhead` only. The lambda `prefetchTarget` and the loop are covered only by P4, PrivateTests and the crash hunt. A prefetch does not change a result, so a wrong prefetch would not fail any test [N].
* GC stress and a long soak were not run. The verifier was on in PrivateTests and in the crash hunt only.
* `gc_lxr` was not changed and not measured. The same loop exists there (`lxr_reference_counting.cpp`).
* The A/B ran with the default heap settings of each workload; no big-heap shape other than the standard six was run in this A/B (`listsuffix-big`, `binarytrees-20` were not repeated).
* The `losarrays` loss is small, but it is real in 30 pairs. The decision to merge it with this loss is not made here.

## 7. Files

* `scripts/`: `build-laxori.sh` (build of the library), `layout-check.sh`, `validate-s1.sh`, `pipeline-ab.sh`, `configs-ab.json`, `run-ab2.py` (runner and analyzer).
  Libraries used: `/root/s1/lib/s1.so` (sha256 `5f78d450...dcb6`), `/root/s1/lib/base.so` (sha256 `a05b880e...0420`) [WSL path; not in the repository].
* `data/ab/runs.jsonl`, `data/ab.log`, `data/ab2.log` (the extra pairs); `data/val/` (validation output); `data/layout/` (record layouts).
* `tables/ab-full.md`, `tables/ab-full.tsv`.
* Reproduce: build `s1` with `scripts/build-laxori.sh s1`; build `base` from the base sources in the same build directory (`ninja clrlaxorigc`); run `scripts/pipeline-ab.sh`, then
  `python scripts/run-ab2.py analyze base data/ab`.
