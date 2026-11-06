# P50: parallel evacuation-set selection (item 8a)

Status: implemented, tested, measured. Committed on this branch, not pushed.
Base: `lxr-gc-review` `3a6fe592c8e` (this is also the head of `origin/lxr-gc-review` at the end of this work; the two squash
commits for items 13 and the safe LOS change were already in it, and the validation below ran on the rebased tree).
Labels: **Measured** = a number from the run directories (tables are in `results/`). **Inferred** = my reasoning from code or from
measured numbers. **[N]** = not measured or not verified.

## 1. Result

`SelectMatureCandidates` was one serial loop on the pause thread. It cost 236 ns for each occupied block (P49). It now runs on
all workers and on the pause thread when the allocator has 4096 blocks in use or more (128 MiB). Below that it is the old loop.

**Measured** (InitialMark pauses, `bigheap` driver of P49, 16 processors, 13 workers and the pause thread, 5 runs per cell,
medians over the per-run medians; the build phase pauses are included, as in P49):

| live set (capacity) | occupied blocks | `SelectMature` serial -> parallel | speed-up (per thread of 14) | InitialMark pause serial -> parallel | share of the pause |
|---|---|---|---|---|---|
| 1 GB (2.4 GB) | 48 k | 12.6 -> 2.5 ms | 5.0x (0.36) | 59.8 -> 42.2 ms | 19% -> 5% |
| 4 GB (8 GB) | 174 k | 37.3 -> 6.3 ms | 5.9x (0.42) | 86.1 -> 60.0 ms | 44% -> 9% |
| 8 GB (14.5 GB) | 297 k | 64.1 -> 9.4 ms | 6.8x (0.49) | 122.1 -> 75.7 ms | 53% -> 12% |
| 16 GB (21 GB) | 469 k | 101.6 -> 14.3 ms | 7.1x (0.51) | 206.8 -> 94.4 ms | 50% -> 15% |

* The loop gets faster by 5 to 7 times. The gain grows with the heap, because the fixed hand-over cost (about 0.6 ms) is spread over
  more work.
* At 16 GB the InitialMark pause is 112 ms shorter (206.8 -> 94.4 ms). The loop explains 87 ms of it. The other 25 ms is a smaller
  `Increments` stage in the parallel cells (90 -> 68 ms at 16 GB). I did not find why **[N]**. It can be a warm cache or awake
  workers, or run-to-run change; the serial cells have a wide range (195 to 264 ms). So I claim the 87 ms only.
* A Full pause gets 3.5 times faster in the loop (16 GB: 156.7 -> 42.9 ms), but that is 2% of a Full pause (8.5 s). The serial
  tail (sort and copy budget) is now as long as the parallel scan in a Full pause (16 GB: scan 20.8 ms, tail 20.9 ms) because every
  occupied block is a candidate. A parallel sort is the next step if this ever matters **[N]**.
* After the change the selection is 15% of the 16 GB InitialMark pause. The rest (80 ms) is the increments stage (68 ms), the
  release and other stages. They are not part of this item.
* The six standard workloads run the selection 0 to 4 times per run and only in small heaps (section 7). The change does not
  change their speed (section 7).

## 2. What was built

Code is in `src/coreclr/gc_lxr/lxr_reference_counting.{h,cpp}` and `lxr_gc.cpp` (two settings).

* `SelectMatureCandidates` picks the implementation:
  * `SelectMatureSerial`: the old loop, kept as it was (one pass over the blocks, then one pass over the candidates, with the
    word-wise dead-line count of commit `2a3a73aa229`). Only the end of it moved into `ApplyMatureSelection`.
  * `SelectMatureParallel`: below.
  * `SelectMatureValidated`: runs both on the same state and compares (section 5).
* `ApplyMatureSelection` is the part that both paths share: sort, copy budget, store of the evacuation flags, counters. It is the old
  code, unchanged.
* Parallel path (`SelectMatureParallel`, `SelectChunk`, `RunSelectionLoop`, `FinishSelection`):
  1. The heap is cut into chunks of 4 MiB (128 blocks), cut at the same absolute addresses as the serial loop cuts them. A
     `SelectionRun` holds, for each chunk, 128 candidate slots, the number of eligible candidates, and the number of free blocks.
  2. The pause thread submits one packet (work kind `SelectMature`, stage `Unconstrained`) for each worker. The pause thread and the
     packets take chunk numbers from one atomic cursor. A thread that wakes late finds the cursor at the end and returns.
  3. `SelectChunk` is the first loop of the serial selection over the blocks of one chunk. It also counts the occupied blocks of the
     chunk (the serial selection counts them in a second pass), sets the chunk score, and keeps the eligible candidates.
  4. The pause thread waits until the counter of finished chunks equals the number of chunks (a chunk takes about 30 us). It merges
     the chunks in address order (a `memmove` for each chunk) and calls `ApplyMatureSelection`.
  5. The packets that had not started yet are waited for at the end of `Suspend` (`FinishSelection`): `BeginStwCycle` refuses to
     start while the `Unconstrained` stage is busy, and the late workers are awake by then. This keeps the wake-up latency of the
     slowest worker out of the path of the selection (a smoke run showed 1.19 -> 1.02 ms for the scan of a 16 000-block heap; one
     run of each, so **[N]** as a number).
* New settings (`LXRSelectParallelBlocks`, default 4096, decimal; `LXRSelectValidate`, default off). Both are in the padding of
  `LxrRcConfiguration` (after `evacuateMature`).
* Phase timers (only in builds with phase timers): `SelectMature` (whole selection), `SelectScan`, `SelectGather`, `SelectTail`,
  `SelectBusy` (sum of the busy time of all threads in chunks). The enum entries exist only with `LXR_HAS_PHASE_TIMERS`, so the
  product object does not change in size.

### 2.1 Where this differs from the design sketch of P45 (section 4a)

* **No new scheduler stage.** The sketch asked for a stage that the pause waits for. I used a fork and join on the existing
  `Unconstrained` stage before `PrepareWork`: submit, work on the pause thread, wait. The ordering that the sketch needs is the same
  (the evacuation set is complete before the increments), and `Suspend` does not change. A new stage would have moved the numbers
  of the stages (`Initial`, `Prepare`, ...) and every mask in the scheduler, the schedule table and the harnesses. The pause thread
  does all the work itself if no worker comes, so the selection cannot wait for a worker that is busy.
  The contract that this uses is tested in P3.1 (`ValidateForkJoinBeforeCycle`): packets of the `Unconstrained` stage that are
  submitted before a cycle run on the workers; the wait for the stage ends only when every packet is completed; `BeginStwCycle` is
  refused while a packet runs. The held packet of that test is its control.
* **The pin list is not an input of the selection.** The sketch says that `SealPins` must run first because a pinned block is never a
  source. `IsPinnedBlock` reads `ImmixAllocationManager::PinnedBlockFlag` (blocks of the pinned object heap), which the allocator sets
  outside a pause. The pause pin flag (`PausePinFlag`, set by `AddPinnedRoot`) is never read by the selection. So there is no ordering
  constraint with `SealPins` (the call stays where it was). `RetainPinnedMatureBlocks` runs after the selection, as before.
* **Threshold.** About 128 MiB in use, from measurements (section 4), not 0.5 GiB.

## 3. Why the evacuation set is identical

The same inputs give the same set. Each point is a property of the code, and the validation (section 5) checks it by running both.

1. **Same input state.** The mutators are stopped and the lazy work has drained (pre-drain of `RunPause`), and no other stage runs
   (the `Unconstrained` stage is empty before the packets are submitted). The selection reads four things: the block state byte,
   the block epoch (nursery test), `PinnedBlockFlag`, and the count plane. Nothing writes them during the scan. The only writes of the
   whole selection are in `ApplyMatureSelection`, on the pause thread, after all chunks are done.
2. **Same candidate for a block.** `SelectChunk` has the loop body of the serial loop: free blocks are not candidates, a pinned
   block is not a candidate, the dead-line count is the same word-wise count (`CountDeadLines` is a copy of the inline loop of the
   serial path; the control `SelectDeadLines` shows that the tests see a difference). `GetStateFast` and `GetState` read the same
   byte.
3. **Same chunk score.** The serial code counts the blocks of a chunk with state `!= Unallocated` (pinned blocks included) over the
   chunk range cut at the start of the reservation and at the end of the capacity. `SelectChunk` counts the same blocks in the same
   range, in the same pass (control `SelectOccupied`). The score is `128 - occupied` below the threshold, else 0. The eligible
   filter is the same (score is not 0, or Full pause, or at least 64 dead lines), and it only reads the chunk.
4. **Same order, so the same ties.** The serial candidate array is in ascending block address. The gather takes the chunks in
   ascending order and the candidates of a chunk are in ascending order, so the array that `ApplyMatureSelection` gets is equal to
   the serial one element by element (control `SelectGatherReversed`). `std::sort` has no randomness, so the same input gives the
   same order of equal keys. The tests compare the evacuation flags, the defrag plane, and the counters.
5. **Same free bytes.** The serial loop adds a block to `freeBytes` when it is `Unallocated` and not a nursery block. The chunks add
   the same blocks (`freeBlocks`), and the sum is multiplied by the block size.
6. **Same budget and store.** Same function.
7. **No lost chunk.** `visited` must equal the number of chunks, else the engine fails with `InvariantViolation` (control
   `SelectLoseChunk`). A chunk that is counted but not visited is found by the equivalence test (control `SelectSkipChunk`).

## 4. Threshold

Measured, same library, serial against parallel in every cell (`DOTNET_LXRSelectParallelBlocks` 4294967295 against 0), 6 runs per
cell, InitialMark pauses (`results/threshold-sweep.md`). Blocks are the capacity (the heaps are tight, so blocks in use are close).

| capacity blocks | occupied | `SelectMature` serial | parallel | note |
|---|---|---|---|---|
| 3 200 | 1 078 | 0.32 ms | 0.64 ms | serial is better |
| 4 800 | 2 078 | 0.61 ms | 0.72 ms | serial is better |
| 8 000 | 4 182 | 1.16 ms | 0.82 ms | parallel is better |
| 12 800 | 8 033 | 2.16 ms | 1.00 ms | |
| 16 000 | 13 162 | 3.25 ms | 1.16 ms | |
| 22 400 | 20 451 | 4.76 ms | 1.37 ms | |
| 28 800 | 25 014 | 5.91 ms | 1.55 ms | |
| 48 000 | 34 432 | 8.72 ms | 2.01 ms | |
| 70 400 | 49 718 | 11.24 ms | 2.25 ms | |

* The parallel time is about 0.7 ms plus 30 ns for each occupied block. The serial time is 230 to 300 ns for each occupied block in
  these cells. They cross at about 3 000 occupied blocks. The fixed 0.7 ms is the wake-up of the workers and the hand-over (WSL2;
  **Inferred**, I did not measure the parts).
* The fixed hand-over is about 0.7 ms. Below about 3 000 occupied blocks it costs more than the loop.
* I use 4096 blocks in use (128 MiB), a little above the crossing. Below it the serial loop is shorter than about 1.2 ms, so the
  best gain that is left is under 0.5 ms. The number depends on the wake-up latency of the machine **[N]** (WSL2 with 16 virtual
  processors here). The setting `LXRSelectParallelBlocks` changes it.

## 5. Validation

All run on the final tree (Linux x64, WSL2).

| Check | Result |
|---|---|
| `validate-variant.sh default Release` (P2.1-P2.5, P3.1-P3.4, P4 and all selectors) | all pass (`results/validate-variant.txt`). `--mature-released-candidate` passed there; it is flaky: it fails in 7 of 15 runs on the base tree and in 7 of 15 on this tree. `--zero-rc-control` is an injected failure and is filtered as usual. |
| `validate-variant.sh bitmap Release` | all pass except `--mature-released-candidate` (flaky, as above). |
| P4 selectors with the parallel path forced in every InitialMark and Full pause (`LXR_TEST_SELECT_PARALLEL_BLOCKS=0`) | same result as the default run (only the flaky selector fails in some runs). |
| the same, with `LXR_TEST_SELECT_VALIDATE=1` (both selections in every pause, a difference fails the engine) | all pass; no difference. Includes `--mature*`, `--pause-trace`, `--p8-policy`, `--f4-scheduler`, `--f4b-scheduler`. |
| new P4 selector `--select-parallel` (`ValidateParallelSelection`, 462 checks) | pass. 90 random heaps (3 seeds x 10 cases x 3 heap sizes) with free, nursery, pinned and source blocks, partly full chunks, Full and InitialMark pauses, a copy budget that ends in the middle of the list (and a budget of 0). It compares the evacuation flags, the defrag plane, and the counters. |
| P4 in Debug (the assertions of `GetStateFast` are on) with the forced and validated mode: `--select-parallel`, `--mature`, `--pause-trace` | pass. |
| P3.1 `ValidateForkJoinBeforeCycle` | pass (652/652). |
| `PrivateTests all 2 13`, 20 runs per setting, product library (`run-privatetests.sh`) | 0 failures in each of: default; `DOTNET_LXRTraceThreshold=1`; parallel selection forced and validated (`LXRSelectParallelBlocks=0`, `LXRSelectValidate=1`); that and `LXRTraceThreshold=1`. A run has about 210 Full and 2 to 6 InitialMark pauses, so the forced runs validated about 4 000 selections in each setting (counted with the experiment library: 1 run of each setting). |
| crash hunt `p50hunt.py` (six workloads and the interior stress test, worker counts 13:3, 4:2, 1:1, 63 runs per setting) | 126 of 126 runs ok (default; forced + validated + `LXRTraceThreshold=1`), all checksums right. |
| six checksums | the A/B runs of section 7 check them in every run (540 runs, 0 bad), and the hunt checks them with the parallel path forced. |

**Mutation controls** (`run-select-controls.sh`; each builds P4 with one injected defect, and `--select-parallel` must fail):

| Control | Defect | Detected by |
|---|---|---|
| `SelectLoseChunk` | a chunk is lost and not counted | the visit check (`both selections complete`, `visits every chunk`) |
| `SelectSkipChunk` | a chunk is counted but not visited | the equivalence check |
| `SelectGatherReversed` | chunks merged in descending order | the equivalence check (order of equal keys) |
| `SelectDeadLines` | the first line is not counted as dead | the equivalence check |
| `SelectOccupied` | pinned blocks do not count as occupied | the equivalence check |

All five are detected (exit 1 with `FAIL:` lines). The control of P3.1 is the held packet inside the test.

**Layout** (`results/layout-diff.txt`, clang `-fdump-record-layouts` of the product build, before and after): no existing member of
`LxrReferenceCounting`, `LxrRcConfiguration` or `LxrPauseTimers` moved. `LxrRcConfiguration` stays 208 bytes (the two new fields
are in the padding after `evacuateMature`). `LxrReferenceCounting` gets one member at the very end (`m_select_run`, offset 11600);
its size stays 11648 (alignment 64). `LxrPauseTimers` stays 4480 bytes (the new timers exist only with phase timers).

## 6. Scaling cells in full

`results/scaling-8a.md` (InitialMark and Full pauses, all columns), `results/scaling-8a-other-phases.md` (other phases).
Method: `p50run.py 8a`, the cells of P49 (`bigheap`, `DOTNET_LXRTraceThreshold=2`, capacity = initial = reserve,
`DOTNET_LXRNativePlaneLimitMB=200000`), 5 runs per cell, serial and parallel adjacent in every repetition, one run at a time under
`flock /tmp/lxr-bench.lock`. The 16 GB runs waited for 24.5 GB of free memory. Library: the experiment build (phase timers and the
P49 per-pause record, not merged), with the setting `LXRSelectParallelBlocks` (4294967295 or 0) as the only difference.

* The busy time of the threads in chunks is 65% (1 GB) to 95% (16 GB) of the scan time times 14 threads. At 16 GB the threads are
  busy all the time, but each block costs about 1.9 times more than in the serial loop (51% efficiency per thread). I think this is
  memory bandwidth or shared cores **[N]**.
* `SelectGather` (merge) is 0.01 to 0.02 ms in InitialMark pauses and 1.4 ms in a 16 GB Full pause.

## 7. Small heaps and the six standard workloads

`results/ab-six-workloads.md`. Three arms in one library pair, 30 interleaved repetitions of every workload, the order of the arms
shuffled in every repetition, one repetition of one workload (3 runs) under one lock: `base` (the base tree), `p50s` (the new
library with `LXRSelectParallelBlocks=4294967295`, the serial path only), `p50` (the new library, defaults). 540 runs, all
checksums right. Paired differences are in percent, with a 95% bootstrap interval of the median.

| workload | p50s against base: wall | p50s against base: cpu | p50 against base: wall | p50 against base: cpu | p50 against base: pause |
|---|---|---|---|---|---|
| requests | +0.3% [-2.2, +1.5] | +0.7% [-1.3, +2.0] | +1.1% [-2.2, +3.2] | +0.5% [-1.6, +3.0] | -0.6% [-4.8, +1.7] |
| binarytrees | +1.4% [-2.1, +5.8] | +2.5% [-7.1, +21.0] | +1.9% [-2.0, +7.5] | +2.6% [-9.6, +46.4] | +1.4% [-6.6, +46.2] |
| listsuffix | -0.0% [-2.0, +1.2] | -1.3% [-3.6, +1.7] | -0.6% [-2.3, +1.8] | -0.8% [-3.0, +1.7] | -1.3% [-5.0, +1.0] |
| mixedmedium | +0.2% [-1.3, +2.3] | -0.1% [-1.2, +3.3] | -0.9% [-2.2, +1.8] | -0.2% [-1.7, +1.0] | -0.1% [-2.3, +2.4] |
| losarrays | -0.2% [-1.3, +0.3] | -0.9% [-1.5, +0.2] | -0.2% [-1.3, +0.2] | -0.8% [-1.1, -0.0] | -0.1% [-1.1, +0.6] |
| mediumarrays | -0.3% [-1.6, +0.6] | -0.1% [-1.4, +0.9] | -0.7% [-2.5, +0.9] | -0.2% [-2.1, +0.7] | -1.1% [-3.3, +0.7] |

* No workload shows a change that the interval separates from zero, except `losarrays` CPU (-0.8%, upper end -0.0%), which is a
  gain, not a cost. The serial path of the new library (`p50s`) is not slower than the base tree: the intervals are within about
  +-2% (+-5 to +-20% for `binarytrees`; **no claim for `binarytrees`**: its CPU time has two modes in every arm, 1.7 and 3.4 s,
  also in the base tree, and 30 pairs cannot separate a small change from that).
* These workloads do not exercise the new path much. One run does 0 to 4 selections, and only `mediumarrays` (1 selection) uses
  the parallel path at the default threshold (`results/selections-in-six-workloads.md`, counted with the experiment library). All of
  them together cost 0.0 to 0.9 ms per run. So this A/B shows that the dispatch and the refactor are free, and nothing more about
  the parallel path. The effect of the parallel path is in sections 1, 4 and 6.
* I did not measure a run with the parallel path forced in the six workloads **[N]**.

## 8. Not verified, limits

* **[N]** Only one mutator thread and one workload (`bigheap`) were used for the large heaps; the measured per-block costs depend on
  the layout of the heap (live share, dead lines). Heaps above 16 GB were not run.
* **[N]** Only 16 virtual processors on WSL2 were used. The fixed cost of 0.6 ms and the threshold depend on the wake-up time of the
  worker threads. Other numbers of processors, Windows, and NUMA were not tested. The Windows build of the new code was not
  compiled **[N]** (it uses `YieldProcessor` and `GCToOSInterface::YieldThread`, which the file already uses).
* **[N]** The 25 ms of the 16 GB InitialMark pause that is not the loop (section 1).
* **[N]** The failure path of `LXRSelectValidate` in the product library (a difference fails the engine with `InvariantViolation`)
  was not run; the test platform reports the difference, and the product runs with the switch found none.
* The sort in the serial tail is not parallel. In a Full pause it is as long as the parallel scan (section 1).
* The experiment library (P49 per-pause record) is a throw-away build (`P49 EXPERIMENT, NOT FOR MERGE` cherry-picked on this
  work, with one more `atexit` dump in `lxr_p49_experiment.cpp`). It is not committed here. The scripts in this directory
  (`p50run.py`, `p50analyze.py`, ...) need it for the scaling cells, and `p50ab.py` needs only the two product libraries.
* The tests with `DOTNET_LXRSelectParallelBlocks=0` are the only ones that run the parallel path in the small heaps of the harnesses.

## 9. Files

* `p50run.py` (scaling and threshold cells), `p50analyze.py` (tables), `p50rest.py` (other phases), `p50ab.py` and
  `p50abanalyze.py` (A/B of the six workloads), `p50count.py` (selections per workload), `p50hunt.py` (crash hunt),
  `run-privatetests.sh`, `run-select-controls.sh`, `dump-layout.sh`.
* `results/` (tables and logs of this document).
* Tests: `P4/lxr-rc-validation.cpp` (`ValidateParallelSelection`, selector `--select-parallel`, also in the default run),
  `P4/run-lxr-rc-vertical.sh` (the five controls), `P3.1/lxr-work-packet-validation.cpp` (`ValidateForkJoinBeforeCycle`),
  `P31-object-start-walk/run-p4-selectors.sh` (selector added). Test platform switches:
  `LXR_TEST_SELECT_PARALLEL_BLOCKS`, `LXR_TEST_SELECT_VALIDATE` (read by `Initialize`).
