#!/usr/bin/env bash
# usage: rtloop.sh <so> <rounds> <log>   runs RequestTests at 1,2,4,8 threads, <rounds> times each
so="$1"; rounds="$2"; log="$3"; : > "$log"; ok=0; bad=0
for ((r=0;r<rounds;r++)); do
  for t in 1 2 4 8; do
    out=$(TAILN=3 /root/laxori/rtn.sh "$so" $t 40000 2>&1)
    if echo "$out" | grep -q '^rc=0' && echo "$out" | grep -q PASS; then ok=$((ok+1)); echo "round $r threads $t PASS" >> "$log"
    else bad=$((bad+1)); echo "round $r threads $t FAIL: $out" >> "$log"; fi
  done
done
echo "DONE ok=$ok bad=$bad" >> "$log"
