#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Builds PrivateTests and runs it many times on one LXR library. Failures by kind are counted at the end.
#   usage: repeat.sh <libclrlxrgc.so> <runs> <output directory> [PrivateTests arguments, default: all 2 13]
# Needs: a corerun frame with a CoreLib built with CrossgenOldValueWriteBarriers (CORERUN, default
# /root/prof/frame-c4/corerun) and a dotnet SDK (DOTNET, default /root/.dotnet-runtime-p13/dotnet).
# Heap settings go in the environment (DOTNET_LXRImmixInitialMB, DOTNET_LXRImmixReserveMB; hex values).
set -u
lib="$1"; runs="$2"; out="$3"; shift 3
args="${*:-all 2 13}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
corerun="${CORERUN:-/root/prof/frame-c4/corerun}"
dotnet="${DOTNET:-/root/.dotnet-runtime-p13/dotnet}"
build="${PT_BUILD:-/tmp/privatetests-build}"
if [[ ! -f "$build/out/PrivateTests.dll" ]]; then
    mkdir -p "$build" && cp "$here"/PrivateTests.cs "$here"/PrivateTests.csproj "$build"/
    (cd "$build" && "$dotnet" build -c Release -o out > build.log 2>&1) || { echo "build failed"; tail -5 "$build/build.log"; exit 1; }
fi
mkdir -p "$out"
export DOTNET_gcServer=1 DOTNET_GCPath="$lib"
fails=0
for i in $(seq 1 "$runs"); do
    timeout 300 "$corerun" "$build/out/PrivateTests.dll" $args > "$out/r$i.log" 2>&1 || fails=$((fails + 1))
done
echo "lib=$(basename "$lib") args=[$args] runs=$runs fails=$fails"
echo "engine fatal (LXR fatal):        $(grep -l 'LXR fatal' "$out"/r*.log 2>/dev/null | wc -l)"
echo "OutOfMemoryException from Alloc: $(grep -l 'OutOfMemoryException' "$out"/r*.log 2>/dev/null | wc -l)"
exit $((fails != 0))
