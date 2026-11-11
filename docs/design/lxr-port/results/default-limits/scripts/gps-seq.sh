#!/usr/bin/env bash
# One lock grant per run. usage: gps-seq.sh   (runs the list below)
G=/root/dl/gps.sh
L=/root/dl/libs
run() { flock /tmp/lxr-bench.lock bash $G "$@"; sleep 8; }
run $L/libclrlxrgc-old.so 540 /root/dl/out/g-old-540-r6000.log DOTNET_LXRImmixReserveMB=6000 DOTNET_LXRNativePlaneLimitMB=60000
run $L/libclrlxrgc-new.so 540 /root/dl/out/g-new-540-r6000.log DOTNET_LXRImmixReserveMB=6000 DOTNET_LXRNativePlaneLimitMB=60000
run $L/libclrlxrgc-new.so 540 /root/dl/out/g-new-540-default.log
echo GPSDONE
