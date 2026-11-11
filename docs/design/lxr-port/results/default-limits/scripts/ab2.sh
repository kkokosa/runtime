#!/usr/bin/env bash
# Isolation run for listsuffix and binarytrees: old, new, new with the old reserve set explicitly. usage: ab2.sh <reps> <outdir>
reps=${1:-10}; out=${2:-/root/dl/out/ab2}
for rep in $(seq 1 $reps); do
  for w in listsuffix binarytrees; do
    python3 /root/dl/dl-run.py $out $rep $w old,new,newr128 default
  done
done
echo AB2DONE
