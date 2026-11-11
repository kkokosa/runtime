#!/usr/bin/env bash
# Check each message variant and that it is printed once. usage: msg.sh <lib>
lib=$1
frame=/root/prof/frame-c4
gps() { # extra env...
  env DOTNET_gcServer=1 DOTNET_GCPath=$lib "$@" $frame/corerun /root/gcoom/GCPerfSim.dll -tc 28 -tagb 4 -tlgb 2 -lohar 0 -pohar 0 -sohsr 100-4000 -lohsr 102400-204800 -pohsr 100-204800 -sohsi 50 -lohsi 0 -pohsi 0 -sohpi 0 -lohpi 0 -sohfi 0 -lohfi 0 -pohfi 0 -ramb 20 -rlmb 2 -allocType reference -testKind time 2>&1
}
echo "== LOS reserve 64 MB (losarrays)"
rm -rf /tmp/m; mkdir /tmp/m
env DOTNET_gcServer=1 DOTNET_GCPath=$lib DOTNET_LXRLOSReserveMB=64 $frame/corerun /root/prof/drv/bin/CompareDriver.dll /tmp/m losarrays 1500 100000 2>&1 | grep "LXR: out" | cut -c1-260
echo "== native plane limit 2000 MB (default reserve)"
gps DOTNET_LXRNativePlaneLimitMB=2000 | grep "LXR: out" | cut -c1-300
echo "== hard limit 300 MB"
gps DOTNET_LXRManagedHeapHardLimitMB=300 | grep "LXR: out" | cut -c1-300
echo "== counts (28 threads, reserve 128): lines printed"
gps DOTNET_LXRImmixReserveMB=128 | grep -c "LXR: out"
