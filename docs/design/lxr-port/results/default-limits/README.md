# LXR default heap limits and the out-of-limit message

Branch `kkokosa-lxr-default-limits-oom-message`, base `kkokosa-lxr-gc-review` 7e4d693af24. Nothing is pushed. **Update:** the LOS reserve default was raised in a third commit; sections 1 to 10 describe the first two commits (Immix reserve), and the rule that is valid now is in section 11 (it replaces the lines that say "minus the LOS reserve").
This file uses plain words. A claim that was not verified is marked **[N]**. A build or test is called "passed" only if it was run (section 8 lists what was run).
Background: `docs/design/lxr-port/results/gcperfsim-oom/README.md` (branch `kkokosa-gcperfsim-oom-investigation`).

## 1. Result in short

* **Jan's command now passes with no setting**, on Windows and on Linux (section 5). With the old build it fails at once with `OutOfMemoryException`.
* **New default rule** (`src/coreclr/gc_lxr/lxr_default_limits.h`, used in `LxrGcHeap::Initialize`):
  * Immix reserve = memory limit of the process (`GCToOSInterface::GetPhysicalMemoryLimit()`, which includes a container limit). Lowest value 128 MB (the old default), highest value 262144 MB (256 GiB). *(first commit: the limit minus the LOS reserve; now see section 11)*
  * Native plane limit = 4.5 x (Immix reserve + LOS reserve), lowest value 4096 MB (the old default).
  * LOS reserve: the same rule (lowest value 256 MB, highest 262144 MB), added in the third commit (section 11).
  * An explicit `LXRImmixReserveMB` or `LXRNativePlaneLimitMB` always wins, and keeps the old rules.
* **The policy depended on the reserve** (section 2), so a larger reserve alone changed the behaviour of every program. The sizing now uses a "policy reserve": 128 MB while the live size is small, and 2 x live size above that, never more than the real reserve. The large reserve is only the growth ceiling. For small programs the collection counts, pauses and times are the same as before (section 4).
* **One-line message** when an allocation fails (`LxrGcHeap::ReportOutOfMemory`): it names the limit and the setting to raise. It is printed once per process, with one system call, and it allocates nothing (section 6).
* The reserve is address space. The startup working set is +3.7 MB at the default on a 31 GB host (section 4.4). The card tables are now allocated lazily; before that change the cost was +19 MB.

## 2. The policy depends on the reserve (measured before the change)

Code (read, not guessed):

* `LxrHeapSizer::TargetCapacity` (`lxr_heap_sizing.h`) limits the capacity target at each heap-full collection to 75% of the Immix reserve: 96 MB at reserve 128. With a nursery budget of 96 MB, the target is `min(live + 96, 96)` = 96 MB for every program, so the nursery is `96 - live`.
* `LxrReferenceCounting::BorrowSuspended` lets a pause borrow to-space only up to `reserve - capacity` (32 MB at the old default).
* Nothing else in the policy reads the reserve. `m_hard_limit` is used for `LXRNurseryRatio`, for `PublishMemoryInfo` and for the growth room.

Measured with the old build (7e4d693af24), default settings against `DOTNET_LXRImmixReserveMB=60000 DOTNET_LXRNativePlaneLimitMB=250000`, one run each, the machine was busy with builds (so the times are not reliable; the counts are): `logs/linux-exp1-dependence.txt`.

| workload | collections, old default | collections, large reserve | pause ms | peak RSS MB |
|---|---|---|---|---|
| listsuffix | 6 | 5 | 191 -> 222 | 202 -> 295 |
| binarytrees | 38 | 22 | 163 -> 98 | 205 -> 266 |
| mixedmedium | 215 | 16 | 215 -> 108 | 193 -> 410 |
| requests | 9 | 9 | 35 -> 34 | 170 -> 208 |
| losarrays | 49 | 49 | 457 -> 474 | 105 -> 142 |
| mediumarrays | **fails** | 18 | | 574 |

So a plain larger default makes most programs faster (fewer collections), but it costs 40 to 220 MB of working set and it is not "today's behaviour". The coordinator chose to keep the old behaviour for small programs.

## 3. The rule in detail

```
policyReserve = min(reserve, max(128 MB, 2 x liveBytes))       // only when the Immix reserve is the default
sizer ceiling = 75% of policyReserve                           // as before, with policyReserve instead of reserve
borrow room   = policyReserve - capacity                       // as before, with policyReserve instead of reserve
growth ceiling (TryGrow, RequestGrowth) = the real reserve
```

* `liveBytes` is the mature live size that the lazy sweep measures (`m_mature_live_bytes`). Before the first sweep it is 0.
* For a live size up to 64 MB the policy reserve is 128 MB, so the sizer and the borrowing give the same numbers as the old default. The earlier message to the coordinator said "48 MB"; the exact limit is 64 MB (2 x 64 = 128).
* Above 64 MB the heap can grow with the program: the target is `live + nursery budget`, up to 75% of `2 x live`. The factor 2 is the finding of the investigation report ("the heap needs about 2 times the live data").
* `LxrHeapSizer::PolicyReserveBytes` (pure function, tested in P4) computes it. `LxrGcHeap::PolicyReserveBytes` applies it only if the reserve is the default. `LxrReferenceCounting::SetBorrowCeiling` gives the engine the ceiling for borrowing; `FinishLazy` updates it after each sweep.
* **Hard limit.** LXR does not support `GCHeapHardLimit*` (`Initialize` returns `E_NOTIMPL` if one is set), so there is no standard hard limit to respect. The LXR hard limit is `LXRManagedHeapHardLimitMB`. If it is set and the reserve is not, the reserve is `hard limit - LOS reserve` (when that is above 128 MB), so that the reservation equals the hard limit as before; the engine never admits more than the hard limit. A hard limit below 384 MB keeps the old reserve of 128 MB (old behaviour).
* **Container.** The limit comes from `GetPhysicalMemoryLimit()`. Tested with a cgroup v2 limit of 1200 MB on Linux: the reserve was 944 MB (1200 - 256), see section 5.
* **Address space.** Windows accepted an explicit reserve of 150000 MB and of 1000000 MB (1 TB) at start (section 5.3), so a reserve (not a commit) does not fail at init there. No retry on init failure was added: **[N]** for a host that limits address space (`ulimit -v`, strict overcommit with a limit); the runtime itself reserves a very large range, so such a host is not usable for CoreCLR anyway.
* **Per-reservation tables.** The card table (reservation / 2048 bytes) and the bundle table were zeroing `new[]`, which touched every page. They are now allocated with `VirtualReserve` + `VirtualCommit` (zero pages, taken on first write). The four per-block byte arrays of the engine are still zeroing `new[]` (about 0.13 MB per GB of reserve). The default reserve is capped at 256 GiB for that reason.

## 4. Numbers: old default against new default

Method: Linux x64 (WSL2 on the 16-CPU VM), `corerun` + `CompareDriver` (frame `/root/prof/frame-c4`), `DOTNET_gcServer=1`. The old library is the one of 7e4d693af24 built by the same script (`/root/gcoom/frame-cur/libclrlxrgc.so`); the new library is built from this tree with `scripts/rebuild-linux.sh` (ninja, clang-14, Release). Old, new and "new with explicit large reserve" ran in one block under one lock grant, in shuffled order, one block per grant, then 8 s sleep. 10 repetitions. Checksums were checked in every run: all 170 runs that ended have the right checksum; the 10 runs of the old build on `mediumarrays` fail with OutOfMemoryException, as expected. Intervals are 95% bootstrap intervals of the paired median difference over 10 pairs. Raw runs: `data/*.jsonl`. All tables: `data/tables.md`.

### 4.1 Six standard workloads, defaults (no setting), medians

| workload | metric | old | new | new - old (paired) | new, explicit 60000 reserve |
|---|---|---|---|---|---|
| requests | collections | 9 | 9 | 0 [0, 0] | 9 |
| requests | wall ms | 361.5 | 349.8 | -1.4 [-21.3, +3.4] | 355.0 |
| requests | pause ms | 29.5 | 28.6 | +0.3 [-2.1, +2.1] | 29.4 |
| losarrays | collections | 49 | 49 | 0 [0, 0] | 49 |
| losarrays | wall ms | 1090.4 | 1088.0 | -9.2 [-59.2, +4.4] | 1095.0 |
| losarrays | pause ms | 428.0 | 417.3 | -8.7 [-15.2, -2.2] | 423.1 |
| listsuffix | collections | 6 | 6 | 0 [0, +1] | 5 |
| listsuffix | wall ms | 1250.9 | 1297.3 | +41.6 [+0.2, +86.2] | 1373.1 |
| listsuffix | pause ms | 168.0 | 172.7 | +9.5 [-4.3, +23.4] | 181.1 |
| binarytrees | collections | 35 | 38 | 0 [-5.5, +6] | 22 |
| binarytrees | wall ms | 1090.8 | 1101.6 | +8.5 [-42.1, +52.6] | 1053.1 |
| binarytrees | pause ms | 132.9 | 144.2 | +16.6 [-34.2, +25.5] | 108.9 |
| mixedmedium | collections | 223 | 219 | -3.5 [-12.5, -2.0] | 15 |
| mixedmedium | wall ms | 1369.5 | 1309.2 | -51.9 [-65.9, -17.2] | 825.8 |
| mixedmedium | pause ms | 196.8 | 191.4 | -0.8 [-7.0, +7.0] | 109.4 |
| mediumarrays | result | **fails 10 of 10** | **passes 10 of 10**: 97.5 collections, 1241 ms | | 19 collections, 1043 ms |

* **requests, losarrays, listsuffix (live size below 64 MB): the collection counts are equal in every pair** (requests 9/9, losarrays 49/49, listsuffix 6/6; the interval for listsuffix is [0, +1]). The pause times are equal within the intervals (losarrays: the new default is 8.7 ms, 2%, shorter). This is the "no change for small programs" claim of the coordinator. The wall time of listsuffix shows +42 ms (+3%) with an interval that only just excludes zero [+0.2, +86]. A second run of 10 pairs (section 4.2) gave +39 [-54, +71], and the same build with `LXRImmixReserveMB=128` set explicitly gave +11 [-48, +53]. So I treat it as noise **[N]** (not proven; 10 pairs).
* **binarytrees and mixedmedium** have a live size near or above 64 MB (the trace shows `liveK` up to 76 MB and 67 MB). For them the policy reserve rises above 128 MB, so the new default may differ from the old one. Measured: mixedmedium has 4 fewer collections and 52 ms less wall time; binarytrees shows no significant difference (counts 35 and 38 in the first run set, 34.5 and 32 in the second; the count itself varies from run to run in the old build).
* **mediumarrays** fails with the old default (`OutOfMemoryException`) and passes without any setting with the new default (the coordinator's check 1). It is slower than with the settings of the standard runs (`InitialMB=200 ReserveMB=400`: 937 ms, 14 collections) because the heap starts at 8 MB and grows by sizing. With those explicit settings the old and the new library are the same: 937.1 and 933.5 ms, 14 and 14 collections (20 runs, `data/tables.md`).
* The explicit large reserve (new library, `LXRImmixReserveMB=60000`) shows what a plain larger reserve would do: mixedmedium 15 collections instead of 223 (but +189 MB peak RSS), binarytrees 22 instead of 35, listsuffix +135 ms wall (+85 MB RSS). These runs are what the "policy reserve" avoids at the default.

### 4.2 Isolation run (10 more pairs: old, new default, new with `LXRImmixReserveMB=128`)

listsuffix: wall 1233.6 / 1235.7 / 1215.9 ms, collections 6 / 6 / 6, pause 171.2 / 171.4 / 173.5 ms. binarytrees: wall 1103.7 / 1107.0 / 1099.1 ms, collections 34.5 / 32 / 30. The explicit reserve 128 behaves as the old build (differences inside the intervals). `data/tables.md`, `data/ab2-runs.jsonl`.

### 4.3 Policy trace (`DOTNET_LXRPolicyTrace=1`), one run each, largest `capK` (KB) and number of lines

| workload | old default | new default |
|---|---|---|
| listsuffix | capK 131072, 37 lines | capK 131072, 39 lines |
| requests | 112256, 99 | 113664, 98 |
| losarrays | 98304, 178 | 98304, 296 |
| mixedmedium | 131072, 342 | 132256, 327 |
| binarytrees | 128768, 109 | 124000, 74 |

The capacity stays in the same range as with the old default (the old 96 MB sizing ceiling plus the 32 MB borrow room). The number of trace lines of losarrays differs (178 and 296) but the collection counts of the six-workload runs are the same (49 and 49): a trace line is also printed for a call that does not collect, and this count varies with timing **[N]** (I did not look into it). Raw: `logs/linux-policy-trace-*.txt`.

### 4.4 Startup working set (one run each, Linux, 31 GB host, default reserve 31812 MB)

`logs/linux-startup-rss.txt`: old 153.4 MB; new 157.1 MB (+3.7 MB). With a zeroing card table the new default cost +19 MB (172.5 MB). With an explicit reserve of 250000 MB: old 305.9 MB, new 183.6 MB. Windows: **[N]** not measured.

## 5. Jan's command (GCPerfSim, 28 threads), new library, no setting

Command: `corerun GCPerfSim.dll -tc 28 -tagb <4|540> -tlgb 2 -lohar 0 -pohar 0 -sohsr 100-4000 -lohsr 102400-204800 -pohsr 100-204800 -sohsi 50 -lohsi 0 -pohsi 0 -sohpi 0 -lohpi 0 -sohfi 0 -lohfi 0 -pohfi 0 -ramb 20 -rlmb 2 -allocType reference -testKind time`, `DOTNET_gcServer=1 DOTNET_GCPath=<new library>`. Logs are in `logs/`.

### 5.1 Linux (WSL2, 31 GB)

| Run | Result |
|---|---|
| new, default, `-tagb 4` | **pass**, 4 s (`linux-g-final-4-default.log`) |
| new, default, `-tagb 540` | **pass**, 155 s (`linux-g-new-540-default.log`; built before the last change of the message text) |
| new, `LXRImmixReserveMB=6000 LXRNativePlaneLimitMB=60000`, `-tagb 540` | pass, 201 s |
| old, same explicit settings, `-tagb 540` | pass, 211 s |
| new, `LXRImmixReserveMB=128`, `-tagb 4` | **fails** with the message (1 line) and `OutOfMemoryException` (`linux-g-final-4-r128.log`) |

The investigation report measured 98 s for the explicit settings on Linux; in this session the same settings took 200 s with the old and with the new library. The machine state was different **[N]** (not investigated). The comparison inside this session (old 211 s, new 201 s, new default 155 s) is the valid one.

### 5.2 Windows (same VM, MSVC build of this tree, `C:\lx-run\frame\clrlxrgc-new.dll`; the old DLL is `clrlxrgc-7e4d.dll`)

| Run | Result |
|---|---|
| new, default, `-tagb 4` | **pass**, exit 0 (`windows-wf-4-default.log`) |
| new, `LXRImmixReserveMB=128`, `-tagb 4` | fails with the message (1 line) and `OutOfMemoryException` (`windows-wf-4-r128.log`) |
| new, default, `-tagb 540` | **pass** in 237 s (first run), 141 s, 259 s |
| new, `6000 / 60000`, `-tagb 540` | pass in 300 s, 104 s, 105 s |
| old (7e4d), `6000 / 60000`, `-tagb 540` | pass in 102 s, 229 s, 108 s |

All runs passed (3 of 3 for each kind of the 540 runs). The time of the full run is bimodal on this VM (about 100 s or 230 to 300 s) for the old and for the new DLL, and it does not follow the settings. **[N]** Why. The investigation report measured 101 s for the old DLL with 6000 / 60000; this session measured 102, 229 and 108 s for the same DLL. So the full-run times are not a result of this change. The runs are in `logs/windows-w*.log`, order in `logs/windows-win-seq.out`. The first sequence of runs (237, 300, 102 s) and the second sequence (141 / 259 / 104 / 105 / 229 / 108 s) ran at different times; the machine was shared with other sessions, and the lock only protects against sessions that use it.

### 5.3 Large reserve at start (Windows, `-tagb 0.2`)

An explicit `LXRImmixReserveMB=150000` (146 GB, more than the 75.1 GB commit limit of the VM) and `LXRImmixReserveMB=1000000` (about 1 TB) both start and run to the end (`windows-w-r150000.log`, `windows-w-r1000000.log`). A reserve is address space, so the commit limit of the Windows README section 9 (`ERROR_COMMITMENT_LIMIT` for a large initial commit) does not apply to it. The default (about 64 GB on this VM) passed the runs of 5.2. The card table commit (reserve / 2048 bytes, 0.5 MB per GB) counts against the commit charge; at the 256 GiB cap this is 128 MB. **[N]** not tested on a Windows host with a job-object memory limit; Linux with a cgroup limit was tested (below).

### 5.4 Container limit (Linux cgroup v2)

With `memory.max` = 1200 MB (`scripts/cg.sh`, 4 threads, `-tlgb 1.5`) the message says `LXRImmixReserveMB=944 MB (default: the memory limit of the process minus the LOS reserve)`: the reserve is 1200 - 256 = 944 MB. The run ends with `OutOfMemoryException` because 4 GB of allocation with 1.5 GB of live data does not fit a heap of 944 MB; it is the expected result for this limit.

## 6. The message

`LxrGcHeap::ReportOutOfMemory` runs when `LxrGcHeap::Alloc` returns null (and when a thread cannot attach, 1024 contexts). It picks the limit from the result of the last `TryGrow` and from the state of the heap, builds one line in a 640-byte buffer on the stack (`snprintf`) and writes it with one call (`write` on Linux, `WriteFile` on Windows). It allocates no memory. An atomic flag allows only the first caller to print.

Tested on Linux (`scripts/msg.sh`, the new library):

| Case | Message (start) | Lines for 28 threads |
|---|---|---|
| `LXRImmixReserveMB=128` | `The Immix heap is full at its reserve: 128 MB used of LXRImmixReserveMB=128 MB. Raise DOTNET_LXRImmixReserveMB ...` | 1 |
| `LXRLOSReserveMB=64`, losarrays | `The large-object space reached LXRLOSReserveMB=64 MB (64 MB used; the request is 65328 bytes). Raise DOTNET_LXRLOSReserveMB ...` | 1 |
| `LXRNativePlaneLimitMB=2000` | `The side metadata (native planes) would use 2000 MB, and LXRNativePlaneLimitMB is 2000 MB (1999 MB are committed now; Immix capacity 483 MB of 31812 MB, LOS 16 MB of 256 MB). Raise DOTNET_LXRNativePlaneLimitMB` | 1 |
| `LXRManagedHeapHardLimitMB=300` | the Immix reserve message (the reserve 128 MB is reached before the hard limit of 300 MB); the "hard limit" and "operating system did not commit" and "threads" messages were **not** triggered in a test **[N]** | 1 |

Windows: the Immix message was seen once (`windows-wf-4-r128.log`). A run with a printed message ends with the unhandled `OutOfMemoryException` as before.

Known limits of the message: the values are read without a lock and can be a little old. The flag "native plane limit refused" is not cleared; it could name the native limit if a later OS commit failure follows an earlier refusal that was served with a smaller size (rare) **[N]**.

## 7. What changed

Code commit (`src/coreclr/gc_lxr` and the P4 test):

* `lxr_default_limits.h` (new): default reserve and native limit functions.
* `lxr_heap_sizing.h`: `PolicyReserveBytes`, `LiveReserveFactor`.
* `lxr_gc.cpp`, `lxr_gc.h`: default rule in `Initialize`, `PolicyReserveBytes`, `ReportOutOfMemory`, lazy card tables, `CanAdmitRange` records a refusal.
* `lxr_reference_counting.cpp`, `.h`: `SetBorrowCeiling`, used in `BorrowSuspended`.
* `docs/design/lxr-port/P4/lxr-rc-validation.cpp`: 13 new checks in `ValidateHeapSizer` (selector `--p8-policy`, 88/88 pass): default reserve for 64 GB, 2 GB container, small and unknown limit, huge machine, address limit; native limit; policy reserve for 0, 48 MB, 100 MB, 2 GB, small reservation, overflow; the target of a small live size and of 2 GB live size.

Documentation commit: this README, scripts, data, logs, and `docs/design/lxr-port/P29-heap-sizing/heap-sizing.md` (default settings table and limits).

## 8. Validation (what was run)

Linux x64 (WSL2), final tree, no timed run overlapped the validation:

* Native suites P2.1 to P2.5, P3.1 to P3.4, P4 with all selectors, both variants (`validate-variant.sh default` and `bitmap`): all pass, except **`--mature-released-candidate`: 65/67** in both variants (the known flaky selector of the recipe; I did not run it on the old build, so **[N]** whether it also fails there). The line `FAIL: injected zero-RC old target rejected before overwrite` appears in the `--p8-storage` output with rc=0 and 1441/1441 (1449/1449 bitmap) pass; it is printed by a control in the test (`lxr-rc-validation.cpp` line 2949) and is not from this change **[N]** (not checked on the old build). `logs/linux-validate-dl.log`. This run used the libraries built before the last edit (the text of one message, and one bool for it).
* PrivateTests `all 2 13` x20 per library, both variants, on the final libraries: 0 failures of 20 in each; no LXR fatal, no OutOfMemoryException (`logs/linux-validate-dl2.log`).
* Checksums of the six standard workloads, both variants, with no setting and with the standard settings (mediumarrays: `InitialMB=200 ReserveMB=400`): all 24 right. `losmany` with explicit settings and with the native limit at the default: 42674603309 in both.
* The product build is the Linux `clrlxrgc` and `clrlxrgc_bitmap` (clang-14, Release) of this tree and the Windows `clrlxrgc` (MSVC, Release) of this tree. A full product build of the runtime was not repeated on Linux; on Windows `clr.runtime` was built once from this tree before the last edits and `clrlxrgc` was rebuilt after each edit.
* Native programs P2.x, P3.x and P4 construct engines and sizers with explicit sizes. They do not use `LxrGcHeap::Initialize`, so the default rule does not change what they test. P4 `--p8-policy` has the new checks.

## 9. Not verified

* Windows: the native suites (P4 needs local patches on Windows, see `lxr-7e4d-windows.md`) and PrivateTests were not run. The startup working set on Windows was not measured. A job-object memory limit was not tested.
* The LOS reserve default stayed at 256 MB in the first two commits. It is raised in the third commit (section 11).
* Intervals are from 10 pairs. The wall time of listsuffix at the new default is +42 ms in the first set (interval [+0.2, +86]) and not significant in the second; I did not run more pairs.
* The reason for the two time modes of the full GCPerfSim run, and for the difference to the 98 s and 101 s of the investigation report.
* A host that restricts address space (`ulimit -v`): no retry with a smaller reserve exists.
* The "hard limit", "operating system did not commit" and "threads" message variants were not triggered in a test; the code is reviewed only.
* `LXRManagedHeapHardLimitMB` together with the default reserves: only the 300 MB case was run (section 11 has the rule for hard limits above 384 MB, tested only in the native P4 checks) **[N]**.
* A machine with more than 256 GB of memory gets the cap of 256 GiB; not tested.

## 10. Files

* `scripts/`: `dl-run.py` (one block of the A/B), `dl-table.py` (paired tables), `ab.sh`, `ab2.sh`, `exp1.sh` (dependence experiment), `rss.sh`, `pt.sh` (policy trace), `gps.sh`, `gps-seq.sh`, `msg.sh`, `quick.sh`, `cg.sh` (cgroup), `validate-dl.sh`, `validate-dl2.sh`, `win-rebuild.cmd`, `run-win.cmd`, `win-seq.ps1`, `env-*.cmd`. The `.sh` files need LF line ends. They use paths of this machine (`/root/dl`, `/root/prof/frame-c4`, `C:\lx-run`).
* `data/`: `ab-runs.jsonl` (default, 10 reps x 6 workloads x 3 configs), `ab-asrun-runs.jsonl`, `ab2-runs.jsonl`, `tables.md`.
* `logs/`: raw outputs named in the text.

## 11. The LOS reserve default (third commit)

The user decided to raise the LOS reserve default in the same way as the Immix reserve. This section is the current rule.

### 11.1 The rule

(`LxrDefaultLimits::ReservesMB` in `lxr_default_limits.h`, called from `LxrGcHeap::Initialize`; pure function, 14 new checks in P4 `--p8-policy` (they replace 5 checks of the Immix-only rule), 97/97 pass.)

* No hard limit: each space that has no setting gets a reserve equal to the memory limit of the process (`GCToOSInterface::GetPhysicalMemoryLimit()`, which includes cgroup and job-object limits): Immix 128 MB to 256 GiB, LOS 256 MB to 256 GiB. The two reserves together can be up to twice the memory limit. Each space can use all the memory (a program with only small objects, or only large objects), and the reserve is address space. The operating system enforces the memory limit. A reserve that has a setting is taken as it is; the other one is made to fit the address limit of the host (`SetReservedVMLimit`, or the 47-bit side-metadata space).
* `LXRManagedHeapHardLimitMB` above 384 MB: the reservation is made equal to it (so that the to-space borrowing of the engine stays on, as in section 3). Both defaults: LOS = max(256, half of it), Immix = the rest. One default: it gets the rest after the explicit one. A hard limit up to 384 MB keeps the old reserves (128 and 256).
* `LXRLOSInitialMB` above the default LOS reserve raises the reserve to it. `LXRLegacyCapacity` keeps its meaning (reserve = initial).
* Native plane limit: 4.5 x (Immix reserve + LOS reserve), at least 4096 MB, unless set. It is a cap on the committed side metadata. It does not make the committed planes larger.
* `GCHeapHardLimit*` is not supported by LXR (E_NOTIMPL), so there is nothing to respect there; the container and job limits are in `GetPhysicalMemoryLimit()`.

### 11.2 Policy and other uses of the reserves (code read)

* The LOS reserve is used by the engine only as a growth ceiling (`RequestGrowth`, `GrowSuspended`, `FitAdmission` through the native limit) and for the size of the tables: `LxrLargeObjectSpace::Initialize` (free-page tree and page map, `calloc`, zero pages), the dead-large-object list (`m_dead_large`, one entry per page of the reservation). No sizing or trigger rule reads it. The LOS grows by doubling from its admitted size, as before. **The policy needs no decoupling for the LOS.**
* Two things did depend on the sum of the reserves, and were changed so that the default behaves as before: (a) `LXRNurseryRatio` took a share of `m_hard_limit` (the sum); with default reserves it now takes the old sum (128 + 256 MB), as in the old build; (b) `PublishMemoryInfo` reports `min(hard limit, physical memory limit)` as the available memory (the sum of two reserves would be twice the memory).
* `m_dead_large` was a zeroing `new[]`: 8 bytes for each 4 KB page of the reservation, which is 64 MB touched at start-up for a 32 GB reserve. It is now `calloc`/`free` (zero pages, taken on first write). The LOS free tree and page map were already `calloc`.

### 11.3 Results (Linux, same method as section 4: old, prev, new in one lock grant, shuffled, 10 pairs; `data/tables.md`, raw runs in `data/ab3-*.jsonl`, `data/ab4-runs.jsonl`)

`old` = 7e4d693af24, `prev` = bee59a41835 (Immix reserve default only), `new` = the third commit. No setting.

**Check 1: more than 256 MB of live large objects, no setting.** `losmany 2000 60000` (about 1.3 GB of large arrays; today it needs `LOSInitialMB=1000 LOSReserveMB=1600 NativePlaneLimitMB=16000`): old fails 10 of 10 (`OutOfMemoryException`), prev fails 10 of 10 (`LXRLOSReserveMB=256 MB (256 MB used; the request is 719208 bytes)`), **new passes 10 of 10** with the right checksum 42674603309: median 1137 ms wall, 2818 ms CPU, 67 collections, 222.8 ms pause, 184 MB peak RSS. Bigger tables pass too (one run each): 8000 entries 1.8 s, 562 MB RSS; 30000 entries 4.4 s, 2.05 GB RSS. On Windows (MSVC, same VM): old fails, **new passes** `losmany 2000 60000` with the right checksum in 9.6 s (1.18 GB peak RSS), and 8000 entries in 11.7 s (the checksum for 8000 is the same as on Linux: 42442525409). The Windows losmany driver is the Linux one with the Windows timer (`C:\lx-run\dl\drvlm`) **[N]** not compared with the Windows numbers of the earlier README (different driver build).

**Check 2: programs that fit in the old limits** (medians; "new - old" is the paired median difference with its 95% bootstrap interval):

| workload | metric | old | prev | new | new - old |
|---|---|---|---|---|---|
| requests | collections | 9 | 9 | 9 | 0 [0, 0] |
| requests | wall ms | 382.4 | 387.8 | 385.5 | -3.3 [-21.6, +13.2] |
| requests | pause ms | 29.6 | 29.7 | 29.2 | -0.6 [-8.4, +0.6] |
| requests | peak RSS MB | 170.2 | 174.1 | 173.6 | +3.5 [+3.0, +3.8] |
| losarrays | collections | 49 | 49 | 49 | 0 [0, 0] |
| losarrays | wall ms | 1180.2 | 1185.4 | 1199.2 | +5.6 [-0.2, +34.1] |
| losarrays | CPU ms | 2522.6 | 2503.2 | 2580.7 | **+71.7 [+27.7, +125.8]** |
| losarrays | pause ms | 479.7 | 460.3 | 474.8 | -1.8 [-10.6, +10.3] |
| losarrays | peak RSS MB | 105.3 | 109.1 | 108.6 | +3.5 [+3.1, +3.6] |
| mediumarrays | result | fails 10/10 | passes (255 MB RSS, 97.5 collections) | passes (97.5 collections, 1322 ms) | |

With the standard explicit settings (mediumarrays `200/400`; losmany `LOSInitialMB=1000 LOSReserveMB=1600 NativePlaneLimitMB=16000`), old and new are the same within the intervals: mediumarrays wall 1002.8 / 1006.1 ms, 14 / 14 collections, RSS 482.2 / 481.4 MB; losmany wall 1125.5 / 1184.5 ms (+65.8 [-73.4, +143.7]), 73 / 73 collections, RSS 180.9 / 181.0 MB.

* **Collection counts are equal in every pair** for requests and losarrays (and mediumarrays new = prev), and the pauses are equal within the intervals.
* **Found: losarrays uses about 2.6% more CPU with the large LOS reserve** (+71.7 ms [+27.7, +125.8] in this set; +66.9 [+10.6, +89.7] in a second set of 15 pairs, `data/ab4-runs.jsonl`). Its wall time is not significantly different (+5.6 [-0.2, +34.1] and +11.1 [-7.9, +13.0]), and the pause is the same. With `LXRLOSReserveMB=256` set explicitly the new library has no difference to old (-13.5 [-58.2, +22.4]), so the cause is the size of the LOS reserve. Cause **[N]** (not profiled): a likely one is the depth of the free-page tree of the LOS (`m_free_tree`, a segment tree over the reservation: 16 levels at 256 MB, 23 levels at 32 GB) in each large allocation. I did not change the tree. A program that wants the old cost sets `LXRLOSReserveMB`.
* **Start-up working set** (`logs/linux-los-startup-rss.txt`, one run each): old 153.1 MB, prev 156.9 MB, new 156.6 MB. The LOS default adds nothing measurable (the `m_dead_large` table is lazy).

**Check 3: the message names the LOS limit.** With `DOTNET_LXRLOSReserveMB=64` (losarrays): `LXR: out of memory. The large-object space is full at its reserve: 64 MB used of LXRLOSReserveMB=64 MB (the request is 65328 bytes). Raise DOTNET_LXRLOSReserveMB (decimal MB; also DOTNET_LXRNativePlaneLimitMB if you set it).` One line. Under a cgroup limit of 700 MB with the default reserve (`scripts/cg2.sh`, losmany 20000): `... 700 MB used of LXRLOSReserveMB=700 MB (default: the memory limit of the process) (the request is 920488 bytes). ...`, one line, then the `OutOfMemoryException`. With the default reserve at 32068 MB the native plane message of the earlier test reads `Immix capacity 483 MB of 32068 MB, LOS 16 MB of 32068 MB`. The "(default: derived from LXRManagedHeapHardLimitMB)" text appears only when the hard limit is above 384 MB (in the first build it was also printed for the 300 MB hard limit, which keeps the old reserves; fixed before this commit).

**Jan's command with the third-commit libraries, no setting.** Linux: `-tagb 4` passes (4 s); `-tagb 540` passes in 181 s (the earlier run of the Immix-only build: 155 s; the lock was held by nothing else, the machine state differs, **[N]** not investigated). Windows: `-tagb 4` passes; `-tagb 4` with `LXRImmixReserveMB=128` fails with the one-line message (`logs/windows-los-wg-*.log`). The full 540 run was not repeated on Windows **[N]**.

### 11.4 Validation (Linux, final libraries of this commit)

* Native suites P2.1 to P2.5, P3.1 to P3.4, P4 with all selectors, both variants: all pass, including `--mature-released-candidate` (it did not fail in this run: it is the known flaky selector), `--p8-policy` 97/97. The output line `FAIL: injected zero-RC old target rejected before overwrite` is printed by a deliberate negative control of `--p8-storage` (the test expects the engine to reject the write and prints this text; the selector exits with 0) **[N]** I read the code around `lxr-rc-validation.cpp:2976`, I did not run the old build to compare. `logs/linux-los-validate-dl3.log`.
* PrivateTests `all 2 13` x20 per library, both variants: 0 failures; no LXR fatal, no OutOfMemoryException.
* Checksums of the six standard workloads, both variants, with no setting and with the standard settings: all 24 right. `losmany`: right with explicit settings, with only the native limit at its default, and with **no setting** (both variants).
* Builds: Linux `clrlxrgc` and `clrlxrgc_bitmap` (clang-14, Release) and Windows `clrlxrgc` (MSVC, Release). Windows native suites and PrivateTests were **not** run **[N]** (the Windows session is to do this).

### 11.5 Not verified

* The cause of the +2.6% CPU of losarrays (above). The effect on workloads with many more large allocations than losarrays **[N]**.
* A host that limits address space (`ulimit -v`) with the two reserves (up to twice the memory): no retry exists. The Windows test of section 5.3 reserved 146 GB and 1 TB; two default reserves of 64 GB each were not run on Windows as defaults, only one explicit Immix reserve **[N]**.
* The hard-limit rule for limits above 384 MB: only the pure function is tested (P4); no run with `LXRManagedHeapHardLimitMB` above 384 MB **[N]**.
* Windows: start-up working set, job-object limit, native suites, PrivateTests, full 540 run.