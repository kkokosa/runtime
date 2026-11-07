#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Validation of the S1 library (no timing). Every step takes the benchmark lock alone and sleeps 8 s afterwards (shared machine).
#   usage: validate-s1.sh <repo root WSL> <s1.so> <base.so> <outdir>
#   1  native engine suites (run-native-all.sh compiles the sources of the worktree: P2.1 to P2.5, P3.1 to P3.4, P4 release)
#   2  PrivateTests all 2 at 1/2/4/8/13 threads, L2 (default) and L1 (DOTNET_LAXORIEscapedInPlace=0), verifier on
#   3  PrivateTests all 2 13, 20 runs each, interleaved: base (L2), s1 (L2), s1 (L1)
#   4  crash hunt (hunt3.sh: 5 workloads + PrivateTests x 3 worker configurations): 54 runs L2, 36 runs L1, verifier on
#   5  trace forced: DOTNET_LAXORITraceThreshold=1 (30 runs)
set -uo pipefail
root="$1"; so="$2"; baseso="$3"; out="$4"
mkdir -p "$out"
L=/root/laxori
locked() { flock /tmp/lxr-bench.lock "$@"; local rc=$?; sleep 8; return $rc; }
echo "== native"; locked nice bash "$root/docs/design/laxori-port/run-native-all.sh" "$root" "$out/native-all" > "$out/native-all.txt" 2>&1; tail -3 "$out/native-all.txt"
echo "== PrivateTests matrix"
: > "$out/pt-matrix.txt"
for th in 1 2 4 8 13; do
  for lvl in L2 L1; do
    e=""; [ $lvl = L1 ] && e="DOTNET_LAXORIEscapedInPlace=0"
    r=$(EXTRA="DOTNET_LAXORIVerifyPrivate=1 $e" TAILN=1 TMO=600 locked bash $L/pt.sh "$so" all 2 $th | tr '\n' ' ')
    echo "$lvl threads=$th: $r" | tee -a "$out/pt-matrix.txt"
  done
done
echo "== PrivateTests all 2 13 x20 (interleaved: base L2, s1 L2, s1 L1)"
declare -A fails; : > "$out/p13.txt"
for i in $(seq 20); do
  for lab in base-L2 s1-L2 s1-L1; do
    case $lab in base-L2) lib="$baseso"; e="";; s1-L2) lib="$so"; e="";; s1-L1) lib="$so"; e="DOTNET_LAXORIEscapedInPlace=0";; esac
    o=$(EXTRA="DOTNET_LAXORIVerifyPrivate=1 $e" TAILN=400 TMO=600 locked bash $L/pt.sh "$lib" all 2 13 2>&1)
    if ! echo "$o" | grep -q '^rc=0'; then
      fails[$lab]=$(( ${fails[$lab]:-0} + 1 )); echo "run $i $lab FAIL: $(echo "$o" | grep -m1 -E 'engine failure|OutOfMemory|FAIL:' | cut -c1-110)" >> "$out/p13.txt"
    fi
  done
done
for lab in base-L2 s1-L2 s1-L1; do echo "$lab: ${fails[$lab]:-0}/20 failed" >> "$out/p13.txt"; done
tail -4 "$out/p13.txt"
hunt() {   # hunt <label> <runs> <env words...>: chunks of 6 runs, one lock hold for each chunk
  local label="$1" runs="$2"; shift 2
  : > "$out/hunt-$label.txt"
  for ((off=0; off<runs; off+=6)); do
    n=$(( runs - off < 6 ? runs - off : 6 ))
    locked bash $L/hunt3.sh "$so" $n "$out/hunt-$label.part" $off "$@"
    cat "$out/hunt-$label.part" >> "$out/hunt-$label.txt"
  done
  echo "$label: ok=$(grep -c ' OK ' "$out/hunt-$label.txt") fail=$(grep -c ' FAIL ' "$out/hunt-$label.txt") of $runs" | tee -a "$out/hunt-summary.txt"
}
echo "== crash hunt"
hunt L2 54 DOTNET_LAXORIVerifyPrivate=1
hunt L1 36 DOTNET_LAXORIVerifyPrivate=1 DOTNET_LAXORIEscapedInPlace=0
echo "== trace forced"
hunt trace 30 DOTNET_LAXORITraceThreshold=1
echo VALIDATION_DONE
