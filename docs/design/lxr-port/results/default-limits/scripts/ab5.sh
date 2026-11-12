#!/usr/bin/env bash
# A/B of the commit-on-demand fix: new (d67c equivalent) against fix. One lock grant per block. usage: ab5.sh <reps> <outdir>
reps=${1:-10}; out=${2:-/root/dl/out/ab5}
for rep in $(seq 1 $reps); do
  for w in losarrays losmany requests mixedmedium listsuffix; do
    python3 /root/dl/dl-run.py $out $rep $w new,fix default
  done
done
echo AB5DONE