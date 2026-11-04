#!/bin/bash
# usage: count.sh <so> : runs the six workloads once and prints barrier counters of the measured window
exec 9>/tmp/lxr-bench.lock; flock 9
SO=$1
FRAME=/root/prof/frame-c4
declare -A SZ=( [requests]="8192 200000" [binarytrees]="18 1" [listsuffix]="8192 600000" [mixedmedium]="12000 200000" [losarrays]="1500 100000" [mediumarrays]="20000 300000" )
for W in requests binarytrees listsuffix mixedmedium losarrays mediumarrays; do
  MARK=/tmp/wbc-$W
  rm -f $MARK.*
  EXTRA=""
  if [ $W = mediumarrays ]; then EXTRA="DOTNET_LXRImmixInitialMB=200 DOTNET_LXRImmixReserveMB=400"; fi
  mkdir -p /root/wb/res/count-$W
  env DOTNET_gcServer=1 DOTNET_GCPath=$SO PROF_MARK=$MARK $EXTRA $FRAME/corerun /root/prof/drv/bin/CompareDriver.dll /root/wb/res/count-$W $W ${SZ[$W]} > /root/wb/res/count-$W.log 2>&1
  echo "== $W $(python3 -c "import json;r=json.load(open('/root/wb/res/count-$W/result.json'));print(round(r['wall_ms']),round(r['cpu_ms']),r['checksum'])")"
  cat $MARK.wbcount
done
