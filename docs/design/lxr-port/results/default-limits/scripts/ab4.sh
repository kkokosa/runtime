#!/usr/bin/env bash
# Isolation for losarrays: old, prev, new, new with LXRLOSReserveMB=256 set explicitly. usage: ab4.sh <reps> <outdir>
reps=${1:-15}; out=${2:-/root/dl/out/ab4}
for rep in $(seq 1 $reps); do
  python3 /root/dl/dl-run.py $out $rep losarrays old,prev,new,newlos256 default
done
echo AB4DONE