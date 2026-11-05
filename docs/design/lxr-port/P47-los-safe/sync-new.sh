#!/usr/bin/env bash
# usage: sync-new.sh   Copies the LXR sources and the P-docs of the worktree into /root/los-safe/new-src (ext4) and builds subdir "new".
W=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-super-lamp
N=/root/los-safe/new-src
if [[ ! -d $N ]]; then mkdir -p $N; rsync -a --exclude artifacts /root/los-safe/base-src/ $N/; fi
rsync -a --delete $W/src/coreclr/gc_lxr/ $N/src/coreclr/gc_lxr/
rsync -a $W/docs/design/lxr-port/ $N/docs/design/lxr-port/
rm -f /root/los-safe/build-new.done
bash /root/los-safe/build-in.sh $N new
cat /root/los-safe/build-new-2.log | tail -4
mkdir -p /root/los-safe/libs/new
cp $N/artifacts/obj/coreclr/linux.x64.Release/new/gc_lxr/libclrlxrgc*.so* /root/los-safe/libs/new/
ls -l /root/los-safe/libs/new
