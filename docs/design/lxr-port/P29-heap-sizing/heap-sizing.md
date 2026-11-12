# LXR heap sizing policy

Status: implemented in `src/coreclr/gc_lxr/lxr_heap_sizing.h`, used by `LxrGcHeap::CollectForPressure`.

## Problem

The Java LXR runs in the fixed heap that `-Xms`/`-Xmx` give. Its heap-full trigger
(`plan/lxr/global.rs`, `collection_required`) makes the whole free heap the nursery. The .NET host has no such setting.
The port started with an 8 MB Immix capacity and grew it only when an allocation failed after a collection
(`LxrGcHeap::TryGrow`). A program with little live data never failed an allocation, so the heap stayed at 8 MB and
`requests` made about 125 collections in the measured window.

## Policy

At each heap-full collection (`LxrCollectionCause::HeapFull`, not emergency, not user) the sizer returns the Immix
capacity that the pause should leave:

    target = min(live + budget, 75% of the Immix reservation), never below the current capacity

* `budget` starts at the initial capacity, doubles at each heap-full collection and stops at the nursery cap.
* The nursery cap is `min(96 MB, max(16 MB, physical memory / 16))`. The standard collector also limits its gen0 budget
  to a share of physical memory. `GCToOSInterface::GetPhysicalMemoryLimit` includes container limits.
* `live` is the mature live size that the previous lazy sweep left: whole non-free Immix blocks minus the free lines of
  reusable blocks (`GetImmixOccupiedBytes`), minus the young data allocated since the pause. `FinishLazy` stores it.
* The pause serves the request with `RequestImmixCapacity`. It adds exactly the missing whole blocks (no doubling),
  clamped to the reservation and the hard limit, and then the existing `FitAdmission` clamps it to the native plane limit.
* The 25% of the reservation that sizing leaves is the room that a pause borrows for its to-space (P17 S5b).
* A failed allocation after a collection still grows the heap beyond the ceiling (`TryGrow`).
* The capacity never shrinks. The part above the floor is still given back after a pause as before.

This replaces the earlier rule in `CollectForPressure` that requested one block when the nursery had at most 4 clean
blocks and at most one block was free.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `DOTNET_LXRHeapSizing` | `true` | `false` restores growth only on allocation failure |
| `DOTNET_LXRNurseryCapMB` | from physical memory, at most 96 | largest nursery budget; a value not above the initial capacity stops the growth |
| `DOTNET_LXRImmixInitialMB` | 8 | initial capacity and first budget |
| `DOTNET_LXRImmixReserveMB` | memory limit of the process (at least 128, at most 262144) | decimal MB; the growth ceiling of the Immix heap |
| `DOTNET_LXRLOSReserveMB` | memory limit of the process (at least 256, at most 262144) | decimal MB; the growth ceiling of the large-object space |
| `DOTNET_LXRNativePlaneLimitMB` | 4.5 x (Immix reserve + LOS reserve), at least 4096 | decimal MB; limit on the committed side metadata |
| `DOTNET_LXRPolicyTrace` | `false` | print one `LXRPOLICY` line to stderr for each collection |

Metrics (`GC_LxrPrototype_GetMetric`): 520..527 count collections by `LxrCollectionCause`; 528 budget, 529 sizing growth
requests, 530 live estimate, 531 nursery cap, 532 floor, 533 capacity.

## Review of the earlier trigger changes

* `GetUsedPages` counts a block as used until it is free, and `GetOccupiedPages` subtracts the free lines of reusable
  blocks. The Java LXR counts a block as reserved until it is released, so `GetUsedPages` matches the oracle. In the
  traces, `requests` shows a gap of 2% between whole blocks and occupied bytes. `listsuffix` shows a large gap
  (121 MB of non-free blocks, 34 MB occupied) but every such collection followed a failed allocation
  (`heapFull=1`) after about 92 MB of young allocation into recycled lines, so the trigger was not early.
  No false heap-full trigger was found.
* `copyReservePages != 0` in `CopyReserveExhausted`: the Java check is `reserved > total`, which is
  `reserve > free`. With no reserve and no free page it does not fire and the failed allocation collects. The port gives
  the same result, and `>=` collects one step earlier when the reserve equals the free pages. It was kept.

## Measurements (5 interleaved runs, medians, WSL2, 16 CPUs)

| Workload | Default before: collections / wall ms / RSS MB | Default after |
|---|---|---|
| `requests` 8192/200000 | 127 / 1078 / 69 | 9 / 433 / 166 |
| `binarytrees` 18 | 59 / 1722 / 174 | 23 / 1375 / 185 |
| `listsuffix` 8192/600000 | 18 / 2051 / 173 | 7 / 1460 / 198 |

## Limits

* The Immix and the LOS reservation are each the memory limit of the process (until 2026-11, a fixed 128 MB and 256 MB; with `LXRManagedHeapHardLimitMB` they are its halves). The
  sizing ceiling and the to-space borrowing use the old 128 MB while the live size is small, and twice the live size
  above 64 MB of live data; an explicit `LXRImmixReserveMB` is used as it is. See
  `docs/design/lxr-port/results/default-limits/README.md`.
* The native planes need several bytes per admitted byte (a 400 MB limit admitted about 97 MB of Immix in the test).
  `LXRNativePlaneLimitMB` stops the growth silently and the collector then keeps the smaller heap. Its default is now
  4.5 times the reservation (at least 4096 MB).
* No shrinking: a program that had a large live set keeps its capacity.
* The tables that scale with a reserve (card table, per-block tables, LOS page map, free tree and dead list) are committed for the admitted part only, so the start-up commit charge on Windows does not depend on the reserve (results/default-limits/README.md section 12).
