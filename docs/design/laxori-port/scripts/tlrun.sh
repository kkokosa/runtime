#!/usr/bin/env bash
# usage: tlrun.sh <so> <outdir> <tag> <workload> <size> <ops> [ENV=VAL ...]   one Laxori run with LAXORITlTimers=1; leaves <outdir>/<tag>/result.json
so="$1"; out="$2"; tag="$3"; w="$4"; sz="$5"; ops="$6"; shift 6
mkdir -p $out/$tag
extra=""
if [ "$w" = mediumarrays ]; then extra="DOTNET_LAXORIImmixInitialMB=200 DOTNET_LAXORIImmixReserveMB=400"; fi
env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_GCPath=$so DOTNET_LAXORITlTimers=1 $extra "$@" \
  /root/prof/frame-c4/corerun ${DRV:-/root/laxori/drv2/bin}/CompareDriver.dll $out/$tag $w $sz $ops > $out/$tag/log.txt 2>&1
echo "$tag rc=$?"
