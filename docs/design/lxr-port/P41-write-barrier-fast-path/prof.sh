#!/bin/bash
# usage: prof.sh <tag> <so> <workload> <size> <ops> [extra env KEY=VAL...]
# perf record (cpu-clock) of the measured window only, call chains off. Output /root/wb/res/<tag>.data
export PATH=/usr/lib/linux-tools/5.15.0-202-generic:$PATH
exec 9>/tmp/lxr-bench.lock; flock 9
TAG=$1; SO=$2; W=$3; SZ=$4; OPS=$5; shift 5
OUT=/root/wb/res; mkdir -p $OUT
FRAME=/root/prof/frame-c4
MARK=/tmp/profwb-$TAG
rm -f $MARK.start $MARK.end /tmp/profwb-$TAG.ctl /tmp/profwb-$TAG.ack
mkfifo /tmp/profwb-$TAG.ctl /tmp/profwb-$TAG.ack
cat /tmp/profwb-$TAG.ack > /dev/null &
ACKPID=$!
(
  while [ ! -f $MARK.start ]; do sleep 0.01; done
  echo enable > /tmp/profwb-$TAG.ctl
  while [ ! -f $MARK.end ]; do sleep 0.01; done
  echo disable > /tmp/profwb-$TAG.ctl
) &
WATCH=$!
env DOTNET_gcServer=1 DOTNET_GCPath=$SO DOTNET_PerfMapEnabled=1 DOTNET_EnableWriteXorExecute=0 PROF_MARK=$MARK "$@" \
  perf record -D -1 -F ${PROF_F:-4000} ${PROF_CG:--g} -e cpu-clock --control=fifo:/tmp/profwb-$TAG.ctl,/tmp/profwb-$TAG.ack \
  -o $OUT/$TAG.data $FRAME/corerun /root/prof/drv/bin/CompareDriver.dll $OUT/$TAG $W $SZ $OPS > $OUT/$TAG.log 2>&1
RC=$?
cp $(ls -t /tmp/perf-*.map | head -1) $OUT/$TAG.map
kill $WATCH $ACKPID 2>/dev/null
rm -f /tmp/profwb-$TAG.ctl /tmp/profwb-$TAG.ack
echo "$TAG rc=$RC $(python3 -c "import json;r=json.load(open('$OUT/$TAG/result.json'));print(round(r['wall_ms']),round(r['cpu_ms']),round(r['pause_ms']),r['collections'],r['checksum'])" 2>&1 | tail -1)"
