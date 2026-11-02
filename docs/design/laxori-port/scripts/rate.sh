#!/usr/bin/env bash
# usage: rate.sh <runs> <test> <scale> <threads> [ENV=VAL ...]   prints how many runs pass
runs="$1"; t="$2"; sc="$3"; th="$4"; shift 4
ok=0; bad=0
for i in $(seq 1 $runs); do
  EXTRA="$*" TAILN=3000 /root/laxori/pt.sh /root/laxori/l1/libclrlaxorigc.so $t $sc $th > /tmp/rate.txt 2>&1
  if grep -q '^rc=0' /tmp/rate.txt; then ok=$((ok+1)); else bad=$((bad+1)); fi
done
echo "test=$t scale=$sc threads=$th env=[$*] pass=$ok fail=$bad"
