#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# The WSL2 side of the Windows-versus-Linux comparison: the same six workloads and losmany, the same collectors, on the same VM,
# with the Linux frame /root/prof/frame-c4 and the Linux libraries of the same source head (count-plane build, stage c).
# One repetition per flock (a repetition is about 3 to 5 minutes), nine repetitions, each in its own output directory.
# usage: bench-wsl2.sh <outroot> [reps]
out="${1:-/root/laxori/winlinux}"; reps="${2:-9}"
export FRAME=/root/prof/frame-c4
export DRIVER=/root/laxori/drv2/bin/CompareDriver.dll
export LXR_SO_WALK=/root/p31/so/libclrlxrgc-walk.so
mkdir -p "$out"
for ((r = 0; r < reps; r++)); do
  flock /tmp/lxr-bench.lock python3 /mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-refactored-journey/docs/design/laxori-port/scripts/bench3.py \
    "$out/rep$r" 1 wks,svr,lxr-walk,laxori-count-c,satori requests,binarytrees,listsuffix,mixedmedium,losarrays,mediumarrays,losmany \
    > "$out/rep$r.log" 2>&1
done
echo done > "$out/DONE"
