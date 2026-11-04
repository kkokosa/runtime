#!/usr/bin/env bash
# P32. Makes a frame directory for p32hunt.py: the files of frame-c4 (symlinks) and the library <name> as libclrlxrgc.so.
# usage: mkframe.sh <name>    (the library is /root/lxr-locks/libs/<name>.so)
set -eu
n=$1
d=/root/lxr-locks/frame-$n
rm -rf "$d"; mkdir -p "$d"
for f in /root/prof/frame-c4/*; do
    b=$(basename "$f")
    case "$b" in libclrlxrgc.so|libclrlxrgc.so.dbg) ;; *) ln -s "$f" "$d/$b";; esac
done
cp /root/lxr-locks/libs/$n.so "$d/libclrlxrgc.so"
ls "$d" | wc -l
