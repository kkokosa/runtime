# Laxori for CoreCLR: design

Status: design for the `gc_laxori` collector. Section 10 lists the milestones M0, M1 and M2. The file `STATUS.md` in this
folder says which of them are built and tested, and what is not verified. This text was written from the code of
`src/coreclr/gc_lxr` (our LXR port) and `src/coreclr/gc_satori` (our Satori port) in this repository, and from the
description of Laxori that the author gave. It does not use any code of other runtimes.

## 1. What Laxori is

Laxori is a standalone GC (`libclrlaxorigc.so`, loaded with `DOTNET_GCPath`) that combines two ideas:

* From Satori: allocation inside a **request-private region**. Objects of one request live in a region that only that
  request can reach. While they stay private, they cost no barrier slow path and no reference counting. When the request
  ends and nothing escaped, the region is reused at once. No trace, no pause.
* From LXR: **reference counting and block reclamation for the shared heap**. Only what is shared, or what survives a
  pause, pays for LXR bookkeeping (field logging, increments, decrements, line/block reuse, cycle recovery).

`gc_laxori` is a new collector with new files. Its engine (Immix blocks, side metadata, reference counts, work packets,
pause coordinator, finalizer registry, large object space) is a renamed copy of the engine in `gc_lxr`. The request-private
layer is new code on top. `gc_lxr` and `gc_satori` are not changed.

### Why the LXR engine is the base and not Satori

The Satori port is a generational, region-based mark-and-sweep collector with its own allocation contexts, its own write
barrier (card marking) and its own thread-local gen0 GC. The LXR port already has what Laxori needs for the shared heap
(items f to i) and an allocation model that fits a private region (items a and b). The mutator allocates in a *buffer* of
a 32 KiB Immix block. The JIT helpers bump `alloc_ptr` in that buffer. The engine learns about young objects only from
*spans* (the used part of a buffer) when the buffer is retired. Young objects have no reference count and no log bit until
a pause finds them alive. That is the same life cycle as "private objects pay nothing". To move the Satori region logic into
the LXR engine is a smaller and safer change than the other direction. From Satori we take the **idea and the invariants**
(owner table, escape publication, bulk retirement). The Satori source is the reference for how a thread-local region is
handed out and retired.

## 2. Mapping of the concepts (a) to (i)

| # | Laxori concept | What it is in this .NET implementation |
|---|---|---|
| a | request-private 64 KiB TLAB regions | one **32 KiB Immix block** per thread that is inside a request (the block size of the LXR engine; all side metadata planes are per block). One private region per thread at a time. |
| b | inline bump allocation | the region is given to the thread as its `gc_alloc_context` buffer (`alloc_ptr`/`alloc_limit`). The stock JIT/R2R helpers bump it. No call into the GC, no count. LXR already hands out buffers in this way. |
| c | owner-table write barrier | a **block table**, one byte per Immix block (`1` = private, `0` = shared), read by the assembly barrier. The barrier is `LaxoriAssignRef`/`LaxoriCheckedAssignRef` (a copy of the LXR barrier with the table check added). |
| d | escape publication | the store slow path `LaxoriEscapeSlowPath` runs when a reference to a private object is stored into a place that is not private. It *publishes the region* (section 6). |
| e | O(1) bulk retirement | `GC_Laxori_EndRequest`: if the region did not escape, the cursor goes back to the start of the block and the used bytes are zeroed. No trace, no pause, no list walk. |
| f | escape-only RC | the LXR engine counts only objects that a pause finds alive (young survivors) and mature objects whose fields are logged. A private object never gets a count. A published region is an ordinary young span. |
| g | deferred roots, coalesced RC | inherited from the LXR engine without change (unlog bit per field, one log per field and epoch, increments and decrements applied in a pause, root reconciliation in the next pause). |
| h | zero-count reclamation | inherited: lazy decrements, dead-line detection, line/hole recycling, whole-block release (`ReleaseEpoch`, lazy sweep). A published region whose objects all died is freed as a clean nursery block at the next pause. |
| i | cycle recovery | **The LXR port does not use trial deletion.** It reclaims cycles with the SATB concurrent trace (`BeginTrace`, `FinalMark`, dead-cycle sweep). Laxori keeps this for the shared heap. Bounded trial deletion is future work and is not part of M0 to M2. |

## 3. What "request" means for .NET

.NET has no request object, and no new public API is allowed. The GC cannot find the end of a request by itself: it cannot
know that no reference from a stack frame to a private object is left. So the *program* tells the GC, through an internal
mechanism.

**Decision.** A request is a **thread-affine, explicitly delimited scope**:

* `GC_Laxori_BeginRequest()` is called on the thread that starts the scope.
* `GC_Laxori_EndRequest(void* result)` is called on the *same* thread when the scope has finished. `result` can be null.
  If it is not null, its region is published first, so a handler can return a result object.
* Both are **exported symbols of `libclrlaxorigc.so`** (like `GC_LxrPrototype_GetMetric`). A driver finds them with
  `NativeLibrary.TryGetExport` and calls them through `delegate* unmanaged[SuppressGCTransition]`. The thread then stays in
  cooperative mode, so a pause cannot start while the hook changes the allocation context. A hook never allocates and never
  waits for a GC.
* `DOTNET_LAXORIRequests=0` (the default) makes the hooks no-ops. The collector then behaves as the LXR that it was copied
  from. The CMake option `CLR_CMAKE_ENABLE_LAXORI_GC` is off by default, so no build contains Laxori unless asked.
* Scopes do not nest. A `BeginRequest` on a thread that is in a request ends the first request as "escaped".

Why this choice:

* **A thread or async-flow epoch** (for example `AsyncLocal`/`ExecutionContext`) needs the runtime to tell the GC when an
  async continuation moves to another thread. That is a runtime change. A continuation on another thread would also touch
  the region from two threads and break invariant I1 (section 5).
* **An environment switch alone** (all allocation of a thread is private, always) has no point where a region can be retired
  without a trace. That is the thread-local gen0 GC of Satori, a different collector.
* An explicit scope with an exported hook is internal (no new public API), cheap, and exactly as safe as its contract:
  *"at `EndRequest`, no stack slot, register or heap location outside the request refers to a request object, except
  `result`."* The heap part of this contract is checked by the barrier (an escaping store publishes the region). The stack
  part is the promise of the caller. In Satori the stack roots are scanned instead. A debug check of the promise is in the risks.

Async code is outside M1: a request that awaits can resume on another thread. It must call `EndRequest` before it awaits
(or its state machine escapes, which publishes the region). The first users are a synchronous handler, or a work item on a
pool thread.

## 4. Identifying a private region in O(1)

* The Immix arena is one contiguous reservation. For an address `a` in it, the block number is `(a - arenaBase) >> 15`.
* `blockTable[block]` is one byte. `1` means "private: the block is the request region of one thread". `0` means shared. The
  table is a reserved array (the OS commits it on first touch) with one byte per possible block of the reservation. It is
  allocated at heap start. Its address, the arena base and the arena size are patched into the barrier through the
  `GCWriteBarrierPatchableValue` slots (the mechanism that the LXR barrier uses for its metadata base).
* The table does not say which thread owns a private block. A private block can be reached only by its owner (I1). The owner
  keeps the block address in its `LaxoriRcMutator`.
* **Published is a property of the block.** The table byte is cleared when the region is published. There is no per-object
  bit. This is coarser than a per-object bit, and it makes publication cheap (section 6).

## 5. The invariants

* I1. A private region is referenced only from the stack and registers of its owner thread, and from objects of the same region.
* I2. A thread has at most one private region at a time.
* I3. A store of a reference `r` into a field `f`: if the block of `f` is private, the store needs no log and no check
  (it is a store inside request-private data). Otherwise, if the block of `r` is private, the region of `r` is published
  before the store. Otherwise the normal LXR log-before-write check applies.
* I4. A region that is published stays shared. The next allocation of the thread takes a new private region.

Why I1 holds: a reference leaves the stack, the registers and the region of the owner only in one of these ways. (1) A store
through a barrier (I3). (2) A store by the runtime (`pre_store` callback, bulk move callback). (3) A GC handle. (4) The
finalizer registry or the finalizer queue. (5) The sync block table. Section 7 handles each of them. I2 makes the closure
simple. When region R is published, no other private region of the thread exists that R could reach: an older region was
published when the thread needed a new block, and a younger region does not exist yet. A reference from R to a later object
is made by a store into a block that is not private, so I3 publishes the younger region.

## 6. The write barrier and the escape slow path

The Linux x64 barrier block is `amd64/laxori_writebarrier.S`. Paths of the new helper:

```
dst in a private block                               : load table byte of dst, test, branch -> plain store
dst not private, ref not in a private block          : two table loads, then the LXR unlog-bit check
ref null or outside the arena                        : the ref table load is skipped
ref in a private block, dst not private              : LaxoriEscapeSlowPath(dst, ref), then the LXR unlog check, then the store
```

A store into a private object costs less than an LXR store into a young object (it does not read the metadata plane). A
store into a shared object costs about six instructions and one cache-resident byte load more than in LXR. There is no
per-object "published bit" to test.

`LaxoriEscapeSlowPath(dst, ref)` runs with the vector state saved, as the LXR slow path does:

1. Find the mutator of the thread. Check that `ref` is in the private block of this mutator.
2. `PublishRegion(mutator)`:
   * retire the thread's allocation buffer (synchronise the cursor);
   * close the span `[regionStart, cursor)` and push it on the span list of the mutator (the *same* list that ordinary LXR
     spans use);
   * clear the block table byte and give the block back to the engine (`ImmixBumpAllocator::Reset`). The block is now an
     ordinary young block with a span, the same as a block that LXR retired at the end of a hole;
   * set the buffer of the thread to "none", so that the next allocation calls `Alloc`, which takes a new private block.

Publication is O(1). The "transitive publication" of the description is done by the invariants and not by a graph walk: all
objects of the region become shared together, and every object that they point to is in the same region (I1) or is already
shared. The price is that one escaping object makes the whole region (up to 32 KiB of request data, dead objects included)
a shared young span. A pause then finds the dead objects dead (a young object that no increment reaches costs nothing, and a
block with no survivor is released whole).

The slow path does **not** change reference counts. Published objects are young, so they have no count. The LXR pause gives
them counts when it finds them from roots or from logged fields. This is the lazy form of "publication commit": the first
pause after the escape is the commit.

## 7. Everything else that can carry a reference out of a request

| Path | How Laxori sees it |
|---|---|
| JIT/R2R reference stores (`CORINFO_HELP_ASSIGN_REF`, `CHECKED_ASSIGN_REF`) | the barrier above. The runtime already runs with `FASTGC_REQUIRES_OLD_VALUE` for an LXR-style collector, so the JIT emits the helper for **every** reference store, also for null and frozen values. |
| struct copies with references, `Array.Copy`, `Buffer.BulkMove*` | the `bulk_move_with_write_barrier` callback. In a request, when the destination block is not private, the callback scans the **source words** for addresses inside the private block. It does not need to know which words are references. A false hit publishes a region early; it is never unsafe. |
| `Interlocked.CompareExchange`/`Exchange`, runtime stores, `ZeroMemoryInGCHeap` | the `pre_store(dst, ref)` callback of `FastGCFunctions`. The runtime calls it before every runtime store and CAS attempt. Laxori adds the destination/reference test there. |
| GC handles (strong, weak short/long, dependent, pinned, ref-counted, `GCHandle.Alloc`) | Laxori has its own `IGCHandleManager` wrapper (a copy of `gchandletable.cpp` with one hook). Every `CreateHandleOf*`, `StoreObjectInHandle` and `SetDependentHandleSecondary` call `EscapeObject(obj)`. A weak handle also publishes: a weak handle must not see an object die by bulk retirement. |
| finalizable objects (`GC_ALLOC_FINALIZE`) | `Alloc` does not allocate a finalizable object in the request region. It goes to the shared allocator (the finalizer registry is a root). `GC.ReRegisterForFinalize` calls `RegisterForFinalization(obj)`, which publishes. |
| statics and thread statics | their storage is a managed array or a field of an object in the shared heap. The store goes through the barrier, so it publishes. |
| sync blocks (`lock` with contention, `Monitor.Wait`, hash code plus lock) | the sync block table holds a raw pointer to the object. **M1 does not detect this.** A thread-private object cannot be contended, so only the combination "hash code, then `lock`" (or `Monitor.Wait`, which needs a second thread) creates a sync block for it. A linear walk of the object headers at `EndRequest` would detect it, but it costs O(objects) per request, so it was not built. See the risks. |
| interior pointers, `Span<T>`, `ref` locals | stack only: inside the stack contract of `EndRequest`. At a pause, the normal stack scan finds them (a private region is an ordinary young span at a pause). |
| pinning (`fixed`, `GCHandle.Alloc(Pinned)`, pinned object heap) | `fixed` is a stack pin (same contract). A pinned handle publishes. Objects for the pinned object heap (`GC_ALLOC_PINNED_OBJECT_HEAP`) are never allocated in a request region. |
| large objects and arrays of 8 KiB or more | allocated by the shared allocator (large object space from 32 KiB; shared Immix below that). A store of a private reference into them is a store into a shared object, so it publishes. |
| thread exit inside a request | `FixAllocContext` (the thread-detach callback) publishes the region before it detaches the mutator. |
| a pause in the middle of a request | every pause **dissolves** all private regions. `FlushMutators` closes their spans like the spans of ordinary buffers, clears the block table and returns the blocks. What is alive is found by the normal stack scan and counted. The request goes on: its next allocation takes a new private region. |
| cross-thread reference | a request region is not reachable from another thread (I1). A reference that leaves it passes one of the paths above and publishes. |
| exceptions | the runtime keeps thrown objects in GC handles: strong handle, publish. |
| `GC.Collect`, allocation counters | a user `GC.Collect` is a pause (it dissolves regions). Allocation counters follow the LXR accounting: a buffer is counted when handed out and the unused tail is subtracted when it is retired. After a bulk retirement the region is accounted as a new buffer. |

## 8. Reclamation, cycles and the pause

* A private region that is retired in O(1) is never seen by the engine: no span is pushed, no counts, no log. A block that is
  taken during a trace has its object mark bits set for the whole block when it is prepared (objects are allocated black). A
  reused region keeps that state. This is conservative.
* The memory that the engine gives out is zero. `EndRequest` zeroes the used prefix `[start, cursor)` (the engine itself zeroes
  the whole 32 KiB when it acquires a block). So bulk retirement is O(1) for the accounting (cursor reset) and O(bytes used)
  for the zeroing, which is a `memset` of cache-hot memory. This is the one place where "O(1)" is not literally true here.
* A published region is a normal span. The pause treats it as young: survivors get counts (and the engine may copy them), the
  rest dies with the block.
* Shared cycles: the SATB trace of the LXR engine (inherited).

## 9. Risks

1. **The stack contract of `EndRequest`.** A live reference from a stack frame to a request object after `EndRequest` is a
   dangling reference after the region is reused. This is a program error, like an escaping `Span<T>`. A debug mode that
   poisons the retired region and keeps it out of the pool for one pause would find it. It is not part of M1.
2. **Sync blocks and other native tables with raw object pointers** (section 7). M1 does not check them. A request object that
   gets a sync block (hash code, then `lock`) and is then retired leaves a stale pointer in the sync block table. Not tested.
3. **False publication.** The slow path is cheap, but a request that stores every object into a shared structure publishes its
   region each time, loses the benefit, and pays one block acquisition (a 32 KiB memset) each time.
4. **Barrier cost** for stores into shared objects: a few instructions more than in LXR.
5. **Region granularity.** A published region keeps up to 32 KiB of dead objects until the next pause. A request that needs
   more than one block publishes each block when it is full (I2), so O(1) retirement works only for the last block.
6. **Async code** is not supported inside a request (section 3).
7. **Linux x64 only.** The Windows barrier is not ported.
8. **A conservative scan of bulk copies** can publish a region for a word that only looks like an address.
9. **The JIT must route all reference stores through the helpers.** R2R code of the frame must be built with
   `CrossgenOldValueWriteBarriers=true` (R2R code without the flag is rejected). A store that bypasses the helpers would bypass
   escape detection. LXR makes the same assumption for its log.
10. **The hooks write `ee_alloc_context::m_CombinedLimit`.** The runtime's inline allocation helpers test this field (the
   pointer-sized field just before the `gc_alloc_context`), not `alloc_limit`. The runtime refreshes it after every `Alloc`
   call, but the request hooks and the escape slow path change the buffer outside `Alloc`. Laxori therefore writes the field
   itself (`SetCombinedLimit` in `laxori_gc.cpp`). This relies on the layout in `vm/gcheaputilities.h`. A better interface would
   be a callback of the EE (an addition to `IGCToCLR`); that is future work.
11. **The mutator count.** The engine admits 1024 simultaneous contexts (inherited from LXR). The thread-exit hook must run for
   each exiting thread (it does: `FixAllocContext`).

## 10. Milestones

* **M0 (scaffold).** `gc_laxori` builds (`-component clrlaxorigc`), loads through `DOTNET_GCPath`, exports `GC_Laxori_GetMetric`
  (and `GC_LxrPrototype_GetMetric`, so the existing driver works) and runs the six benchmark workloads. Its behaviour equals LXR
  (renamed copy). No request hooks.
* **M1 (private regions).** Request hooks, block table, `LaxoriAssignRef` barrier, region allocation, publication, bulk
  retirement, handle wrapper, pause dissolution. RC only for published and surviving objects. Selected with
  `DOTNET_LAXORIRequests=1`.
* **M2 (shared reclamation).** Tests of the interaction between published regions and the LXR block reclamation and cycle
  recovery (cyclic shared graphs that come from published request data). No new mechanism is planned: the engine already
  reclaims blocks and cycles.

The state of each milestone, the tests that were run, and what is **not** verified, are in `STATUS.md` in this folder.
