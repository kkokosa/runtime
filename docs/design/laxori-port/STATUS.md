# Laxori: status

Everything below was run in this worktree on WSL2 Ubuntu 22.04 (16 CPUs), against the benchmark frame `/root/prof/frame-p`
(R2R built with `CrossgenOldValueWriteBarriers=true`). Other sessions used the machine at the same time. Nothing here is
pushed. Laxori is **off by default** at two levels: the CMake option `CLR_CMAKE_ENABLE_LAXORI_GC` is OFF, and the request
regions need `DOTNET_LAXORIRequests=1` plus a program that calls the request hooks.

## Summary

| Milestone | State |
|---|---|
| M0 scaffold | Done. `gc_laxori` builds and runs. It is a renamed copy of the LXR engine. |
| M1 request-private regions | Done and stable in the tests listed below. **It is not faster** than the LXR engine on the benchmark set (section 4). |
| M2 shared reclamation and cycles | No new mechanism. Tests of published request data (rings with back pointers) run and the memory stays bounded. Trial deletion is **not** implemented; cycles are reclaimed by the LXR trace. |

## 1. Build

```
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
bash src/coreclr/build-runtime.sh -release -x64 -ninja -component clrlaxorigc -subdir <name> -numproc 4 \
     -cmakeargs "-DCLR_CMAKE_ENABLE_LAXORI_GC=ON"
```

The output is `artifacts/obj/coreclr/linux.x64.Release/<name>/gc_laxori/libclrlaxorigc.so`. It was built twice (M0, and M1
in the same build directory). `gc_lxr` and `gc_satori` are not changed. Only `src/coreclr/CMakeLists.txt` has two small
additions (option and `add_subdirectory`).

Run: `DOTNET_gcServer=1 DOTNET_GCPath=<so> DOTNET_LAXORIRequests=1 corerun ...`. The configuration keys of the engine are
the LXR keys with the prefix `LAXORI` (for example `DOTNET_LAXORIGCThreads`).

## 2. Tests that were run

| Test | Result |
|---|---|
| Native barrier test (`BarrierTest/`): the assembly barrier copied to an executable page, with a fake heap, block table and metadata. 15 checks: private dst, shared/shared with clear and set unlog bit, shared dst with private reference (escape once, then log, then store), null and non-heap references, checked helper outside and inside the heap, xmm state preserved across both slow paths. | 15 of 15 PASS |
| Request tests (`RequestTests/`): stores into arrays, a struct array, a static, a large array, `Array.Copy`, `Interlocked.CompareExchange`, a `Dictionary`; strong, weak, weak-track and pinned `GCHandle`s; `ConditionalWeakTable`; finalizable objects; `GC.Collect` inside a request; a result object passed to `EndRequest`; nested `BeginRequest`; `EndRequest` without a body; 40 threads that exit inside a request; objects above the private size limit; large arrays. Every published object carries a checksum that is validated all the time and at the end. | M1: 24 of 24 runs PASS (1, 2, 4 and 8 threads, 6 rounds, 40000 requests per thread); also 2, 4, 8 threads with 60000 requests. The same tests PASS on WKS and on the M0 build. |
| Cycle test (`RequestTests ... cycles`): 1.5 million requests, each publishes a ring of 16 nodes with `Next` and `Prev` and replaces an old ring. | PASS. Peak working set 201 MB (WKS: 65 MB). Rings validated during the run and after a full GC. |
| Crash hunt M0 (`scripts/hunt-m0.log`): 6 workloads, worker settings default, 1/1, 2/1, 4/2, 8/4 | 102 runs: 85 OK, 17 FAIL. **All 17 failures are `mediumarrays` with an `OutOfMemoryException`.** The frame's LXR (`libclrlxrgc.so`) fails the same workload in the same way, so this is inherited from the base, not new. |
| Crash hunt M1 (`scripts/hunt-m1.log`): `DOTNET_LAXORIRequests=1`, five workloads (without `mediumarrays`), same worker settings, scaled-down sizes, checksums compared with a WKS run of the same size | 135 runs: 135 OK. |

The hunts and the request tests ran with `nice -n 19` and **without** the benchmark lock, because the lock was held by long
runs of other sessions for hours. The benchmark itself ran under `flock /tmp/lxr-bench.lock`.

## 3. What M1 does (as built)

* A thread is "in a request" between `GC_Laxori_BeginRequest()` and `GC_Laxori_EndRequest(result)` (exported from the
  library, called through `SuppressGCTransition` function pointers). The first small allocation of the request takes a clean
  32 KiB Immix block as the private region and hands the rest of it to the runtime as the allocation buffer of the thread.
* The block table (one byte per block) and `amd64/laxori_writebarrier.S` implement the owner check and the escape publication.
  Bulk copies, `pre_store`, GC handles and `GC.ReRegisterForFinalize` also publish. Finalizable, pinned, large and
  objects of more than 8 KiB are allocated in the shared heap.
* `EndRequest` with no escape zeroes the used bytes of the region and moves the cursor back. No span, no count, no pause.
* A pause, a full region, a thread exit and a nested `BeginRequest` publish the region (it becomes a normal young span).
* Metrics 700 to 709 of `GC_Laxori_GetMetric` count requests, resets, publications by cause, and escape slow calls.

## 4. Benchmark (5 interleaved runs, median; `scripts/bench-m1.log`)

Wall ms / CPU ms / pause ms / peak RSS MB. All checksums equal the expected ones. `lxr` is the `libclrlxrgc.so` of the frame
(built from a newer commit than the base of this branch). `laxori0` is the M1 build with requests off (the hooks do nothing),
`laxori1` is the M1 build with `DOTNET_LAXORIRequests=1`. Only the `requests` workload calls the hooks (one request per loop
iteration); for the other workloads `laxori1` is the same program as `laxori0`. `mediumarrays` is not in the table: LXR and
Laxori fail it with an out-of-memory error.

| workload | WKS | SVR | LXR | Satori | Laxori requests off | Laxori requests on |
|---|---|---|---|---|---|---|
| requests | 476 / 477 / 81 / 67 | 764 / 1183 / 316 / 99 | 533 / 712 / 40 / 172 | 814 / 934 / 28 / 88 | 563 / 744 / 40 / 172 | 552 / 705 / 39 / 165 |
| binarytrees | 1213 / 1217 / 355 / 91 | 1632 / 2470 / 690 / 202 | 1135 / 2632 / 117 / 195 | 1135 / 1762 / 69 / 162 | 1221 / 2222 / 99 / 195 | 1219 / 2394 / 100 / 195 |
| listsuffix | 2774 / 2917 / 1515 / 99 | 1445 / 3429 / 392 / 209 | 1716 / 4751 / 212 / 203 | 1109 / 2579 / 115 / 228 | 1782 / 5009 / 221 / 203 | 1699 / 4653 / 200 / 200 |
| mixedmedium | 1414 / 1429 / 610 / 181 | 1363 / 2318 / 409 / 503 | 2398 / 5785 / 347 / 193 | 839 / 1827 / 164 / 360 | 2543 / 6363 / 366 / 193 | 2507 / 6304 / 348 / 193 |
| losarrays | 2388 / 2507 / 1441 / 313 | 3133 / 6634 / 1589 / 488 | 12462 / 85185 / 1757 / 329 | 856 / 1508 / 112 / 533 | 13284 / 97516 / 1696 / 329 | 12637 / 94471 / 1865 / 332 |

Checksums (all collectors, all rows equal): requests 27134172608, binarytrees 68332294, listsuffix 159636632672,
mixedmedium 40586599707, losarrays 13936826922.

What the numbers say (honestly):

* On `requests`, request regions give **about 2% less wall time** than the same engine with requests off (552 against 563
  ms). This is inside the noise of this shared machine. Laxori is **slower than the frame's LXR (533 ms) and than WKS (476 ms)**
  on this workload. The engines differ in age (the frame's LXR is newer), so the part of the gap between `laxori0` and `lxr`
  is not caused by Laxori.
* In that run, 12% of the requests store a new object into a shared table, so their region escapes. Each escape takes a new
  block: the engine zeroes 32 KiB and the unused tail of the old block is wasted until the next pause. The number of pauses
  therefore did not go down (9 pauses with and without requests). Of 1.92 million requests (warm-up included), 1.69 million
  were retired in place (7.8 GB of request data zeroed and reused); 233 thousand escaped.
* For the other workloads, `laxori0` is equal to LXR within noise. The barrier has not been measured separately.
* No claim of a speed-up is made.

## 5. Not verified / known gaps

* No speed-up was shown. A request that escapes pays a 32 KiB block acquisition; the tail of the block is not reused.
* Sync blocks (hash code then `lock` on a request object) are not detected; a retired object could leave a stale pointer in
  the sync block table. There is no test for it.
* The stack contract of `EndRequest` is not checked (no poison/verify mode).
* The hooks write `ee_alloc_context::m_CombinedLimit` by its layout (see risk 10 in `DESIGN.md`).
* Windows is not ported (the barrier assembly exists only for Linux x64). ARM64 is not ported.
* Async code in a request is not supported. Only thread-affine scopes were tested.
* Trial deletion (item i of the description) is not implemented. The shared heap uses the LXR trace.
* Crash hunts of M1 used scaled-down workload sizes (135 runs). Full-size runs of M1 were: the benchmark matrix (5 runs for
  each workload and collector, no failures) and 2 hand runs. Full-size M0 hunt had 85 OK and 17 inherited `mediumarrays` OOMs.
* `GC.GetTotalAllocatedBytes` accounting for request regions was not checked against the runtime.
* Profilers, debugger heap walks (`DiagWalkHeap`) and the DAC were not tested with request regions.
* The request tests use a Release frame without GC stress.
