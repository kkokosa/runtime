# P32 results

Machine: WSL2, 16 vCPU, shared with other sessions (their builds and tests run without the lock, so the noise is high: the IQR of a
cell is often 10% of the median). Frame `/root/prof/frame-c4`, driver `CompareDriver.dll`, `DOTNET_gcServer=1`, `DOTNET_GCPath=<library>`,
default LXR settings. Baseline `base0` = `a3a225d40a9` built in an ext4 copy. Runs interleaved in a shuffled order per repetition and
workload, under `flock /tmp/lxr-bench.lock`; all checksums correct. `runlocks.py`, `analyzelocks.py`. Percentages are the median of the
paired per-repetition differences, with a 95% bootstrap interval of the median and the number of repetitions in which the new library is
better. Negative = better.

## Validation

For HEAD (all four changes): P2.1-P2.5, P3.1-P3.4 and P4 (105380/105380) pass, Release and Debug (P4). All P4 selectors of
`run-p4-selectors.sh` pass (`--mature-released-candidate` and `--p8-storage` passed in this run; they are flaky on the baseline).
Crash hunt (`p32hunt.py`, 28 runs for each of 13:3, 4:2 and 1:1 workers, the six workloads and the interior-pointer stress test): 0 failures, for the first three
changes and for HEAD.

## Profile of the baseline (listsuffix, perf cpu-clock, 12.6k worker samples in the library)

* 20% on the load of `*slot` in `LxrPrefetch::Ahead` inside `ProcessChildIncrements` (the first use of the slot of entry i+8; the
  miss is real, the helper only moves it) and 3-4% in the other two `Ahead` loops.
* 13% in `DecrementWithDeathCore`, 10% of it on the instruction after `lock cmpxchg`. The compare-exchange comes after the `Death`
  callback, which has loads in flight (the counts of the children), and a locked instruction waits for them. So most of this is the
  chain of cold loads, not the lock itself.
* The increment `lock cmpxchg` in `ProcessIncrement` has 1.3%: the count line was loaded just before, and the line is in the cache.
* `TryCopyNursery` 6.8% (the `xchg` of the forwarding pointer has 1%), `SetUnloggedLines` (plain stores to cold lines) 2.9%.

## Effect of each change (`bench1`, 15 repetitions, cumulative libraries; wall | CPU | pause, median % paired)

| Change | requests | binarytrees | listsuffix | mixedmedium | losarrays | mediumarrays |
|---|---|---|---|---|---|---|
| C1 vs base | +1.6 +2.0 +6.5 | +5.2 +10.1 +6.4 | -0.7 +3.1 +1.3 | +4.7 +2.4 +7.4 | +1.4 +1.8 +1.2 | +1.5 -0.8 -0.4 |
| C2 vs C1 | +3.7 +3.0 -2.7 | -1.2 -6.6 -1.0 | -1.7 **-2.8** -2.7 | **-2.1** -3.3 -3.5 | +0.6 -1.4 -1.1 | +0.1 -0.8 +0.5 |
| C3 vs C2 | +3.5 0.0 +3.4 | +0.8 +6.0 +4.9 | -1.1 **-7.5** +0.6 | -0.7 -0.9 +1.5 | +1.1 -0.4 +0.1 | -0.1 +0.5 -0.5 |
| C4 vs C3 | -4.5 -4.9 -4.7 | **-2.9** -6.8 -9.5 | **+3.0** +3.3 +2.3 | **-2.9** -1.2 -3.5 | -1.2 -0.2 -0.1 | -0.4 -1.6 -3.4 |

(Bold: the 95% interval of that cell excludes 0. Most cells include 0.) Read honestly: no single change has a measured gain that
is outside the noise on every workload. C3 (flag of the mature candidate) has the clearest single effect: CPU of `listsuffix` -7.5%
[-10.8, -1.4], 12/15. C4 has the effect that is expected (fewer locked operations for objects larger than a line): `mixedmedium` wall
-2.9% [-4.5, -0.8], 11/15; for `mediumarrays` the pause is -3.4% but the interval includes 0. C4 also shows `listsuffix` wall +3.0% [+1.7, +8.1], 4/15,
which is a worse reading; C4 does not touch objects of up to one line, which is all of `listsuffix`, and the confirmation run (`bench2`, all changes) shows +0.1% there,
so this is treated as noise. C1 looks worse in this run
(`binarytrees` CPU +10%, interval [-1.4, +13.3]); C1 and C2 are measured separately here, but the binarytrees samples of C1 contain
a few slow repetitions (the IQR of `binarytrees` CPU is 2300-3200 ms), so the difference is not evidence of a loss.

## All four changes together (`bench2`, 25 repetitions, `base0` against HEAD)

| | wall | CPU | pause |
|---|---|---|---|
| requests | +0.3% [-2.4, +4.2] | -3.0% [-4.1, +3.3] | -3.2% [-8.8, +2.8] |
| binarytrees | **-7.7%** [-9.5, -0.1] 18/25 | **-15.3%** [-20.7, -6.8] 20/25 | **-22.4%** [-36.6, -9.3] 22/25 |
| listsuffix | +0.1% [-4.4, +5.6] | **-3.9%** [-8.8, -0.7] 18/25 | +0.3% [-11.2, +11.7] |
| mixedmedium | +1.0% [-2.9, +3.0] | -1.3% [-3.4, +1.1] | +0.3% [-5.1, +7.5] |
| losarrays | +1.0% [-4.5, +2.7] | +0.5% [-2.4, +2.5] | 0.0% [-3.0, +3.5] |
| mediumarrays | +0.7% [-1.5, +3.2] | -0.8% [-3.0, +0.5] | +0.5% [-3.3, +3.2] |

Medians (wall / CPU / pause, ms): binarytrees 1205/3427/158 -> 1134/2895/125; listsuffix 1389/3843/191 -> 1405/3620/201.
`binarytrees` is the workload with mature copies and many nursery copies, so the saved header operations and the flag are on its path. The large
gain there and the missing gain on `listsuffix` agree with the profile: in-place promotion (80% of the survivors of `listsuffix`) has one locked operation per
survivor at the increment and one at the decrement, and the removed operations were on the copy path and in the death of larger objects.

## Tried and not kept

All four are prefetch experiments on the cold-load side (the library is `bench1`).

* **d1**: `LxrPrefetch::Read(child)` in `ScanIncrements` before the count of the child is loaded (overlaps the count miss and the header
  miss of the child). Against C4: `binarytrees` CPU +7.8%, `mixedmedium` wall +3.8%, `listsuffix` CPU -4.3% (interval includes 0). Not kept.
* **d2**: the same in `ScanDecrements`. Against d1: `binarytrees` CPU -14.9% [-28.2, -4.5], `listsuffix` +4.2%, `mixedmedium` pause -6.1%. Mixed. Not kept.
* **np** (`-DLXR_NO_PREFETCH`, the whole prefetch helper off), against C4: `listsuffix` pause -15.3% [-20.6, -9.9], 13/15; wall -4.9% and CPU +0.2% (not
  significant); `mixedmedium` wall +2.8% [+1.1, +7.0], `losarrays` wall +4.7% [+0.2, +7.9], `requests` CPU +2.7% [+0.8, +9.2]. The helper is the Java default and is not
  changed. It helps `mixedmedium`, `losarrays` and `requests` and costs `listsuffix` its pause time, where it has no entry to look ahead at (a chain) and its
  load of the slot is itself the miss.
* A lock-free early exit in `TryPromoteInPlace` (skip the operation stripe and the block lock when the block is promoted already) was written
  and dropped before measuring: reading the code showed that only objects of the block that race the first promotion call it, because
  `IsNurseryFast` is false for the later objects.

## Not verified

* ARM64 (the code uses release stores or follows a full-barrier compare-exchange, but it ran on x64 only), Windows, Debug runs of the benchmarks.
* The interval of each change is wide; a gain of a few percent on one change cannot be shown with 15 repetitions on this machine. Only the sum
  (`bench2`) is measured with enough repetitions for `binarytrees`.
* `LXRRCBits` 4 and 8 (the comment in C4 relies on a count byte that covers at most 32 bytes of data; it holds for all three widths).
* The decrement `lock cmpxchg` stays after `Death` because the order (scan the object while its count is 1, then take the count to zero) is part of the
  design. Moving it before `Death` would remove the stall of 13% in `DecrementWithDeathCore`, but it changes what a concurrent reader sees, and it was not tried.
