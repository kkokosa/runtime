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
more per copy source (before the claim), one per death (`DecrementWithDeathCore` stores 0 at count 1), one bulk clear per hole
refill (`InitializeFieldLogRange`), one clear per copied source (`RetireSourceChunk`), one clear per dead cycle object, one fill
per freed block, and 1/64 of the heap as committed metadata. This is about 1.8-2.8% of worker CPU in leaf profiles
(`MarkPromotedStart` 98 ms of 3255 ms on listsuffix). Interior lookups are rare (at most about 10^3 per run).

## 2. Facts about this engine that decide the design

1. **A young object has no bit and no count.** The engine knows young objects only from the *young spans* (`lxr_young_spans.h`):
   the used part of each allocation buffer, complete objects, no gaps. They exist from the pause start to `Resume`. This part is
   already a heap walk (`FindInYoungSpans`) and does not use the plane.
2. **A dying object is left intact.** `Death` only updates side tables. The object bytes change only when its lines are
   reused. A hole is zeroed whole at hand-out (`PrepareRecycledHole`). The unused tail of a buffer is **not** filled
   (`RetireAllocationSpan`). `gc_lxr` never writes a free object (only `g_gc_pFreeObjectMethodTable` is set).
3. **No brick table and no first-object index exist.** A block is 32 KiB = 128 lines of 256 B.
4. **The count plane is exact for mature objects (F9 invariant).** A count is stored at the first slot of an object. It is also
   stored at the first slot of each *continuation line* (a line that lies wholly inside an object that is longer than a line; the
   straddle byte of such a line is set; the count is the liveness of the line). The count of a dead object is cleared when the
   object dies (`DecrementWithDeathFast` takes it to 0; `RetireSourceChunk` and `SweepCycleRange` store 0). A hole or a free block
   has zero counts (`InitializeFieldLogRange` only verifies it). A line is free exactly when the counts of its range are zero
   (`IsLineDead` uses `IsRangeZero`). So *a non-zero count at slot S, where S is not the first slot of a line whose straddle byte
   is set, means: an object that was promoted and has not died starts at S.* The plane already exists, the RC protocol already
   writes it, and it costs nothing extra. A saturated count never goes down (sticky), so such an object stays counted until the
   cycle sweep.
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
* `SweepCycleRange`, `WalkObjects`, `WalkObjectStarts`, `FindNextObject`, `GetMarkedBytes` use `FindNextValidSlot` (in the walk variant it enumerates counted slots).
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

## 6. Findings during the implementation

1. **The plane was also the discriminator of a forwarded copy source.** `ResolveForwarded` read the header of a value only if
   its ValidObject bit was set, because a stale value (a weak target, a queued trace entry) can point into the middle of a new
   object, and the header word there is arbitrary data (the forwarding state is the first dword of the header slot; state 2
   makes a reader wait, state 3 makes it follow the word at +8). Without the plane:
   * `ResolveForwarded` is for values that are object starts by construction (references of live slots, roots, counted objects,
     the objects of a span walk). It reads the header first and needs no metadata for the common case of state 0.
   * `ResolveForwardedChecked` is for values that may be stale (`IsPromoted`, `IsMarked`, `ProcessTraceObject`,
     `TryCopyMature`, `FixPacketReferences`). A counted start (count not zero, and not the first slot of a continuation line) is
     trusted. For count zero the value is a copy source only if a span of the pause has an object that starts exactly there
     (`FindInYoungSpans`); outside a pause there is no source. The span walk runs only when the header has a forwarding state.
   * After `RetireSourceChunk` a source keeps its forwarding state in the header (the default variant cleared its bit). The
     spans are gone at `Resume`, so the value is then no source for `ResolveForwardedChecked`, as before.
   P4 `--object-start` has a check with arbitrary header bits and a mutation control (`WalkTrustedResolve`).
2. **The count plane has non-zero entries that are not starts**: the first slot of each continuation line (finding in section 2,
   item 4). `FindCountedSlotBelow`, `FindNextValidSlot` and `IsObjectStart` skip a slot whose line has a straddle byte.
3. **A young pinned object is found only inside a pause** in the walk variant: it is in a span (the pinned allocator records one,
   `ClosePinnedSpan`), it has no count, and there is no bit. In the default variant it was found at once. Nothing in the engine
   asks for it outside a pause: the bulk barrier asks for objects whose unlogged bit is set (mature).
4. `IsObjectStart` for a large object is an exact start in the large-object space (`GetAllocation`); the default variant read the
   bit that was set at the allocation.
5. `ValidObject` is not committed in the walk variant (`SideMetadataManager::Initialize` with a mask). That saves 1/64 of the
   heap in native plane memory, and any access to the plane in the product code fails closed.

## 7. How to build and validate both variants

```
bash docs/design/lxr-port/P31-object-start-walk/build-lxr.sh base          # libclrlxrgc.so      (ValidObject plane)
bash docs/design/lxr-port/P31-object-start-walk/build-lxr.sh walk walk     # libclrlxrgc-walk.so (no plane)
bash docs/design/lxr-port/P31-object-start-walk/validate-variant.sh default Release   # P2.1-P2.5, P3.1-P3.4, P4 (all selectors)
bash docs/design/lxr-port/P31-object-start-walk/validate-variant.sh walk Release
bash docs/design/lxr-port/P31-object-start-walk/compare-digests.sh                    # cycle sweep / heap walk equal in both
bash docs/design/lxr-port/P31-object-start-walk/run-walk-controls.sh                  # mutation checks of the walk variant
```
`LXR_OBJECT_START_WALK=1` in the environment makes the P2.2-P2.5 and P4 scripts build the walk variant. The managed stress
test is `managed/InteriorStress` (see its header). Selectors that are flaky under load in both variants:
`--mature-released-candidate` and `--p8-storage`.

## 8. Results

All numbers come from WSL2 (16 CPUs), frame copies of `frame-c4`, `DOTNET_gcServer=1`, 9 interleaved runs per workload, medians, under `flock /tmp/lxr-bench.lock`. All checksums were correct. "walk" means the count-plane variant; "base" means the ValidObject variant. Values are walk relative to base (negative is better).

### 8.1 Validation

- Release, both variants: P2.1-P2.5 pass. P3.1 641, P3.2 395, P3.3 357, P3.4 70, P4 105380.
- Debug, both variants: P4 105380.
- New `--object-start` selector: 4279 checks pass in both variants. The deterministic DIGEST lines are equal in both variants (`compare-digests.sh`).
- Six walk mutation controls (`run-walk-controls.sh`) and the P2.4 write-valid control are detected.
- Some selectors are flaky under load in BOTH variants (and in the baseline): `--mature-released-candidate` (about 4 of 8 runs fail in default Release, 1 of 8 in walk Release, 0 of 8 in Debug) and sometimes `--p8-storage`. `--zero-rc-control` is a control that is expected to fail.
- Managed `InteriorStress` passes with stock GC, LXR base and LXR walk.

### 8.2 Benchmarks

| Workload | wall (batch 1 / 2) | cpu (batch 1 / 2) | pause (batch 1 / 2) | rss (batch 1 / 2) |
|---|---|---|---|---|
| requests | -3.2% / -0.6% | -6.1% / -3.7% | -5.1% / -5.1% | -0.9% / -1.1% |
| binarytrees | -2.4% / -1.8% | -11.9% / -14.0% | -21.7% / -8.0% | -1.2% / -2.6% |
| listsuffix | -5.4% / -2.6% | -11.8% / -11.0% | -13.0% / -14.5% | -1.5% / -0.3% |
| mixedmedium | -3.7% / +0.1% | -4.8% / -2.5% | -2.6% / -3.0% | -1.0% / -1.1% |
| losarrays | -2.7% / -2.2% | -4.0% / -2.5% | -7.3% / -4.8% | -3.4% / -4.1% |
| mediumarrays | -3.3% / -3.0% | -5.5% / -3.6% | -6.4% / -2.1% | -1.3% / -1.3% |

Control: the stock `frame-c4` library against the default variant of this tree gives about 0% (wall -0.6 to +2.3%, CPU about +0.4%). The default variant is unchanged in speed.

### 8.3 Worker CPU by function (perf, cpu-clock, 2 repetitions)

- The largest saving is the per-death clear of the ValidObject bit in `DecrementWithDeathCore` (listsuffix 612 to 447 ms, mixedmedium 107 to 38 ms, requests 16.5 to 9.4 ms). This cost is higher than the early estimate (1.8-2.8%) because the bitmap costs two CAS per mature object life: one at promotion and one at death.
- `MarkPromotedStart` is removed (listsuffix 85 ms, binarytrees 43 ms in base).
- `TryCopyMature` in binarytrees: 166 to 87 ms.
- The walk variant adds `FindNextValidSlot` (binarytrees 53 ms) and `ResolveForwardedChecked` (63 ms, partly offset by a cheaper `ResolveForwarded`).
- Worker CPU total: binarytrees 2708 to 2416 ms, listsuffix 3065 to 2565 ms, mixedmedium 1202 to 1134 ms, losarrays 1633 to 1507 ms, mediumarrays 872 to 848 ms. The requests value is too small to read (noise).

### 8.4 Interior lookups per pause (`LXRLookupStats=1`)

- Number of lookups is small: stress test about 83K per run (about 17 per pause), requests 18, listsuffix about 1.1-1.5K, mixedmedium 2.5-38K.
- Cost per lookup: stress test base 0.42 us, walk 0.30 us.
- binarytrees (remembered-set replay, depends on the pause policy): base 65K-410K lookups per run; walk runs vary in number. The per-lookup cost is about 0.4 us in walk. Base is slower on failing lookups because it scans bits slot by slot.
- Stale-value span walks in walk (`checked`): about 1.4K per binarytrees run, about 200-970 for the other workloads. These are cheap.
- Interior lookups are never the main cost in either variant.

### 8.5 Crash hunt (walk variant)

- Mixed programs: 105 runs at each of 13/3, 4/2 and 1/1 workers = 315 of 315 OK.
- Stress test only: 100 runs at each configuration = 300 of 300 OK.
- Base control: 40 runs at each configuration = 120 of 120 OK.

### 8.6 Limits of the walk variant

- A literal heap walk was not made correct without a new invariant (filler objects or a first-object index) that costs at least as much as the bitmap. See sections 3 and 4. The walk variant uses the count plane and young spans.
- Young pinned objects are found only inside a pause (through the pinned span). In the base variant the bit finds them at once. Young objects are not found outside a pause in either variant.
- The ValidObject plane is not committed in the walk variant (1/64 of the heap less native plane memory).

## 9. A literal heap walk as a possible third variant: what exists and what is missing

Decision (user, confirmed through the roadmap session): use the count-plane alternative (sections 3 (F), 4) to remove the
ValidObject bits. A literal walk (stock CoreCLR style: brick or index entry, then step by object size over parsable objects) is
NOT built. This section says exactly what exists and what a literal walk needs, so the decision can be explained and, if needed,
reversed.

### 9.1 Swap points that exist

The lookup is behind these functions only. A third variant needs changes inside them and in their helpers, not in the callers:

* `FindContainingObject` (wrapper with counters) and `FindContainingObjectCore`: interior pointer to object start.
* `IsObjectStart`: "is this address the start of a registered object".
* `FindNextValidSlot`: the enumeration used by `SweepCycleRange`, `WalkObjects`, `WalkObjectStarts`, `FindNextObject`,
  `GetMarkedBytes`.
* `ResolveForwarded` and `ResolveForwardedChecked`: the forwarded-source discriminator (it used the ValidObject bit before).
* Callers (not to change): byref and pinned interior roots, remembered-set replay, bulk write barrier, `GetContainingObject`
  in the GC interface, `DiagWalkHeap`.

### 9.2 What exists today for each variant

| Piece | ValidObject variant (default) | Count-plane variant (`LXR_OBJECT_START_WALK`) | Literal walk |
|---|---|---|---|
| Mature object start | bit per 8-byte slot, set at promotion, cleared at death | non-zero count, skipping continuation slots | needs a parsable heap or a first-object index |
| Young object start | young spans | young spans (and a pinned span) | young spans (unchanged) |
| Gaps between objects | not walked | not walked | free objects over every gap (does not exist) |
| Dead objects in live lines | skipped by the bit | skipped by count zero | must be parsable (does not exist) |
| Index | none | none (the count plane is the index) | first-object index per 2 KiB or per line (does not exist) |
| Per-object cost | 2 CAS (promotion, death) | none beyond the RC protocol | one free-object store per mature death, or index maintenance |
| Large objects | LOS page map | LOS page map | LOS page map |

### 9.3 What a literal walk needs (none of it exists in gc_lxr)

1. **Filler objects.** A free object (`g_gc_pFreeObjectMethodTable`, minimum 24 bytes) over every unused buffer tail
   (`RetireAllocationSpan` writes nothing today), every run of freed lines (zeroed at hand-out only), and every dead object in a
   live line. gc_lxr never writes a free object today; only the method table pointer is set.
2. **A rule for gaps below 24 bytes**: a zero word pad that the walker skips, or object alignment, or no gaps.
3. **A first-object index** (Satori `m_index`, every 2 KiB; or one bit per line) updated by the allocators at hand-out and by
   promotion in place and copy. This does not exist.
4. **Torn-remainder repair.** Before a hole is zeroed, find the object that crosses its start and its end and format that part
   as free. This needs a read of the old hole content, and a read of dead objects.
5. **A rule for dead objects of unloaded collectible types.** Their MethodTable can be dangling after the loader allocator is
   freed. A walker reads sizes of dead objects, so it is safe only inside the finalization-gate window (`IsCycleSweepPending`),
   or the dead object must be formatted as free before the type can go away (a write at each death).
6. **A concurrency rule for the mutator lookup** (bulk barrier): a reader that steps over a block reads bytes that other
   allocators write in other holes of the same block. It needs the block-owner and epoch fences the sweep already has.
7. **An enumeration for the cycle sweep** that does not read dead objects outside the window (or the window rule from item 5).
8. **New validation**: torn remainder, filler, index and concurrency checks, and mutation controls for each.

### 9.4 Cost summary used in the decision

* The count plane costs no extra write per object (it is written by the RC protocol already) and adds a scan of at most 128
  words per mature lookup. Measured: 0.30 us per lookup vs 0.42 us (stress test); section 8.4.
* The literal walk costs at least one write per mature death (items 1 and 5), or a read of every old hole at hand-out (item 4).
  That is the same order as the two CAS of the bitmap, and it adds the invariants above. It is not measured, because it does
  not exist. The only advantage of a literal walk would be that the engine would match stock CoreCLR heap parsability.

### 9.5 If a third variant is wanted

Keep the three variants behind the same functions (9.1). Add a second switch (for example `LXR_OBJECT_START_LITERAL_WALK`,
mutually exclusive with `LXR_OBJECT_START_WALK`), implement items 1-7, and reuse the `--object-start` suite (it already
checks every offset, torn remainders, hole reuse, WalkObjects equivalence and a deterministic digest that must be equal in all
variants). Items 1, 4 and 5 are the risky ones.