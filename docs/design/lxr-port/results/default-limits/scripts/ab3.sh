#!/usr/bin/env bash
# A/B for the LOS default. One lock grant per block. usage: ab3.sh <reps> <outdir>
reps=${1:-10}; out=${2:-/root/dl/out/ab3}
for rep in $(seq 1 $reps); do
  for w in losarrays losmany mediumarrays requests; do
    python3 /root/dl/dl-run.py $out $rep $w old,prev,new default
  done
done
# the standard explicit settings of mediumarrays and losmany: old and new must be the same
for rep in $(seq 1 $reps); do
  for w in losmany mediumarrays; do
    python3 /root/dl/dl-run.py ${out}-asrun $rep $w old,new asrun
  done
done
echo AB3DONE
