# P46: marking window after InitialMark (item 13)

Base: `lxr-gc-review` at 9664cfe78cb. Scope: `src/coreclr/gc_lxr` and `docs/design/lxr-port/P4`. Java reference:
`C:\github\lxr-reference\mmtk-core` HEAD 9625c174 (old pin 304ce69).

Tags: **Measured** (a command or a test showed it). **Read** (read in the code). **[N]** (not verified, or an estimate).

## 1. Result

The lazy decrements of the epoch right after InitialMark do not mark the objects that die. They do not queue the children of
these objects for the trace. This is the Java rule. Later epochs of the same trace mark as before.

| Commit | What |
|---|---|
| `af8326f63b4` | Counters: dead objects, marked dead objects and queued children, first epoch after InitialMark against later epochs. Flag `m_first_window`. |
| `2c15fd2e585` | The change: `MarkDeadObjects()` replaces `m_marking` in four places of the decrement path. |
| `da09054e60e` | P4 check `ValidateMarkingWindow`, selector `--marking-window`, two mutation controls. |

* **Safe in our design (argument and test, sections 4 and 7).** No difference between Java and our pause protocol was found that
  makes the rule unsafe. This is not a formal proof **[N]**.
* **The old rule did much work (Measured, section 6).** In a trace the first epoch did 94-100% of all dead-object marks in
  every workload with traces. Most traces end after one epoch (`pauses per trace` is 1.0-2.0 with the old rule). With the new
  rule the first epoch marks nothing.
* **No wall-clock gain (Measured, section 8).** The CPU time is lower in two cells where the first epoch marked a lot:
  `listsuffix` with traces forced (-11.2%, interval [-18.8, -4.3]) and `binarytrees` default (-13.9%, [-22.5, -5.6]). The
  `binarytrees` default gain did not repeat in the back-to-back null control (-4.5%, [-11.9, +2.7]); `listsuffix` forced was
  not repeated. The wall time does not improve in any cell. With traces forced, `binarytrees` gets 3 more collections and +4.3%
  wall: a cheaper trace ends sooner, so the policy starts more traces in the same run. `requests` default showed +5.4% wall
  ([+3.1, +11.2]) in the long run, although no trace ran there. It did not repeat in the null control (+0.7%, [-2.7, +2.5]).
* The goal was parity with Java where it is safe. It is not a speed-up.

## 2. What the Java rule does (Read)

`mmtk-core/src/plan/lxr/gc_work/rc.rs:866-881` (`ProcessDecs::do_work`), lazy mode:

```rust
self.mark_dead_objects = lxr.concurrent_work_in_progress() && lxr.previous_pause() != Some(Pause::InitialMark);
self.mature_sweeping_in_progress = lxr.previous_pause() == Some(Pause::FinalMark) || lxr.current_pause() == Some(Pause::Full);
```

* `concurrent_work_in_progress()` is `in_concurrent_marking`. `gc_pause_end` sets it to true at the end of the InitialMark
  pause (`plan/lxr/global.rs:374-379`). `gc_pause_start` of FinalMark sets it to false (`global.rs:361-371`).
* `previous_pause` is stored at the end of every pause (`global.rs:382`). A lazy `ProcessDecs` packet runs after the pause
  that made it. So a packet that runs after InitialMark sees `previous_pause == InitialMark` and does not mark. Packets after the
  next RC pause see `RefCount` and mark. In non-lazy mode the test is `current_pause() != InitialMark`.
* If `mark_dead_objects` is set, `process_dead_object` (`rc.rs:747-814`) calls `lxr.mark(o)` for the dead object. For each child
  `x` that is not marked it pushes `x` to `mark_objects`. `flush` (`rc.rs:720-735`) turns them into `LXRConcurrentTraceObjects`.
  `record_mature_evac_remset` (`rc.rs:737`) also needs the flag.
* The filter is the same in both cases. `process_decs` (`rc.rs:827-831`) skips an entry whose count is 0 or sticky, and an
  unmarked object while mature sweeping is on. A child with count 0 or sticky gets no recursive decrement (`rc.rs:776`).
* The rule is old in the Java tree. The pin 304ce69 has it (`src/plan/lxr/rc.rs`). The merge lineage reached it again in
  5f7e2dcf "Fix dead object scanning during RC decs" (17 Mar 2026). That commit replaced
  `cm_in_progress() || (!LAZY && current_pause == InitialMark)` by the rule above. The message says nothing more. Why the Java
  authors chose it is **[N]**. Section 4 gives the correctness argument.

Which decrements run in the first epoch (Read): the decrement log of the epoch *before* InitialMark (old targets of the first
store to a field), the previous roots, and the cascade of objects that these decrements kill. The barrier flush decides for each
buffer if it also makes a SATB packet. `should_create_satb_packets` needs `concurrent_work_in_progress()` or
`current_pause == FinalMark` (`plan/lxr/barrier.rs:138-142`). During the InitialMark pause `concurrent_work_in_progress()` is still
false, so the log of the epoch before InitialMark gets **no** SATB packet. The Java LXR already treats these decrements as
"before the snapshot".

## 3. What our code did before the change (Read)

* `m_marking` is set at the end of the InitialMark release (`ReleaseEpoch`). It is cleared when a FinalMark or Full pause starts.
* While `m_marking` was true, the decrement path did four things for a dying object. `Death` called `FinishDyingTraceObject`
  (mark, and finish a running scan, under the trace lock). `ScanDecrements` used `queueAll` (no count filter, every child
  appended). `ProcessDecrements` called `QueueTrace` for the children of every level of the cascade. `ReferenceBatch::Flush`
  called `QueueTrace` for a flushed batch.
* The decrement log of a pause gets a SATB packet only if a trace is on and the pause is not InitialMark (`PrepareWork`:
  `m_trace_phase != Inactive && m_pause_kind != InitialMark`). So our pause protocol had the same split as the Java barrier
  flush, but the dead-object marking ignored it.
* Lazy decrements are submitted in `PrepareWork` into the deferred concurrent bucket, so they start after the pause ends. The
  pre-pause drain (`RunPause`: `DrainEpoch`) waits for the whole lazy generation and for the Unconstrained bucket before every
  pause. So the packets of epoch N end before pause N+1 starts.

## 4. Why the Java rule keeps the SATB snapshot in our design

Names. Pause E is the InitialMark pause. "Epoch E-1" is the time between pause E-1 and pause E. "First epoch" is the time
between pause E and pause E+1.

1. **Counts at the snapshot.** The snapshot is the heap and the roots of pause E. All increments for epoch E-1 (new references
   found in the log, roots) are applied inside pause E. The decrements of epoch E-1 (old targets, previous roots) are not yet
   applied. So at the end of pause E the count of an object is at least its number of snapshot references, plus its pending
   decrements. A count saturates at the maximum and then never dies (sticky).
2. **An object that dies in the first epoch was not reachable at the snapshot.** The decrements of the first epoch are exactly
   the pending ones. A count reaches 0 only after every snapshot reference is gone. During the cascade the count never goes
   below the number of snapshot references. The trace starts from the roots of pause E, so it cannot reach such an object.
3. **The children are not lost.** A child of a dead object that is reachable at the snapshot is reachable by another path, and
   the trace marks it by that path. A child that was only reachable through the dead object is unreachable too, and the cascade
   decremented it. A child that stays in a garbage cycle keeps a count and is not marked: the cycle sweep at the end of the
   trace frees it. The old rule marked it and kept it for one more cycle (floating garbage).
4. **The mutators cannot bring the dead object back.** Mutators hold roots (counted in pause E) or read fields of reachable
   objects. An object with no snapshot reference cannot be loaded. So no new reference to it is made. The SATB deletion
   barrier has nothing to keep.
5. **The decrements of later epochs are different.** A decrement of epoch E (it runs after pause E+1) removes a reference that
   can be a snapshot reference, because the log is taken after the snapshot. Its target can be reachable at the snapshot and not
   traced yet. The log of epoch E gets a SATB packet (`PrepareWork`). It runs at the end of the trace (stage
   `FinishConcurrentWork`) and reads the object then. If the lazy decrements freed the target before that, the packet would
   read freed memory. So a dying object is marked and scanned first (`FinishDyingTraceObject`), and its children are queued.
   This is the mark-and-scan-on-delete rule of the paper. It stays for these epochs.
6. **Our extra requirement: no trace entry for a freed object.** `FinishDyingTraceObject` also finishes a running trace scan of
   the dying object. The trace then never touches an object that RC frees. This is needed only for objects that the trace can
   reach or has queued. The trace queue has three sources. (a) The roots of pause E: they have a count from pause E, so they
   cannot die in the first epoch. (b) The fields of traced objects: a field that holds the object is a snapshot reference or a newer
   one, so the count is not zero. (c) SATB packets: none is made for the log of epoch E-1 (section 3). So the trace has no
   entry for an object that dies in the first epoch.
7. **The flag covers exactly that epoch.** `m_first_window` is set in `ReleaseEpoch` of InitialMark just before `m_marking`.
   It is cleared in `RunPause` after the pre-pause drain and before the next pause makes work. The lazy packets of pause E are
   made inside pause E and run after it. The drain ends all of them before pause E+1 starts. So no packet of epoch E or later
   can run while the flag is true. If a first-epoch packet ever ran after the clear, it would mark: the old, safe direction.
   Non-lazy mode and the Full pause run their decrements inside the pause. There `m_marking` is false (InitialMark sets it
   only at the end; Full never sets it), so nothing changes.
8. **What does not change.** The count filter and the mature-sweep check in `ProcessDecrementEntry`; the SATB packets; the
   increment path (`NeedsIncrementTrace`: an unmarked counted object that gets an increment during a trace is traced); black
   allocation; `RememberMatureSlot`.

Where our design differs from Java, and what was checked:

* The SATB packet condition `m_pause_kind != InitialMark` is the same as the Java barrier flush.
* The drain before every pause replaces the Java lazy-jobs counter. Java stores `previous_pause` at the end of a pause, so a
  packet that still runs during the next pause sees `InitialMark`. Our flag is cleared at the start of the next pause, after
  the drain: the same packets.
* The large-object space: a dead large object is released after the count update (`ReleaseAfterDecrements`) in phase
  `ConcurrentMark`. It needs no mark, because it is not in the trace. The comment in `large_object_space.cpp` says this now.

No difference was found that makes the rule unsafe. This is an argument and a test (section 7), not a proof **[N]**.

## 5. Implementation (Read)

* `m_first_window` (`std::atomic<bool>`) sits after `m_hold_trace` in the padding. The layout of `LxrReferenceCounting` does not
  change: `sizeof` 11584, same offsets for `m_trace_phase` to `m_cycle_sweep` (Measured with `-Xclang -fdump-record-layouts`
  for 9664cfe78cb and HEAD, release flags). The diagnostic counters (`m_window_metrics`) are at the end of the class and exist only
  in builds with phase timers or diagnostic probes.
* `ReleaseEpoch`, InitialMark branch: `m_first_window = true`, then `m_marking = true`. `RunPause`: after the drain and
  `m_pause_kind = kind`, `m_first_window = false`.
* `MarkDeadObjects()` is `m_marking && !m_first_window` (inline). It replaces `m_marking` in `ScanDecrements` (`queueAll`),
  `Death` (`FinishDyingTraceObject`), `ProcessDecrements` (the `QueueTrace` of the cascade levels) and `ReferenceBatch::Flush`.
  Each place reads one more byte, and only while `m_marking` is true. The path without a trace is the same.
* Controls for the test platform: `LXR_MARKING_WINDOW_WIDE_CONTROL` (the old rule: the first epoch marks) and
  `LXR_MARKING_WINDOW_NONE_CONTROL` (no epoch marks).
* Counters (`LxrTraceMetrics`, last 7 fields): `firstEpoch{Deaths,Marked,Children}`, `laterEpoch{Deaths,Marked,Children}`,
  `tracePauses`. `DOTNET_LXRWindowStats=1` prints one `LXRWINDOW` line at the end of each trace. The library must be built with
  `-DCLR_CMAKE_ENABLE_LXR_PHASE_TIMERS=ON`. "Children" is the number of entries that `QueueTrace` got from the decrement path
  (including children with count 0 that the filter would skip).

## 6. Counters: how much work the window did

Libraries: `diag-c1` is commit af8326f63b4 (counters, old rule). `diag-c2` is HEAD (counters, new rule). Both with phase timers.
Frame `/root/prof/frame-c4`, `DOTNET_gcServer=1`, six workloads with the checksums of the task, 3 runs per cell, interleaved and
shuffled (`run46.py` in this directory). All 72 runs had the right checksum. A "first epoch" is the epoch right after InitialMark. A trace
spans one epoch if `pauses per trace` is 1.0: the pause that ends the epoch is the FinalMark.

**Default trace threshold.** `requests` made no trace in 3 runs.

| Workload | rule | InitialMarks | deaths (all) | first-epoch deaths | first-epoch marked | first-epoch children queued | later-epoch deaths | later-epoch marked | later-epoch children queued |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| binarytrees | old | 1 | 3,709,006 | 524,287 | 402,903 | 524,286 | 166,650 | 2,048 | 166,644 |
| binarytrees | new | 2 | 4,093,820 | 524,318 | 0 | 0 | 295,138 | 0 | 295,128 |
| listsuffix | old | 1 | 190,971 | 190,971 | 173,151 | 185,712 | 0 | 0 | 0 |
| listsuffix | new | 1 | 190,971 | 190,971 | 0 | 0 | 0 | 0 | 0 |
| mixedmedium | old | 2 | 2,074,719 | 1,705 | 1,705 | 0 | 0 | 0 | 0 |
| mixedmedium | new | 2 | 2,008,482 | 1,102 | 0 | 0 | 0 | 0 | 0 |
| losarrays | old | 5 | 39,672 | 584 | 584 | 0 | 0 | 0 | 0 |
| losarrays | new | 4 | 519 | 301 | 0 | 0 | 0 | 0 | 0 |
| mediumarrays | old | 1 | 345,230 | 8,618 | 8,618 | 0 | 0 | 0 | 0 |
| mediumarrays | new | 1 | 357,985 | 8,554 | 0 | 0 | 0 | 0 | 0 |

**`DOTNET_LXRTraceThreshold=1`** (traces forced).

| Workload | rule | InitialMarks | deaths (all) | first-epoch deaths | first-epoch marked | first-epoch children queued | later-epoch deaths | later-epoch marked | later-epoch children queued |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|
| requests | old | 13 | 3,909,483 | 455,584 | 341,134 | 437,751 | 0 | 0 | 0 |
| requests | new | 20 | 3,795,313 | 769,380 | 0 | 0 | 0 | 0 | 0 |
| binarytrees | old | 15 | 3,689,756 | 1,103,482 | 744,744 | 1,103,470 | 278,682 | 0 | 278,676 |
| binarytrees | new | 21 | 4,094,327 | 1,441,878 | 0 | 0 | 524,380 | 24,278 | 524,376 |
| listsuffix | old | 9 | 16,003,502 | 5,019,301 | 4,328,098 | 4,936,939 | 486,384 | 286,192 | 473,417 |
| listsuffix | new | 5 | 15,870,835 | 3,723,854 | 0 | 0 | 0 | 0 | 0 |
| mixedmedium | old | 27 | 2,314,902 | 416,030 | 365,597 | 248,522 | 11,262 | 1,690 | 5,017 |
| mixedmedium | new | 31 | 2,203,743 | 491,430 | 0 | 0 | 7,930 | 927 | 3,525 |
| losarrays | old | 7 | 12,115 | 1,013 | 1,013 | 0 | 0 | 0 | 0 |
| losarrays | new | 7 | 12,072 | 1,013 | 0 | 0 | 0 | 0 | 0 |
| mediumarrays | old | 11 | 370,221 | 78,826 | 56,247 | 28,696 | 0 | 0 | 0 |
| mediumarrays | new | 12 | 393,740 | 90,576 | 0 | 0 | 0 | 0 | 0 |

What the data shows:

* Old rule, first epoch against all marks of the trace: 94-100% in every workload with traces. The share of the first-epoch
  deaths that were marked is 68-100% (for example `listsuffix` forced: 4.33 M of 5.02 M). So the window was not small. This
  corrects the guess in P45 that the first epoch is a small part of the window.
* New rule: `first-epoch marked` and `first-epoch children queued` are 0 in all cells. The first-epoch deaths still happen (the
  counters see them).
* The number of traces differs between the two rules in the same configuration (for example `listsuffix` forced: 9 against 5;
  `binarytrees` forced: 15 against 21). The policy starts a trace when the garbage share is high, and the timing of the traces
  depends on how fast the previous trace ended. Compare per trace, not per run. [N] The cause of the differences in trace count
  was not studied.
* Later epochs mark a small number of objects (up to 286 k in `listsuffix` forced, old rule). That work stays.
* Per-trace first-epoch marks (old rule, median, forced): `binarytrees` 45 k, `listsuffix` 481 k, `mixedmedium` 13.5 k,
  `requests` 25 k, `mediumarrays` 5.3 k, `losarrays` 145. (`/root/p46/counters.txt`, made by `analyze46.py`.)

## 7. Validation

All on the new library or its sources (HEAD).

* **Suites.** `docs/design/lxr-port/P31-object-start-walk/validate-variant.sh default Release` (Measured): P2.1 to P2.5 PASS;
  P3.1 641/641, P3.2 395/395, P3.3 357/357, P3.4 70/70; P4 default 105,419/105,419. All P4 selectors pass, including `--trace`
  (8,372), `--pause-trace` (259,424), `--f1-trace` (79,477), `--f4b-scheduler` (4,044), `--release-stage` (4,955),
  `--object-start` (4,279) and the new `--marking-window` (39/39). Only the known flaky `--mature-released-candidate` failed
  (65/67); `--p8-storage` passed in this run. `--zero-rc-control` prints its expected injected `FAIL` line.
* **Regression check.** `ValidateMarkingWindow` in `P4/lxr-rc-validation.cpp` follows one trace through InitialMark, one RC
  pause and FinalMark. Objects: `live -> shared -> tail`, `head -> mid -> shared`, `cycle <-> twin`.
  Pause 1 has roots {live, head, cycle}; InitialMark has roots {live}: `head` and `mid` die in the first epoch and must not be
  marked (`deletionMarks == 0`, not `IsMarked`, counters: 2 deaths, 0 marks); the cycle and `shared` keep their counts. Then
  `live -> shared` is deleted and an RC pause runs: `shared` and `tail` die in the second epoch and must be marked and scanned
  (`deletionMarks` +2). FinalMark must end the trace and release the cycle (`cycleObjects == 2`, 48 bytes, no cycle sweep
  pending), and only `live` (24 bytes) may stay.
* **Mutation controls** (`run-lxr-rc-vertical.sh Release <dir> <Control>`, Measured).
  `MarkingWindowWide` (the old rule) fails with "objects that die in the first lazy epoch ... are not marked" and "the epoch
  counters see both deaths in the first epoch and no mark" (37/39). `MarkingWindowNone` (no epoch marks) fails with "objects that
  die in a later epoch of the trace are marked and scanned" (38/39). The script prints `CONTROL ... detected`. The same check on
  the base engine (9664cfe78cb, which has the old rule) fails in the same way (36/38 before the counter check was added).
* **Managed `PrivateTests all 2 13`**: 20 runs with the default threshold and 20 runs with `DOTNET_LXRTraceThreshold=1`
  (copy of `P32-privatetests-failure`, library = HEAD, `repeat.sh`): 40/40 runs pass, 0 `LXR fatal`, 0 `OutOfMemoryException`.
* **Crash hunt** (`p31hunt.py`, reduced to 14 runs per worker setting 13:3, 4:2 and 1:1; the six workloads and
  `InteriorStress`): 42/42 runs pass with the default threshold and 42/42 with `DOTNET_LXRTraceThreshold=1` (added to the copy of the
  script as `HUNT_TRACE`). All checksums right.
* **Benchmark runs**: 360 + 72 runs, all with the right checksums (sections 6 and 8).

## 8. Benchmark

Method. Base library `base.so` is built from `lxr-gc-review` 9664cfe78cb. `new.so` is HEAD. Both are Release without counters
(`base.so` was built first; `new.so` after a reconfigure of the same build directory with `CLR_CMAKE_ENABLE_LXR_PHASE_TIMERS=OFF`).
Frame `/root/prof/frame-c4/corerun`, driver `/root/prof/drv/bin/CompareDriver.dll`, `DOTNET_gcServer=1 DOTNET_GCPath=<lib>`, the six
workloads with the task parameters (all checksums right; `mediumarrays` with `DOTNET_LXRImmixInitialMB=200
DOTNET_LXRImmixReserveMB=400`). 15 runs per cell. In each rep the order of the four configurations (`base`, `new`, `base-tr1`,
`new-tr1`) is shuffled for each workload. The runs of a rep hold `/tmp/lxr-bench.lock`, so no run of another session overlapped
with it. The numbers are the median of the per-rep percentage differences (new against base, same rep), with a 95% bootstrap
interval (4,000 resamples). `tr1` means `DOTNET_LXRTraceThreshold=1` (a trace starts at every cycle). Scripts in this directory:
`run46.py` (runner), `analyze46.py`, `tables46.py`, `null-control.sh` (they expect the libraries in `/root/p46/libs/<name>.so`; WSL2,
16 CPUs; other sessions ran their own jobs between my reps). The raw results are in `/root/p46/bench/runs.jsonl`,
`/root/p46/counters/runs.jsonl` and `/root/p46/null/runs.jsonl` on the WSL machine (not in the repository).

**Default trace threshold** (negative = new is lower).

| Workload | n | base wall ms | new wall ms | wall diff | base CPU ms | new CPU ms | CPU diff | base pause ms | new pause ms | pause diff | collections base / new |
|---|--:|--:|--:|---|--:|--:|---|--:|--:|---|--:|
| requests | 15 | 397 | 412 | +5.4% [+3.1, +11.2] | 517 | 544 | +5.4% [+1.9, +9.1] | 30 | 31 | +3.0% [+1.6, +7.5] | 9 / 9 |
| binarytrees | 15 | 1101 | 1104 | +1.4% [-3.6, +2.1] | 3132 | 2671 | -13.9% [-22.5, -5.6] | 122 | 126 | +1.6% [-23.2, +4.9] | 30 / 29 |
| listsuffix | 15 | 1495 | 1471 | -1.1% [-3.2, +2.7] | 3698 | 3595 | -1.0% [-3.6, +2.0] | 178 | 174 | +0.6% [-6.3, +3.2] | 6 / 6 |
| mixedmedium | 15 | 1542 | 1543 | +0.2% [-1.8, +1.2] | 2664 | 2604 | -0.1% [-4.2, +3.4] | 222 | 219 | -1.6% [-4.2, +3.1] | 227 / 228 |
| losarrays | 15 | 1231 | 1242 | -0.2% [-4.2, +2.4] | 2567 | 2613 | +1.0% [-3.2, +2.1] | 500 | 503 | -0.4% [-1.6, +4.5] | 49 / 49 |
| mediumarrays | 15 | 1051 | 1044 | -0.0% [-2.2, +1.9] | 1802 | 1794 | -1.2% [-2.2, +1.6] | 87 | 86 | +0.1% [-3.7, +4.0] | 14 / 14 |

**Traces forced (`tr1`).**

| Workload | n | base wall ms | new wall ms | wall diff | base CPU ms | new CPU ms | CPU diff | base pause ms | new pause ms | pause diff | collections base / new |
|---|--:|--:|--:|---|--:|--:|---|--:|--:|---|--:|
| requests | 15 | 420 | 407 | -4.1% [-7.6, +2.8] | 687 | 673 | -7.5% [-9.4, +1.4] | 44 | 43 | -5.2% [-13.1, +0.2] | 12 / 12 |
| binarytrees | 15 | 1165 | 1205 | +4.3% [-0.9, +6.7] | 3639 | 4579 | +4.2% [-11.2, +52.3] | 154 | 172 | +3.8% [-8.8, +35.5] | 29 / 32 |
| listsuffix | 15 | 1667 | 1699 | +3.3% [-3.5, +5.7] | 6569 | 5940 | -11.2% [-18.8, -4.3] | 284 | 327 | +9.9% [+1.3, +21.9] | 9 / 9 |
| mixedmedium | 15 | 1568 | 1559 | +1.0% [-5.4, +4.3] | 2853 | 2817 | -1.6% [-3.6, +5.5] | 247 | 242 | -2.8% [-7.6, +7.2] | 227 / 222 |
| losarrays | 15 | 1221 | 1247 | +1.4% [-1.0, +3.8] | 2563 | 2631 | +1.6% [+0.1, +2.3] | 503 | 506 | +2.1% [-0.3, +3.8] | 49 / 49 |
| mediumarrays | 15 | 1082 | 1079 | -1.2% [-4.6, +2.9] | 2028 | 2045 | -1.1% [-2.8, +3.4] | 128 | 137 | +5.3% [-4.7, +12.4] | 17 / 18 |

The bootstrap of a median of 15 values is lumpy. A second run of the analysis with another random seed (`analyze46.py`, in
`/root/p46/bench.txt`) moves some interval ends by up to 2 points: for example `binarytrees` forced wall is `[+1.1, +6.7]`
there, and `mediumarrays` forced wall is `[-5.2, -0.1]`. Read the cells with an interval end near 0 as "not shown".

What the numbers say:

* **Wall time: no gain.** No cell has a wall interval that is clearly below 0. `requests` default is clearly above 0 (+5.4%,
  see below). With traces forced, `binarytrees` (+4.3%) and `listsuffix` (+3.3%) get longer pauses and, for `binarytrees`,
  3 more collections. The traces end earlier because the first epoch does not queue children, so the policy starts the next
  trace sooner (the counter runs show 21 against 15 InitialMarks for `binarytrees` forced). Each trace costs pause time (InitialMark
  and FinalMark). [N] I did not measure the pause cost per trace.
* **CPU time (all threads): lower where the old window marked a lot, but not confirmed.** `listsuffix` forced -11.2%
  [-18.8, -4.3]; `binarytrees` default -13.9% [-22.5, -5.6] (null control: -4.5% [-11.9, +2.7]). The rest are inside the noise.
  `losarrays` forced is +1.6% [+0.1, +2.3]; [N] no cause found (`losarrays` queued no children in the first epoch even with the
  old rule).
* **Peak RSS** is about the same (medians within 2%, `bench.txt`).
* **`requests` default +5.4% wall.** In the counter runs `requests` made no trace with the default threshold (3 of 3 runs), so the
  new rule does not run in this cell [N for the 15 benchmark runs: the release library has no counters]. The `requests` cell
  with traces forced is -4.1% with the same two libraries, and the null control below gives +0.7% [-2.7, +2.5]. So the +5.4% is not a
  stable effect of the new rule.

**Null control.** The long run above took hours, because the lock was shared with other sessions, so the reps are spread over a
long time. A second, short run (`null-control.sh`, which makes `run46c.py` from `run46.py` with one lock hold) holds the lock once: 15 reps of `requests`, `binarytrees` and `listsuffix`
with the default threshold, and three configurations in a shuffled order in each rep: `base`, `base2` (an identical copy of
`base.so`) and `new`. Paired differences against `base`, wall and CPU (Measured):

| Workload | `base2` against `base`: wall | CPU | `new` against `base`: wall | CPU |
|---|---|---|---|---|
| requests | -0.4% [-2.1, +1.1] | +0.1% [-1.8, +1.6] | +0.7% [-2.7, +2.5] | +0.7% [-2.9, +1.8] |
| binarytrees | +1.0% [-2.3, +2.9] | +3.9% [-8.1, +14.2] | -1.5% [-2.2, -0.0] | -4.5% [-11.9, +2.7] |
| listsuffix | +1.3% [-2.7, +4.0] | +2.6% [-1.6, +6.7] | +2.5% [-6.6, +3.3] | +1.6% [-2.3, +5.5] |

* The same binary against itself differs by up to +1.3% wall and +3.9% CPU in the median, with intervals of +-3% wall and up to
  +-10% CPU for `binarytrees`. This is the noise of the method.
* `requests` default: `new` is +0.7% [-2.7, +2.5]. The +5.4% of the long run did not repeat. It was noise (or a change of the
  machine between reps) **[N]**; the code cannot run in a cell without a trace.
* `binarytrees` default: CPU -4.5% [-11.9, +2.7] and wall -1.5% [-2.2, -0.0] here, against -13.9% in the long run. The gain is not
  confirmed. `listsuffix` default is +1.6% CPU, inside the noise. The `listsuffix` forced gain (-11.2%) was not repeated **[N]**.

## 9. What was not verified

* No formal proof of the SATB invariant. Section 4 is an argument, and section 7 has one targeted test and the existing suites.
* The reason why the Java authors chose the rule is not in a document **[N]**. The argument here is mine.
* The memory order of `m_first_window` on ARM64 was not studied (release and acquire are used; the engine has an open ARM64 item).
* Non-lazy mode (`LXRLazyDecrements=0`) was not run in the managed tests. Section 4 (item 7) says that nothing changes there.
* The extra collections with traces forced (`binarytrees` +3) and the different number of traces per run were not studied.
* The `requests` default wall difference (+5.4% in the long run) did not repeat in the null control. Its cause is not known [N]. It
  was not checked with `perf` or with a second build of the base.
* Only the Release build of the P4 harness was run (the task asked for Release). The Debug build was not run.
* ARM64, Windows and the Laxori branch were not built.
* No test makes a large object die in the first epoch after InitialMark **[N]**. The large-object path is covered by the
  `losarrays` and `mediumarrays` runs and the existing suites.
