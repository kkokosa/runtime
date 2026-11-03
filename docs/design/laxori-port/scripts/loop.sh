#!/usr/bin/env bash
# usage: loop.sh <runs> <so> <test> <scale> <threads> [ENV=VAL ...]   runs PrivateTests repeatedly, prints pass/fail counts and the first fatal message
runs="$1"; so="$2"; t="$3"; sc="$4"; th="$5"; shift 5
ok=0; bad=0; first=""
for i in $(seq 1 $runs); do
  EXTRA="$*" TAILN=3000 /root/laxori/pt.sh $so $t $sc $th > /tmp/loop-$$.txt 2>&1
  if grep -q '^rc=0' /tmp/loop-$$.txt; then ok=$((ok+1)); else bad=$((bad+1)); [ -z "$first" ] && first=$(grep -m1 -E 'fatal|FAIL|Segm' /tmp/loop-$$.txt | cut -c1-140); fi
done
echo "so=$(basename $so) test=$t scale=$sc threads=$th env=[$*] ok=$ok bad=$bad ${first:+first: $first}"
