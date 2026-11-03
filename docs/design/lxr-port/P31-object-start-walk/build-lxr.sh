#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Builds the LXR collector library in one build directory.
#   usage: build-lxr.sh <subdir> [bitmap] [extra cmake args...]
#   build-lxr.sh walk             -> artifacts/obj/coreclr/linux.x64.Release/walk/gc_lxr/libclrlxrgc.so   (default: count-plane object starts, no ValidObject plane)
#   build-lxr.sh base bitmap      -> artifacts/obj/coreclr/linux.x64.Release/base/gc_lxr/libclrlxrgc.so   (ValidObject plane)
# The default full LXR build also builds libclrlxrgc-bitmap.so (target clrlxrgc_bitmap) next to libclrlxrgc.so.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
sub="$1"; shift
variant=""
if [[ "${1:-}" == "bitmap" ]]; then variant="-DCLR_CMAKE_LXR_OBJECT_START_BITMAP=ON"; shift; fi
extra="${*:-}"
cd "$root"
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
bash src/coreclr/build-runtime.sh -release -x64 -ninja -component clrlxrgc -subdir "$sub" -numproc 4 \
    -cmakeargs "-DCLR_CMAKE_ENABLE_LXR_GC=ON $variant $extra"
rc=$?
ls -l artifacts/obj/coreclr/linux.x64.Release/"$sub"/gc_lxr/libclrlxrgc*.so
echo "BUILD_RC=$rc"
