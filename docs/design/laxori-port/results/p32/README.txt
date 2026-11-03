After the P32 fixes (see STATUS.md, "Update: P32").
13-thread PrivateTests all 2 13, verifier on, 20 runs per configuration, interleaved (scripts/p13-multi.sh):
  count L2 0/20, bitmap L2 0/20, count L1 0/20, bitmap L1 0/20.
Before (results/p31): L1 12/20 (count) and 11/20 (bitmap) interleaved; L2 1/12 each; LXR count 2/12, LXR bitmap 4/12 (sequential batches).
Crash hunt (13/3, 4/2, 1/1 workers, verifier on): count L2 36/36, bitmap L1 36/36.
PrivateTests all 2 at 1/2/4/8 threads, L1 and L2, count build: all pass.
One run of the six workloads on both builds: all checksums right (binarytrees 1065/1062 ms, requests 323/337, listsuffix 1667/1662,
mixedmedium 1587/1565, losarrays 1219/1245, mediumarrays 1067/1099, walk/bitmap), same as before the fix.
Native: all 10 programs pass in both builds (native-validate-*.txt); P4 --s3-bookkeeping 1325/1325 with the new pastEnd root.
