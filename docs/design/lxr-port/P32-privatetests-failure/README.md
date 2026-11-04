# P32: failures of the stock LXR collector in PrivateTests `all 2 13`

Base: `lxr-gc-review` at a3a225d40a9. Scope: `src/coreclr/gc_lxr`. `PrivateTests` is a managed stress program from the Laxori
branch (copied here unchanged, not merged). `repeat.sh` builds it and runs it many times on one library.

## 1. Result

`PrivateTests all 2 13` (13 threads) on the stock library failed in about 30% of the runs. The failures had two causes, and
both were collector defects. The heap was large enough in both cases.

| Failure | Where it comes from | Fix |
|---|---|---|
| `LXR fatal: space-pressure collection failed before growth admission (engine failure 1)`, and four other `LXR fatal` messages with `engine failure 1` | A pause failed while it captured the stack roots: an interior root that points one byte past the end of an array has no containing object, and `LxrGcHeap::AddRoot` treated that as a fatal error. | `AddRoot` ignores an interior root that no live object contains. `RelocateRoot` moves a root that points one past the end of an object together with that object. |
| `System.OutOfMemoryException` from a small allocation | `LxrGcHeap::Alloc` gave up after one emergency collection. | The allocation runs up to `MaximumEmergencyCollections` (3) emergency collections, and it sets the allocation cursors back before each retry. |

## 2. Cause 1: interior root one past the end of an object

The message is produced at `lxr_gc.cpp` (`Alloc`, stage 2). It is only the first place where a thread notices that the engine is
`Faulted`; the five different messages all end with `engine failure 1` (`LxrRcResult::InvalidArgument`) because the first failure
of the engine is sticky (`LxrReferenceCounting::Fail`).

The first failure was found with a temporary backtrace in `Fail`: it is `LxrReferenceCounting::Suspend`, line
`engine->Fail(result)` after `m_capture` (= `LxrGcHeap::CaptureRoots` -> `ExecuteScan(0)`). The scan result was set by
`AddRoot`: `FindContainingObject` returned `InvalidArgument` for a root with `GC_CALL_INTERIOR`.

With a second probe, `FindContainingObject(address - 8)` was called for each of these roots. In all 6 of 6 recorded cases it found an
object whose end was exactly the address of the root (`Start(object) + size == address`), for example
`address=0x...5430 prev=0x...53f8 size=64`. So the root is a byref one past the end of an array. The JIT makes such byrefs for
array loops, and the managed rules allow them. The next object (or the free space) starts at that address, and the header of the
next object is not "inside" it for `FindContainingObject` (`address >= candidate` is false). The standard collector ignores an
interior pointer for which `find_object` finds nothing (`GCHeap::Promote`); LXR made it a fatal error.

The test triggers it with `foreach (long v in Data)` in `Node.Compute` together with a pause on another thread. It does not
depend on the heap size: the failure rate with `DOTNET_LXRImmixInitialMB=200 DOTNET_LXRImmixReserveMB=400` was 4/20 before the fix
(4 engine fatals, no OutOfMemoryException).

The fix is in two places:

* `LxrGcHeap::AddRoot`: `InvalidArgument` from the lookup of an interior root means that no live object contains the address. The
  root is ignored. The other error codes stay fatal.
* `LxrReferenceCounting::RelocateRoot`: when the lookup fails, the root is relocated with the object that ends at the address (if
  there is one). Only ignoring the root would leave the end pointer of a loop at the old address while the pointer inside the array
  moves. The root does not pin the object, because `AddRoot` did not keep it.

Regression check: `P4/lxr-rc-validation.cpp`, selector `--s3-bookkeeping` (`ValidateForwardedArraySizes`): "a byref one past the
end of a forwarded array source follows the copy". With only the ignore (no relocation) the check fails: `FAIL: 1324/1325`.
The same check passes in the default and in the bitmap build (1325/1325).

## 3. Cause 2: the allocation gave up too early

After the first fix, the remaining failures were `OutOfMemoryException`s from `Alloc` while the heap was far from full. A
temporary probe printed the heap at each null return. The state after the emergency collection was `freeAfterGc=0K`. A second
emergency collection freed 83-110 MB in each of the 4 recorded cases, and the allocation then succeeded.

Two reasons were found:

1. The collection policy (`Select` in `lxr_collection_policy.h`) returns `FinalMark` for an emergency collection when a concurrent trace is in progress. That collection only
   ends the trace; it frees little. The next emergency collection is a `Full` one. `Alloc` made one emergency collection only.
2. The allocation cursors of the Immix allocator move forward only and are set back at the end of a pause. Other threads run again
   at once and move the cursors past the blocks that the lazy sweep of the pause has not freed yet. A collection that waits for the
   sweep (every emergency collection) frees them, but they are behind the cursors. In an experiment, a `ResetAllocationCursors()` and
   a retry rescued 3 of 3 failing allocations in 30 runs (free space 49952K, 160K and 0K at that time).

Other threads can also use the freed space before the retrying thread allocates. A heap that is full really (live data fills it)
now costs up to three emergency collections before the exception, and the exception stays.

## 4. Failure rates

`all 2 13`, WSL2 with 16 CPUs shared with other jobs, the machine was loaded during all runs. "default" is the count-plane library
(`libclrlxrgc.so`), "bitmap" is `libclrlxrgc-bitmap.so`. Heap settings are in hex, as the settings expect: `mid` is
`InitialMB=40 ReserveMB=100` (64 MB, 256 MB), `big` is `InitialMB=200 ReserveMB=400` (512 MB, 1 GB). The default is 8 MB initial and
128 MB reserve.

| Library | Heap | Stock | After fix 1 only | After both fixes |
|---|---|---|---|---|
| default | default | 6/20 (3 fatal, 4 OOM) | 13/40 (13 OOM) | 0/60 |
| bitmap | default | 10/30 (8 fatal, 3 OOM) | 7/40 (7 OOM) | 0/40 |
| default | mid | 6/20 (3 fatal, 4 OOM) | | 0/40 |
| default | big | 4/20 (4 fatal) | | 0/20 |

The rates changed from run to run with the load of the machine (instrumented builds of the stock logic failed in 8/20 and in 1/8
runs in other sets). The counts above are from the sets that are named here.

## 5. Not verified

* The cause of the original report was found for the stock library only. The Laxori runs (private tier on or off) were not run.
  If they still fail, the Laxori branch can have its own cause. Laxori has its own `Alloc` and root scan, which were not looked at.
* The six benchmark workloads gave the expected checksums with the fixed default library (`requests`, `binarytrees`,
  `listsuffix`, `mixedmedium`, `losarrays`, `mediumarrays`). Their timing was not measured, so a cost of the change is not excluded.
  The new loop in `Alloc` runs only when an allocation finds no memory after a collection and a growth.
* The native suites P2.1-P2.5, P3.1-P3.4 and P4 (all selectors) pass in the default Release variant
  (`validate-variant.sh default Release`). The bitmap variant was run only for the P4 default run and `--s3-bookkeeping`.
* `MaximumEmergencyCollections = 3` is a choice, not a measured value. One round is not enough (the trace case) and two rounds are
  enough in the cases that were seen. Three leaves room for a new trace that another thread starts between the rounds.
* A byref one past the end of an object that is directly followed by an object start is resolved by the young-span lookup to the
  next object (the span lookup uses extents that include the header). Such a root is relocated with the next object. That behaviour
  was there before; it was not changed.
