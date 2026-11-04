#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Builds and runs the micro-benchmark of the LXR write barrier assembly. Run it under the benchmark lock.
#   usage: run-microbench.sh <repo-root> <output-dir> [reps] [assembly file]
# The fourth argument replaces the assembly of the tree, to compare two versions of the barrier.
set -eu
REPO="$1"; OUT="$2"; REPS="${3:-9}"
GC="$REPO/src/coreclr/gc_lxr"
ASM="${4:-$GC/amd64/lxr_writebarrier.S}"
mkdir -p "$OUT"
clang -c -x assembler-with-cpp -DHOST_AMD64 -DTARGET_AMD64 -DTARGET_UNIX -DHOST_UNIX \
    -I"$REPO/src/coreclr/pal/inc" -I"$REPO/src/coreclr/pal/inc/unix" "$ASM" -o "$OUT/wb.o"
clang++ -std=c++17 -O2 -mxsave -I"$GC" "$REPO/docs/design/lxr-port/P41-write-barrier-fast-path/barrier-microbench.cpp" \
    "$GC/lxr_write_barrier.cpp" "$OUT/wb.o" -o "$OUT/microbench"
"$OUT/microbench" "$REPS"
