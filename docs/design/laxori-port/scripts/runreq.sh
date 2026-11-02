#!/usr/bin/env bash
# usage: runreq.sh <so> <workload> <size> <ops> ; Laxori requests on, prints result line and request metrics
so="$1"; w="$2"; size="$3"; ops="$4"
out=/tmp/runreq-$$; mkdir -p $out
flock /tmp/lxr-bench.lock env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_LAXORIRequests=${REQ:-1} DOTNET_GCPath="$so" $EXTRA \
  /root/prof/frame-p/corerun /root/laxori/drv/bin/CompareDriver.dll $out $w $size $ops > $out/log.txt 2>&1
echo rc=$?
tail -3 $out/log.txt
python3 -c "import json; r=json.load(open('$out/result.json')); print(r['workload'], r['checksum'], 'wall',round(r['wall_ms']), 'cpu',round(r['cpu_ms']), 'pause',round(r['pause_ms']), 'cols',r['collections'], 'rss',round(r['peak_rss_mb']))"
