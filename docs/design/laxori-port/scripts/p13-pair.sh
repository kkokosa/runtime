#!/usr/bin/env bash
# Interleaved 13-thread PrivateTests failure counts of two builds (removes machine-load drift between the two).
#   usage: p13-pair.sh <runs> <soA> <soB> [extra env...]      prints the failure count and the first message of every failure
runs=$1; a=$2; b=$3; shift 3
fa=0; fb=0
for i in $(seq "$runs"); do
  for w in a b; do
    so=$a; [ $w = b ] && so=$b
    o=$(EXTRA="$*" TAILN=400 TMO=600 bash /root/laxori/pt.sh "$so" all 2 13 2>&1)
    if ! echo "$o" | grep -q '^rc=0'; then
      [ $w = a ] && fa=$((fa+1)) || fb=$((fb+1))
      echo "run $i $w FAIL: $(echo "$o" | grep -m1 -E 'engine failure|OutOfMemory|FAIL:' | cut -c1-110)"
    fi
  done
done
echo "A=$a failed $fa/$runs ; B=$b failed $fb/$runs"
