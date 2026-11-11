#!/usr/bin/env bash
# Run under a cgroup v2 memory limit: the default reserve must follow the container limit. usage: cg.sh <lib> <limit e.g. 1G>
lib=$1; lim=$2
cg=/sys/fs/cgroup/dltest
mount | grep -q "cgroup2" || { echo "no cgroup2"; exit 1; }
mkdir -p $cg || exit 1
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
echo $lim > $cg/memory.max || { echo "cannot set memory.max"; exit 1; }
echo "memory.max=$(cat $cg/memory.max)"
(
  echo $BASHPID > $cg/cgroup.procs
  export DOTNET_gcServer=1 DOTNET_GCPath=$lib
  /root/prof/frame-c4/corerun /root/gcoom/GCPerfSim.dll -tc 4 -tagb 4 -tlgb 1.5 -lohar 0 -pohar 0 -sohsr 100-4000 -lohsr 102400-204800 -pohsr 100-204800 -sohsi 50 -lohsi 0 -pohsi 0 -sohpi 0 -lohpi 0 -sohfi 0 -lohfi 0 -pohfi 0 -ramb 20 -rlmb 2 -allocType reference -testKind time 2>&1 | grep -E "LXR: out|OutOfMemory|Killed|final_heap" | head -4
  echo "rc=${PIPESTATUS[0]}"
)
rmdir $cg 2>/dev/null
