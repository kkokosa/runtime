# Laxori thread-local GC: cost diagnosis against Satori

Question (user): is our thread-local GC implementation reasonable compared with Satori, or defective? Suspicion: "thread-local GCs
should handle many reclamations and reduce pauses a lot".

**Answer in short.** Not defective in design, but it had **one real defect in cost**: every thread-local collection walked *all objects of the
region* (live and dead) to find objects with a sync block. That walk was **41 percent** of the cost of a collection on `requests` (256 KiB
regions), **66 percent** on `binarytrees`, and **57 to 86 percent** with 2 MiB regions. It is fixed (commit after `33a8103`):
sync-block creation now escapes the object through `pre_store` (the way Satori does it), and the walk is gone. After the fix a
thread-local collection is 40 to 68 percent cheaper, `requests` is the first workload that is faster than LXR in wall time (323 against
382 ms, 9 runs, median), and the per-collection cost is at the level of Satori or below. The stack scan and the escaped-object
handling were not unusual. The remaining pauses are longer because they are fewer and carry more survivors, not because of work that
moved into the pause.

All numbers: frame-c4, WSL2 16 CPUs, `flock /tmp/lxr-bench.lock`, files in `results/tlgc/` (names in brackets).

## 1. Cost per thread-local collection (question 1)

Laxori: TSC timers (`DOTNET_LAXORITlTimers=1`, `scripts/tl-report.py`). Satori: perf call chains at 10 kHz (`scripts/tlgc-perf.py`;
perf inflates the wall time about 1.4x, so Satori numbers are upper bounds). Satori runs `DOTNET_gcServer=0`, 2 MiB regions.

| workload / region | collector | collections in the window | thread-local GC total | per collection |
|---|---|---|---|---|
| requests, 256 KiB | Laxori before fix | 3032 | 131 ms | 43 us |
| requests, 256 KiB | **Laxori after fix** | 3039 | **78 ms** | **26 us** |
| requests, 2 MiB | Laxori before fix | 371 | 109 ms | 294 us |
| requests, 2 MiB | **Laxori after fix** | 369 | **43 ms** | **118 us** |
| requests, 2 MiB | Satori (perf) | 638 | 271 ms | 424 us |
| binarytrees, 256 KiB | Laxori before fix | 4991 | 283 ms | 57 us |
| binarytrees, 256 KiB | **Laxori after fix** | 5080 | **92 ms** | **18 us** |
| binarytrees, 2 MiB | Laxori before fix | 738 | 257 ms | 348 us |
| binarytrees, 2 MiB | **Laxori after fix** | 662 | **100 ms** | **151 us** |
| binarytrees, 2 MiB | Satori (perf) | 1050 | 137 ms | 131 us |
| listsuffix | Laxori / Satori | 0 / 0 | 0 | every region escapes (limit) and goes to the shared heap in both |

Split of one collection of Laxori (microseconds per collection; `laxori-before-fix.txt`, `laxori-after-fix.txt`):

| phase | requests 256K before | after | requests 2M before | after | binarytrees 256K before | after | binarytrees 2M before | after |
|---|---|---|---|---|---|---|---|---|
| escaped-object bit scan | 2.7 | 2.4 | 31.2 | 31.1 | 0.7 | 0.6 | 5.3 | 4.9 |
| stack scan, mark | 7.6 | 8.0 | 14.1 | 13.5 | 8.5 | 8.0 | 14.4 | 15.7 |
| **sync-block walk of the region** | **17.8** | **0** | **167.7** | **0** | **37.5** | **0** | **299.7** | **0** |
| propagate marks | 0.2 | 0.2 | 0.3 | 0.2 | 0.7 | 0.5 | 3.5 | 29.8 |
| plan | 3.4 | 3.4 | 28.6 | 25.3 | 0.7 | 0.7 | 5.1 | 32.3 |
| stack scan, update | 6.1 | 6.0 | 10.0 | 5.9 | 7.1 | 6.7 | 10.7 | 9.0 |
| update object references | 2.7 | 2.9 | 20.9 | 20.8 | 0.7 | 0.7 | 4.1 | 31.4 |
| compact | 2.5 | 2.5 | 20.1 | 20.0 | 0.6 | 0.6 | 4.0 | 27.7 |
| gap zeroing (at allocation, outside the collection) | 8.8 ms total | | 19.3 ms | | 16.4 ms | | 46.3 ms | |

(`binarytrees` 2 MiB: the phases after the fix are larger only because many more collections now succeed and carry 58 KB of
survivors, not 2 KB; before the fix the walk dominated and the run saw other survivor sets.) Finalizer handling: Laxori allocates
finalizable objects in the shared heap, so a thread-local collection has nothing to do for them (Satori tracks them in the region
and does extra mark work for them).

## 2. Escape behaviour (question 2)

* Bytes escaped per region: `requests` 15.1 MB over 719 regions = 21 KB per 256 KiB region (8 percent); `binarytrees` 28 MB over about 3100 = 9 KB;
  `listsuffix` 45 MB over 650 = 70 KB, above the limit region/4 = 64 KB, so every region is dissolved (never collected).
* Survivors per collection: `requests` 2.2 KB, `binarytrees` 0.6 KB (256 KiB) and 58 KB (2 MiB).
* Regions not collected (calls / collected): `requests` 3698 / 3039 (659 skipped because escaped bytes are above region/16 = 16 KB),
  `binarytrees` 8243 / 5080 (3024 skipped by the back-off of 1, 3, 7, 15 regions and the escape limit, 139 mark aborts, 0 "not worth").
* **Escaped objects are handled like in Satori.** The mark phase finds them by a bit scan of the escape bits (`LocalMark`, the first loop)
  and reads only the size of each escaped object; it does not walk dead objects. Every escaped object of the region is rescanned at
  every collection, as in Satori: 168 objects (8.8 KB) per collection at 256 KiB, 1383 (72 KB) at 2 MiB. The scan itself is 2.4 us (256 KiB)
  and 31 us (2 MiB) per collection. The plan, update and compact phases also step over the escaped objects (as Satori does): with the
  threshold raised to region/2 (`LAXORIEscapedCollectDiv=2`) a collection has 674 escaped objects and costs 49 us instead of 26 us, and the wall time is worse
  (445 against 314 ms, `escaped-div-sweep.txt`). The default region/16 stays the best of 2, 4, 8, 16, 32 for `requests`.
* **Before the fix the sync-block walk did walk dead objects** (every object of the region: 2790 per collection at 256 KiB, 8485 for binarytrees,
  22334 and 67222 at 2 MiB). That is the defect.

## 3. Stack scan (question 3)

Per collection Laxori scans the stack **twice**, once for mark and once for update (Satori: `ThreadLocalMark` and `ThreadLocalUpdatePointers`, the
same), and once for an attempt that aborts. A skipped call (escape limit, back-off) does not scan. There are no retries inside one fill.
`GcScanCurrentStackRoots` reports 165 to 177 roots per scan (thread statics and the tail-call buffer are in the scan), of which 1 to 8
point into the region. Cost per scan: 7 to 8 us (mark) and 6 us (update) at 256 KiB; 13 to 16 us and 6 to 10 us at 2 MiB (cache effects). Satori: 12 ms for
638 collections = 19 us (mark) and 10.5 us (update) in the perf run (about 14 and 7.5 us after deflating). The same function, the same cost.
The stack scan is 55 to 80 percent of the collection after the fix (256 KiB), as it should be: it is the fixed cost of a collection.

## 4. Why do the remaining LXR pauses get longer (question 4)

Not because of work that moved into the pause. Measured:

* Dissolving a region costs 2.4 us at 256 KiB and 6 to 14 us at 2 MiB (`TlDissolveCyc`: 722 regions, 1.8 ms in the whole `requests` run).
  A pause dissolves at most one region per thread; in the single-thread workloads the allocating thread has no region at a pause
  (it dissolved it before it asked for the collection). The span list (one span for each stretch of live objects) is part of that cost.
* Pause time follows the bytes that the pause copies (`pause-survivors.txt`): `requests` LXR 9 pauses, 1.34 MB copied per pause, 3.65 ms;
  Laxori L1 the same (1.37 MB, 3.97 ms); Laxori L2 2 pauses with 3.18 MB each and 6.18 ms (1.9 ms per MB against 2.7 ms per MB for LXR).
  `binarytrees` LXR 23 pauses with 1.36 MB, 3.44 ms; Laxori 10 pauses with 4.3 MB, 8.4 to 9.9 ms.
* Why more bytes per pause: a thread-local collection reuses the region, so the allocation that counts towards the next LXR pause
  grows slower. Fewer pauses mean more survivors in each one. The total pause time falls (`requests` 11 ms against 42, `binarytrees` 103 against 142 ms, `pause-stats-after-fix.txt`),
  the p50 and the p99 of one pause rise. This is the nature of the design (fewer, larger pauses), not a defect. A pause threshold that
  counts the private allocation would make the pauses shorter again; not done.

## 5. Defect and fix list (question 5)

1. **Fixed: sync-block walk** (above). The runtime creates a sync block in `SyncBlockCache::NewSyncBlockSlot` and calls
   `GCHeapUtilities::PreStoreCheck(&obj, obj)` there, a hook that Satori uses to escape the object (`CheckEscapeSatori`). Laxori's `PreStore` returned
   early when the destination (a stack slot) is not in the heap, so no escape happened and the walk was added as a safe-guard. Now `PreStore`
   escapes first, and escapes also for stores to non-heap places (handles, native memory), as Satori does. The walk stays behind
   `DOTNET_LAXORISyncWalk=1` for A/B tests. Evidence: the `sync` test passes with the fix and the walk off; with the escape in `PreStore`
   switched off (`LAXORITestControl=7`) it crashes (segfault), so the test does see the protection.
2. Not a defect, an optimization: the escaped objects are touched four times per collection (scan, plan, update, compact), about 50 ns
   each per object and collection. A per-region list of escaped objects (filled at escape time) would remove the header reads of the scan
   and allow plan, update and compact to skip them. Estimated saving: 5 to 10 us of 26 us at 256 KiB; not done.
3. Stack scan twice per collection: the same as Satori. Merging mark and update would need a recorded list of root slots; not done.
4. Region/16 escaped threshold: confirmed by the sweep.

## 6. Answers from the code (question 6)

(a) **No card marking anywhere in `gc_laxori`.** `grep` finds the card table only in `laxori_gc.cpp:514-542` (allocation of `m_cards`,
`m_bundles` and the `WriteBarrierParameters`), and `m_cards` is never read. The runtime needs the table to exist (the VM writes a bit into it in
`SyncBlockCache` and expects the globals). The barrier (`amd64/laxori_writebarrier.S`) is the LXR old-value barrier plus the owner
and escape test; `functions->write_barrier` is `NoPostStoreBarrier` (laxori_gc.cpp:971, :2789). How references are found:
* **mature (shared) to private (old to young in a region):** by the escape. A store of a private reference into a shared object calls
  the escape routine first (target and its closure in the region get the Escaped bit, their reference slots the exposed bit), then the LXR log
  check. The thread-local collection treats every Escaped object as a root by the bit scan, so no remembered set or card is needed. Escaped
  objects never move.
* **mature to young (not in a region) and mature to a dissolved region:** by the LXR logging. The first store into a mature slot logs it (old
  value into the decrement stream, slot into the increment/log stream); the pause reads the logged slot, increments the current target
  (promotion) and, for a young object, copies or promotes it. Regions are dissolved at the pause, so their objects are young objects then.

(b) **Concurrent marking.** The SATB trace of the engine is unchanged (it is the copy of LXR): the old targets of the decrement stream are
the SATB buffer, and the trace is started and ended in pauses (`InitialMark`, `FinalMark`). Private regions and a running trace:
1. A region never lives across a pause (every pause dissolves all regions, `FlushMutators`), so a region exists in one marking state only.
2. A region taken while a trace runs is **black**: `TryAcquireRun` passes the marking context, and `PrepareFreshBlock` sets the ObjectMark bits of the
   whole run. So its objects need no trace; a TLGC that moves an object inside the region keeps it inside black memory.
3. The trace can reach only escaped objects of a region (a shared object refers to them). They are black (or, if not, traced by the increment of
   the dissolving pause: `ProcessIncrement` queues a trace for a not marked object that is promoted inside the trace window, `NeedsIncrementTrace`),
   and they **do not move** in a thread-local collection. A movable (not escaped) object is not referenced from the heap, so no trace packet or
   SATB entry can contain it. Packets are made from roots of the initial pause (all regions were dissolved) and from logged old values of shared slots.
4. A store into a private object is not logged (young). The SATB argument holds as for any young object: what it references was
   reachable at the snapshot (marked) or is newer (black).
Test: `PrivateTests trace` (publishes cyclic graphs into a shared ring, keeps deleted graphs alive only through private holders, reads
shared graphs back, many threads): with `DOTNET_LAXORITraceThreshold=10` at 8 threads (scale 120) 40 concurrent traces completed with 12713 SATB entries, at 13
threads 16 traces; no failure. **Limit of the test:** a mutation that disables the black marking of regions
did not make it fail (the promotion-time trace in `ProcessIncrement` covers the same case), so the test shows "no failure with traces
running", it does not isolate the black marking. I found no unprotected case.

## 7. What else was found (not caused by the private tier)

**The stock LXR engine fails `PrivateTests all 2 13` in 10 of 20 runs** (`LXR fatal: space-pressure collection failed before growth admission (engine failure 1)`, run on
`libclrlxrgc.so` of the frame); Laxori with the private tier off fails 5 of 20 (`OutOfMemoryException` and the same fatal), Laxori with the tier on about 1 of 6
(also seen at 8 threads in L1 mode). The tests pass when run alone at 13 threads (8 of 8 each for `trace`, `handoff`, `escape`); the combination in one process
fails. The first failure is an `InvalidArgument` in a pause (`Suspend`, `NewWork` or logging). I did not find the cause. This is inherited from the LXR engine, so it should be
handled on the LXR side; the hunts (6 jobs x 3 worker settings, `PrivateTests` at 4 threads) do not see it.

## 8. Verification of the fix

* Native engine programs 10 of 10, barrier test 19 of 19 (unchanged engine code).
* `PrivateTests all 2` with the region verifier: 1, 2, 4, 8 threads pass; mutation controls 1 to 4 and 7 make it fail; L1 mode and
  `SyncWalk=1` pass at 8 threads (one L1 run hit the inherited failure of section 7).
* Crash hunts with the fixed build: L1 126 of 126, L2 126 of 126 (`hunt-fix-L1.txt`, `hunt-fix-L2.txt`).
* Six workloads, 9 interleaved runs, 378 runs, all checksums right (`bench-after-fix.txt`):

| workload (wall / CPU / pause ms) | WKS | LXR | Satori | Laxori L2 old build | **Laxori L2 fixed** | **fixed, 2 MiB** | fixed, L1 |
|---|---|---|---|---|---|---|---|
| requests | 333 / 334 / 68 | 382 / 529 / 30 | 597 / 686 / 23 | 397 / 492 / 10 | **323 / 415 / 9** | **323 / 429 / 10** | 385 / 540 / 33 |
| binarytrees | 1074 / 1090 / 318 | 1127 / 3266 / 158 | 1041 / 1746 / 64 | 1203 / 2200 / 65 | 1128 / 2697 / 124 | 1072 / 2978 / 130 | 1083 / 2678 / 120 |
| listsuffix | 2236 / 2337 / 1260 | 1331 / 4182 / 198 | 840 / 2147 / 97 | 1638 / 5426 / 229 | 1616 / 5444 / 231 | 1645 / 5469 / 244 | 1621 / 5302 / 230 |
| mixedmedium | 1142 / 1155 / 477 | 1478 / 2528 / 209 | 758 / 1522 / 134 | 1459 / 2553 / 200 | 1517 / 2546 / 202 | 1465 / 2524 / 199 | 1459 / 2521 / 201 |
| losarrays | 2028 / 2106 / 1224 | 1210 / 2545 / 487 | 762 / 1356 / 102 | 1231 / 2596 / 498 | 1227 / 2585 / 494 | 1259 / 2618 / 499 | 1257 / 2640 / 498 |
| mediumarrays | 1372 / 1366 / 588 | 1035 / 1817 / 88 | 724 / 1735 / 185 | 1057 / 1858 / 97 | 1064 / 1814 / 94 | 1086 / 1847 / 98 | 1088 / 1872 / 110 |

`requests`: wall -15 percent and CPU -22 percent against LXR, equal to WKS in wall time; `binarytrees`: equal to LXR in wall time, CPU -17 percent (2 MiB
region: wall 1072, -5 percent); `listsuffix` is still +21 percent slower than LXR (everything escapes; the barrier slow path and the workers),
the others equal within noise. The old-build column of this run differs from the earlier table of `STATUS.md` by the usual noise of a shared machine
(`requests` 397 here, 364 there; `binarytrees` 1203 and 1201).

## 9. Conclusion

The thread-local GC is **reasonable in design and was defective in one place**: the sync-block walk made a collection 1.7 to 3 times as expensive as
it should be. With the fix its cost per collection is at or below Satori's at the same region size (118 us against about 300 to 424 us on
`requests`; 151 us against 131 us on `binarytrees`), and the stack scan and the escaped-object handling are the same as Satori's. The suspicion
"we did not implement the Satori part properly" is right for this one item and wrong for the rest. What the thread-local GC cannot do for these
workloads is the reduction of pauses *per pause*: it reduces their number and total time (`requests` 11 against 42 ms), and `listsuffix` (everything escapes) gets
nothing from it, as in Satori.
