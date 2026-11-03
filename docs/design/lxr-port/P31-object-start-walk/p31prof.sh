#!/usr/bin/env bash
# usage: p31prof.sh <outdir> <reps> [workloads]
# Windowed cpu-clock profiles of both variants on the six workloads (tools of the combined3 experiment), then leaf summaries.
set -u
OUT=$1; REPS=$2; WL=${3:-requests,binarytrees,listsuffix,mixedmedium,losarrays,mediumarrays}
export PATH=/usr/lib/linux-tools/5.15.0-202-generic:$PATH
mkdir -p $OUT
sed "s#OUT=/root/prof/res5#OUT=$OUT#" /root/prof/prof-run5.sh > /root/p31/prof-run-p31.sh
declare -A SZ=([requests]="8192 200000" [binarytrees]="18 1" [listsuffix]="8192 600000" [mixedmedium]="12000 200000" [losarrays]="1500 100000" [mediumarrays]="20000 300000")
for rep in $(seq 1 $REPS); do
  for w in ${WL//,/ }; do
    for v in base walk; do
      extra=""
      if [ $w = mediumarrays ]; then extra="DOTNET_LXRImmixInitialMB=200 DOTNET_LXRImmixReserveMB=400"; fi
      tag=$v-$w-$rep
      CMP_FRAME=/root/p31/frame-$v bash /root/p31/prof-run-p31.sh $tag lxr $w ${SZ[$w]} $extra 2>&1 | tail -1
      python3 /root/prof/summary5.py $OUT/$tag.data --tag $tag --json $OUT/$tag.json --frame /root/p31/frame-$v > $OUT/$tag.txt 2>&1
      rm -f $OUT/$tag.data
    done
  done
done