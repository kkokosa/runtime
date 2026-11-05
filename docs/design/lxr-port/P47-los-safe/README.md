# P47 - Safe improvements of the large object space (young-span list, running totals)

Base: `lxr-gc-review` at 9664cfe78cb. Scope: `src/coreclr/gc_lxr/large_object_space.{h,cpp}`, the P2.5 harness, and the scripts
in this directory. Two changes that the measurement of P44 found to be safe:

* (A) `SweepNursery` visits the young spans only, not all active spans under the LOS lock.
* (B) `GetMatureStatistics` returns running totals, and does not walk all spans under the LOS lock.

Nothing else changed: the madvise, the zeroing and the metadata reset of the release are as before, and no default changed.
Anything that I did not verify is marked with [N].

## 1. Result

Both changes are implemented as asked, with the layout kept (section 3.1) and the control measured (section 6.2).

* **They give a gain only on workloads with thousands of live large objects**, as P44 predicted: `losmany` pause -19.7 % [-24.5,
  -14.9] and wall -5.8 % [-10.1, +0.6] against the base (against the control in the same layout: pause -18.8 %, wall -5.6 % [-7.7, -2.5], CPU
  -3.5 % [-5.3, -0.4]); `losarrays` pause -4.4 % [-4.9, -1.9] (wall -1.8 % [-2.6, +0.7] and CPU -0.4 % [-1.1, +1.3]: the intervals contain zero
  against the base). The other five workloads: no effect that I can tell from noise.
* **The layout control passes**: with the features switched off, the new build equals the base in CPU on `losarrays` (+0.7 % [-0.8,
  +1.7]) and `losmany` (+0.6 % [-2.1, +2.3]); all members of `Span` and of `LxrLargeObjectSpace` keep their offsets.
* **Validation**: P2.5 (209037 checks, 30744 before), P2.1-P2.4, P3.1-P3.4 and P4 pass in both variants, also with the validation
  mode on; four mutation controls fail as they should; `PrivateTests all 2 13` 20/20 (and 20/20 with validation); crash hunt 72/72
  (and 16/16 with validation); all checksums correct. `--mature-released-candidate` is flaky on the base as well.

Commits: A `LXR LOS: SweepNursery visits the young spans only`, B `LXR LOS: running totals for GetMatureStatistics`, and one
commit with the tests, the scripts and this document.

## 2. Why the old walk existed

`SweepNursery` walked the whole active list because that is the simplest way to find the young spans that died: the space
had no index of the young spans. The walk does one thing only: for each `Active` span whose object has the nursery bit set and
a reference count of zero it takes the span for a release (`BeginSpanRelease`), takes it out of the active list, and the
release runs outside of the lock. I checked the other duties that a walk like this could have:

| Duty | Where it is done | Does the walk do it? |
|---|---|---|
| Promote a surviving young span (clear the nursery bit, set the unlog bits) | `TryMarkAndPromote`, called from the promotion of the object in the pause | No. A promoted span has no nursery bit when the walk reaches it and is skipped. |
| A young span with a reference count that is not promoted yet | stays as it is | The walk skips it, and finds it again at the next pause. The list keeps it too. |
| Release of a dead young span | `SweepNursery` | Yes. This is the only duty. |
| Mature spans | nobody (released by the lazy decrements through `ReleaseAfterDecrements`) | The walk reads and skips them. This is the cost. |
| Pinned or young-object bookkeeping | not in the LOS (it is in the Immix blocks) | No. |
| `Allocating` spans (between `TryCarve` and `PublishSpan`) | owned by the allocating thread | Skipped (state is not `Active`). No allocation runs in the phase `Release` where the sweep runs, so there are none. |

The nursery bit is set in one place (`InitializeAllocationMetadata`, in the allocation, after `TryCarve` has linked the span)
and cleared in one place (`TryMarkAndPromote`), and `ResetAllocationMetadata` clears it when the span is released. So a span
can be young and dead only if it was allocated, and it is in the young list from `TryCarve` on. This is the invariant of (A).

## 3. Design

### 3.1 Layout: a side structure

P44 found that adding fields to `Span` or to `LxrLargeObjectSpace` made `losarrays` use 25 % more CPU: the LOS spin lock is
contended, and 63 % of the self samples of `FinishSpanRelease` were on the lock loop. So the layout is the first requirement:

* `Span` is not changed.
* The members of `LxrLargeObjectSpace` are not changed. One pointer `SideState* m_side` is added **after the last member**.
* All new state is in `SideState` (allocated by `Initialize`, freed by the destructor), whose hot fields are on their own cache
  lines (`alignas(64)`: the totals, which workers write, and the young list, which the lock holder writes).

Check (`clang -Xclang -fdump-record-layouts`, `results/layout-base.txt`, `results/layout-new.txt`): all members of
`LxrLargeObjectSpace` and all members of `Span` have the same offsets in the base and in the new build; the only difference is
the new member `m_side` at offset 128 (`sizeof` 128 -> 136). The members after it in the containing class move by 8 bytes
(the same as in the `exp2` build of P44, which was equal to its control in CPU). Section 6 has the measured control.

### 3.2 (A) Young-span list

* `SideState::young` is an array of `{Span*, version}`, guarded by the LOS lock. `TryCarve` appends the new span right after
  `LinkActive`. It already holds the lock, so there is no new lock, no new atomic, and no new contention on the allocation path.
  Cost on that path: one store into a sequential array and two increments of fields that only the lock holder uses.
* An entry is *stale* when the version of its span changed (the span was released and used again: `WriteSpan` adds 2 to the
  version at every use) or the span is `Pooled` or `Quarantined`. A stale entry is dropped by the next sweep. When the array is
  full, the stale entries are dropped first (the array only grows when more than half is current), so releases between two
  pauses do not make the list grow without limit.
* `SweepNursery` (lock held, phase `Release`) visits the entries:
  * stale: dropped; `Active` without the nursery bit (promoted): dropped, the span is old now;
  * `Active`, young and the reference count is zero: `BeginSpanRelease`, `UnlinkActive`, put on the list of spans to release
    (same order as the old walk), and not kept in the young list;
  * `Active`, young and the count is not zero: stays (it is promoted at a later pause);
  * `Allocating` or `Releasing` (another thread works on it): stays.
  After a metadata error the entries that were not visited stay.
* The release itself (outside of the lock, `FinishSpanRelease`) is unchanged. If a release fails (`DecommitFailed`), the span
  is `Active` again and is young (it was dead and young), so it is appended to the list again (`RequeueYoung`). The spans that the
  sweep had taken but not released after a failure are put back in the same way.
* If an append cannot allocate (`realloc` fails), `youngValid` becomes false, and the next sweep walks all spans (the old
  walk) and builds the list again. No allocation can fail because of the list.

### 3.3 (B) Running totals

`GetMatureStatistics` returns `(bytes, slack)` of the spans that are `Active` and have no nursery bit. Totals in `SideState`
(two relaxed atomics on their own cache line) keep these two numbers:

* `TryMarkAndPromote`: when its compare-exchange changes the state from nursery to non-nursery, add the span's page bytes and
  slack (`page bytes - object bytes`). The span fields come from the snapshot that the function already has.
* `BeginSpanRelease` (after the checks of identity and owner): when the object has no nursery bit, subtract. The old walk does
  not count a span in the state `Releasing`, so the subtraction is done when the state changes, not at the end of the release.
  Callers that know that the span is young (the sweeps) skip the metadata read. `AbortSpanRelease` adds the span back
  (a mature span only; it reads the nursery bit again).
* There is no other place where a span becomes mature, dies or changes its size: the LOS has no resize, and a `Quarantined`
  span was subtracted when its release began.

Statistics callers: the heap statistics in the pause (one call) and the policy after the lazy sweep (two calls) read two
atomics and take no lock.

### 3.4 Switches

Both are environment variables, read once by `Initialize`. They are off by default.

| Variable | Effect |
|---|---|
| `LXR_LOS_LEGACY_WALKS=1` | The young list and the totals are off: the sweep and the statistics walk all spans, as in the base. The same layout as the new build, so it is the control of section 6. |
| `LXR_LOS_VALIDATE=1` | Every `SweepNursery` first computes with a walk of all spans which spans must be released and which stay young, and after the sweep compares both with what the young list did. Every `GetMatureStatistics` compares the totals with a walk. A difference is printed to stderr (`LXR LOS validation: ...`) and counted (`GetValidationFailures`). |

For the tests there are `GetMatureStatisticsByWalk` and `GetYoungObjects` (the objects of the current entries and the number of
entries including stale ones). `SweepNursery` moved out of `LXR_ENABLE_LAZY_COMPLETION_COUNTER` (it did not need it), so the
P2.5 harness can call it.

## 4. Validation

All runs on the new build (commit B). Raw outputs: `results/val-*.txt`. Both variants of the object-start walk (`default` and `bitmap`),
Release, with `docs/design/lxr-port/P31-object-start-walk/validate-variant.sh`.

| Suite | default | bitmap |
|---|---|---|
| P2.1, P2.2, P2.3, P2.4 | pass | pass |
| **P2.5 (LOS)** | **pass, 209037 checks** (base: 30744) | **pass, 209037 checks** |
| P3.1 / P3.2 / P3.3 / P3.4 | 641 / 395 / 357 / 70 pass | 641 / 395 / 357 / 70 pass |
| P4 (`default`) | 105380 / 105380 | 105380 / 105380 |
| P4 selectors | all pass except `--mature-released-candidate` (65/67, flaky) | all pass |

* The same run with `LXR_LOS_VALIDATE=1` (validation mode on, all suites, both variants): the same results. I also ran every P4
  selector with validation on and counted the reports (`results/p4sel-valon-*.txt`): 0 reports in 47 selectors, both variants. P2.5
  reads the counter itself (mode 1 of the new checks).
* `--mature-released-candidate` is flaky on the base as well: 11 of 20 runs of the base harness fail with the same message
  (65/67; `the legitimate LOS incoming field follows the actually moved mature target`), and 7 of 20 on the new harness
  (`results/summary-controls-flaky.txt`). `--p8-storage` passed in all my runs (1441/1441, bitmap 1449/1449).
  The line `FAIL: injected zero-RC old target ...` is printed by `--zero-rc-control`, a control that injects a violation.
* The six workload checksums and the `losmany` checksum are correct in every run of the benchmark (336 runs, three
  configurations), and in a run with `LXR_LOS_VALIDATE=1` (7 workloads; no validation line on stderr).

### 4.1 New checks in P2.5 (`large-object-space-validation.cpp`, `RunYoungAndTotalsChecks`)

Run in three modes: the default, the validation mode, and `LXR_LOS_LEGACY_WALKS=1` (the list checks are skipped there; the
sweep and the totals checks run). Each mode runs with the three reference-count widths of the harness.

* The young list holds exactly the spans allocated since they were last young: after six allocations, after the next
  allocations, after threads allocate together.
* A promoted span leaves the list at the pause; a young span with a count but no promotion stays; a dead young span is
  released (`SweepNursery` returns its page bytes) and leaves the list; a span that a thread released itself before the sweep leaves
  a stale entry that the sweep drops (no stale entry is left after a sweep).
* A failed decommit during the sweep keeps all dead spans in the list (`DecommitFailed` is returned), and the next sweep releases
  them.
* 3000 allocate-and-release cycles between pauses do not make the list grow without limit (at most 2048 entries).
* 400 random pauses with a model (allocate, promote, leave a count, release a young span, release a mature span): the list, the
  released bytes, `ValidateStructure`, and the totals (`GetMatureStatistics` equals `GetMatureStatisticsByWalk` and equals the
  model) are checked after each pause.
* Mutation controls: section 5.

### 4.2 Managed and crash hunt

* `PrivateTests all 2 13` (13 threads; `P32-privatetests-failure/PrivateTests.cs`, built with the dotnet SDK), 20 runs on the new
  library: 20 pass, no `LXR fatal`, no `OutOfMemoryException`. The same 20 runs with `LXR_LOS_VALIDATE=1`: 20 pass, no validation
  report in any log. (`results/pt-new.txt`, `results/pt-val.txt`)
* Crash hunt (`p47hunt.py`, from `p31hunt.py`): the six workloads, `losmany` and the interior-pointer stress test, 24 runs per
  worker configuration (13/3, 4/2 and 1/1 GC/concurrent threads), 72 runs: 0 failures (nonzero exit, wrong checksum, stress failure or
  timeout), 9 runs of every program. With `LXR_LOS_VALIDATE=1`: 16 runs (13/3 and 1/1): 0 failures.
  (`results/hunt-*.jsonl`) This is a reduced hunt (the P31 hunt used at least 100 runs per configuration).

## 5. Mutation controls

`run-p25-controls.sh` builds the P2.5 harness with one piece of the logic broken (a `-D` macro in `large_object_space.cpp`, off
in every normal build) and requires a failure:

| Control | What it breaks | Result |
|---|---|---|
| `LXR_LOS_CONTROL_YOUNG_NO_RECORD` | `TryCarve` does not record the new span | detected (dead young spans are not released; the list is empty) |
| `LXR_LOS_CONTROL_YOUNG_KEEP_PROMOTED` | the sweep keeps promoted spans in the list | detected (a promoted span stays in the list) |
| `LXR_LOS_CONTROL_TOTALS_NO_PROMOTE` | a promotion does not add to the totals | detected (totals differ from the walk and the model) |
| `LXR_LOS_CONTROL_TOTALS_NO_RELEASE` | a release does not subtract | detected |

## 6. Benchmark

Frame `/root/prof/frame-c4/corerun`, `DOTNET_gcServer=1`, `DOTNET_GCPath=<lib>`, WSL2, 16 vCPU, default worker counts. Driver: the
P44 driver (`driver/`, built with the dotnet SDK `/root/p24-linux-postreview/.dotnet/dotnet`). Workloads and checksums as in the task
(`mediumarrays` with `DOTNET_LXRImmixInitialMB=200 DOTNET_LXRImmixReserveMB=400`; `losmany 2000 60000` with
`DOTNET_LXRLOSInitialMB=1000 DOTNET_LXRLOSReserveMB=1600 DOTNET_LXRNativePlaneLimitMB=16000`, decimal MB). Every run checks its
checksum (336 of 336 correct).

* Configurations: `base` = library built from `lxr-gc-review` 9664cfe78cb; `new` = this change; `new:LXR_LOS_LEGACY_WALKS=1` =
  the control (the new build with the young list and the totals off: the old code paths in the new layout).
* 7 workloads x 3 configurations x 16 repetitions = 336 runs. In each repetition and workload the order of the three
  configurations is shuffled (`p47run.py`, seed 47). The whole batch ran under one `flock /tmp/lxr-bench.lock`
  (`P47_HOLD_LOCK=1`, because many sessions share the lock and a run-by-run lock took hours). The load average before a run: median
  2.6, maximum 4.9. Other sessions ran work that does not take the lock at the same time.
* Statistics: the difference (configuration minus reference) is taken per repetition; the table gives the median of the 16
  differences with a 95 % bootstrap interval of the median (2000 resamples). `*` = the interval excludes zero. `p47analyze.py`,
  `results/benchB.analysis.txt`, raw runs in `results/bench-runs.jsonl`.

### 6.1 new against base (median paired difference in %, [95 % interval])

| Workload | wall | CPU | pause |
|---|---|---|---|
| requests | -2.0 [-5.3, +1.8] | -1.5 [-4.1, +2.5] | -2.3 [-8.7, +2.1] |
| binarytrees | +2.1 [-3.2, +6.6] | +10.5 [-11.0, +50.1] | +6.4 [-30.6, +42.7] |
| listsuffix | -2.2 [-3.9, -0.6] * | -5.1 [-7.5, -1.1] * | -5.9 [-8.4, -1.7] * |
| mixedmedium | +0.1 [-1.8, +2.4] | -0.3 [-2.1, +3.3] | -0.2 [-4.8, +5.7] |
| **losarrays** | -1.8 [-2.6, +0.7] (-23 ms) | -0.4 [-1.1, +1.3] | **-4.4 [-4.9, -1.9] \*** (-22 ms) |
| mediumarrays | +1.4 [-1.5, +2.5] | +0.8 [-1.1, +2.5] | +1.4 [-1.1, +3.7] |
| **losmany** | **-5.8 [-10.1, +0.6]** (-70 ms) | -2.8 [-6.4, +1.5] | **-19.7 [-24.5, -14.9] \*** (-53 ms) |

Medians: `losarrays` base wall 1233 ms, CPU 2592 ms, pause 500 ms; new 1212, 2576, 478. `losmany` base 1227, 2974, 268; new 1173,
2892, 218. The number of collections is the same in all configurations (`losarrays` 49, `losmany` 73).

### 6.2 Control: layout (new build with the features off against base)

| Workload | wall | CPU | pause |
|---|---|---|---|
| requests | -1.9 [-4.8, +2.7] | -1.0 [-3.9, +2.9] | +1.7 [-5.2, +3.1] |
| binarytrees | +1.3 [-5.0, +7.7] | +2.8 [-15.6, +39.6] | +11.8 [-23.9, +38.9] |
| listsuffix | -1.2 [-2.8, +0.7] | -1.8 [-4.8, +2.5] | -1.8 [-6.7, +1.3] |
| mixedmedium | -0.3 [-3.9, +3.3] | -0.8 [-3.6, +3.0] | -2.2 [-5.0, +6.0] |
| **losarrays** | +0.5 [-0.7, +3.2] | **+0.7 [-0.8, +1.7]** | +2.3 [+0.0, +3.9] * |
| mediumarrays | -0.3 [-1.3, +3.2] | +0.0 [-0.8, +2.8] | +0.5 [-1.5, +4.1] |
| **losmany** | +0.6 [-3.3, +4.5] | **+0.6 [-2.1, +2.3]** | +0.7 [-7.8, +2.7] |

The CPU of the control is equal to the base on `losarrays` and `losmany` (the intervals contain zero and are at most +-2.3 %,
against the +25 % of P44's layout error). One pause interval on `losarrays` touches zero (+2.3 % [+0.0, +3.9], 4 of 16 lower), and wall and CPU
do not move; I treat it as noise [N: not repeated with more runs].

### 6.3 new against the control (the effect of the two changes in the same layout)

| Workload | wall | CPU | pause |
|---|---|---|---|
| losarrays | -2.2 [-3.0, +0.0] | -0.8 [-1.8, +0.8] | **-5.3 [-8.0, -3.1] \*** |
| losmany | **-5.6 [-7.7, -2.5] \*** | **-3.5 [-5.3, -0.4] \*** | **-18.8 [-20.5, -14.9] \*** |
| the other five | no interval excludes zero except `listsuffix` wall (-1.1 [-3.7, -0.0]) | none | none |

### 6.4 Reading

* `losmany` (2000 live arrays of 64 KiB to 1 MiB): the pause is 19 % shorter, the wall 5-6 % shorter, the CPU 3-4 % lower.
  `losarrays` (1500 live arrays of 36-100 KiB): the pause is 4-5 % shorter; the wall (-1.8 %) and the CPU (-0.4 %) intervals
  contain zero in the comparison with the base, and wall is just at zero against the control. These agree with the P44 prediction
  (`losarrays` wall -2.3 % [-3.5, -0.5], pause -3.9 %; `losmany` wall -6.1 % [-8.7, -0.9], pause -18.8 %), which was measured with the
  experiment code. So (A) and (B) together give a real but small gain, and only on workloads with thousands of live large objects.
* The other five workloads have one or two large objects per pause; there is nothing to gain and nothing was lost.
  `binarytrees` is noisy (CPU interquartile range 2111-3407 ms in the base; its intervals are wide).
* `listsuffix` is lower than the base on all three metrics (the intervals exclude zero). `listsuffix` has one large object (the
  64 KiB `heads` array), so the change does nothing there: the young list holds one span and the old walk visited one span. Against the
  control the CPU and pause intervals contain zero, and the wall interval ends at -0.0 %. I treat it as noise, or as an effect of
  the 8-byte move of the members behind the space in the engine [N: not investigated].
* The effect of (A) and (B) separately was not measured here (P44 did: A alone: `losmany` pause -5.8 %, B alone: -6.9 %).

## 7. Not verified [N]

* The effect of (A) and of (B) alone was not measured with this code (P44 measured them with the experiment code).
* The effect with more than about 2000 live large objects: not measured. The walk costs about 150 ns per span (P44), so the gain
  should grow with the number of spans [N].
* The pause shorter by 19 % on `losmany` is the sum of the two changes. I did not split it into the sweep and the three statistics
  calls.
* The `listsuffix` difference against the base (section 6.4) and the `losarrays` pause interval of the control (+2.3 % [+0.0, +3.9])
  were not investigated or repeated.
* No Windows, macOS or Debug-engine build was run. The validation suites ran in Release (P4: Release only, both variants). The
  validation mode (`LXR_LOS_VALIDATE=1`) was not checked for reports during the crash hunt (the runs only check exit code and
  checksum); it was checked for the P2.5 runs, all P4 selectors, `PrivateTests` (20 runs) and one run of each workload.
* The validation mode compares the totals with a walk while other threads may still change them. It showed no difference in
  any run, but it can report a false difference if a statistics call runs at the same time as a promotion or a release; the callers
  in the engine run after the promotions of the pause and after the lazy sweep.
* Memory: the young list holds 16 bytes per span allocated since the last sweep that is still young or stale, and is compacted when full.
  I did not measure the memory of a run with a very large number of allocations between two sweeps.
* I did not run the P4 mutation controls of other work (`run-lxr-rc-vertical.sh <config> <dir> <control>`) on this change.
* The P4 `Debug` configuration was not run.

## 8. Files

* `driver/` - the driver of P44 (the workloads, with `losmany`), unchanged.
* `p47run.py`, `p47analyze.py` - the runner and the analysis of P44 (`p44run.py`, `p44analyze.py`) with the paths of this work;
  `P47_HOLD_LOCK=1` is for a caller that holds `/tmp/lxr-bench.lock` for the whole batch. The batch of section 6 was
  `P47_HOLD_LOCK=1 flock /tmp/lxr-bench.lock python3 p47run.py <out> 16 "base;new;new:LXR_LOS_LEGACY_WALKS=1" requests,binarytrees,listsuffix,mixedmedium,losarrays,mediumarrays,losmany 47`
  (libraries in `/root/los-safe/libs/<base|new>/libclrlxrgc.so`).
* `p47hunt.py` - the crash hunt of P31 (`p31hunt.py`) with `losmany` and a frame argument. `privatetests-batch.sh` - `PrivateTests all 2 13`
  runs (from `P32-privatetests-failure/repeat.sh`). `p4-validate-sel.sh` - every P4 selector with the validation mode on.
* `run-p25-controls.sh` - the mutation controls. `layout.sh` - the record layouts of section 3.1.
* `build-in.sh`, `sync-new.sh` - how the libraries were built: the first CMake configure of a new subdirectory on `/mnt/c` was very
  slow (over 15 minutes, and I stopped it), so the base was built from `git archive` of 9664cfe78cb and the new
  library from a copy of the sources, both on the ext4 disk of WSL.
* `results/` - raw outputs.
