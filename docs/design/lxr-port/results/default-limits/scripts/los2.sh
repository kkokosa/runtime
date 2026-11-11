#!/usr/bin/env bash
# losmany with bigger tables at the new default. usage: los2.sh <lib> <entries>...
lib=$1; shift
for n in "$@"; do
  rm -rf /tmp/lm; mkdir /tmp/lm
  flock /tmp/lxr-bench.lock env DOTNET_gcServer=1 DOTNET_GCPath=$lib /root/prof/frame-c4/corerun /root/p44/drv/bin/CompareDriver.dll /tmp/lm losmany $n 60000 > /tmp/lm/out.txt 2>&1
  echo "losmany $n rc=$? $(grep -o '"checksum":[0-9]*' /tmp/lm/result.json 2>/dev/null) $(grep -o '"wall_ms":[0-9.]*' /tmp/lm/result.json 2>/dev/null) $(grep -o '"peak_rss_mb":[0-9.]*' /tmp/lm/result.json 2>/dev/null) $(grep -m1 'LXR: out' /tmp/lm/out.txt | cut -c1-250)"
  sleep 8
done
