#!/usr/bin/env bash
# usage: hunt2.sh <so> <runs> <log> <offset> [extra env words...]
# Short workloads (scaled sizes). Expected checksums come from a WKS run of the same size (computed once, cached in /tmp/hunt2-sums).
so="$1"; runs="$2"; log="$3"; off="$4"; shift 4
EXTRA_BASE="$*"
declare -A SZ=( [requests]="8192 40000" [binarytrees]="16 1" [listsuffix]="8192 120000" [mixedmedium]="12000 40000" [losarrays]="1500 20000" )
WL=(requests binarytrees listsuffix mixedmedium losarrays)
CFG=("" "DOTNET_LAXORIGCThreads=1 DOTNET_LAXORIConcGCThreads=1" "DOTNET_LAXORIGCThreads=2 DOTNET_LAXORIConcGCThreads=1" "DOTNET_LAXORIGCThreads=4 DOTNET_LAXORIConcGCThreads=2" "DOTNET_LAXORIGCThreads=8 DOTNET_LAXORIConcGCThreads=4")
mkdir -p /tmp/hunt2-sums
for w in "${WL[@]}"; do
  if [ ! -s /tmp/hunt2-sums/$w ]; then
    set -- ${SZ[$w]}; d=/tmp/hunt2-sums/d-$w; mkdir -p $d
    env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=0 /root/prof/frame-p/corerun /root/laxori/drv/bin/CompareDriver.dll $d $w $1 $2 > /dev/null 2>&1
    python3 -c "import json;print(json.load(open('$d/result.json'))['checksum'])" > /tmp/hunt2-sums/$w
  fi
done
ok=0; bad=0; : > "$log"
for ((j=0;j<runs;j++)); do
  i=$((j+off)); w=${WL[$((i % 5))]}; c=${CFG[$(( (i / 5) % 5 ))]}
  out=/tmp/hunt2-$$-$j; mkdir -p $out; set -- ${SZ[$w]}; want=$(cat /tmp/hunt2-sums/$w)
  nice -n 19 env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_GCPath="$so" $c $EXTRA_BASE \
    timeout 150 /root/prof/frame-p/corerun /root/laxori/drv/bin/CompareDriver.dll $out $w $1 $2 > $out/log.txt 2>&1
  rc=$?
  got=$(python3 -c "import json;print(json.load(open('$out/result.json'))['checksum'])" 2>/dev/null)
  if [ $rc -eq 0 ] && [ "$got" = "$want" ]; then ok=$((ok+1)); echo "$i OK $w [$c] $got" >> "$log"
  else bad=$((bad+1)); echo "$i FAIL rc=$rc $w [$c] got=$got want=$want" >> "$log"; tail -5 $out/log.txt >> "$log"; fi
  rm -rf $out
done
echo "DONE ok=$ok bad=$bad" >> "$log"
