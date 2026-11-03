# P31: finding the start of an object without the ValidObject plane

Status: design, written before the code. Base: `lxr-gc-review` (3db3b488e29). Scope: `src/coreclr/gc_lxr` only.

## 1. The problem

.NET needs the start of the object that contains an address. The LXR port keeps a `ValidObject` side-metadata plane for this (1 bit
per 8-byte slot). The Java LXR has no such plane.

Users of the plane (all go through `FindContainingObject`, `IsObjectStart`, `FindNextValidSlot` in `lxr_reference_counting.cpp`):

| User | Thread / phase | Needs |
|---|---|---|
| Byref roots (`GC_CALL_INTERIOR`), pinned interior roots (`AddRoot`, `AddPinnedRoot`) | EE thread, **pause** | start of a live object, young or mature |
| `GetContainingObject` (runtime API) | any thread, any phase | start of a live object |
| Mature remembered-set replay (`ReplayRememberedChunk`, `requireCounted=true`) | workers, pause | counted object that contains a slot |
| Bulk write barrier destination (`LxrGcHeap::LogOldReferences`, `lxr_gc.cpp:949`) | **mutator**, concurrent with lazy sweep and with other allocators | the **mature** object (its unlogged bit is set) |
| `IsObjectStart`, `IsMarked`, `IsPromoted`, `GetLiveObjectSize`, `TryCopyMature`, trace checks | all | "is this pointer an object start" |
| `SweepCycleRange` | workers, lazy cycle sweep | every counted, unmarked object of a range |
| `WalkObjects`, `WalkObjectStarts`, `FindNextObject`, `GetMarkedBytes` | pause (`DiagWalkHeap`) or test | every counted object |

Cost of the plane today: one seq_cst byte CAS per promoted or copied object (`MarkPromotedStart`, `side_metadata.h:558-600`), one
bulk clear per hole refill (`InitializeFieldLogRange`), one clear per copied source (`RetireSourceChunk`), one clear per dead cycle
object, one fill per freed block, and 1/64 of the heap as committed metadata. This is about 1.8-2.8% of worker CPU in leaf
profiles (`MarkPromotedStart` 98 ms of 3255 ms on listsuffix). Interior lookups are rare (at most about 10^3 per run).

## 2. Facts about this engine that decide the design

1. **A young object has no bit and no count.** The engine knows young objects only from the *young spans* (`lxr_young_spans.h`):
   the used part of each allocation buffer, complete objects, no gaps. They exist from the pause start to `Resume`. This part is
   already a heap walk (`FindInYoungSpans`) and does not use the plane.
2. **A dying object is left intact.** `Death` only updates side tables. The object bytes change only when its lines are
   reused. A hole is zeroed whole at hand-out (`PrepareRecycledHole`). The unused tail of a buffer is **not** filled
   (`RetireAllocationSpan`). `gc_lxr` never writes a free object (only `g_gc_pFreeObjectMethodTable` is set).
3. **No brick table and no first-object index exist.** A block is 32 KiB = 128 lines of 256 B.
4. **The count plane is exact for mature objects (F9 invariant).** A count is stored at the first slot of an object, and only at
   that slot. The count of a dead object is cleared when the object dies (`DecrementWithDeathFast` takes it to 0;
   `RetireSourceChunk` and `SweepCycleRange` store 0). A hole or a free block has zero counts (`InitializeFieldLogRange` only
   verifies it). A line is free exactly when the counts of its range are zero (`IsLineDead` uses `IsRangeZero`). So *a non-zero
   count at slot S means: an object that was promoted and has not died starts at S.* The plane already exists, the RC protocol
   already writes it, and it costs nothing extra. A saturated count never goes down (sticky), so such an object stays counted
   until the cycle sweep.
5. **A promoted object gets its count before its unlogged bits.** Increments run in the pause (`ProcessIncrement`: count,
   straddle marks, `SetUnloggedLines`). A mutator-side lookup (bulk barrier) only asks for an object whose unlogged bit is set,
   so the count is visible.
6. **Pinned small objects are allocated one by one** with the bit set at allocation and with count zero until the first pause.
   They are in no young span today. They must be findable in the pause that follows their allocation.
7. **A dead object of a collectible type can have a dangling MethodTable.** The runtime frees a loader allocator from a finalizer.
   `GetNextFinalizable` holds finalization back while `IsCycleSweepPending`, because the cycle sweep reads the size of dead
   objects. Any method that reads the size of a *dead* object is only safe inside that window.

## 3. Alternatives for a heap walk

A "heap walk" means: start at a position that is known to be an object start, and step by object size until the address is
reached. It is correct only if every byte between the known start and the address is a parsable object.

### (A) Free-object fillers over every unused span and run of dead lines
Write a free object (`g_gc_pFreeObjectMethodTable`; size in the length field at +8; minimum 24 bytes = `Satori::MIN_FREE_SIZE`;
see `SatoriObject::FormatAsFree` and `SatoriRegion::ThreadLocalPlan`) over each gap at hand-out and retire time.

* Unused tail of a buffer: one store pair at retire time. Cheap. A tail smaller than 24 bytes cannot hold a free object. A zero
  word as an 8-byte pad solves this only if the walker accepts "MethodTable = 0 means skip 8 bytes" and the tail stays zero.
* Run of dead lines: the lines are zeroed at hand-out, so one free object per hole is cheap.
* **Dead objects inside live lines are not covered.** An object that died but shares a line with a live object stays as it is
  (fact 2). To make it parsable the engine must write a free object at *every mature death*. That is about as many writes as
  there are promotions (what is promoted dies later), and the dead object's own MethodTable must not be read again (fact 7). A
  write to the dead object also dirties its cache line; the bitmap CAS does not.
* The write races with readers of the dead object: the trace and the lazy decrements still read dead objects, and the cycle
  sweep reads the size from the object.
* Result: the cost per mature death is at least the cost of the bitmap per promotion, and `Death` needs new invariants.
  **Rejected.**

### (B) First-object index (Satori `m_index`, one entry per 2 KiB; or a first-object offset per line)
Satori sets `m_index` while the allocator hands out space and while it walks (`SetIndicesForObject`, `SatoriRegion.h:319`). In LXR:

* Per hole: record the start of the hole (the first object of a hole is at its first byte). One bit per line = 16 bytes per
  block, cleared over the range of the hole at hand-out and set at the hole start. This is one range clear per hole, on the same
  schedule as the clear of the plane today. The cost is per hole, not per object.
* The walk from the hole start runs until the first zero MethodTable word (the zeroed tail) or the hole end.
* **It breaks when part of a hole is reused** (torn remainder, (C)): the head of a dead object stays in a live line, and its
  tail has been overwritten by new objects. A walk that steps over the head by its size lands in the middle of a new object.
* Promotion in place and copy do not change the index: objects stay where the allocator put them, and a copy destination is a
  hole of the copy allocator that has its own record.
* Result: workable only together with (C).

### (C) Torn remainders
A dead object X starts in a live line L1 (shared with a live neighbour), and its tail lies in lines that the sweep has freed.
When the freed lines are handed out, the tail is overwritten. X is the *crossing object* at the hole start. The same happens at
the hole end for a dead object that starts in the hole and ends in a live line.

Ways to avoid or detect:

1. At hand-out, before the memset, find the object that crosses the hole start and the hole end (a walk over the old content of
   the hole from the old hole record) and format the crossing part as free or zero. This reads dead objects (fact 7), and it
   reads the old content of every hole before it is zeroed (a second pass over the bytes that the memset writes).
2. Walk only from a line start hint that is guaranteed to be an object start. LXR has no such hint (fact 3); the only guarantee
   is the count (fact 4).
3. Detect a torn remainder by reading. This is not possible: a torn remainder looks like an object with a valid MethodTable and
   a size that is too big.

Result: (C) needs the crossing objects, which needs the old walk, which is unsafe for collectible types outside the cycle-sweep
window. **Impossible without a new invariant that costs more than the bitmap** (a write at each death, or a read of the old hole
at each hand-out).

### (D) Concurrency
Lookups run on the mutator (bulk barrier) while other allocators fill other holes of the same block, on workers during the lazy
sweep and the cycle sweep, and in pauses.

* Young objects: only in a pause, from the spans. All spans are closed and the objects are complete. This is race-free now. The
  buffer that another thread fills (zero tail, unfinished object) does not occur: the mutators are stopped, and
  `RetireAllocationSpan` cuts every buffer at the used point.
* Mature objects: a walk reads other objects' bytes. Another allocator writes other holes of the same block while the walk steps
  over the block. The old invariants ("block sweep skips blocks with an owner or taken this epoch", "cycle sweep reads only
  counted objects") protect the *sweep*. They do not protect a *reader* that steps over the neighbours; the reader would need the
  same fences for every block that it crosses.
* The count plane has none of these problems. A live mature object has a count of at least 1; the lazy decrements only kill
  objects that were unreachable at the last pause; an allocator writes to a hole whose counts are zero and does not write the
  counts of the neighbours (F9). A downward scan of the counts from the address reads side metadata only, not object memory.

### (E) The other consumers
* `SweepCycleRange`, `WalkObjects`, `WalkObjectStarts`, `FindNextObject`, `GetMarkedBytes`: `SweepCycleRange`, `WalkObjects` and
  `FindNextObject` skip count zero already; the other two filter by it or can. They need an enumeration of counted objects. A
  block walk cannot give it (fact 7, torn remainders). **The count plane gives it directly.** `WalkObjectStarts` visits stale
  bits today; the walk variant visits counted objects only (a subset: a stale bit is not an object start).
* `IsObjectStart`, `IsMarked`, `IsPromoted`, `GetLiveObjectSize`, trace checks: they ask "is this pointer the start of an object
  that the engine registered". Without the plane: a pointer that comes from a reference slot is an object start by the .NET
  object model (stock CoreCLR does not check). Where the engine needs the check (the pointer may be young, dead or stale), the
  check is *count != 0* for Immix (fact 4), or *a registered large allocation* for the large object space.
* Large objects: unchanged. `LxrLargeObjectSpace::GetContainingAllocation` and `GetAllocation` (page map) give the start. The
  ValidObject bit that is set at large allocation and cleared at release is not needed: `IsObjectStart` for a large address asks
  `GetAllocation` for an exact start.
* Pinned objects: they have count zero until the first pause and no young span. The walk variant gives them a span. The pinned
  allocator is one allocator under `m_pinned_lock`; it records the span of its objects, and the pause merges that span with
  the mutator spans. After the first pause they have a count like all other objects.

### (F) The count plane as the index (not in the original list; recommended)
Lookup of an address A in a block:

1. young spans of the pause (walk), including the pinned span;
2. otherwise scan the count plane downwards from the slot of A, within the block, until the first non-zero count. That slot is
   the candidate start. Read the size of the candidate (it is live, so its MethodTable is valid; for a forwarded source read the
   size from the copy). Accept the candidate if `A < start + size`. This size check exists today.

This is the existing lookup with `m_valid_metadata` replaced by `m_rc_metadata`. The scan runs word by word on the count plane
(2 bits per slot by default, `LXRRCBits`; 32 slots per 64-bit word; at most 128 words for a whole block).

What is different from the bitmap:

* No stale starts: a dead object has count zero (fact 4). With the bitmap the nearest bit could be a dead object whose range was
  not yet reused; the size check turned that into an error. Now the nearest count is a live object, which is stronger.
* A dead cycle object that is not yet swept (count above zero, no mark) is found. This is as before.
* A promoted object is findable as soon as its first increment ran. The bit was set before that increment
  (`MarkPromotedStart`); no reader needs the object before the increment.
* A copy destination has its count set in `TryCopyNursery` and `TryCopyMature` before the `memcpy`, as its bit was. The window is
  the same, and the readers are the same (none outside the pause).
* A forwarded source: a nursery source has count zero and is young (in the spans). A mature source keeps its count until
  `RetireSourceChunk`, so the lookup finds it and reads the size from the copy, as it does today.

## 4. Recommendation

Implement **(F) plus spans plus the pinned span** as the alternative variant. Reject (A), (B) and (C).

| Option | Added cost | Needs a new invariant | Correct? |
|---|---|---|---|
| Bitmap (default) | 1 locked byte CAS per promoted or copied object, 1/64 heap of metadata, 2-3 clears per object life | no | yes |
| (A) fillers | 1 write per mature death (about = promotions) + hole formats | yes: dead objects stay parsable, no MethodTable read after unload | not without a stop on collectible types |
| (B)+(C) hole index | 1 range clear per hole + 1 pre-read of every old hole | yes: crossing-object repair | not without reading dead objects |
| (F) count plane | none per object; one downward scan of at most 128 words per mature lookup | no: the count plane exists and is exact | yes |

These cases are impossible for a walk without a new invariant:

1. A mature lookup that starts from a block start (no object start is known there).
2. A walk across a dead object of a collectible type outside the cycle-sweep window.
3. A walk across a torn remainder (head of a dead object in a live line, tail overwritten).
4. Finding a *young* object outside a pause (no span list exists then; this limit exists today too).

The literal heap walk is not built. If the measurements show that (F) is not enough, the next step is (B) per hole with the
crossing-object repair of (C) item 1, as a second option behind the same switch.

## 5. Implementation plan

Switch: CMake option `CLR_CMAKE_LXR_OBJECT_START_WALK` (default OFF). It defines `LXR_OBJECT_START_WALK` for `gc_lxr` and sets
the library output name `clrlxrgc-walk` (`libclrlxrgc-walk.so`). The name says "walk"; in the walk variant the mechanism is the
span walk for young objects and the count-plane index for mature objects (section 3 (F)).
With the switch OFF the code is the same as before (`#ifndef LXR_OBJECT_START_WALK` around the old lines).
With the switch ON:

* `ValidObject` is not in the enabled spec mask: it is never committed and any access fails. No product line sets, clears or
  reads it (`MarkPromotedStart`, `RegisterObjectInClearedSpan`, `InitializeFieldLogRange`, block release and fill,
  `RetireSourceChunk`, `SweepCycleRange`, large-object `ResetAllocationMetadata` and `InitializeAllocationMetadata`).
* `FindContainingObject` uses spans, then the count scan. `IsObjectStart` is `count != 0` (Immix) or a registered allocation
  (large).
* `SweepCycleRange`, `WalkObjects`, `WalkObjectStarts`, `FindNextObject`, `GetMarkedBytes` use `FindNextCountedSlot`.
* The pinned allocator records a young span (merged at pause start like the mutator spans).
* Counters (both variants): number of interior lookups and their cost in ticks, per pause.

Validation: both variants build the same P2.x-P4 suites (`LXR_OBJECT_START_WALK` is a control selector of `run-lxr-rc-vertical.sh`
and the other scripts take the same flag). New checks (P4): interior lookup at every offset of objects of many sizes; after
promotion in place; after copy; after hole reuse; next to dead objects (torn remainder cases); a concurrent allocator and lookup
stress; bulk-barrier destination lookup; cycle sweep and `WalkObjects` equivalence between the variants. Mutation checks: each new
check has a control macro that breaks the rule that it tests and must make the check fail.
Managed tests: `ref` locals, `Span<T>` and `fixed` into the middle of objects held across GCs (many threads, `GC.Collect` inside;
pinned and unpinned; young and mature; next to dead objects).

Measurement: both `.so` files, six workloads, 9 interleaved runs; perf of worker CPU in promotion, refill and sweep; then a
crash hunt of at least 100 runs at 13/3, 4/2 and 1/1 workers.
