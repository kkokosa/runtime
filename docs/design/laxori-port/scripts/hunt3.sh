#!/usr/bin/env bash
# usage: hunt3.sh <so> <runs> <log> <offset> [extra env words...]
# Crash hunt on frame-c4. Cycles 6 jobs (5 scaled benchmark workloads, PrivateTests) x 3 worker configs (default 13/3, 4/2, 1/1).
# Expected checksums come from a workstation-GC run of the same size (cached in /tmp/hunt3-sums). A run passes when the exit code is 0
# and the checksum is right (PrivateTests: exit code 0).
so="$1"; runs="$2"; log="$3"; off="$4"; shift 4
EXTRA_BASE="$*"
FRAME=${FRAME:-/root/prof/frame-c4}
declare -A SZ=( [requests]="8192 40000" [binarytrees]="16 1" [listsuffix]="8192 120000" [mixedmedium]="12000 40000" [losarrays]="1500 20000" )
JOBS=(requests binarytrees listsuffix mixedmedium losarrays private)
CFG=("" "DOTNET_LAXORIGCThreads=4 DOTNET_LAXORIConcGCThreads=2" "DOTNET_LAXORIGCThreads=1 DOTNET_LAXORIConcGCThreads=1")
CFGNAME=("13/3" "4/2" "1/1")
mkdir -p /tmp/hunt3-sums
for w in requests binarytrees listsuffix mixedmedium losarrays; do
  if [ ! -s /tmp/hunt3-sums/$w ]; then
    set -- ${SZ[$w]}; d=/tmp/hunt3-sums/d-$w; mkdir -p $d
    env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=0 $FRAME/corerun /root/laxori/drv/bin/CompareDriver.dll $d $w $1 $2 > /dev/null 2>&1
    python3 -c "import json;print(json.load(open('$d/result.json'))['checksum'])" > /tmp/hunt3-sums/$w
  fi
done
ok=0; bad=0; : > "$log"
for ((j=0;j<runs;j++)); do
  i=$((j+off)); w=${JOBS[$((i % 6))]}; ci=$(( (i / 6) % 3 )); c=${CFG[$ci]}
  out=/tmp/hunt3-$$-$j; mkdir -p $out
  if [ "$w" = private ]; then
    nice -n 19 env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_GCPath="$so" $c $EXTRA_BASE \
      timeout 300 $FRAME/corerun /root/laxori/pt/bin/PrivateTests.dll all 1 4 > $out/log.txt 2>&1
    rc=$?; got=-; want=-
    if [ $rc -eq 0 ]; then ok=$((ok+1)); echo "$i OK $w [${CFGNAME[$ci]}]" >> "$log"
    else bad=$((bad+1)); echo "$i FAIL rc=$rc $w [${CFGNAME[$ci]}]" >> "$log"; tail -5 $out/log.txt >> "$log"; fi
  else
    set -- ${SZ[$w]}; want=$(cat /tmp/hunt3-sums/$w)
    nice -n 19 env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_GCPath="$so" $c $EXTRA_BASE \
      timeout 150 $FRAME/corerun /root/laxori/drv/bin/CompareDriver.dll $out $w $1 $2 > $out/log.txt 2>&1
    rc=$?
    got=$(python3 -c "import json;print(json.load(open('$out/result.json'))['checksum'])" 2>/dev/null)
    if [ $rc -eq 0 ] && [ "$got" = "$want" ]; then ok=$((ok+1)); echo "$i OK $w [${CFGNAME[$ci]}] $got" >> "$log"
    else bad=$((bad+1)); echo "$i FAIL rc=$rc $w [${CFGNAME[$ci]}] got=$got want=$want" >> "$log"; tail -5 $out/log.txt >> "$log"; fi
  fi
  rm -rf $out
done
echo "DONE ok=$ok bad=$bad" >> "$log"