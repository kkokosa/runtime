#!/usr/bin/env bash
# usage: one.sh <so> <workload> <size> <ops> [ENV=VAL ...]   one run with the updated driver; prints result summary and the private-tier counters
so="$1"; w="$2"; size="$3"; ops="$4"; shift 4
out=/tmp/one-$$; rm -rf $out; mkdir -p $out
env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=${SVR:-1} DOTNET_GCPath=$so "$@" timeout 600 ${FRAME:-/root/prof/frame-c4}/corerun ${DRV:-/root/laxori/drv2/bin}/CompareDriver.dll $out $w $size $ops > $out.txt 2>&1
rc=$?
python3 - $out/result.json $rc <<'PY'
import json,sys
try:
    r=json.load(open(sys.argv[1]))
except Exception as e:
    print("rc="+sys.argv[2], "NO RESULT"); sys.exit()
print("rc=%s wall=%.0f cpu=%.0f pause=%.0f rss=%.0f gcs=%s promotions=%s copied_mb=%.1f checksum=%s" % (sys.argv[2], r["wall_ms"], r["cpu_ms"], r["pause_ms"], r["peak_rss_mb"], r.get("total_collections"), r.get("promotions"), r["lxr_copied_mb"], r["checksum"]))
PY
grep '^laxori:' $out.txt
