# P41: cost of the LXR write barrier on the program thread

Question: can the LXR write barrier on the program thread be made cheaper, and does it matter?

Short answer: the fast path was already close to the Java LXR field barrier (10-11 instructions, no look at the new value).
Two changes were made (one instruction less on the fast path, a prefetch in the slow path). Neither one gives a wall, CPU
or pause effect that is outside the noise of this machine. The barrier is a small share of wall time on five of the six
workloads; it is visible only on `binarytrees` (12-15% of the program thread).

Baseline library: build of `a3a225d40a9`. All numbers are WSL2 Ubuntu 22.04, 16 CPUs, Xeon 8370C, clang-14, frame
`/root/prof/frame-c4`, `DOTNET_gcServer=1 DOTNET_GCPath=<lib>`, under `flock /tmp/lxr-bench.lock`.

## 1. Instruction counts of the common cases

The LXR barrier does not read the new value and does not know whether the destination object is young. It only tests the
unlog bit of the destination field. So the cases below cost the same, and what differs is only the slow path.

| case | LXR (a3a225d40a9) | LXR (this change) |
|---|---|---|
| unchecked helper, bit clear: store of null, store of a young target, store into a young object, store into a mature field that is already logged | 11 instructions (mov, shr, mov, movzx, mov, shr, and, bt, jc, mov store, ret); 2 loads (base slot, plane byte), 1 store, 1 branch | 10 instructions (mov, shr, mov, mov, mov, shr, bt, jc, mov store, ret); 2 loads (base slot, plane word), 1 store, 1 branch |
| checked helper, destination in the heap | 15 (4 more: mov, sub, cmp, jb; 2 more loads of constants) | 14 |
| checked helper, destination outside the heap | 6, 2 loads, 1 store | 6 |
| first store into a mature field (slow path) | the 9 instructions up to `jc`, then 39 instructions of frame, header zeroing, `xsave`, `vzeroupper`, call, `xrstor`, restore (the `xsave` and `xrstor` are microcoded), and the C++ logging code | the same plus 11 instructions of prefetch before the `xsave` |

Why the "cheap exits" that were suggested do not apply:

* a separate exit for a null store is not correct: an overwritten old value must be logged (SATB, decrement of the old target)
  whatever the new value is. A null store into an unlogged field takes the slow path.
* a young-range test first needs a contiguous nursery range. The nursery is a set of blocks, and a thread-local allocation
  buffer can be promoted by a pause between the allocation and the store, so there is no cheap range test. The unlog bits of
  young objects are zero (the refill clears the range), so the plane load is the test.
* a second load of the old value: the fast path does not load it. The slow path loads it once (in `LogOldValue`).
* the "checked metadata variants" of the d1 branch do not exist in this tree: there is one pair of helpers (checked and
  unchecked, both in `lxr_writebarrier.S`).

Comparison (counted from the sources, not measured):

| barrier | store of null | store, destination young / same region | store old -> young (needs a card or an escape) |
|---|---|---|---|
| WKS region barrier (`JIT_WriteBarrier_Byte_Region64`, `jithelpers_fastwritebarriers.S`) | destination in gen0: 7 instructions, 1 load. Other destination: about 10 | 7, 1 load | about 22, 4 loads |
| Satori (`gc_satori/amd64/writebarrier.S`, `RhpAssignRef`) | 5 instructions, 0 loads | about 18, 3 loads (thread tag, region header, exposed bit) | 25-35, card and page writes |
| Java LXR field barrier (`mmtkUnlogBitBarrier.cpp`, inlined by the JIT, no call) | not removed | 12 inline instructions (load byte, extract bit), 1 load | same as the left |
| LXR here | 10 | 10, 2 loads | 10, 2 loads (the logging is deferred to the slow path) |

The WKS stub reads a one-byte-per-region table that is always in L1. The LXR stub reads the unlog plane, one bit for every
8 bytes of heap, so it is a possible cache miss. The call and return are the same for both.

## 2. Measurements on the program thread

### How often each part runs

`wb-count.patch` (not part of the product) counts the barrier calls in the measured window of the driver.

| workload | unchecked calls | stores of null | slow path calls | take rate |
|---|---|---|---|---|
| requests | 9,929,589 | 232,958 | 19,307 | 0.19% |
| binarytrees | 136,664,423 | 68,681,729 | 119 | 0.0001% |
| listsuffix | 20,024,644 | 608,192 | 139,373 | 0.70% |
| mixedmedium | 10,560,036 | 200,001 | 485,111 | 4.6% |
| losarrays | 101,509 | 0 | 54,589 | 54% |
| mediumarrays | 244,193 | 1 | 148,016 | 61% |

The checked helper ran 5 times (0 in `mediumarrays`). Half of the stores in `binarytrees` are stores of null: all take the
whole fast path.

### Share of the program thread (perf cpu-clock 4000 Hz, call chains on, one run per cell)

`prof.sh`, `ana.py`. "fast" is a leaf sample in the fast part of the barrier block, "slow" is a sample in the slow part
of the block or in a C++ function called from it.

| workload | main thread ms | fast, base | slow, base | fast, c2 | slow, c2 |
|---|---|---|---|---|---|
| requests | 417 | 2.5% | 1.1% | 2.3% | 1.1% |
| binarytrees | 1136 | 14.5% (165 ms, 1.2 ns/call) | 0.02% | 12.0% | 0.02% |
| listsuffix | 1403 | 6.7% | 3.5% (350 ns/call) | 6.0% | 2.1% |
| mixedmedium | 1892 | 1.0% | 6.1% (237 ns/call) | 0.7% | 4.2% |
| losarrays | 2043 | 0.3% | 1.7% | 0.2% | 1.4% |
| mediumarrays | 1308 | 0.3% | 4.4% (386 ns/call) | 0.4% | 4.0% |

(c2 = both changes below.) Findings:

* The fast path matters only on `binarytrees` (14.5% of the program thread). Samples of that run are at the entry of
  the stub (39%, the cost of the call), and at the instructions that wait for the plane load (49%).
* The slow path costs 1-6% of the program thread. In the base build, 197 of the 236 leaf samples in `LogBeforeWrite`
  (`mixedmedium`) are on one instruction: the load of the reference count of the old target (a cache miss; the check
  `count != 0` that the zero-RC invariant needs). The `xsave` and `xrstor` take 135 samples (1.8% of the thread).

### Micro-benchmark (`barrier-microbench.cpp`, ns per call, min of 9 repetitions)

| case | base | c1 (word load) | xsavec instead of xsave | fxsave only | no vector save |
|---|---|---|---|---|---|
| sequential, bit clear | 2.9 | 2.4 | 2.8 | 2.8 | 2.5 |
| random over 256 MB, bit clear | 39.9 | 35.2 | 47.0 | 36.5 | 38.0 |
| one hot slot | 2.2 | 2.4 | 2.3 | 2.2 | 2.2 |
| every call takes the slow path (stub does nothing) | 324 | 306 | 276 | 172 | 52 |

The fast path is 2-3 ns in a loop, and the word load is not visible against the noise of the run (a second run of the base
gives 2.7-2.9 for the first row). A random access to the plane costs 35-45 ns whatever the instructions are: a miss
dominates. The vector-state save is about 85% of the cost of the assembly in the slow path in this loop (in the real
runs it is about 75 ns per call, the state is smaller). It cannot be dropped: the C++ code can call libc functions that use
`ymm16-31` and the opmask registers (`__memset_evex_unaligned_erms` is in every profile), and the JIT keeps values in vector
registers across the helper. An `xsavec` variant saves about 12% of the slow path, and was not kept.

## 3. Changes that were kept

1. `read the unlog plane as 8-byte words`: one load of `base[dst >> 9]` and `bt` with a 64-bit register, which takes the
   bit number modulo 64. 11 -> 10 instructions. The plane base is always 8-byte aligned (`AddSpec` aligns every plane), and
   the heap start now checks it. The faulting instruction (`LxrAssignRefMetadataAVLocation`) is still the plane load, and the
   word is in the page of the old byte.
2. `prefetch the reference-count entry of the old value before the vector state is saved`: in the slow path, before `xsave`,
   the assembly reads the old value and issues `prefetcht0` for its count entry (two new patchable slots: plane base and
   shifts). The prefetch is a hint (never faults, any value is harmless), the C++ code reads the field again, so the logging
   and the invariants are unchanged. In the profile the samples on the count load in `LogBeforeWrite` fall from 147 to 23 in
   `mediumarrays` (the slow share falls from 4.4% to 4.0%; from 6.1% to 4.2% in `mixedmedium`; from 3.5% to 2.1% in
   `listsuffix`). Part of the time moves to the first instructions of the assembly (the read of the field and the prefetch).

Both changes are in `lxr_writebarrier.asm` too, in the same form. The Windows file was not built or run here.

## 4. Effect on wall time, CPU and pause

`run9.py`, `analyze9.py`: 15 interleaved repetitions per cell (random order inside each workload and repetition), 270 runs,
all checksums right. Median paired difference to the base library in percent, with a 95% bootstrap interval of the median,
and the number of repetitions in which the variant was faster. c1 = change 1, c2 = changes 1 and 2.

| workload | c1 wall | c1 cpu | c1 pause | c2 wall | c2 cpu | c2 pause |
|---|---|---|---|---|---|---|
| requests | -2.7% [-14.0,+2.8] | -2.0% [-6.9,+1.9] | -2.1% [-22.2,+1.6] | +0.5% [-6.2,+8.5] | +0.8% [-6.7,+6.6] | -1.3% [-8.5,+10.7] |
| binarytrees | -1.5% [-18.3,+5.3] | +1.4% [-19.1,+10.7] | +3.0% [-33.9,+39.8] | -0.3% [-9.6,+4.9] | +3.7% [-15.2,+36.2] | +10.8% [-23.7,+51.1] |
| listsuffix | -0.7% [-15.0,+3.8] | +1.0% [-7.7,+6.2] | -4.0% [-12.3,+3.6] | -0.1% [-10.4,+6.8] | +0.2% [-2.4,+9.5] | +0.9% [+0.1,+13.0] |
| mixedmedium | -0.4% [-3.1,+2.7] | -0.3% [-2.3,+4.7] | -1.1% [-6.0,+9.3] | -1.5% [-5.3,+3.5] | -2.1% [-3.5,+2.8] | -2.4% [-4.5,+5.6] |
| losarrays | -1.3% [-5.6,+1.4] | -1.0% [-4.1,+1.2] | -2.4% [-4.7,+1.8] | -1.3% [-3.3,+5.2] | -1.0% [-2.0,+0.2] | +0.3% [-1.6,+0.8] |
| mediumarrays | +1.6% [-3.3,+8.1] | -0.3% [-5.3,+4.5] | +0.8% [-3.9,+10.6] | -2.5% [-8.6,+3.9] | -1.8% [-4.4,-0.3] | -1.3% [-8.7,+3.9] |

Every interval but two contains zero (`mediumarrays` cpu of c2, `listsuffix` pause of c2, which goes the wrong way). The
other sessions use the same machine and the interquartile range of a cell is 5-35% of its median, so differences below
a few percent cannot be seen. This is the expected size: the profile says the most the fast path could give is 1-2% of
`binarytrees`, and the slow path change removes 1-2% of the program thread of `mixedmedium`, `listsuffix` and `mediumarrays`.

## 5. Validation

* native barrier test (`P21-specialized-barrier/native-barrier-linux.sh`): 0 failures, the five controls fail as required;
  a new check `rc-prefetch-hint` runs the slow path with eight kinds of old values and three entry sizes.
* `P31-object-start-walk/validate-variant.sh default Release` (P2.1-P2.5, P3.1-P3.4, P4 and all selectors): all pass; the
  known flaky `--mature-released-candidate` failed once (65/67) and passed on three reruns; `--zero-rc-control` is the
  negative control.
* crash hunt `p31hunt.py` (18 runs for each of 13:3, 4:2 and 1:1 workers, six workloads and the interior stress test): 0 failures.

## 6. Not verified, not done

* The Windows `.asm` was not built or run. The change is the same structure as the `.S`, with `rcx` kept in `r10` around the
  shifts of the prefetch.
* No hardware counters (WSL2): cache misses and mispredictions are inferred from sample positions (cpu-clock, with skid).
* One profile run per cell. The profile shares are not repeated measurements.
* Not tried: logging the old value and the slot in assembly for the common case (no vector save at all; needs the thread's
  buffers in assembly), logging a whole range of a large array at the first store (`losarrays` and `mediumarrays` take the slow
  path for 54-61% of their stores), a JIT-inlined fast path as in the Java binding (saves the call, but is a JIT change).
* Not tried: `xsavec` in the slow path (about -12% of the assembly cost of a slow call in the micro-benchmark).

## Files

* `barrier-microbench.cpp`, `run-microbench.sh`: the micro-benchmark.
* `prof.sh`, `ana.py`, `lines9.py`: perf recording of the measured window, and the classification of the samples.
* `run9.py`, `analyze9.py`: the interleaved runner and the paired summary.
* `count.sh`, `wb-count.patch`: take-rate counters (a patch for `a3a225d40a9`, not for the product).
