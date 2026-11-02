#!/bin/bash
# usage: profile-laxori.sh <tag> <wks|svr|lxr|satori|laxori> <workload> <size> <ops> [extra env KEY=VAL...]
# Records only the measured window of the driver (cpu-clock, 4000 Hz, call graphs) on frame-c4. perf: 5.15.0-202.
# Laxori: LAXORI_SO (default /root/laxori/prof/libclrlaxorigc.so, with its .dbg next to it).
export PATH=/usr/lib/linux-tools/5.15.0-202-generic:$PATH
TAG=$1; COL=$2; W=$3; SZ=$4; OPS=$5; shift 5
OUT=${OUT:-/root/laxori/res-prof}; mkdir -p $OUT
FRAME=${FRAME:-/root/prof/frame-c4}
DRV=${DRV:-/root/laxori/drv2/bin/CompareDriver.dll}
LAXORI_SO=${LAXORI_SO:-/root/laxori/prof/libclrlaxorigc.so}
MARK=/tmp/prof-$TAG
rm -f $MARK.start $MARK.end /tmp/prof-$TAG.ctl /tmp/prof-$TAG.ack
mkfifo /tmp/prof-$TAG.ctl /tmp/prof-$TAG.ack
cat /tmp/prof-$TAG.ack > /dev/null &
ACKPID=$!
EXTRA_MA=""
case $COL in
  wks) ENVS="DOTNET_gcServer=0" ;;
  svr) ENVS="DOTNET_gcServer=1" ;;
  satori) ENVS="DOTNET_gcServer=0 DOTNET_GCPath=$FRAME/libsatorigc.so" ;;
  lxr) ENVS="DOTNET_gcServer=1 DOTNET_GCPath=$FRAME/libclrlxrgc.so" ;;
  laxori) ENVS="DOTNET_gcServer=1 DOTNET_GCPath=$LAXORI_SO" ;;
esac
(
  while [ ! -f $MARK.start ]; do sleep 0.01; done
  echo enable > /tmp/prof-$TAG.ctl
  while [ ! -f $MARK.end ]; do sleep 0.01; done
  echo disable > /tmp/prof-$TAG.ctl
) &
WATCH=$!
env $ENVS DOTNET_PerfMapEnabled=1 DOTNET_EnableWriteXorExecute=0 PROF_MARK=$MARK "$@" \
  perf record -D -1 -F ${PROF_F:-4000} ${PROF_CG:--g} -e cpu-clock --control=fifo:/tmp/prof-$TAG.ctl,/tmp/prof-$TAG.ack \
  -o $OUT/$TAG.data $FRAME/corerun $DRV $OUT/$TAG $W $SZ $OPS > $OUT/$TAG.log 2>&1
RC=$?
kill $WATCH $ACKPID 2>/dev/null
rm -f /tmp/prof-$TAG.ctl /tmp/prof-$TAG.ack
echo "$TAG rc=$RC $(python3 -c "import json;r=json.load(open('$OUT/$TAG/result.json'));print(round(r['wall_ms']),round(r['cpu_ms']),round(r['pause_ms']),r['collections'],r['checksum'])" 2>&1 | tail -1)"
