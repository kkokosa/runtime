#!/usr/bin/env bash
# Startup working set of a tiny program at several reserves (one run each). usage: rss.sh <lib>
lib=$1
frame=/root/prof/frame-c4
for r in default 128 8000 60000 250000; do
  rm -rf /tmp/rss; mkdir /tmp/rss
  if [[ $r == default ]]; then extra=""; else extra="DOTNET_LXRImmixReserveMB=$r DOTNET_LXRNativePlaneLimitMB=2000000"; fi
  env DOTNET_gcServer=1 DOTNET_GCPath=$lib $extra $frame/corerun /root/prof/drv/bin/CompareDriver.dll /tmp/rss requests 64 2000 > /dev/null 2>&1
  echo "$r rc=$? $(grep -o '"peak_rss_mb":[0-9.]*' /tmp/rss/result.json) $(grep -o '"wall_ms":[0-9.]*' /tmp/rss/result.json)"
done
