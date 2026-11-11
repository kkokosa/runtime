#!/usr/bin/env bash
# LOS default under a cgroup v2 limit: losmany with more large data than the limit. usage: cg2.sh <lib> <limit> <entries>
lib=$1; lim=$2; n=$3
cg=/sys/fs/cgroup/dltest2
mkdir -p $cg || exit 1
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
echo $lim > $cg/memory.max || exit 1
echo "memory.max=$(cat $cg/memory.max)"
(
  echo $BASHPID > $cg/cgroup.procs
  rm -rf /tmp/lm2; mkdir /tmp/lm2
  env DOTNET_gcServer=1 DOTNET_GCPath=$lib /root/prof/frame-c4/corerun /root/p44/drv/bin/CompareDriver.dll /tmp/lm2 losmany $n 60000 2>&1 | grep -E "LXR: out|OutOfMemory" | head -3 | cut -c1-300
  echo "rc=${PIPESTATUS[0]}"
)
rmdir $cg 2>/dev/null
