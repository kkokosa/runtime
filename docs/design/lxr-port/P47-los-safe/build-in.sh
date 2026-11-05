#!/usr/bin/env bash
# usage: build-in.sh <source root> <subdir> [bitmap]
# Builds libclrlxrgc.so in a source tree on the ext4 disk (the first configure of a subdir may fail: it runs twice).
root="$1"; sub="$2"; shift 2
cd "$root" || exit 1
bash docs/design/lxr-port/P31-object-start-walk/build-lxr.sh "$sub" "$@" > /root/los-safe/build-$sub-1.log 2>&1
bash docs/design/lxr-port/P31-object-start-walk/build-lxr.sh "$sub" "$@" > /root/los-safe/build-$sub-2.log 2>&1
echo done > /root/los-safe/build-$sub.done
