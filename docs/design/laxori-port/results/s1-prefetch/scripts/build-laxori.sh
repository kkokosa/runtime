#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Builds libclrlaxorigc.so in one build directory of this worktree (count-plane build is the default).
#   usage: build-laxori.sh <subdir> [extra cmake args...]
#   build-laxori.sh base                -> artifacts/obj/coreclr/linux.x64.Release/base/gc_laxori/libclrlaxorigc.so
#   build-laxori.sh loc "-DCLR_CMAKE_ENABLE_LAXORI_PHASE_TIMERS=ON"   (diagnostic build)
# The first CMake configure of a new subdir on /mnt/c can fail with a CMakeScratch permission error: run the same command again.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)"
sub="$1"; shift
extra="${*:-}"
cd "$root"
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
bash src/coreclr/build-runtime.sh -release -x64 -ninja -component clrlaxorigc -subdir "$sub" -numproc 4 \
    -cmakeargs "-DCLR_CMAKE_ENABLE_LAXORI_GC=ON $extra"
rc=$?
ls -l artifacts/obj/coreclr/linux.x64.Release/"$sub"/gc_laxori/libclrlaxorigc*.so
echo "BUILD_RC=$rc"
