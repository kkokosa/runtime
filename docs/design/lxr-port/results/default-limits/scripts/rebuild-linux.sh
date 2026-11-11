#!/usr/bin/env bash
# Rebuild gc_lxr in the Linux object directory of this worktree.  usage: rebuild-linux.sh [subdir]
subdir=${1:-old}
root=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-fluffy-pancake
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14 CLR_OBJCOPY=/usr/bin/objcopy
cd $root/artifacts/obj/coreclr/linux.x64.Release/$subdir && ninja clrlxrgc clrlxrgc_bitmap 2>&1 | tail -40
echo "NINJA_RC=${PIPESTATUS[0]}"
ls -l gc_lxr/libclrlxrgc*.so
