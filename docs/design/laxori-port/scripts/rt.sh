#!/usr/bin/env bash
# usage: rt.sh <so|none> <threads> <iterations> [REQ=0|1]   runs RequestTests; prints result and request metrics
so="$1"; th="$2"; it="$3"
if [ "$so" = none ]; then gcenv=""; else gcenv="DOTNET_GCPath=$so"; fi
flock /tmp/lxr-bench.lock env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=${SVR:-1} DOTNET_LAXORIRequests=${REQ:-1} $gcenv $EXTRA \
  timeout 600 /root/prof/frame-p/corerun /root/laxori/rt/bin/RequestTests.dll $th $it $4 > /tmp/rt-$$.txt 2>&1
rc=$?
echo "rc=$rc"; tail -${TAILN:-6} /tmp/rt-$$.txt; rm -f /tmp/rt-$$.txt
