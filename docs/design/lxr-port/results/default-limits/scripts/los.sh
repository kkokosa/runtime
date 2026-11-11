#!/usr/bin/env bash
# losmany at the defaults (no setting): old, prev (Immix default only), new. usage: los.sh [entries] [ops]
e=${1:-2000}; o=${2:-60000}
for v in old prev new; do
  rm -rf /tmp/lm; mkdir /tmp/lm
  flock /tmp/lxr-bench.lock env DOTNET_gcServer=1 DOTNET_GCPath=/root/dl/libs/libclrlxrgc-$v.so /root/prof/frame-c4/corerun /root/p44/drv/bin/CompareDriver.dll /tmp/lm losmany $e $o > /tmp/lm/out.txt 2>&1
  rc=$?
  echo "$v losmany $e $o rc=$rc $(grep -o '"checksum":[0-9]*' /tmp/lm/result.json 2>/dev/null) $(grep -o '"wall_ms":[0-9.]*' /tmp/lm/result.json 2>/dev/null) $(grep -o '"collections":[0-9]*' /tmp/lm/result.json 2>/dev/null) $(grep -o '"peak_rss_mb":[0-9.]*' /tmp/lm/result.json 2>/dev/null) $(grep -m1 'LXR: out' /tmp/lm/out.txt | cut -c1-200)"
  sleep 8
done
