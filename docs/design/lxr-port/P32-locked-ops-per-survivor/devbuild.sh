#!/usr/bin/env bash
# P32. Builds the LXR collector from the work tree in an ext4 copy (much faster than /mnt/c) and saves the library.
# usage: devbuild.sh <name>     -> /root/lxr-locks/libs/<name>.so and /root/lxr-locks/dbg/<name>/
# The copy /root/lxr-locks/tree-base has been configured once with `build-lxr.sh base0`; only the sources of the collector are synced.
set -eu
name=$1
src=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-bookish-couscous
tree=/root/lxr-locks/tree-base
rsync -a --delete "$src/src/coreclr/gc_lxr/" "$tree/src/coreclr/gc_lxr/"
rsync -a "$src/src/coreclr/gc/env/" "$tree/src/coreclr/gc/env/"
cd "$tree"
bash docs/design/lxr-port/P31-object-start-walk/build-lxr.sh base0 > /root/lxr-locks/build-$name.log 2>&1 || true
tail -3 /root/lxr-locks/build-$name.log | cut -c1-200
grep -E "error:|BUILD_RC" /root/lxr-locks/build-$name.log | head -20
mkdir -p /root/lxr-locks/libs "/root/lxr-locks/dbg/$name"
b=$tree/artifacts/obj/coreclr/linux.x64.Release/base0/gc_lxr
cp $b/libclrlxrgc.so /root/lxr-locks/libs/$name.so
cp $b/libclrlxrgc.so "/root/lxr-locks/dbg/$name/libclrlxrgc.so"
cp $b/libclrlxrgc.so.dbg "/root/lxr-locks/dbg/$name/libclrlxrgc.so.dbg"
ls -l /root/lxr-locks/libs/$name.so
