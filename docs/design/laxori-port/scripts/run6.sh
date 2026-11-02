#!/usr/bin/env bash
# usage: run6.sh <so|none> [only-workload]   one run of each of the six workloads on frame-c4; prints checksum, wall, cpu, pause, rss
# env: SVR=1|0, EXTRA="A=B C=D" (extra environment), FRAME, TMO
so="$1"; only="${2:-}"
FRAME=${FRAME:-/root/prof/frame-c4}
if [ "$so" = none ]; then gcenv=""; else gcenv="DOTNET_GCPath=$so"; fi
declare -A exp=( [requests]=27134172608 [binarytrees]=68332294 [listsuffix]=159636632672 [mixedmedium]=40586599707 [losarrays]=13936826922 [mediumarrays]=7032863679 )
run() {
  w="$1"; size="$2"; ops="$3"; extra=""
  if [ -n "$only" ] && [ "$only" != "$w" ]; then return; fi
  if [ "$w" = mediumarrays ] && [ "$so" != none ]; then extra="DOTNET_LAXORIImmixInitialMB=200 DOTNET_LAXORIImmixReserveMB=400"; fi
  out=/tmp/run6-$$; rm -rf $out; mkdir -p $out
  env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=${SVR:-1} $gcenv $extra $EXTRA timeout ${TMO:-600} $FRAME/corerun /root/laxori/drv/bin/CompareDriver.dll $out $w $size $ops > $out.txt 2>&1
  rc=$?
  if [ -f $out/result.json ]; then
    python3 - "$out/result.json" "$w" "${exp[$w]}" "$rc" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); w=sys.argv[2]; exp=int(sys.argv[3]); rc=sys.argv[4]
ok = "OK" if r["checksum"]==exp else "WRONG"
print(f'{w:12s} rc={rc} checksum={ok} wall={r["wall_ms"]:.0f} cpu={r["cpu_ms"]:.0f} pause={r["pause_ms"]:.0f} rss={r["peak_rss_mb"]:.0f} gcs={r.get("total_collections")}')
PY
  else
    echo "$w rc=$rc NO RESULT"; grep -E "fatal|FAIL|Error|error" $out.txt | head -3 | cut -c1-200
  fi
}
run requests 8192 200000
run binarytrees 18 1
run listsuffix 8192 600000
run mixedmedium 12000 200000
run losarrays 1500 100000
run mediumarrays 20000 300000
