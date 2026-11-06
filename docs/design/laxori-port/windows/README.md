# Laxori on Windows x64

Branch `kkokosa-laxori-windows-bringup`, base `kkokosa-laxori-gc` 9c88b2681b6 (in sync with LXR `lxr-gc-review` a782e26dc3e). Nothing is pushed.
Before this work Laxori (and LXR) had only run on Linux x64. This file says what was done on Windows x64, on the same VM that hosts
the WSL2 Ubuntu used for all earlier work, what was found, and what was not verified. A number that was not measured is marked **[N]**.

## 1. Result in short

* Laxori builds with MSVC and runs on Windows x64 (library `clrlaxorigc.dll`, selected with `DOTNET_GCPath`, as on Linux). The Windows write
  barrier `laxori_writebarrier.asm` **did not exist**; it was written from the `.S` file in this work. LXR (`clrlxrgc.dll`, unchanged) and Satori
  (`satorigc.dll`) built and ran in the same frame.
* Correctness on Windows: the 10 native engine programs and all P4 selectors pass, all P4 mutation controls are detected (one control is not detected
  on Linux either, one is detected only in most runs, see 5.2), the native barrier test passes (19 checks plus a vector-state control), `PrivateTests` passes
  (L1 and L2, 1/2/4/8/13 threads, `all 2 13` 20 times each: 70 of 70 runs), the six standard workloads and `losmany` give the right checksums
  with every collector, and a reduced crash hunt ran 108 runs without failure.
* Six Windows defects were fixed, each in its own commit (section 4). No change of Linux behaviour: the Linux native programs, the Linux barrier test and a Linux
  syntax check of the changed files pass.
* The big difference of Windows is **memory**: the large-object space gives memory back with `madvise(MADV_DONTNEED)` on Linux and keeps the range committed.
  Windows has no call with the same effect (zeros on the next use, no re-commit), so every large allocation commits and every release decommits (section 8).
* Timed results (sections 6 to 10): 9 Windows and 5 WSL2 repetitions per cell, checksums right in all 490 runs; `losmany` on WSL2, the write barrier cost alone, the working set after a collection and large pages are [N]. The large-object workloads are 2.8 to 6 times slower than WKS on Windows (they are faster than WKS on Linux): commit and decommit cost, section 10.

## 2. Machine and toolchain

| | |
|---|---|
| Machine | Windows 11 Enterprise 10.0.26300 (a VM), Xeon Platinum 8370C 2.80 GHz, 8 cores / 16 threads, 64 GB. The WSL2 Ubuntu 22.04 (16 CPUs, 31 GB) runs on the same VM. |
| Compiler | Visual Studio 18 (IntPreview): `cl` 19.51.36252, `ml64` 14.51.36252, CMake and Ninja from the VS folder, Windows SDK 10.0.26100 |
| .NET SDK | `11.0.100-rc.1.26420.103` (`global.json`); the `.dotnet` folder was copied from another worktree of this machine (no download) |
| Python | 3.12 (benchmark scripts) |
| Repository | the worktree, NTFS, build tree `artifacts\obj\coreclr\windows.x64.Release` |
| Free disk | about 0.8 TB; the build used a few GB |

**MAX_PATH.** The worktree path (`C:\Users\konradkokosa\.copilot\repos\copilot-worktrees\runtime-fork\kkokosa-refactored-journey`) is so long that the native build fails with
`C1041: cannot open program database ...System.Globalization.Native-Static.pdb` (the path of the pdb is over 260 characters). Every build and every script here
runs through `subst K: <worktree>`. This is an environment problem, not a code defect.

## 3. Build commands, exactly as run

```
subst K: C:\Users\konradkokosa\.copilot\repos\copilot-worktrees\runtime-fork\kkokosa-refactored-journey

:: 1. CoreCLR with the LXR library (13 min). CrossgenOldValueWriteBarriers=true is what makes the R2R image of System.Private.CoreLib acceptable to
::    a collector that needs the old value of every overwritten reference (readytoruninfo.cpp rejects unmarked images). Without it the runtime
::    runs JIT-first with a distorted profile.
K:\build.cmd -subset clr -c Release -a x64 -cmakeargs "-DCLR_CMAKE_ENABLE_LXR_GC=1" /p:CrossgenOldValueWriteBarriers=true

:: 2. The libraries (5 min)
K:\build.cmd -subset libs.sfx -c Release -a x64 /p:CrossgenOldValueWriteBarriers=true

:: 3. Laxori, Satori and the bitmap variant of Laxori in the same build tree (windows\cmake-laxori.cmd: reconfigure with
::    -DCLR_CMAKE_ENABLE_LAXORI_GC=1 -DCLR_CMAKE_ENABLE_SATORI_GC=1, then cmake --build --target ...)
docs\design\laxori-port\windows\cmake-laxori.cmd clrlaxorigc clrlaxorigc_bitmap satorigc
```

The frame (`C:\lx-run\frame`, a short path on NTFS) is `artifacts\bin\runtime\net11.0-windows-Release-x64` (the libraries) plus `coreclr.dll`,
`System.Private.CoreLib.dll`, `clrjit.dll`, `corerun.exe`, `clrgc.dll` from `artifacts\bin\coreclr\windows.x64.Release`, plus `clrlxrgc.dll`,
`clrlaxorigc.dll`, `clrlaxorigc-bitmap.dll` and `satorigc.dll` from the build tree. The drivers are built with `K:\.dotnet\dotnet.exe build -c Release`
(`windows\driver`, `windows\driver-scaling`, `PrivateTests`) and run with `corerun.exe app.dll args`.
Check of the frame: the number of methods that the JIT compiled until `Main` is 27 with stock WKS, LXR and Laxori (R2R of CoreLib is accepted by all;
Linux WKS gave 25).

Stock WKS is `DOTNET_gcServer=0`, SVR `DOTNET_gcServer=1`, both without `GCPath`. LXR and Laxori run with `DOTNET_gcServer=1` and `DOTNET_GCPath=<full path of the dll>` (as in the Linux runs).
Settings are decimal MB (`DOTNET_LAXORIImmixInitialMB=200`...).

## 4. Windows defects found and fixed

| # | Defect | Symptom | Commit |
|---|---|---|---|
| 1 | `amd64/laxori_writebarrier.asm` was never written; CMake allowed Linux only | `-DCLR_CMAKE_ENABLE_LAXORI_GC=1` stops with "requires standalone Linux AMD64 CoreCLR" | `a07b0f2ab6c` |
| 2 | GCC builtins in the private tier: thread tag from `fs:0` (laxori_private.cpp, laxori_gc.cpp), `__builtin_ia32_rdtsc`, `__builtin_ctzll`, `__atomic_load_n` / `__atomic_store_n` (laxori_private.cpp, laxori_reference_counting.cpp) | MSVC: C3861 / C2065 | `a07b0f2ab6c` (`laxori_platform.h`) |
| 3 | The P2.5 test used `setenv` / `unsetenv`; the P4 test has locals named `small`, a macro of `rpcndr.h` (`windows.h`) | MSVC: C3861, C2628 | `6ea74aacaed` |
| 4 | Five Debug asserts in `laxori_side_metadata.h` compare `int` with `uint32_t` | MSVC `/W4 /WX`: C4389 in a Debug build | `a732ade1865` |
| 5 | The native barrier test was Linux only (inline asm, `mmap`, `fs:0`) | no barrier test on Windows | `fef67ed59a9` |

### The Windows barrier (`laxori_writebarrier.asm`)

Compared instruction by instruction with `laxori_writebarrier.S` of the same commit. What differs:

* Arguments: `rcx` = destination slot, `rdx` = new reference (the JIT helper convention of Windows: `RBM_CALLEE_TRASH_WRITEBARRIER` kills rax, rcx, rdx, r8-r11, so rdi and rsi are not touched).
  The fast path uses rax, r8, r9, r10 as temporaries; the shift by the region shift needs `cl`, so the destination goes to r10 for one instruction.
* Thread tag (the owner of a region): the address of the TEB, `gs:[30h]` (`__readgsqword(0x30)` in C++), not `fs:0`. Both sides use `LaxoriCurrentThreadTag()`.
  `FEATURE_TLS_DESCRIPTORS` is a glibc feature and is not used.
* `xsave` uses `rdx` for the high half of its mask, so the escape path reads the reference again from its save slot after the save (`mov rdx, [rbp-16]`). The log path needs only `rcx`.
* The C++ slow paths are called with 32 bytes of shadow space; the stack stays 64 byte aligned for `xsave`.
* Unwind information: `NESTED_ENTRY` / `push_nonvol_reg rbp` / `set_frame rbp, 0`, as in `lxr_writebarrier.asm`. The two slow paths are inside the block that the runtime copies.
  The RIP-relative references to the patchable slots stay valid in the copy (slots are inside the block).
* The runtime side is generic (`WriteBarrierManager`: `GetAssignRefFunctions` returns the block, its AV locations and its patchable values), so no VM change was needed.
* Test: `windows\native-barrier-windows.ps1`. 19 checks (private store, exposed slot, escape, escape + log, other region, foreign owner, null and non-heap references, checked helper, dissolve) with all of xmm0-xmm15
  filled before the call and compared after it; the test slow paths clobber xmm0-xmm15. With `LAXORI_WB_CONTROL_NO_VECTOR_SAVE` (new, same name as in the LXR barrier) the vector checks fail, as required.
  Without the define, the instruction stream is the same (`dumpbin /disasm`, 173 instructions compared).
  In a real run: `PrivateTests` shows `escapeCalls=112257 escapedObjects=255557` (the escape path ran) and no failure.

## 5. Correctness on Windows

### 5.1 Native engine programs (`windows\native-windows.ps1`, MSVC `/O2 /MT /W4 /WX`, Release)

| Program | Result |
|---|---|
| P2.1 side metadata | 1096/1096 |
| P2.2 immix block | 2215/2215 |
| P2.3 reference count | 37/37 cases (1882 checks) |
| P2.4 immix allocation | 277861/277861 |
| P2.5 large object space | 209043/209043 (Linux: 209037; the Windows commit path has more checks) |
| P3.1, P3.2, P3.3, P3.4 | 652/652, 395/395, 357/357, 70/70 |
| P4 default | 105881/105881 |
| P4 selectors | `--pause-trace` 259424, `--lazy-sweep` 3098, `--d2-spans` 2268, `--prezero` 129, `--fresh-block-race` 10, `--s7-pins` 4099, `--s6-registry` 241, `--s5b-overshoot` 422, `--s4-sweep` 16631, `--s3-bookkeeping` 1325, `--lazy-large-release` 13, `--inline-metadata` 465, `--log-storage` 2109, `--mature` 692, `--mature-remset` 58, `--mature-reader` 17, `--mature-retained-owner` 18, `--mature-released-candidate` 67, `--mature-headroom` 67, `--mature-completed-scan` 12, `--mature-remset-whole` 58, `--mature-remset-wrap` 1078, `--mature-remset-same-shape` 1079, `--mature-remset-boundaries` 4315, `--nursery` 165, `--nursery-reader` 17, `--root-batching` 3095, `--trace-batching` 206016, `--aux-retirement` 8209, `--object-planes` 16, `--storage-diagnostics` 29, `--lifetime` 15, `--p8-policy` 75, `--p8-storage` 1441, `--f1-trace` 79789, `--f2-pause` 2488, `--f8-lazy` 115758, `--f4b-scheduler` 4044, `--f4-scheduler` 3547, `--f10-rc` 72, `--item3` 564, `--f5-policy` 16272, `--trace` 8372, **`--marking-window` 39, `--release-stage` 4955, `--object-start` 4279, `--select-parallel` 462** (all checks of all selectors pass; `--zero-rc-control` fails as designed) |
| Bitmap build (`-Bitmap`) | P2.2 to P2.5 as above; P4 default, `--object-start`, `--mature`, `--select-parallel`, `--marking-window`, `--prezero` pass with the same counts |
| Debug config | compiles after fix 4; the Debug programs are very slow (P2.2 did not finish in 3 minutes, Release takes seconds), so no Debug run was completed **[N]** |

The numbers of P4 (105881, 4279, 462, 39) are the same as on Linux.

### 5.2 Mutation controls (`windows\run-controls.ps1`)

All 46 P4 controls were built and run (`-D...CONTROL`); each has to make a check fail. 44 are detected. Two are not:

* `PendingRetirement` is not detected on Linux either (the Linux script gives the same message: the control needs a selector that the script does not map). Not a Windows difference.
* `SelectOccupied` (a pinned block does not count as occupied in the parallel selection) is detected in 25 of 30 runs on Windows and in 30 of 30 on Linux (same control, `--select-parallel`).
  The heap of the selection test is built from the absolute address of the arena (`block & (ChunkBytes - 1)`, 4 MiB chunks), so it changes with the address that the OS gives: the numbers "eligible" differ from run to run on both OS.
  Windows gives 64 KiB aligned addresses with ASLR; a test with the arena aligned to 4 MiB detects it in 0 of 30 runs. So the detection depends on a partly filled first chunk. This is a weakness of the test, not a product defect; I did not change it.
  Also P2.4 `WalkWriteValid` is detected.

### 5.3 Library tests

| Test | Result |
|---|---|
| `windows\private-tests.ps1`, count build, verifier on (`DOTNET_LAXORIVerifyPrivate=1`): L2 and L1 (`DOTNET_LAXORIEscapedInPlace=0`), `all 2 T` for T = 1, 2, 4, 8, 13, and `all 2 13` 20 times | 50 of 50 pass |
| the same with the bitmap library, `all 2 13` 5 times | 20 of 20 pass |
| six standard workloads + `losmany`, checksums, collectors wks, svr, lxr, laxori, laxori-l1 (`windows\bench-windows.py --nolock`, 1 round) | all 35 runs right (27134172608, 68332294, 159636632672, 40586599707, 13936826922, 7032863679, 42674603309) |
| crash hunt `windows\hunt-windows.py` (5 scaled workloads and PrivateTests, 13/3, 4/2, 1/1 workers, verifier on): count build 72 runs, bitmap build 36 runs | 108 of 108 pass |
| Linux regression (WSL2, under the lock): the 10 native programs of `run-native-all.sh`, `BarrierTest/native-barrier-linux.sh`, clang syntax check of the changed files with the Linux flags | pass |

The hunt is smaller than the 180 runs of the last Linux stage. GC stress was not run **[N]**.

## 6. Timed runs and the shared lock

WSL2 and Windows run on one VM, so every timed run holds the lock `/tmp/lxr-bench.lock` of the WSL2 side:
`wsl.exe -d Ubuntu-22.04 --exec flock /tmp/lxr-bench.lock cmd.exe /c <python> <script> --worker ...` (the scripts do this themselves; `--exec` is needed, with `--` the
WSL shell eats the backslashes of the Windows paths). Blocks of two workload rounds (about 3 minutes) per lock hold.

During this work two other sessions held the lock for hours (`run-ab2.py` of another worktree, 15 repetitions in one hold; `run-gt.py --lock all`), and the WSL2 VM restarted once
(at about 19:14; Windows did not restart; every queued lock waiter on the WSL2 side died; no memory event in the Windows log). After that the sessions took the lock per block. The Windows
runs are 9 repetitions (4 before and 5 after the restart, one repetition = 5 collectors x 7 workloads per lock hold, interleaved in the order wks, svr, lxr, laxori, satori inside each workload).
The WSL2 runs are 5 repetitions (one lock hold each, same order, bench3.py). The big-heap runs ran in a **quiet window** (WSL2 shut down, nothing else on the VM, no lock).
The raw runs and the generated tables are in `windows\results\` (`windows-runs.jsonl`, `wsl2-runs.jsonl`, `comparison.md`, `commitbench.txt`, `suspend.txt`, `bigheap.txt`).

Every run in the tables has the right checksum (315 of 315 Windows runs, 175 of 175 WSL2 runs, `bad 0`).

## 7. Comparison on Windows (WKS, SVR, LXR, Laxori, Satori)

Median of wall ms / CPU ms / pause ms / peak working set MB, 9 runs per cell. LXR and Laxori are the count-plane builds, server mode, default settings (`mediumarrays` with the 200/400 MB setting, `losmany` with the LOS settings of the task).

| workload | WKS | SVR | LXR | Laxori | Satori |
|---|---|---|---|---|---|
| requests | 321 / 281 / 55 / 62 | 301 / 547 / 51 / 102 | 320 / 453 / 23 / 168 | 305 / 312 / 8 / 163 | 517 / 719 / 9 / 69 |
| binarytrees | 940 / 906 / 246 / 116 | 866 / 1,188 / 137 / 252 | 997 / 3,000 / 122 / 200 | 984 / 2,391 / 107 / 197 | 857 / 1,547 / 35 / 142 |
| listsuffix | 1,905 / 1,797 / 1,002 / 96 | 780 / 1,719 / 141 / 214 | 1,166 / 3,656 / 183 / 198 | 1,360 / 3,719 / 187 / 194 | 763 / 2,359 / 52 / 169 |
| mixedmedium | 1,030 / 875 / 372 / 177 | 650 / 1,109 / 111 / 470 | 1,717 / 5,375 / 155 / 190 | 1,245 / 2,109 / 124 / 192 | 654 / 1,328 / 61 / 303 |
| losarrays | 1,865 / 1,859 / 1,059 / 311 | 1,306 / 2,719 / 306 / 796 | **8,075 / 50,484** / 957 / 327 | **5,163 / 5,922** / 504 / 327 | 694 / 1,578 / 71 / 440 |
| mediumarrays | 1,252 / 1,078 / 452 / 226 | 737 / 1,516 / 99 / 600 | 873 / 2,156 / 82 / 484 | 944 / 1,672 / 77 / 483 | 594 / 1,375 / 67 / 432 |
| losmany | 2,339 / 2,453 / 127 / 3,129 | 2,700 / 3,203 / 128 / 4,474 | **14,437 / 105,859** / 799 / 1,160 | **9,536 / 10,641** / 580 / 1,149 | 2,018 / 3,531 / 128 / 2,973 |

Paired differences (Laxori - other) / other in percent, median and 95 percent bootstrap interval (full tables for LXR, WKS, SVR and Satori in `results\comparison.md`):

| Laxori against LXR | wall | CPU | pause | peak WS |
|---|---|---|---|---|
| requests | -7.2 [-12.4, -1.0] | -30.0 [-37.5, -2.9] | -67.3 [-69.9, -57.3] | -3.1 [-3.6, -2.7] |
| binarytrees | -1.3 [-4.2, +2.3] | -15.8 [-37.0, -6.4] | -13.4 [-22.2, +12.4] | -2.0 [-4.4, +2.8] |
| listsuffix | +16.6 [+11.5, +28.3] | +1.2 [-10.2, +16.9] | +5.3 [-10.3, +16.3] | -2.9 [-3.4, -0.6] |
| mixedmedium | -27.6 [-28.7, -25.0] | -60.9 [-65.0, -59.2] | -18.0 [-22.7, -13.6] | +0.9 [+0.7, +1.1] |
| losarrays | -35.3 [-37.5, -32.7] | -88.2 [-90.0, -87.3] | -49.7 [-77.0, +19.1] | +0.0 [-1.1, +1.0] |
| mediumarrays | +8.3 [-1.7, +11.1] | -24.6 [-36.6, -6.2] | -3.1 [-13.2, +1.3] | -0.2 [-0.2, -0.1] |
| losmany | -33.6 [-34.2, -33.1] | -89.9 [-90.1, -89.6] | -27.2 [-28.2, -26.4] | -0.9 [-0.9, -0.9] |

Reading (what the numbers say, not more):

* Where the large-object space is not the main cost (requests, binarytrees, listsuffix, mixedmedium, mediumarrays), Laxori and LXR behave on Windows as on Linux: pauses 2 to 7 times
  shorter than WKS (requests 8 ms against 55 ms), CPU above WKS, working set 1.1 to 2.6 times WKS on the small heaps. Laxori has less CPU than LXR on requests, binarytrees, mixedmedium and
  mediumarrays; on listsuffix it is 17 percent slower in wall time (as on Linux, where the STATUS file says 25 to 29 percent against LXR).
* **The large-object workloads are the Windows problem**: `losarrays` Laxori 2.8 times and LXR 4.3 times the wall time of WKS (on WSL2 both are 0.58 times); `losmany` 4.1 and 6.2 times.
  Section 10 shows that this is kernel time of commit and decommit.
* SVR and Satori have the shortest wall times on mixedmedium, listsuffix and mediumarrays (SVR uses 16 server threads on this 16-thread VM); Satori leads on losarrays and listsuffix.
* Laxori against SVR and Satori: slower wall time on every workload but requests (where it is 41 percent faster than Satori and equal to SVR).

## 8. Windows against WSL2 (same VM, same workloads)

Ratio of the medians, Windows / WSL2 (wall, CPU, pause). Windows 9 runs, WSL2 5 runs per cell. WSL2 libraries: LXR `libclrlxrgc-walk.so` (P31, older than the three a782e26dc3e ports), Laxori `libclrlaxorigc-count-c.so` (stage c, same sources as this head). Values below 1: Windows is cheaper.

| workload | WKS | SVR | LXR | Laxori | Satori |
|---|---|---|---|---|---|
| requests | 0.97 / 0.86 / 0.82 | 0.49 / 0.54 / 0.19 | 0.84 / 0.89 / 0.75 | 0.93 / 0.78 / 0.80 | 0.85 / 1.00 / 0.40 |
| binarytrees | 0.84 / 0.81 / 0.78 | 0.58 / 0.52 / 0.21 | 0.87 / 0.88 / 0.81 | 0.90 / 0.97 / 0.95 | 0.85 / 0.95 / 0.55 |
| listsuffix | 0.83 / 0.75 / 0.78 | 0.68 / 0.63 / 0.42 | 0.82 / 0.90 / 0.96 | 0.88 / 0.87 / 0.91 | 0.86 / 1.04 / 0.50 |
| mixedmedium | 0.89 / 0.75 / 0.75 | 0.61 / 0.57 / 0.29 | 1.18 / 2.12 / 0.73 | 0.82 / 0.83 / 0.58 | 0.91 / 0.85 / 0.55 |
| losarrays | 0.92 / 0.86 / 0.84 | 0.46 / 0.46 / 0.22 | **6.86 / 20.41** / 2.05 | **4.40 / 2.34** / 1.11 | 0.92 / 1.16 / 0.69 |
| mediumarrays | 0.96 / 0.83 / 0.81 | 0.59 / 0.70 / 0.30 | 0.88 / 1.23 / 0.90 | 0.89 / 0.94 / 0.81 | 0.84 / 0.79 / 0.39 |
| losmany | [N] | [N] | [N] | [N] | [N] |

`losmany` on WSL2 is [N]: the driver copy that the WSL2 benchmark used (`/root/laxori/drv2`) has no `losmany` mode (it is in the P44 driver, which the Windows runs use).
Medians of collector wall time against WKS on each OS (Windows | WSL2): Laxori requests 0.95 | 0.99, binarytrees 1.05 | 0.98, listsuffix 0.71 | 0.67, mixedmedium 1.21 | 1.31, mediumarrays 0.75 | 0.81, **losarrays 2.77 | 0.58**.

Reading: Windows is 10 to 20 percent cheaper in wall time and 15 to 25 percent in CPU for WKS on this VM, and about the same for Laxori (0.82 to 0.93). Pauses of LXR and Laxori are 5 to 40 percent shorter on Windows
(SVR pauses are 2.4 to 5 times shorter on Windows). The only large loss is the large-object space.

## 9. Large heaps (P49 `bigheap`, 60 s window, one mutator thread, trace threshold 2, fixed heap, quiet window)

The commit limit of this VM is 75.1 GB and 36 to 41 GB of it is committed by the system and other processes (not by processes of a single large owner; it stayed at 37 GB after `wsl --shutdown`).
A run that commits more than the rest fails with `ERROR_COMMITMENT_LIMIT` (1455) at reservation or commit: with the cap of 14400 MB 10 of 20 starts of Laxori and 6 of 15 of LXR failed to initialize in the first minutes of a
busy system, none failed with a smaller cap at other times. So the starts below are not all independent of the state of the host.

| live heap / cap | collector | runs OK | pauses in the window | median pause (ms) | max pause (ms) | CPU (s, 60 s wall) | peak WS (GB) | build time |
|---|---|---|---|---|---|---|---|---|
| 8 GB / 14.5 GB | Laxori | 3 of 3 | 81 | 224.7 | 312 | 414 | 14.6 | 34 s |
| 8 GB / 14.5 GB | LXR | **0 of 3** | | | | | | |
| 16 GB / 29 GB | WKS | 3 of 3 | 1046 | 25.6 (gen0 and gen1 pauses) | 41 (of the 30 ms or longer) | 60 | 21.9 | 29 s |
| 16 GB / 29 GB | SVR | 3 of 3 | 53 | 75.1 | 262 to 542 | 135 | 28.2 | 15 s |
| 16 GB / 29 GB | Laxori | 2 of 3 | 70 | 333.7 | 401 | 468 | 23.5 | 86 s |
| 16 GB / 29 GB | LXR | **0 of 3** | | | | | | |
| 24 GB / 40 GB | Laxori | 1 of 1 | 61 | 452.5 | 521 | 520 | 31.8 | 156 s |

* **The failure of LXR (and of one Laxori run at 16 GB) is understood and fixed in Laxori** (commit `56afaba0222`). It is `allocation-pressure collection failed (engine failure 8, SchedulerFailure)`: a **30 s timeout of the InitialMark pause**
  (`CompletePause`, `Timeout = 30000` in `lxr_gc.h`). A temporary diagnostic build of LXR (not committed; `gc_lxr` is unchanged) printed the scheduler state at the timeout: the Release stage open, 13 of 13 workers executing, none parked.
  A capture of all worker stacks (suspend, unwind, symbolize) shows the pause thread and every worker in `free()` -> `RtlFreeHeap` -> `RtlEnterCriticalSection`, called from `RetireSourceChunks` (the `delete chunk` of the copy log);
  `RetireSources` took 38 s in one pause, 13 s and 2.4 s in others, all threads ending together. With the timeout raised to 600 s the same run passes (build phase 75 s).
  Cause: `CopyLog::Chunk` was 16 KB plus 16 bytes. The Windows process heap serves only blocks up to 16368 bytes from its scalable low-fragmentation front end; a larger block goes to the back end (one lock, free-list walk), and 13 workers free tens of thousands of chunks in one pause.
  The same chunk size in a temporary LXR build (1020 entries) makes the 8 GB run pass with no stage longer than 500 ms and a build phase of 52 s. Laxori at 12 GB live: old library 1 of 2 runs failed with failure 8, the fixed library 0 of 2 (small numbers). The tables above were measured **before** the fix.
  Why Laxori passes more often: it copies fewer sources in the private tier, so it frees fewer chunks. The big-heap runs of the table were not repeated with the fixed library [N] (the host was not quiet).
* A growth path observation [N]: with `ImmixInitialMB=4000` and `ImmixReserveMB=21600` (12 GB live) the build phase took about 490 s for the old and the fixed library, against 86 s at 16 GB with initial equal to reserve. I did not look into it (commit steps of the growth on Windows are a candidate).* Laxori at 8 GB: median pause 225 ms on Windows against 235 ms measured on WSL2 for the previous head (STATUS.md, P33), the same size of work. The Laxori library has no per-pause kind record, so all pauses of the window are listed (each is long).
* The 16 GB run of the task needed about 25 GB RSS; Laxori used 23.5 GB, WKS 21.9 GB, SVR 28.2 GB working set.
* Laxori in a 24 GB heap pauses 452 ms (median) and uses 31.8 GB working set; the live heap of 24 GB took 156 s to build.

## 10. What Windows changes (found)

| Topic | Finding |
|---|---|
| **Commit and decommit (large-object space)** | The LOS gives free pages back with `madvise(MADV_DONTNEED)` on Linux and keeps the range committed (`LAXORI_LOS_PERSISTENT_COMMIT`, `HOST_UNIX` only). Windows has no call that gives the memory back and keeps it committed and zero: every large allocation commits, every release decommits (`VirtualCommit` / `VirtualDecommit`). `losarrays` with Laxori: **user 2.3 s, kernel 7.3 s** (WKS: 4.6 s and 0.4 s; LXR: 59 s and 28 s, lock spinning in the LOS under contention). The wall time is 2.8 times WKS (Linux 0.58). The micro benchmark below says why. This is the biggest Windows cost; a fix is a design change (keep the range committed and zero in software, as in the LXR P48 study) and was not done here. |
| Page fault cost | `windows\commitbench.cpp`, ns per 4 KiB page, 2 repetitions, 1 MiB per call: first touch of fresh memory Windows 0.73 to 0.81 us, Linux 1.13 to 1.19 us (1 thread); 2.6 to 3.0 us against 7.3 to 7.9 us (8 threads). |
| Give back and take again | 1 MiB per call, 1 thread: Windows recommit 0.91 to 0.94 us per page, `DiscardVirtualMemory` 1.35 to 1.47 us (slower than recommit); Linux `madvise(DONTNEED)` 1.07 to 1.09 us. 8 threads: Windows recommit 3.3 to 3.8 us, discard 4.8 to 5.0 us; Linux madvise 1.8 us. With 32 KiB per call (the size of an Immix block), 8 threads: Windows 16 to 19 us per page (recommit and discard), Linux madvise 6.4 to 6.8 us. So the best Windows call costs 1.8 times (1 MiB) to 2.5 to 3 times (32 KiB) the Linux call with 8 threads. |
| Thread suspension | `ScalingDriver alloc 32 threads, depth 100` (3 repetitions): median pause Windows / Linux in ms: WKS 0.34 / 0.39, SVR 0.44 / 1.10, LXR 0.99 / 1.60, Laxori 0.87 / 1.48 (p90: 0.99 / 1.68 for Laxori). Windows suspends and scans 32 threads about 40 percent faster than WSL2 for LXR and Laxori. |
| Pause times (six workloads) | Laxori pause Windows / WSL2 0.58 to 1.11 (median 0.85); LXR 0.73 to 2.05 (the 2.05 is losarrays, the commit cost inside the pause). |
| Write barrier cost | Not measured separately [N]. Laxori against LXR on requests and binarytrees on Windows (CPU -30 and -16 percent) is in the range of the Linux difference; the barrier is the same code path with different registers. |
| Working set after a collection | `DRV_WS_AFTER=1` was implemented in the driver but not run [N]. |
| Large pages | Not tried: no `SeLockMemoryPrivilege` for this account [N]. |
| Address space | The side metadata is reserved at fixed addresses (`0xc0000000000` and `0x4c0000000000`); on Windows `VirtualAlloc` at these addresses worked in every run. |
| Commit limit | Windows charges every commit against RAM plus page file at once (Linux over-commits lazily). With a 14 to 40 GB fixed heap and its metadata, initialization can fail with `ERROR_COMMITMENT_LIMIT` when the host has other commit (here 36 to 41 GB of 75 GB). Not a bug of the collector, but it makes `ImmixInitialMB` equal `ImmixReserveMB` large settings less robust than on Linux. |
| Satori | Satori builds and runs on Windows in the same frame (it was not changed); slower than the others on requests (517 ms) and fastest on losarrays and listsuffix. |

## 11. Hardware counters (W4)

`wpr -pmcsources` and `xperf -pmcsources` list only the source `Timer` (interval 10000, "Maximum selectable profile sources: 1") and say "Last Branch Record tracing NOT supported".
The VM exposes no PMU (a hypervisor is present). So ETW "PMC" profiling (cache misses, branch misses, instructions) cannot work on this machine, and Intel VTune would
have no hardware event source either (it could only sample by timer). Nothing was installed. The WSL2 side has the same limit (the `perf` runs of earlier work use `cpu-clock`).

## 12. What was not verified

* ARM64, x86, Debug runs of the native programs, GC stress, the debugger, the DAC and profilers with Laxori on Windows.
* Large pages (`DOTNET_GCLargePages`): the account has no `SeLockMemoryPrivilege` (`whoami /priv`), so they were not tried.
* Hard limits and job objects (container-like memory limits) on Windows.
* More than 64 processors (processor groups); the machine has 16.
* A Windows build of the stock frame without `CrossgenOldValueWriteBarriers` (not needed; the flag is accepted by stock WKS and SVR).
* The LXR library was not rebuilt for Linux at a782e26dc3e: the Linux LXR column uses `libclrlxrgc-walk.so` of P31 (older than the marking-window, safe-LOS and parallel-selection ports), the Linux Laxori column the stage-c build (`libclrlaxorigc-count-c.so`, the same sources as this head; the changes here do not alter Linux code generation).

## 13. Defects that also exist in gc_lxr (not fixed there)

* `src/coreclr/gc_lxr/side_metadata.h:573, 637, 672, 767, 842`: `_ASSERTE((checked.shift & 7) == byteShift)` gives C4389 in a Windows Debug build with `/WX` (same fix as Laxori commit `a732ade1865`).
* `docs/design/lxr-port/P4/lxr-rc-validation.cpp:8413` (and other locals named `small`): `small` is a macro of `rpcndr.h`; `run-lxr-rc-vertical.ps1` stops with C2628 at the head of this branch.
* src/coreclr/gc_lxr/lxr_reference_counting.cpp:637: CopyLog::Chunk::Capacity = 1024 (16 KB + 16 bytes) is above the 16368 byte limit of the Windows low-fragmentation heap. Repro: windows\bigheap-windows.py <out> 1 8000 14500 60 lxr (fails 3 of 3 on Windows with ngine failure 8); with Capacity = 1020 the same run passes (section 9). Same fix as Laxori commit 56afaba0222.
* `gc_lxr` itself compiled with MSVC and ran all seven workloads right in this frame; no other defect was seen. The LXR native programs other than P4 were not run on Windows here.

## 14. Files (`docs/design/laxori-port/windows/`)

`cmake-laxori.cmd`, `native-windows.ps1`, `run-controls.ps1`, `native-barrier-windows.ps1`, `private-tests.ps1`, `hunt-windows.py`, `bench-windows.py`, `bench-wsl2.sh`,
`summarize-comparison.py`, `bigheap-windows.py`, `suspend.py`, `suspend-inner.sh`, `suspend-run.sh`, `commitbench.cpp`, `commitbench-matrix.sh`, `commitbench-run.sh`,
`linux-native-regression.sh`, `driver\` (CompareDriver with the Windows timer and peak working set), `driver-scaling\` (ScalingDriver). In `BarrierTest\`: `laxori-barrier-test-win.asm`.
