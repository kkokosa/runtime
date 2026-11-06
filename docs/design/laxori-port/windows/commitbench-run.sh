#!/usr/bin/env bash
# usage: commitbench-run.sh <outfile> <reps>   alternates Windows and Linux, each matrix under the shared lock
out="$1"; reps="${2:-5}"
S=/root/laxori/commitbench-matrix.sh
: > "$out"
for ((r = 0; r < reps; r++)); do
  for os in win lin; do
    flock /tmp/lxr-bench.lock bash $S $os | sed "s/^/rep$r /" >> "$out"
  done
done
echo done >> "$out.done"
