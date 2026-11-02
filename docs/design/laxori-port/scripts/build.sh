#!/usr/bin/env bash
# usage: build-laxori.sh <subdir> [extra cmake args]
set -uo pipefail
sub="$1"; shift
extra="${*:-}"
cd /mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-reimagined-eureka
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
bash src/coreclr/build-runtime.sh -release -x64 -ninja -component clrlaxorigc -subdir "$sub" -numproc 4 -cmakeargs "-DCLR_CMAKE_ENABLE_LAXORI_GC=ON $extra"
rc=$?
so=artifacts/obj/coreclr/linux.x64.Release/$sub/gc_laxori/libclrlaxorigc.so
ls -l "$so"
echo "BUILD_RC=$rc"
