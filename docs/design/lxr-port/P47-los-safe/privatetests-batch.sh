#!/usr/bin/env bash
# usage: pt.sh <libdir with libclrlxrgc.so> <runs> <outdir>   PrivateTests "all 2 13", every run under the benchmark lock.
lib="$1/libclrlxrgc.so"; runs="$2"; out="$3"
corerun=/root/prof/frame-c4/corerun
dotnet=/root/p24-linux-postreview/.dotnet/dotnet
here=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-super-lamp/docs/design/lxr-port/P32-privatetests-failure
build=/root/los-safe/pt-build
if [[ ! -f $build/out/PrivateTests.dll ]]; then
    mkdir -p $build && cp $here/PrivateTests.cs $here/PrivateTests.csproj $build/
    (cd $build && $dotnet build -c Release -o out > build.log 2>&1) || { echo "build failed"; tail -5 $build/build.log; exit 1; }
fi
mkdir -p "$out"
export DOTNET_gcServer=1 DOTNET_GCPath="$lib"
fails=0
for i in $(seq 1 $runs); do
    if [[ -n "${PT_HOLD_LOCK:-}" ]]; then
        timeout 300 $corerun $build/out/PrivateTests.dll all 2 13 > $out/r$i.log 2>&1 || fails=$((fails + 1))
    else
        flock /tmp/lxr-bench.lock timeout 300 $corerun $build/out/PrivateTests.dll all 2 13 > $out/r$i.log 2>&1 || fails=$((fails + 1))
    fi
done
echo "lib=$lib runs=$runs fails=$fails"
echo "LXR fatal: $(grep -l 'LXR fatal' $out/r*.log 2>/dev/null | wc -l)  OOM: $(grep -l 'OutOfMemoryException' $out/r*.log 2>/dev/null | wc -l)"
