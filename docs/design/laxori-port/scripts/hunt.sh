#!/usr/bin/env bash
# usage: hunt.sh <so> <runs> <log> [extra env words...]   cycles workloads x thread configs, checks checksums
so="$1"; runs="$2"; log="$3"; shift 3
EXTRA_BASE="$*"
declare -A SZ=( [requests]="8192 200000" [binarytrees]="18 1" [listsuffix]="8192 600000" [mixedmedium]="12000 200000" [losarrays]="1500 100000" [mediumarrays]="20000 300000" )
declare -A SUM=( [requests]=27134172608 [binarytrees]=68332294 [listsuffix]=159636632672 [mixedmedium]=40586599707 [losarrays]=13936826922 [mediumarrays]=7032863679 )
WL=(requests binarytrees listsuffix mixedmedium losarrays mediumarrays)
CFG=("" "DOTNET_LAXORIGCThreads=1 DOTNET_LAXORIConcGCThreads=1" "DOTNET_LAXORIGCThreads=2 DOTNET_LAXORIConcGCThreads=1" "DOTNET_LAXORIGCThreads=4 DOTNET_LAXORIConcGCThreads=2" "DOTNET_LAXORIGCThreads=8 DOTNET_LAXORIConcGCThreads=4")
ok=0; bad=0
: > "$log"
for ((i=0;i<runs;i++)); do
  w=${WL[$((i % 6))]}; c=${CFG[$(( (i / 6) % 5 ))]}
  out=/tmp/hunt-$$-$i; mkdir -p $out
  set -- ${SZ[$w]}
  flock /tmp/lxr-bench.lock env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_GCPath="$so" $c $EXTRA_BASE \
    timeout 150 /root/prof/frame-p/corerun /root/laxori/drv/bin/CompareDriver.dll $out $w $1 $2 > $out/log.txt 2>&1
  rc=$?
  got=$(python3 -c "import json;print(json.load(open('$out/result.json'))['checksum'])" 2>/dev/null)
  if [ $rc -eq 0 ] && [ "$got" = "${SUM[$w]}" ]; then ok=$((ok+1)); echo "$i OK $w [$c] $got" >> "$log"
  else bad=$((bad+1)); echo "$i FAIL rc=$rc $w [$c] got=$got" >> "$log"; tail -5 $out/log.txt >> "$log"; fi
  rm -rf $out
done
echo "DONE ok=$ok bad=$bad" >> "$log"
