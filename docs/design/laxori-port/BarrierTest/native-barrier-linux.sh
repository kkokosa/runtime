#!/bin/bash
# Build and run the native test of the Laxori write barrier assembly.
# usage: native-barrier-linux.sh <repo-root-as-WSL-path> <output-dir>
set -u
REPO="$1"
OUT="$2"
mkdir -p "$OUT"
GC="$REPO/src/coreclr/gc_laxori"
TEST="$REPO/docs/design/laxori-port/BarrierTest/laxori-barrier-test.cpp"
clang -c -x assembler-with-cpp -DHOST_AMD64 -DTARGET_AMD64 -DTARGET_UNIX -DHOST_UNIX \
  -I"$REPO/src/coreclr/pal/inc" -I"$REPO/src/coreclr/pal/inc/unix" "$GC/amd64/laxori_writebarrier.S" -o "$OUT/asm.o" || exit 1
clang++ -std=c++17 -O2 -mxsave -pthread -Wall -Wextra -Wno-unused-parameter -I"$GC" \
  "$TEST" "$GC/laxori_write_barrier.cpp" "$OUT/asm.o" -o "$OUT/barrier-test" || exit 1
"$OUT/barrier-test"
