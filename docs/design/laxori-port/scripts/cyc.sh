#!/usr/bin/env bash
# usage: cyc.sh   incremental build in m0, copy the library and its symbols to /root/laxori/l1, print errors only
R=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-reimagined-eureka
TAILN=2000 /root/laxori/ninja.sh m0 2>&1 | grep -E 'error|FAILED|libclrlaxorigc.so$' | head -${ERRN:-30}
D=$R/artifacts/obj/coreclr/linux.x64.Release/m0/gc_laxori
cp $D/libclrlaxorigc.so $D/libclrlaxorigc.so.dbg /root/laxori/l1/
