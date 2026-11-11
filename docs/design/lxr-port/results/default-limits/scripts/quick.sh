#!/usr/bin/env bash
# quick functional checks (not timed). usage: quick.sh <lib>
lib=$1
frame=/root/prof/frame-c4
export DOTNET_gcServer=1 DOTNET_GCPath=$lib
echo "== mediumarrays default (no settings)"
rm -rf /tmp/q; mkdir /tmp/q
$frame/corerun /root/prof/drv/bin/CompareDriver.dll /tmp/q mediumarrays 20000 300000 2>&1 | tail -3
echo "rc=$? $(grep -o '"checksum":[0-9]*' /tmp/q/result.json) expected 7032863679 $(grep -o '"collections":[0-9]*' /tmp/q/result.json)"
echo "== requests with ImmixReserve=128 explicit (expect OOM + message once?)"
rm -rf /tmp/q; mkdir /tmp/q
DOTNET_LXRImmixReserveMB=128 $frame/corerun /root/prof/drv/bin/CompareDriver.dll /tmp/q mediumarrays 20000 300000 2>&1 | grep -c "LXR: out of memory"
DOTNET_LXRImmixReserveMB=128 $frame/corerun /root/prof/drv/bin/CompareDriver.dll /tmp/q mediumarrays 20000 300000 2>&1 | grep -m3 -E "LXR: out of memory|OutOfMemory"
