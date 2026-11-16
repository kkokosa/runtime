#!/bin/bash
# Run the seven standard CompareDriver workloads with stock WKS/SVR, Satori, LXR and Laxori and check the checksums.
# usage: workloads-linux.sh <frame> <out> [repeats] [configs] [workloads] [noset]
#   configs and workloads are comma lists. Without "noset", LXR and Laxori get the usual heap settings for
#   mediumarrays and losmany (as in windows/bench-windows.py). Hold /tmp/lxr-bench.lock around the call for timed runs.
# Writes one CSV line for each run to <out>/runs.csv. Exit code 1 if a run fails or a checksum differs.
set -u
FRAME=$1; OUT=$2; REP=${3:-1}
CONFIGS=${4:-wks,svr,satori,lxr,laxori}
WORKLOADS=${5:-requests,binarytrees,listsuffix,mixedmedium,losarrays,mediumarrays,losmany}
NOSET=${6:-}
DRV=${DRV:-/root/laxori/drv4/bin/CompareDriver.dll}
declare -A SIZE=([requests]=8192 [binarytrees]=18 [listsuffix]=8192 [mixedmedium]=12000 [losarrays]=1500 [mediumarrays]=20000 [losmany]=2000)
declare -A OPS=([requests]=200000 [binarytrees]=1 [listsuffix]=600000 [mixedmedium]=200000 [losarrays]=100000 [mediumarrays]=300000 [losmany]=60000)
declare -A SUM=([requests]=27134172608 [binarytrees]=68332294 [listsuffix]=159636632672 [mixedmedium]=40586599707 [losarrays]=13936826922 [mediumarrays]=7032863679 [losmany]=42674603309)
mkdir -p $OUT
CSV=$OUT/runs.csv
[ -f $CSV ] || echo "repeat,config,workload,exit,checksum,ok,wall_ms,cpu_ms,pause_ms,collections,peak_rss_mb" > $CSV
failed=0
for r in $(seq 1 $REP); do
  for w in ${WORKLOADS//,/ }; do
    for c in ${CONFIGS//,/ }; do
      e=()
      case $c in
        wks) e=(DOTNET_gcServer=0) ;;
        svr) e=(DOTNET_gcServer=1) ;;
        satori) e=(DOTNET_GCPath=$FRAME/libsatorigc.so) ;;
        lxr) e=(DOTNET_gcServer=1 DOTNET_GCPath=$FRAME/libclrlxrgc.so); p=LXR ;;
        laxori) e=(DOTNET_gcServer=1 DOTNET_GCPath=$FRAME/libclrlaxorigc.so); p=LAXORI ;;
      esac
      if [ -z "$NOSET" ] && { [ $c = lxr ] || [ $c = laxori ]; }; then
        [ $w = mediumarrays ] && e+=(DOTNET_${p}ImmixInitialMB=200 DOTNET_${p}ImmixReserveMB=400)
        [ $w = losmany ] && e+=(DOTNET_${p}LOSInitialMB=1000 DOTNET_${p}LOSReserveMB=1600 DOTNET_${p}NativePlaneLimitMB=16000)
      fi
      d=$OUT/$c-$w-$r
      rm -rf $d
      env -i HOME=/root PATH=/usr/bin:/bin "${e[@]}" timeout 600 $FRAME/corerun $DRV $d $w ${SIZE[$w]} ${OPS[$w]} > $d.log 2>&1
      code=$?
      line=$(python3 - "$d/result.json" "${SUM[$w]}" "$code" <<'EOF'
import json, sys
p, want, code = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    j = json.load(open(p))
except Exception:
    print(f"{code},,False,,,,,"); sys.exit()
ok = code == 0 and int(j["checksum"]) == want
print(f"{code},{j['checksum']},{ok},{j['wall_ms']},{j['cpu_ms']},{j['pause_ms']},{j['collections']},{j['peak_rss_mb']}")
EOF
)
      case $line in *,True,*) ;; *) failed=$((failed+1)) ;; esac
      echo "$r,$c,$w,$line" | tee -a $CSV
    done
  done
done
echo "failed=$failed"
[ $failed -eq 0 ]
