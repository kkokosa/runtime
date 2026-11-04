#!/bin/bash
# P32. Records the measured window of one CompareDriver run with perf (cpu-clock, WSL2 has no hardware counters).
# usage: profrun.sh <tag> <path of libclrlxrgc.so> <workload> <size> <ops> [extra env KEY=VAL...]
# Output: /root/lxr-locks/prof/<tag>.data, <tag>.log, <tag>/result.json
export PATH=/usr/lib/linux-tools/5.15.0-202-generic:$PATH
TAG=$1; SO=$2; W=$3; SZ=$4; OPS=$5; shift 5
OUT=/root/lxr-locks/prof; mkdir -p $OUT
FRAME=/root/prof/frame-c4
MARK=/tmp/prof-$TAG
rm -f $MARK.start $MARK.end /tmp/prof-$TAG.ctl /tmp/prof-$TAG.ack
mkfifo /tmp/prof-$TAG.ctl /tmp/prof-$TAG.ack
cat /tmp/prof-$TAG.ack > /dev/null &
ACKPID=$!
(
  while [ ! -f $MARK.start ]; do sleep 0.01; done
  echo enable > /tmp/prof-$TAG.ctl
  while [ ! -f $MARK.end ]; do sleep 0.01; done
  echo disable > /tmp/prof-$TAG.ctl
) &
WATCH=$!
env DOTNET_gcServer=1 DOTNET_GCPath=$SO DOTNET_EnableWriteXorExecute=0 PROF_MARK=$MARK "$@" \
  perf record -D -1 -F ${PROF_F:-4000} ${PROF_CG:--g} -e cpu-clock --control=fifo:/tmp/prof-$TAG.ctl,/tmp/prof-$TAG.ack \
  -o $OUT/$TAG.data $FRAME/corerun /root/prof/drv/bin/CompareDriver.dll $OUT/$TAG $W $SZ $OPS > $OUT/$TAG.log 2>&1
RC=$?
kill $WATCH $ACKPID 2>/dev/null
rm -f /tmp/prof-$TAG.ctl /tmp/prof-$TAG.ack
echo "$TAG rc=$RC $(python3 -c "import json;r=json.load(open('$OUT/$TAG/result.json'));print(round(r['wall_ms']),round(r['cpu_ms']),round(r['pause_ms']),r['collections'],r['checksum'])" 2>&1 | tail -1)"
