#!/usr/bin/env bash
# usage: lib.sh <tree> <subdir> <name>   copies the built libclrlxrgc.so (+ .dbg) to /root/lxr-locks/libs/<name>.so and /root/lxr-locks/dbg/<name>/
set -eu
tree=$1; sub=$2; name=$3
mkdir -p /root/lxr-locks/libs /root/lxr-locks/dbg/$name
cp $tree/artifacts/obj/coreclr/linux.x64.Release/$sub/gc_lxr/libclrlxrgc.so /root/lxr-locks/libs/$name.so
cp $tree/artifacts/obj/coreclr/linux.x64.Release/$sub/gc_lxr/libclrlxrgc.so /root/lxr-locks/dbg/$name/libclrlxrgc.so
dbg=$(find $tree/artifacts -name 'libclrlxrgc.so.dbg' -path "*$sub*" | head -1)
echo "dbg: $dbg"
[ -n "$dbg" ] && cp $dbg /root/lxr-locks/dbg/$name/libclrlxrgc.so.dbg
ls -l /root/lxr-locks/libs /root/lxr-locks/dbg/$name
