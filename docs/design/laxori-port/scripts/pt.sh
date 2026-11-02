#!/usr/bin/env bash
# usage: pt.sh <so|none> <test> <scale> <threads>   runs PrivateTests on frame-c4 without the bench lock
so="$1"; t="${2:-all}"; sc="${3:-1}"; th="${4:-1}"
if [ "$so" = none ]; then gcenv=""; else gcenv="DOTNET_GCPath=$so"; fi
env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=${SVR:-1} $gcenv $EXTRA \
  timeout ${TMO:-300} /root/prof/frame-c4/corerun /root/laxori/pt/bin/PrivateTests.dll $t $sc $th > /tmp/pt-$$.txt 2>&1
rc=$?
echo "rc=$rc"; tail -${TAILN:-25} /tmp/pt-$$.txt; rm -f /tmp/pt-$$.txt
