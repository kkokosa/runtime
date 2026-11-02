#!/usr/bin/env bash
# usage: ninja-laxori.sh <subdir>   (incremental build in an already configured dir; cmake re-runs only when CMakeLists changed)
set -uo pipefail
sub="${1:-m0}"
R=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-reimagined-eureka
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
cd "$R/artifacts/obj/coreclr/linux.x64.Release/$sub"
ninja -j4 clrlaxorigc 2>&1 | tail -${TAILN:-80}
ls -l gc_laxori/libclrlaxorigc.so
