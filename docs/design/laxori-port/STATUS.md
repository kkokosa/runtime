# Laxori: status after L2

Laxori is our Satori + LXR: every thread allocates into its own private region and collects it alone; the shared heap is the LXR
engine. Design: `DESIGN-v2.md`. Everything below was built and run in this worktree on WSL2 Ubuntu 22.04 (16 CPUs) against the
benchmark frame `/root/prof/frame-c4` (the merged LXR of `lxr-gc-review` 3db3b488e29, R2R with `CrossgenOldValueWriteBarriers=true`).
Nothing is pushed. Laxori is **off by default**: the CMake option `CLR_CMAKE_ENABLE_LAXORI_GC` is OFF, and the library runs only
with `DOTNET_GCPath`.

## Summary (honest)

| Item | State |
|---|---|
| L0 engine re-sync (LOS rewrite, medium allocator, zeroing) | Done. The 10 native engine programs pass (section 2). With `DOTNET_LAXORIPrivate=0` Laxori equals LXR within noise on all six workloads. |
| L1 automatic private regions, per-object escape, thread-local GC (regions with no escapes) | Done, stable in the tests and in 126 hunt runs. |
| L2 escaped objects stay in place, regions with escapes are reused, escape limit | Done, **default**, stable in the tests and in 126 hunt runs. `DOTNET_LAXORIEscapedInPlace=0` gives L1. |
| Speed | **No wall-time gain.** CPU and pauses fall on `requests` and `binarytrees`; `listsuffix` is 25 to 29 percent slower; the other workloads are equal to LXR. |
| Cycle recovery by trial deletion (item i of the description) | **Not implemented.** The shared heap uses the LXR trace (inherited). |

## Update: thread-local GC cost diagnosis and fix (see `results/TLGC-DIAGNOSIS.md`)

The comparison with Satori found one real cost defect: the thread-local mark walked every object of the region (dead ones too) to find
sync blocks (41 to 86 percent of a collection). Fixed by escaping at sync-block creation through `pre_store`. After the fix (9 interleaved runs,
`results/tlgc/bench-after-fix.txt`) wall / CPU ms: `requests` Laxori 323 / 415 against LXR 382 / 529 (-15 percent wall), `binarytrees` 1128 / 2697 (2 MiB regions
1072) against 1127 / 3266, `listsuffix` 1616 against 1331 (still +21 percent), the others equal to LXR. Hunts with the fixed build: L1 126 of 126, L2 126 of 126.
**New known issue (inherited):** the stock LXR engine fails `PrivateTests all 2 13` in 10 of 20 runs (`space-pressure collection failed`, engine failure 1);
Laxori fails it in about 1 of 6 runs with the private tier on and in 5 of 20 with it off. The numbers in sections 3 and 5 below are from before the fix.

## 1. Build and run

```
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
bash src/coreclr/build-runtime.sh -release -x64 -ninja -component clrlaxorigc -subdir <name> -numproc 4 \
     -cmakeargs "-DCLR_CMAKE_ENABLE_LAXORI_GC=ON"
DOTNET_gcServer=1 DOTNET_GCPath=<so> corerun ...
```

The output is `artifacts/obj/coreclr/linux.x64.Release/<name>/gc_laxori/libclrlaxorigc.so`. `gc_lxr` and `gc_satori` are not
changed. Keys: the LXR keys with the prefix `LAXORI` (for example `DOTNET_LAXORIGCThreads`), plus `LAXORIPrivate` (default 1),
`LAXORIRegionKB` (default 256, a power of two from 32 to 4096), `LAXORIEscapedInPlace` (default 1), `LAXORIEscapedCollectDiv`
(default 16), and the debug switches `DOTNET_LAXORIVerifyPrivate=1` (region verifier) and `DOTNET_LAXORITestControl=1..5` (mutation
checks; test only). `mediumarrays` needs `DOTNET_LAXORIImmixInitialMB=200 DOTNET_LAXORIImmixReserveMB=400`, as it does for LXR (OOM
otherwise; inherited).

In an incremental build, a configure on the Windows file system failed twice with a spurious "Permission denied" in CMake's
`CMakeScratch`; building with `ninja` in an already configured directory (`scripts/ninja-laxori.sh`, `scripts/cyc.sh`) avoids it.

## 2. Tests that were run (final build, commit after `3465502`)

| Test | Result |
|---|---|
| Native engine programs (`run-native-all.sh`: P2.1 to P2.5, P3.1 to P3.4, P4), copies of the LXR validation of 3db3b488e29 | 10 of 10 PASS (P3.1 641/641, P3.2 395/395, P3.3 357/357, P3.4 70/70, P4 105380/105380). |
| Native barrier test (`BarrierTest/`): the v2 assembly barrier copied to an executable page, fake heap, owner table, private bitmap, unlog bits. Private store, exposed slot, escape, escape then log then store, other region, shared source, foreign owner, null, non-heap, checked helper, dissolve, xmm state | 19 of 19 checks PASS |
| Managed `PrivateTests` (10 tests: stack roots, interior pointers and `fixed`/`Span`, deep and big graphs, escape into statics, arrays, dictionaries, bulk copies and struct copies, handles (strong, weak, pinned, dependent, `ConditionalWeakTable`), finalizers, `GC.Collect` inside, sync blocks, hand-off between threads and thread exit) | PASS at 1, 2, 4, 8 and 13 threads with the verifier on, in L1 and L2 mode; also scale 6 at 8 threads and scale 4 at 13 threads. |
| Mutation checks (`DOTNET_LAXORITestControl`): 1 skip the update of the stack roots, 2 skip the update of object references, 3 skip the children in an escape, 4 skip the clearing of a gap | all four make the managed tests fail (segfault or abort); the unmodified build passes. Control 5 (skip the sync-block walk) is a cost measurement, not a check. |
| Crash hunt L1 (`results/hunt-L1.txt`): 126 runs, 7 for each of 6 jobs (5 scaled workloads + `PrivateTests`) x 3 worker settings (default 13/3, 4/2, 1/1), checksums against a WKS run of the same size | 126 OK, 0 failures |
| Crash hunt L2 (`results/hunt-L2.txt`), same matrix, default settings | 126 OK, 0 failures |
| Full-size benchmark runs (section 3): 378 runs | 378 OK, all checksums equal |

The hunts used scaled-down workload sizes and ran with `nice -n 19` **without** the benchmark lock (the lock was held for hours by
other sessions earlier); the two hunts ran at the same time. The benchmark, the profiles and the pause statistics ran under
`flock /tmp/lxr-bench.lock`.

**What the tests found** (the bugs of this work, all fixed):

1. The private bitmap was cleared for 1/8 of the region (`>> 9` words against bytes). Found by the first run.
2. **Objects crossed the 32 KiB blocks of a multi-block region.** The Immix engine promotes and sweeps by the block of the start
   of an object, so a pause released the tail block of a live object. It showed only above 32 KiB regions and at 4 and more
   threads (null method tables and non-pointer values in reference fields found at a pause). The fix changed the layout (block
   rule, gap list, one span for each stretch of live objects, see `DESIGN-v2.md` section 6). Verified with the 8-thread graph test
   (about 100 percent failures before, 0 of 20 after) and the region verifier.
3. **Sync blocks.** The sync-block table of the runtime holds raw pointers that only a pause updates; a thread-local collection that
   reclaimed or moved an object with a sync block left a stale entry (found by the `sync` test in L2). First fix: a walk of the
   whole region at every collection; **that walk was a cost defect** (see the update below) and is replaced by escaping the object when
   its sync block is created (`pre_store`, as Satori does).
4. When a region could not be taken, every allocation went through the slow shared path (millions of failed acquisitions, 3 to 4
   times slower on `listsuffix` and `mixedmedium`). Fixed with the fast buffer of the engine and a back-off.

## 3. Benchmark (9 interleaved runs, medians; `results/bench-final.txt`)

Wall ms / CPU ms / pause ms / peak RSS MB. All checksums equal the expected ones (requests 27134172608, binarytrees 68332294,
listsuffix 159636632672, mixedmedium 40586599707, losarrays 13936826922, mediumarrays 7032863679). `lxr` is `libclrlxrgc.so` of the
frame. `Laxori off` is Laxori with `LAXORIPrivate=0` (the LXR engine of the copy); `L1` and `L2` have the private tier on.

| workload | WKS | SVR | LXR | Satori | Laxori off | Laxori L1 | Laxori L2 |
|---|---|---|---|---|---|---|---|
| requests | 315 / 313 / 65 / 67 | 552 / 868 / 260 / 100 | 356 / 496 / 29 / 172 | 570 / 644 / 18 / 94 | 361 / 502 / 29 / 172 | 366 / 509 / 30 / 174 | 364 / **453** / **9** / 167 |
| binarytrees | 1033 / 1039 / 304 / 121 | 1407 / 2152 / 623 / 177 | 1127 / 3616 / 172 / 210 | 982 / 1648 / 61 / 164 | 1129 / 3383 / 142 / 208 | 1175 / **2107** / **70** / 194 | 1201 / **2572** / **85** / 205 |
| listsuffix | 2043 / 2131 / 1166 / 100 | 983 / 2514 / 323 / 165 | 1166 / 3684 / 181 / 201 | 800 / 1995 / 90 / 228 | 1221 / 3826 / 190 / 202 | 1504 / 5005 / 216 / 204 | 1450 / 5057 / 216 / 204 |
| mixedmedium | 1003 / 1014 / 427 / 183 | 1140 / 1918 / 314 / 497 | 1376 / 2417 / 187 / 195 | 688 / 1426 / 119 / 368 | 1385 / 2419 / 188 / 195 | 1381 / 2384 / 186 / 197 | 1376 / 2384 / 188 / 197 |
| losarrays | 1914 / 2003 / 1155 / 317 | 2742 / 5707 / 1340 / 512 | 1157 / 2452 / 464 / 110 | 740 / 1318 / 98 / 504 | 1175 / 2513 / 477 / 110 | 1173 / 2493 / 476 / 111 | 1201 / 2531 / 464 / 110 |
| mediumarrays | 1219 / 1218 / 522 / 232 | 1110 / 2032 / 322 / 510 | 980 / 1735 / 85 / 489 | 649 / 1533 / 154 / 526 | 958 / 1706 / 86 / 489 | 1004 / 1727 / 91 / 491 | 1018 / 1756 / 93 / 492 |

Private-tier counters of L2 (median of the 9 runs): thread-local collections `requests` 3041, `binarytrees` 5075, the others 0;
escaped MB `requests` 15, `binarytrees` 27, `listsuffix` 43, `mixedmedium` 10, `mediumarrays` 331; MB that the pauses copied
(survivors that reached an LXR pause): `requests` 7.2 (LXR 12.4), `binarytrees` 57.1 for L2 and 39.0 for L1 (LXR 45.5), `listsuffix` 41.6 (LXR
39.4); collections `requests` 25 (LXR 98), `binarytrees` 41 (LXR 103). `acquireFailures` (a region was not available): 2 to 10
on `requests` and `binarytrees`, about 320 on `listsuffix`, about 1000 on `mixedmedium`.

**What the numbers say:**

* **Wall time is not better than LXR on any workload.** `requests` and `binarytrees` use less CPU (-9 percent and -29 to -42 percent) and
  have fewer collections and shorter total pause time, but the work that was saved ran on parallel GC workers, while the thread-local
  collections run on the program thread. The program thread of `binarytrees` spends 233 ms in thread-local GC; the workers spend 1172 ms against 2459 ms of LXR (profile below).
* **`binarytrees`: L1 is better than L2** (CPU 2107 against 2572 ms). L2 collects regions with some escapes and rescans their
  escaped objects each time.
* **`listsuffix` is the loss that was predicted.** Everything escapes into the shared array. The slow path of the barrier is
  twice as costly (170 against 86 ms of the program thread), the escape tracking costs 29 ms, and the workers run 570 ms longer.
* `mixedmedium`, `losarrays`, `mediumarrays`: equal to LXR within noise (the objects bypass the region or escape at once).
  `mediumarrays` copies more at pauses (425 against 275 MB), with equal time.
* Satori is faster than all of them on `mixedmedium`, `losarrays`, `mediumarrays` and `listsuffix`; this was not changed by Laxori.

### Region size (L2, 5 runs, `results/region-size.txt`)

32 KiB is clearly worse (`requests` 629 ms and 17463 thread-local collections, against 376 ms and 3040 at 256 KiB; `binarytrees` 1481
against 1238 ms). 128, 256, 512 and 2048 KiB are close (`requests` 402, 376, 365, 377 ms; `binarytrees` 1229, 1238, 1215, 1212 ms).
The default stays 256 KiB.

### Perf profile of the program thread (cpu-clock, 4000 Hz, `results/profile-summary.txt`)

| workload | collector | program thread | other threads | main parts of the program thread |
|---|---|---|---|---|
| requests | LXR | 399 ms | 110 ms | managed 175, memset 84, allocation 66, kernel 22 |
| requests | Laxori L2 | 413 ms | 44 ms | managed 172, **thread-local GC 106** (`LocalMark` 69), memset 28, allocation 32 |
| binarytrees | LXR | 1123 ms | 2459 ms | managed 409, allocation 261, memset 193 |
| binarytrees | Laxori L2 | 1226 ms | 1172 ms | managed 434, **thread-local GC 233** (`LocalMark` 211), allocation 223, memset 89 |
| listsuffix | LXR | 1303 ms | 3317 ms | managed 884, GC work 159, allocation 135 |
| listsuffix | Laxori L2 | 1484 ms | 3912 ms | managed 975, allocation 175, GC work 153, **write barrier 170 (LXR 86)**, escape 29 |

### Pause statistics (3 runs, GC suspend and restart events of the runtime, `results/pause-stats.txt`)

Pauses per run / p50 / p99 / max in ms:

| workload | LXR | Satori | Laxori L1 | Laxori L2 |
|---|---|---|---|---|
| requests | 9.3 / 3.6 / 6.1 / 6.1 | 16 / 0.5 / 8.0 / 8.0 | 9.0 / 3.4 / 5.0 / 5.0 | 2.0 / 5.4 / 8.2 / 8.2 |
| binarytrees | 30 / 1.9 / 30.1 / 30.1 | 119 / 0.5 / 2.3 / 4.3 | 9.3 / 6.1 / 20.8 / 20.8 | 10 / 6.6 / 24.7 / 24.7 |
| listsuffix | 6.7 / 29.2 / 34.1 / 34.1 | 34 / 1.7 / 30.9 / 37.6 | 8 / 30.0 / 32.9 / 32.9 | 8 / 28.2 / 41.7 / 41.7 |
| mixedmedium | 225 / 0.9 / 4.1 / 11.1 | 68 / 0.5 / 16.4 / 43.0 | 226 / 0.9 / 3.7 / 9.7 | 228 / 0.9 / 3.2 / 10.0 |
| losarrays | 49 / 9.7 / 13.7 / 16.1 | 149 / 0.3 / 3.3 / 3.8 | 49 / 9.7 / 34.2 / 66.0 | 49 / 9.4 / 13.4 / 13.7 |
| mediumarrays | 14 / 4.5 / 21.3 / 21.3 | 75 / 0.5 / 31.6 / 83.2 | 16 / 4.9 / 19.4 / 19.4 | 16 / 5.0 / 15.5 / 15.5 |

(With 3 runs the p99 and the max are the worst pauses of the runs; `losarrays` L1 has one 66 ms pause.) A thread-local
collection is not in this table: it stops only its own thread. From the profile it costs about 35 to 45 us on average (106 ms for
3041 collections of `requests`, 233 ms for 5075 of `binarytrees`); a single collection was not timed.

## 4. What the implementation does (as built)

* A thread takes a region of 256 KiB (8 aligned Immix blocks, `AcquireRun`) on its first allocation of a size up to
  `min(8 KiB, R/8)` that is not finalizable, pinned or large. The owner table (8 bytes for each block) holds the thread tag.
* The write barrier (`amd64/laxori_writebarrier.S`) tests the owner of the source, the same-region and the exposed bit. A store of a
  private reference into a place that is not private (or into an exposed slot) calls the escape routine: the target and the
  objects that it reaches in the region get the Escaped bit, their slots get the exposed bit. `pre_store`, bulk copies, GC handles
  and `ReRegisterForFinalize` escape too.
* A full region is collected by its thread: mark from the stack (`GcScanCurrentStackRoots`) and the escaped objects, plan, update,
  compact. Objects that are escaped, pinned or have a sync block stay. Survivors above region/8, or a gain below region/4, skip the
  collection (the region goes to the shared heap and the thread skips the next 1, 3, 7, 15 regions). Above `escaped > region/4`
  the region is dissolved. A region with escapes is collected only when the escaped bytes are at most 1/16 of the region.
* An LXR pause dissolves all regions: the owner entries are cleared and the engine gets one span for each stretch of live objects.
* The shared heap is the LXR engine of `gc_laxori` (a renamed copy; no new reclamation mechanism).

## 5. Not verified / known gaps

* **No speed-up in wall time**, and a 25 to 29 percent loss on `listsuffix`. The program thread pays for the thread-local
  collection (`LocalMark` rescans the escaped objects of the region every time; a block-level retirement of escape-heavy blocks is
  not done).
* Trial deletion for cycles is **not implemented** (item i). Cyclic data of the shared heap is reclaimed by the LXR trace.
* Native tables of the runtime that keep raw object pointers: the sync-block table (fixed), the handle table and the finalizer
  registry (covered) were checked; other tables were not enumerated. A raw pointer outside these would be a stale pointer after a
  thread-local collection.
* No GC stress, no stress with the debugger, a profiler or the DAC; `DiagWalkHeap` is not tested with regions. Async code is covered
  only by the hand-off test (threads and a queue).
* `GC.GetTotalAllocatedBytes` and the per-thread allocation accounting were not compared with the runtime.
* The hunts used scaled-down sizes (126 runs per mode, run in parallel with each other and without the lock). The full-size
  benchmark matrix (378 runs) had no failure. Hunts of intermediate builds are not counted; the only failures found by tests are the
  four bugs in section 2.
* Region size differences above 128 KiB are inside the noise of this shared machine; the default was not tuned further.
* The barrier cost was not measured separately (a micro benchmark was not written); only the `listsuffix` profile shows it.
* The metadata of the shared tier is unchanged (the ValidObject bitmap); options are in `DESIGN-v2.md` section 9, not implemented.
* Linux x64 only (the barrier is assembly). Windows and ARM64 are not ported.
* Each thread holds a 256 KiB region (a program with 1000 threads holds 256 MiB of regions).

## 6. Files

* `src/coreclr/gc_laxori/`: the GC (`laxori_private.{h,cpp}` is the private tier; `amd64/laxori_writebarrier.S`, `laxori_write_barrier.*`
  the barrier; `laxori_immix_allocation.*` has `TryAcquireRun`; `laxori_reference_counting.*` has the region API).
* `docs/design/laxori-port/`: `DESIGN-v2.md`, this file, `BarrierTest/`, `PrivateTests/`, `P2.1..P4/` (native engine tests),
  `driver/` (benchmark driver with the region counters and `DRV_PAUSES=1`), `scripts/` (build, test, hunt, benchmark, pause,
  profile), `results/` (the tables above).
