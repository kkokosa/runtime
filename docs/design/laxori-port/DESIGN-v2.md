# Laxori for CoreCLR: design v2 (thread-local GCs over a global LXR heap)

This text replaces `DESIGN.md` (v1, request based; it stays in git history and is called "M1" below). Status of the work
is in `STATUS.md`. The design was written from the code of `src/coreclr/gc_lxr` (our LXR port, engine re-synced with
`lxr-gc-review` 3db3b488e29), `src/coreclr/gc_satori` (our Satori port) and `src/coreclr/gc_laxori` (the M1 prototype).

## 1. Intent

The user's decision: Laxori is **our Satori plus our LXR**. It is not a copy of any other runtime's "private request region".

* Every thread allocates automatically into a **thread-owned, escape-tracked private region** (Satori: `IsEscapeTracking`,
  `StartEscapeTrackingRelease`). There is no request concept and no hook in the main path.
* Escape tracking is **per object** (Satori: `SatoriRegion::EscapeRecursively`, `EscapeFn`, `SetExposed`). A store of a
  private reference into a place that is not private escapes the target and everything that it reaches inside the region,
  not the whole region. When the escaped size is above a limit (Satori: region size / 4), tracking stops and the region
  goes to the shared heap.
* When a private region is full, the **allocating thread collects it alone** (Satori `ThreadLocalCollect`, `Mark`,
  `Plan`, `UpdatePointers`, `Compact`). Roots are the stack of this thread (`GCToEEInterface::GcScanCurrentStackRoots`)
  and the escaped objects. Escaped and pinned objects do not move. Movable survivors slide to the start of the region.
  Gaps are dead space (see section 6). The collection is skipped when the survivors are more than region/8. It does not stop
  other threads.
* The **shared heap is the LXR engine** (field logging, counts, SATB trace, block reclamation, nursery and mature copying,
  large object space). An LXR pause treats a private region as a set of young objects. After the pause the thread starts
  with an empty region ("a pause dissolves private regions").

M1 (explicit `BeginRequest`/`EndRequest`, whole-block publication, no thread-local collection) is a prototype. In v2 its
hooks are not in the default path. Its tests may call them if a test needs a fixed scope.

## 2. Tiers and the invariants

```
 private tier  : regions owned by one thread. Metadata: owner table, private bitmap, first-object index (section 4).
                 Objects have no LXR metadata at all (no count, no ValidObject bit, unlog bits are 0).
 shared tier   : the LXR engine. Young objects are objects of spans. A pause gives them counts.
```

* **I1.** An object of a private region is referenced only from (a) the stack and the registers of the owner thread,
  (b) other objects of the same region, (c) escaped objects (those are reachable from outside, by definition).
* **I2.** Everything that is reachable from an escaped object of region R is escaped, or is not in R.
* **I3.** An escaped object never moves in a thread-local GC. A slot of an escaped object is "exposed": a store of a
  private reference into it escapes the stored object.
* **I4.** A thread owns at most one private region at a time.
* **I5.** A region does not live across an LXR pause. A pause "dissolves" every region: its used part becomes a young span
  of the engine. (Section 6, item "dissolve".)
* **I6.** Memory that is handed out for allocation is zero (the runtime allocation helpers assume it).

Why I1 and I2 hold is the same argument as in Satori: a reference leaves the owner only by a store into the heap (the
barrier, the bulk-copy callback, the `pre_store` callback), by a GC handle, or through the finalizer machinery. Each of
these escapes the target (section 7).

## 3. Region size

The LXR block manager gives 32 KiB blocks (`ImmixBlockGeometry::BlockBytes`), 256 B lines. A private region needs
contiguous memory, because the sliding compaction, the first-object index and the "same region" test of the barrier use
addresses. So a region is a **run of N aligned blocks** (N a power of two). The block manager gets one new operation,
`AcquireRun(owner, N)`: take N aligned adjacent clean blocks with the same acquire rule as `AcquireBlock`, and give all of
them back when one fails.

| region | stack scan per collection (about 5 to 20 us) as a part of the fill time at 1 GB/s | fits L2 (1 to 2 MiB) | survivors limit (R/8) | bitmap + index | per thread memory | comment |
|---|---|---|---|---|---|---|
| 32 KiB (1 block) | 15 to 60 % | yes | 4 KiB | 0.5 KiB + 64 B | 32 KiB | too small. A tree of 100 objects or one stack frame with a few lists is above the limit. The fixed cost of a collection is larger than the work. Escape limit 8 KiB is hit by a few escapes. |
| 128 KiB (4 blocks) | 4 to 15 % | yes | 16 KiB | 2 KiB + 256 B | 128 KiB | usable. |
| **256 KiB (8 blocks)** | 2 to 8 % | yes | 32 KiB | 4 KiB + 512 B | 256 KiB | **default until measured.** |
| 2 MiB (64 blocks, Satori size) | under 1 % | no (cold after the fill) | 256 KiB | 32 KiB + 4 KiB | 2 MiB | amortizes best. Many threads hold a lot of memory (1000 threads: 2 GiB). The block run is hard to find in a fragmented 8 MiB arena. |

The region size is a setting (`DOTNET_LAXORIRegionKB`, a power of two from 32 to 4096) and the barrier reads its shift from a
patchable slot. L1 measures 32, 128, 256, 512 and 2048 KiB on the six workloads and `STATUS.md` records the result.
The largest object that goes into a region is `min(8 KiB, R/8)`. Larger objects use the shared allocator (the LXR medium
allocator and the large object space).

## 4. Metadata of the private tier

LXR planes are **not** used for private objects (the user's analysis, confirmed in the code): a young object has no count, no
ValidObject bit and its unlog bits are 0 (`immix_allocation.cpp`, `InitializeFieldLogRange` at hand-out). LXR metadata appears
when a pause promotes an object (`MarkPromotedStart`). So the private tier has its own, Satori-style metadata. All of it is
indexed by address, so it is not stored in a region header (an Immix block is full of objects):

| name | shape | meaning |
|---|---|---|
| `region_owner[block]` | one 8-byte word for each 32 KiB block of the reservation | the owner tag (the value of `fs:0` of the owner thread) while the block is in a region that is escape-tracked, 0 otherwise. All N blocks of a region hold the tag. The barrier reads one entry. Overhead 0.024 %. |
| `private_bits` | 1 bit for each 8 bytes of the Immix reservation (like the unlog plane: byte `a >> 6`, bit `(a >> 3) & 7`) | 3 bits per object at its object address `o`: **Marked** at `o`, **Escaped** at `o + 8`, **Pinned** at `o + 16` (the minimum object size is 24 bytes, so the bits never meet the next object). A slot address that is **exposed** uses the Marked bit of the slot, as in Satori. For a first reference field the exposed bit and the Escaped bit of the object are the same bit, which is the meaning "the whole object is escaped". Overhead 1.6 %. Cleared when a region is taken. |
| `private_index[a >> 11]` | one 32-bit offset for each 2 KiB (Satori `INDEX_GRANULARITY_BITS = 11`) | the offset from the region start of an object that starts at or before this 2 KiB granule. Filled lazily by `FindObject` (walk from the previous entry) and by the compaction. Used to resolve interior pointers of stack roots (`GC_CALL_INTERIOR`) and the exposed test of bulk copies. Overhead 0.2 %. |
| `PrivateRegion` (array, one for each region slot) | owner tag, start, size, cursor, `escaped_size`, `alloc_bytes_at_collect`, `mark_stack` (offset), counters | the state of a region. A thread has the pointer in its mutator. |
| object header | the 32-bit "align pad" at `o - 8` | the mark-stack link while marking and the relocation distance while compacting (Satori `GetNextInLocalMarkStack`, `GetLocalReloc`). LXR does not use it (it uses 2 bits of the sync-block value, mask 0x3). |

The metadata of the shared tier (ReferenceCount, FieldUnlogged, ValidObject, straddle, ObjectMark) is **not touched** by the
private tier, with one exception: a block that is taken while an LXR trace runs gets its ObjectMark bits set for the whole
block (black allocation). This is done by the same `PrepareFreshBlock` as today and is correct (section 6, item b).

## 5. The write barrier

`rdi` = destination slot, `rsi` = new reference. The helper is the LXR helper (old-value logging, SATB, shared heap)
with a private check in front. In the table, "extra" is the cost over the LXR helper of M1.

```
AssignRef(dst, src):
  rax = src - heap_low ; if rax >= heap_size            -> NotPrivate     ; null, frozen, outside heap
  rax >>= 15 ; rdx = region_owner[rax]
  if rdx != fs:0                                         -> NotPrivate     ; shared or somebody else's
  ; the source object is in my region
  if ((dst ^ src) >> region_shift) != 0                  -> Escape         ; the destination is in another region, shared, or not heap
  if exposed(dst)                                        -> Escape         ; bit (dst >> 3) of private_bits
  *dst = src ; return                                                        ; private to private: no log, no count, no card
Escape:   call EscapeSlowPath(dst, src)   ; EscapeRecursively; may StopEscapeTracking = dissolve; then ->NotPrivate
NotPrivate:  the LXR check: unlog bit of dst. clear: store. set: LxrBarrierSlowPath (logs the old value), store.
```

| store | what it costs |
|---|---|
| any store, source is null, frozen or outside the heap | 3 extra instructions (the range test), then the LXR path. |
| source is a shared object (the common case for the stores of old data) | + one dependent 8-byte load from `region_owner` (cache-resident: 8 bytes per 32 KiB), `fs:0` load and compare, taken branch: about 6 extra instructions. Then the LXR path. |
| destination private (my region), source private, same region, not exposed | no unlog check, no log. Cheaper than the LXR path of the same store. |
| destination private, source shared or null | the LXR path. The unlog bit of a young slot is 0, so it is a plain store. (A private object's slot is never logged.) |
| source private, destination shared or exposed | the slow path: `EscapeRecursively` marks the object and everything in the region that it reaches (cost proportional to the escaped graph, once per object), sets the exposed bits of its reference slots, then the LXR path. |

`fs:0` is used as the thread tag, as in the Satori barrier of this repository. `PreStore` (runtime stores, CAS) does the
same test in C++. The bulk-move callback escapes precisely: for every reference slot of the destination range (layout of the
destination object, as `LogOldReferences` already does) the source word is a reference; a private one escapes. When the
destination is private and not exposed there is nothing to do.

## 6. Algorithms

### Allocation

The region is the `gc_alloc_context` buffer of the thread (`[alloc_ptr, alloc_limit)` is the rest of the region), so the
inline helpers bump a pointer. `ee_alloc_context::m_CombinedLimit` is updated with it (the layout rule of risk 10 of v1,
still valid). `Alloc` is called when the object does not fit, or when it needs the slow path:

1. finalizable, pinned-object-heap, user-old-heap, larger than the object limit: the shared allocator (the LXR engine
   allocates it; the private buffer is not retired and not touched).
2. the buffer is full: `ThreadLocalCollect` (below). If it freed enough room, allocate. Otherwise **dissolve** the region
   (hand it to the engine as a young span, clear its `region_owner` entries, return its blocks) and take a new region.
3. the thread has no region: `AcquireRun`, prepare every block (`PrepareFreshBlock`: zero, unlog bits 0, ObjectMark by the
   marking state), clear `private_bits` and `private_index` of the range, publish the tag in `region_owner`.

### Escape (`EscapeRecursively`)

As Satori, on `private_bits`, using the mark-stack link in the header: set Escaped on the object, push; for each object popped,
for each reference slot: set the exposed bit of the slot, and for a target in the same region that is not escaped, set it escaped
and push it. `escaped_size` grows by the object size. When `escaped_size > region/4`: `StopEscapeTracking` = dissolve.

### Thread-local collection (`ThreadLocalCollect`, on the allocating thread, no stop-the-world)

Skipped (the region is dissolved instead) when `escaped_size > region/4`, or when less than `region/4` was allocated since the last
collection of this region (the last one did not buy enough).

1. **Mark.** Every Escaped bit sets its Marked bit (bit scan of the bitmap). Then `GcScanCurrentStackRoots` with `MarkFn`: a root
   outside the region is ignored; `GC_CALL_INTERIOR` resolves the object with `FindObject` (index); `GC_CALL_PINNED` sets Pinned
   unless the object is escaped. Propagate with the mark stack. Stop when survivors are more than `region/8` (undo, no change).
2. **Plan.** Walk the marked objects in address order and slide the movable ones (not Escaped, not Pinned, no sync-block index)
   to the lowest free address, skipping unmovable objects. The relocation distance goes to the header. Two rules came out of the
   implementation (see "Layout rule: an object never crosses a block" below): an object never lands across a block boundary
   (it goes to the start of the next block, or stays where it is if that address is not below its source), and the space between
   two objects is recorded as a **gap** (a dead range inside one block, any size), not formatted as a free object. L1 collects only
   a region with no escaped object (a pinned object is unmovable and creates a gap); L2 also collects regions with escaped objects, which stay in place.
3. **Update.** `GcScanCurrentStackRoots` with `UpdateFn`; then every marked object's reference slots that point into the region
   (objects outside the region cannot refer to a movable object by I2).
4. **Compact.** `memmove` runs with the same distance (the header word moves with the object). Clear Marked and Pinned, keep
   Escaped. Reset the index.
5. **Reopen.** The planned gaps replace the old gap list. They are opened one after another as the runtime buffer; a gap is
   zeroed when it is opened (a gap of a new region is zero already) and a gap under 1 KiB is not opened. The cost of the zeroing is
   the garbage that the collection found. Unused gaps stay dead until the pause.

### Layout rule: an object never crosses a block (found in L1, 8 threads, region > 32 KiB)

The Immix engine promotes in place and sweeps **by the block of the object start**. An object that starts in block *b* and ends in
block *b+1* leaves *b+1* without a live object that starts in it, so the pause releases *b+1* while the tail of the object still
lives there. With one-block regions this cannot happen, and the first implementation (one parsable gap per region, objects
across blocks) failed only at region sizes above 32 KiB, at 4 and more threads (`graph` test: 50 to 100 percent of the runs,
with null method tables and non-pointer values in reference fields found by the pause).

The rules now:

1. a buffer is never longer than one block (a gap is inside one block), so the runtime bump allocator cannot cross a boundary;
2. the plan never puts a movable object across a boundary;
3. a dead range can have any size, because it is not parsed. The free-object format needs 24 bytes, and a leftover of 8 or 16 bytes at
   the end of a block (the common case for a 24 to 64 byte object) cannot be formatted. So **gaps are a list**
   (`LaxoriPrivateRegion::gaps`, sorted, disjoint) and the engine gets **one span for each stretch of live objects** (the region
   without its gaps), so the engine never reads dead memory (`CloseRegionSpan`);
4. `FindObject` (interior pointers) walks the objects of a stretch and steps over the gaps.

Free objects (`g_gc_pFreeObjectMethodTable`) are no longer used by the private tier.

### Dissolve (the pause and the "region is full and not collectable" case)

`FlushMutators` already closes every span. A region gives one span for each stretch of live objects (the region without its gaps, so
every span is a sequence of complete objects, with escaped objects in place). Nothing else is done: the clean-nursery-block rule of the
engine releases a block that no object promoted, and a survivor found by the stack scan gets its first increment and is copied or
promoted as any young object. `private_bits` and `region_owner` entries are cleared (the owner table first, so that no barrier
sees a stale tag). The blocks go back with `ReturnBlock` (engine) as in M1.

## 7. Handles, finalizers, pinning, threads

| path | what happens |
|---|---|
| GC handles (strong, weak, dependent, ref-counted, pinned, `GCHandle.Alloc`) | the handle-store wrapper calls `EscapeObject`: **per object** (closure inside the region), not the whole region. The handle table is not scanned by a thread-local collection, so the object must be unmovable and must not be reclaimed: that is exactly "escaped". A weak target is escaped too and lives until the LXR pause. |
| finalizable objects | allocated by the shared allocator (the finalizer registry is a root of the engine). `GC.ReRegisterForFinalize` and `RegisterForFinalization` escape the object. |
| pinning | `fixed` and pinned locals are stack roots with `GC_CALL_PINNED` (Pinned bit, unmovable, not escaped). A pinned handle escapes. Pinned-object-heap objects use the shared allocator. |
| statics, thread statics | stored in heap arrays: a store through the barrier, so the target escapes. |
| `ref`/byref and `Span<T>` | stack only. Interior roots resolve through the index. A byref to a heap field of a private object is a stack root. |
| exceptions | the runtime keeps a thrown object in a handle: it escapes. |
| sync blocks | **found in L2 and fixed**: the sync-block table of the runtime holds a raw pointer to every object that has a sync block (a `lock` after `GetHashCode`, or a contended `lock`) and only a pause updates it. A thread-local collection that reclaimed or moved such an object left a stale entry, which the next pause used as a root (null method table). The mark phase therefore walks the live stretches of the region (dead objects too, they are contiguous between gaps) and treats every object with a sync-block index as a pinned root: it stays and lives until the region is dissolved. Hash code only is stored in the header and moves with the object. Test: `sync` in `PrivateTests` (crashed in L2 mode before the fix, passes after). |
| thread exit | `FixAllocContext` dissolves the region before the mutator is detached. |
| another thread reads a private object | cannot happen (I1). A reference that goes to another thread was stored into the heap (escape) or into a handle (escape). |
| `GC.Collect`, `GetTotalAllocatedBytes` | a user `GC.Collect` is an LXR pause (dissolve). Allocation accounting follows the buffer rules of LXR: a buffer adds its size, the unused tail is subtracted when it is retired. A thread-local collection adds the newly opened tail. |

## 8. Interaction with every LXR phase (the consistency list)

* **(a) Parsable young spans.** The engine assumes a span is "a sequence of complete objects with no gaps"
  (`lxr_young_spans.h`). A private region gives the engine one span for each stretch of live objects, so every span is a sequence
  of complete objects (escaped objects in place are complete objects). Only `FindInYoungSpans` walks a span object by object. The
  nursery sweep and `ReleaseNurseryBatchQuiescent` do not walk objects. `CheckProbeInSpans` is a test probe. The block rule of
  section 6 (an object never crosses a block) is part of this invariant.
* **(b) Black allocation during a concurrent trace.** The engine sets ObjectMark for a whole block when it is taken while a trace
  runs. By I5 a region cannot live across the pause that starts or ends a trace, so all its blocks were taken in one marking state.
  A thread-local collection never changes ObjectMark. The trace never reaches a movable private object (I1, I2). It can reach an
  escaped one (a shared object refers to it): that object is black already and is not scanned, and it does not move. SATB
  logging: a slot of a young (private or escaped) object is not logged, as in LXR today.
* **(c) Nursery copying at a pause versus local relocation.** They never overlap: the pause is stop-the-world, the thread-local
  collection runs in cooperative mode on one thread, and the pause starts only after the thread reaches a safe point (the
  collection finishes before). Local forwarding data (the header pad) is cleared at the end of a collection. The engine writes the
  forwarding pointer into the first field of a source object, only in a pause.
* **(d) Unlog bits after reuse.** A thread-local collection does not touch the planes. The unlog bits of a region stay 0 (young). The
  slots that move carry no bit. After dissolve, the engine treats every slot of the span as young (bit 0), which is true.
* **(e) The old-value barrier (`FASTGC_REQUIRES_OLD_VALUE`).** Stores into private objects need no log (the barrier does not
  read the unlog plane for a private destination of a private source; for any other source the unlog bit is 0 anyway). Stores
  into shared objects keep the LXR slow path. The runtime still calls the barrier for every reference store (null included).
* **(f) Pinned and interior stack roots in the thread-local mark.** `MarkFn` as in Satori (section 6, step 1). The pinned bit
  keeps an object in place for one collection. A pinned object stays pinned only while it is a root.
* **Pause roots.** The LXR root scan of a pause reports the same stack roots as before. A root into a region is resolved by the
  span walk and gets its first increment. **Dead objects of a region are never visited.**
* **Heap limits and sizing.** A region counts as allocated young bytes only when it is dissolved (the span length). A
  thread-local collection does not take new blocks, so a workload that stays inside its regions causes fewer LXR pauses. The
  policy sees this as a lower allocation rate. (To be checked in the benchmark: the number of pauses.)
* **Diagnostics.** `DiagWalkHeap`, `GetContainingObject` between pauses do not see young objects, with or without Laxori.

## 9. The object-start metadata of the shared tier (options, not built in L1/L2)

The user may want a new implementation. The lookup stays behind **one function**, `LaxoriReferenceCounting::FindContainingObject`
(also the callers in `laxori_gc.cpp`), so it can be replaced.

| option | cost | invariants | verdict |
|---|---|---|---|
| **A. keep the ValidObject bitmap** (now) | one locked byte CAS per promoted object (`MarkPromotedStart`, only the first count); the plane is cleared at every block and hole hand-out (a `memset` of range/64); a lookup scans bits backward to the object start and checks the size, to filter stale bits | dead objects stay intact until their lines are reused; no filler objects; a bit is cleared before its range is reused | works, it is the baseline. |
| **B. parsable holes + first-object index** (Satori style) | at a sweep every free run of lines gets a free-object header (one store and a size per hole); at hand-out the hole is zero memory again (the allocator range is not parsable, as in Satori: `m_allocStart/m_allocEnd`). A per-block index of 16 entries (one for each 2 KiB) of the first object offset, filled lazily by the lookup. No per-object write at promotion. | the block is parsable except the allocation range; a free object covers every dead run; the index is cleared when a hole is handed out | removes the CAS and the stale-bit logic. Costs a header write per hole and needs the sweep to run before a lookup of that block. Interaction with the lazy sweep and with defragmentation needs a review. |
| **C. line hints** | one byte for each 256 B line = the offset of the first object that starts in the line; one plain store at promotion/copy (a racy store is safe if only the smallest value is kept); the lookup uses the hint of the nearest line and walks forward through intact objects | dead objects intact until reuse; hints cleared at hand-out | cheaper than A, no filler objects, but a walk over dead objects needs their method tables to stay valid (they do until reuse). Not built. |

L1 and L2 use option A unchanged. The private tier does not use any of these (it has the index of section 4).

## 10. Expected benefit (to be checked by the benchmark; no number is promised)

LXR already treats a dead young object as free (it is never visited) and zeroes a 32 KiB block when it hands it out. So Laxori
does not save the "cost of dead objects". What it can save: **LXR pauses and the work they cause** (the root scan, the promotion
of whatever is alive at that instant, the concurrent CPU of the workers: LXR uses 712 CPU ms for 477 of WKS on `requests`), and
it keeps the working set inside a region of 256 KiB (cache) instead of cycling through the nursery. What it costs: the barrier
(a few instructions on every reference store), the escape work, the stack scan of every thread-local collection, and the tail
zeroing.

| workload | what happens | expectation |
|---|---|---|
| `requests` | each request builds 24 items (about 4.4 KB) that die at the end of the request. Every eighth request stores a new `Entry` (about 0.5 KB) into a shared table. | **should gain**: the temporary lists never reach an LXR pause. Escapes are few and small (L2 keeps them in place; L1 would dissolve the region at every collection, and gives no gain). The CPU time should fall most. |
| `binarytrees` | a tree is built bottom-up and is alive during its construction and check. A tree of depth d is `2^(d+1)` nodes of 32 bytes (d=8: 16 KiB, d=12: 256 KiB, d=18: 16 MiB). Depths 4 to 18 step 2, equal allocation volume for each depth. | **partial gain.** With a 256 KiB region the survivors limit is 32 KiB: trees up to depth 9 (3 of the 8 levels, 3/8 of the allocation) are collectable. Trees above that survive entirely, the thread-local collection is skipped, and the region is dissolved: LXR works as today (+ barrier cost). With 2 MiB regions, depth up to 12 (5/8). The two big trees (depth 18, 19) are LXR only. |
| `listsuffix` | every new node is linked behind an old node of a list that is shared (an array of 8192 lists). | **no gain, a loss is likely**: every node escapes (the destination is shared or exposed), the region fills with escaped objects, the escape limit dissolves it. The cost is the slow path per store plus the region churn. |
| `mixedmedium` | objects of 512 B to 16 KiB stored into a shared array. | **little or no gain.** Objects above 8 KiB bypass the region. The rest escape when stored. |
| `losarrays`, `mediumarrays` | large and medium arrays. | no gain (arrays above the limit go to the engine). Only the barrier cost. `mediumarrays` fails in the LXR base for a memory reason. |

## 11. Milestones

* **L0** (done): the engine copy re-synced with `lxr-gc-review` 3db3b488e29; the native engine tests of LXR, renamed, pass (10 programs).
* **L1**: automatic private regions, owner table, private bitmap, per-object escape, the new barrier, thread-local mark/plan/
  update/compact for a region with no escaped and no pinned object, stack roots only; the dissolve path; the shared tier unchanged; the
  request hooks removed from the default path. Tests: native (barrier, escape closure, thread-local collection with mutation checks) and
  managed (stores, arrays, struct copies, `Array.Copy`, CAS, handles, finalizers, thread exit, `GC.Collect` inside, deep graphs, sync).
* **L2**: escaped objects stay in place, regions with escapes are reused, the plan skips unmovable objects, the escape limit.
* **Benchmarks**, **crash hunts** (at least 100 runs per milestone at 13/3, 4/2 and 1/1 workers), **perf profile** of the program
  thread, **pause statistics**.

Laxori stays off by default: CMake option `CLR_CMAKE_ENABLE_LAXORI_GC` OFF, and it runs only with `DOTNET_GCPath`.

## 12. Risks

1. **Stack scan cost** of a thread-local collection (deep stacks, many frames): measured in L1; the region size is the lever.
2. **Barrier cost** on every reference store; measured with a micro benchmark and in the profile.
3. **Sync blocks** and other native tables that hold raw object pointers (section 7).
4. **`GcScanCurrentStackRoots` inside `Alloc`** works in Satori in this runtime. The frame of the allocation helper must report no
   stale object. To be checked by the mutation tests.
5. **Free objects in a span** reach engine code that expects live objects only (section 8, a).
6. **Block runs** may not be available in a fragmented small arena: fall back to a smaller region, then to the shared allocator.
7. **Handles to private objects** hold raw pointers: handled only by escaping at creation. A handle created by code that does not
   go through the handle wrapper would be a stale pointer.
8. **R2R and the JIT** must route every reference store through the helpers (`CrossgenOldValueWriteBarriers=true`); a store that
   bypasses them bypasses escape tracking.
9. Linux x64 only (the barrier is assembly).
