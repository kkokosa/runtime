#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# Runs the commitbench matrix once on one OS of the VM. usage: commitbench-matrix.sh win|lin
# Under the shared lock:  flock /tmp/lxr-bench.lock bash commitbench-matrix.sh win
os="$1"
if [ "$os" = win ]; then bench() { /mnt/c/Windows/System32/cmd.exe /c 'C:\lx-run\commitbench.exe' "$@" | tr -d '\r'; }
else bench() { /root/laxori/commitbench "$@"; }; fi
for mode in touch recommit discard; do
  for threads in 1 8; do
    for mib in 1 0.03125; do
      if [ "$mib" = 1 ]; then calls=3000; else calls=60000; fi
      echo "$os $(bench $mode $threads $mib $calls)"
    done
  done
done
