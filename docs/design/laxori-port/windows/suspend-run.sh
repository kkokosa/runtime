#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# Runs suspend-inner.sh <reps> times, each under one hold of the shared lock.   usage (in WSL2): suspend-run.sh <outfile> <reps>
out="${1:-/root/laxori/suspend.txt}"; reps="${2:-5}"
: > "$out"
for ((r = 0; r < reps; r++)); do
  flock /tmp/lxr-bench.lock bash /root/laxori/suspend-inner.sh "$out" "$r"
done
echo done > "$out.done"
