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
| P31 count-plane object starts (port of LXR a3a225d40a9) | Done, **default**. Bitmap build kept as `libclrlaxorigc-bitmap.so`. See "Update: P31" below. |

## Update: thread-local GC cost diagnosis and fix (see `results/TLGC-DIAGNOSIS.md`)

The comparison with Satori found one real cost defect: the thread-local mark walked every object of the region (dead ones too) to find
sync blocks (41 to 86 percent of a collection). Fixed by escaping at sync-block creation through `pre_store`. After the fix (9 interleaved runs,
`results/tlgc/bench-after-fix.txt`) wall / CPU ms: `requests` Laxori 323 / 415 against LXR 382 / 529 (-15 percent wall), `binarytrees` 1128 / 2697 (2 MiB regions
1072) against 1127 / 3266, `listsuffix` 1616 against 1331 (still +21 percent), the others equal to LXR. Hunts with the fixed build: L1 126 of 126, L2 126 of 126.
**New known issue (inherited):** the stock LXR engine fails `PrivateTests all 2 13` in 10 of 20 runs (`space-pressure collection failed`, engine failure 1);
Laxori fails it in about 1 of 6 runs with the private tier on and in 5 of 20 with it off. The numbers in sections 3 and 5 below are from before the fix.

## Update: P31 count-plane object starts (port of LXR `lxr-gc-review` a3a225d40a9; results in `results/p31/`)

The engine now finds the start of a mature object from the COUNT plane, not from the ValidObject plane (macro `LAXORI_OBJECT_START_WALK`).
It is the **default** build. The old ValidObject build is the second library `libclrlaxorigc-bitmap.so` (CMake target `clrlaxorigc_bitmap`;
`CLR_CMAKE_LAXORI_OBJECT_START_BITMAP=ON` makes the bitmap build the default one, `CLR_CMAKE_LAXORI_BUILD_BITMAP_VARIANT=OFF` skips the
second library). `DOTNET_LAXORILookupStats=1` prints lookup counters per pause. The LXR P31 design is in
`docs/design/lxr-port/P31-object-start-walk/DESIGN.md` on `lxr-gc-review`.

How the three Laxori points were handled (reviewed in the code; no Laxori-specific code change was needed):
1. Private objects are not counted. The blocks of a region are fresh clean blocks (zero counts, straddle and unlog bits), so a count scan finds
   nothing there. Region lookups keep using the region owner structures and the private index. Outside a pause,
   `GetContainingObject` still returns null for a private address (same in both variants, as before).
2. A dissolved region becomes one young span per live stretch (`CloseRegionSpan` in `FlushMutators`) before roots are scanned. In
   `FindContainingObjectCore` the span walk runs before the count scan, so byref and pinned roots into a dissolved region are found.
   The young pinned span is closed with `ClosePinnedSpan`.
3. Escaped objects have no count and unlog bits 0. `FindInYoungSpans` never returns a free object. Laxori does not put free objects into regions any more.

What was run (final build, commit `0f91534`):

| Check | Result |
|---|---|
| 10 native engine programs (p2.1 to p2.5, p3.1 to p3.4, p4), count build and bitmap build | All pass (`native-validate-*.txt`). P4 has 105380 checks, `--object-start` 4279 of 4279 in both builds. The one `FAIL` line in each file is `--zero-rc-control`, which is expected to fail. |
| Digests of the cycle sweep and heap walk, count against bitmap | Equal (5 lines). |
| Mutation controls of the walk (`WalkNoContinuationSkip`, `WalkOneWord`, `WalkNoExtent`, `WalkNoPinnedSpan`, `WalkTrustedResolve`, `WalkEnumContinuation`, P2.4 `WalkWriteValid`) | All detected. |
| Native barrier test | ALL PASSED. |
| `InteriorStress` (managed byrefs, Span, fixed, across GCs), 8 threads x 2000 and 13 x 1500 | PASS on both builds, 0 failures. |
| `PrivateTests all 2` with verifier, 1/2/4/8/13 threads, L2 and L1, both builds | 1, 2, 4 and 8 threads: pass in all four cells. 13 threads: some runs fail with heap exhaustion (engine failure 1), see below. |
| Managed mutation controls 1, 2, 3, 4, 7 (count build) | All detected (abort or crash). `PrivateTests trace` passes. |
| Crash hunt (verifier on, 13/3, 4/2 and 1/1 workers, five workloads and PrivateTests) | 180 of 180 OK: L2 count 54, L2 bitmap 54, L1 count 36, L1 bitmap 36. This is smaller than the 126-run hunts of earlier milestones. |

**13 threads.** `PrivateTests all 2 13` fails with heap exhaustion in a share of the runs on every build, including LXR (inherited issue, see
the update above). 12 sequential runs each: Laxori L2 count 1 and bitmap 1, LXR count 2 and bitmap 4. In L1 mode the rate is high on both builds
(interleaved, 20 pairs: count 12, bitmap 11; an earlier sequential batch looked different, but it was load drift on the shared machine).
It is not a regression of the port. It is not fixed.

**Benchmark** (17 interleaved runs, six workloads, frame-c4, `flock /tmp/lxr-bench.lock`, all 408 checksums right, `results/p31/bench-p31.txt`,
`scripts/bench3.py`). The machine was shared and loaded (load average about 10), so single runs vary by tens of percent; the paired
differences are the evidence. LXR here is the P31 pair `/root/p31/so/libclrlxrgc-walk.so` (count) and `-base.so` (bitmap), not the frame's old `libclrlxrgc.so`.
Median of the paired difference (A-B)/B in percent, and in how many of 17 runs A was lower:

| Workload | Laxori count vs Laxori bitmap: wall / CPU | LXR count vs LXR bitmap: wall / CPU | Laxori count vs LXR count: wall / CPU / pause |
|---|---|---|---|
| binarytrees | -0.6 (9/17) / -1.3 (9/17) | -2.2 (9/17) / -7.8 (9/17) | +3.2 / +1.1 / -14.5 |
| requests | +0.2 (7/17) / -2.5 (10/17) | -0.8 (9/17) / -2.8 (10/17) | -12.2 / -19.5 / -67.1 |
| listsuffix | -0.9 (10/17) / -9.9 (15/17) | -0.4 (9/17) / -6.5 (13/17) | +17.0 / +31.8 / +25.1 |
| mixedmedium | -8.3 (15/17) / -6.9 (16/17) | -3.4 (10/17) / -4.8 (11/17) | +0.1 / +0.1 / -1.7 |
| losarrays | -3.7 (11/17) / -2.9 (12/17) | -3.2 (14/17) / -3.1 (14/17) | +0.5 / +2.2 / +0.2 |
| mediumarrays | -1.4 (9/17) / -2.1 (10/17) | -0.9 (9/17) / -1.9 (12/17) | +5.3 / +2.4 / +9.2 |

Reading: the count plane gives Laxori a small CPU gain, as it does for LXR (clear on `listsuffix`, `mixedmedium`, `losarrays`; the wall gain
is only clear on `mixedmedium`). Peak RSS is 1 to 3.5 percent lower. The per-run spread is large, so the wall difference on the other
workloads is within noise. The Laxori-against-LXR picture is unchanged by the port: `requests` gains, `listsuffix` loses 17 to 32 percent, the rest is level.
The measured gain of the port is smaller than the LXR report (-2.5 to -10 percent CPU) on `binarytrees` and `requests` (cause not measured; a
likely reason is that fewer objects reach the mature heap there, but this was not checked).

Cost of the span walk that replaces the bitmap for young objects (`results/p31/lookup-stats.txt`): `binarytrees` 50 span walks, 3.3 ms of
151 ms pause; the other three workloads under 1 percent of pause time. Laxori spans can be up to a region long, but the walks are rare.

Not verified for this port: Windows and ARM64; GC stress; the pinned-object and interior-root paths only through `InteriorStress` and the native
`--object-start` checks (no separate managed stress with pinned handles inside private regions); `GetContainingObject` for a private object
outside a pause (null, unchanged); the 126-run hunt size (180 runs were done in total, 36 to 54 per mode and variant); the P31 flaky selectors
`--mature-released-candidate` and `--p8-storage` were not run in a loop; the 13-thread heap exhaustion is not fixed.

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
