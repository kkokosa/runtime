#!/usr/bin/env bash
# 13-thread PrivateTests failure rates of several configurations, interleaved run by run (the machine is shared).
#   usage: p13-multi.sh <runs> <out> <label>=<so>[:ENV=VAL[,ENV=VAL]] ...
runs=$1; out=$2; shift 2
declare -A fails
: > "$out"
for i in $(seq "$runs"); do
  for spec in "$@"; do
    lab=${spec%%=*}; rest=${spec#*=}; so=${rest%%:*}; env=""; [ "$rest" != "$so" ] && env=${rest#*:}
    o=$(EXTRA="DOTNET_LAXORIVerifyPrivate=1 ${env//,/ }" TAILN=400 TMO=600 bash /root/laxori/pt.sh "$so" all 2 13 2>&1)
    if ! echo "$o" | grep -q '^rc=0'; then
      fails[$lab]=$(( ${fails[$lab]:-0} + 1 ))
      echo "run $i $lab FAIL: $(echo "$o" | grep -m1 -E 'engine failure|OutOfMemory|FAIL:' | cut -c1-110)" >> "$out"
    fi
  done
done
for spec in "$@"; do lab=${spec%%=*}; echo "$lab: ${fails[$lab]:-0}/$runs failed" >> "$out"; done
echo done >> "$out"
