#!/usr/bin/env bash
# A/B: old default, new default, new with an explicit large reserve. One lock grant per block (one rep of one workload).
# usage: ab.sh <reps> <outdir>
reps=${1:-10}; out=${2:-/root/dl/out/ab}
for rep in $(seq 1 $reps); do
  for w in listsuffix binarytrees mixedmedium requests losarrays mediumarrays; do
    python3 /root/dl/dl-run.py $out $rep $w old,new,newbig default
  done
done
# explicit settings as the standard runs use them for mediumarrays: old and new must be the same
for rep in $(seq 1 $reps); do
  python3 /root/dl/dl-run.py ${out}-asrun $rep mediumarrays old,new asrun
done
echo ABDONE
