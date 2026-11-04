# P32: locked operations and cold loads per surviving object (LXR)

Base: `lxr-gc-review` at `a3a225d40a9` (count-plane object starts, the P31 default). Default configuration (2-bit counts, nursery
evacuation, 13 workers), Release, Linux x64. Profile: WSL2, perf `cpu-clock` (no hardware counters), `listsuffix 8192 600000`.

## (a) Locked operations on the mature path

"Locked" means a `lock`-prefixed instruction (`lock cmpxchg`, `lock xadd`, `xchg` with memory). A locked instruction is also a full
barrier: loads that come after it cannot start before it has drained the earlier stores and loads, so the misses around it do not
overlap. That is why a profile puts the cost of a miss that comes before the instruction on the `lock cmpxchg` itself.

Counts per object, from the code at `a3a225d40a9`. "Needed" = a plain or relaxed form would be wrong or would give no benefit.

### Increment (`ProcessIncrement`, `ScanIncrements`)

| Case | Locked operation | Needed? |
|---|---|---|
| Young object, promoted in place (about 80% of the survivors of `listsuffix`) | 1: `IncrementSaturating` (`lock cmpxchg` on the count byte) | Yes. One count byte holds the entries of up to four objects (2 bits for 8 bytes), several workers can count the same object, and the count saturates, so neither a plain store nor `lock add` is correct. |
| Same, first object of a nursery block | `TryPromoteInPlace`: 2 `lock xadd` (operation stripe), 2-3 `lock cmpxchg` (block lock, state) | Yes. Once per block and pause, not per object: after the first promotion `IsNurseryFast` is false for the block and the later objects do not call it. |
| Young object, copied | 5: claim of the source header (`lock cmpxchg`), count of the copy (`lock cmpxchg`), **header bits of the copy reset to 0 (`lock cmpxchg`)**, **forwarding pointer (`xchg`)**, state 3 of the source (`lock cmpxchg`) | Claim: yes (ClaimAndPublish). Count of the copy: yes (the byte is shared with a published neighbour). State 3: yes, it is the publication and the full barrier. The two bold ones are not needed: see C1 and C2 below. |
| Old child counted by its parent (`ScanIncrements`) | 1: count (`lock cmpxchg`) | Yes (same reason as the first row). |
| `ProcessIncrementWork`, logged slot | 1: unlog bit (`Store` = CAS loop on a byte of 8 bits that cover 8 slots) | Yes. `lock or` would be the same cost without the retry loop; not changed. |
| Plain already | `MarkStraddleLinesFast`, `SetUnloggedLines` (stores), `CountWorker` (per-worker counter), `RegisterObjectInClearedSpan` (no-op in the walk variant) | |

### Decrement (`ProcessDecrementEntry`, `DecrementWithDeathCore`, `Death`)

| Case | Locked operation | Needed? |
|---|---|---|
| Any decrement that changes the count | 1: `DecrementNonZeroNonSaturated` / `DecrementWithDeathCore` (`lock cmpxchg`) | Yes (same reason as the increment). For the last reference the count that the compare-exchange takes to zero is the invalidation of the object start (walk variant), so it stays last. |
| Death of an object of up to one line | 0 | |
| Death of an object of N lines | 2 x (N - 2) `lock cmpxchg` (`ClearStraddleLinesUnchecked`: straddle byte, count byte, `SequentiallyConsistent` stores) | **Not needed**: see C4. |
| Death, mature-candidate flag | 1 store to a byte that all workers share (not locked, but it moves the cache line) | **Not needed after the first death of a block**: see C3. |
| Death, `ScanDecrements` | 0 (loads of the counts of the children) | |

### Mature copy (`TryCopyMature`, trace pauses only)

The same steps as the nursery copy (claim, count of the copy by `CopyObjectQuiescent`, which is a relaxed `Store` and so a `lock
cmpxchg` unless the byte already holds the value, state 3), plus
`m_mark_metadata.Store(copy, 0, SequentiallyConsistent)` (a `lock cmpxchg`) and, at the retirement of the source,
`m_rc_metadata.Store(start, 0, SequentiallyConsistent)`. These are once per mature copy, which is rare (0.3M copies in `binarytrees`); not changed
except for the two bold steps of C1 and C2, which apply to `TryCopyMature` as well.

### Log and unlog bits (mutator side, not on the survivor path)

`LogBeforeWrite`: one `lock cmpxchg` on the unlog bit for the first write to a slot after a pause. Needed (the byte covers 8 slots that
different mutators write).

## (b) Changes

Each is one commit. All of them are safe without a switch; the reasoning is in the commit messages.

* **C1** `SetGCReservedBitsExclusive`: the header bits of a copy that is not published yet are written with a plain store (was a CAS
  loop). Copied survivor: 5 -> 4 locked operations.
* **C2** the forwarding pointer is stored with a plain store (was `xchg`); the CAS that sets the state to 3 publishes it. 4 -> 3.
* **C3** `Death` writes `m_mature_candidates[block]` only when it is 0 (was one store per death, to a line that all workers share).
* **C4** `ClearStraddleLinesUnchecked` uses `StoreExclusive` (two plain stores per continuation line, was two `lock cmpxchg`).

## What this does not remove

For a surviving young object that is promoted in place (the common case) the floor is now 1 locked operation at the increment and 1
at the decrement (the death). Both are needed with a 2-bit count that several objects and several workers share. The remaining cost
of a survivor is the chain of cold loads: the count line of the child, then its header (the first line that anything reads of the object).

See `RESULTS.md` for the measurements.
