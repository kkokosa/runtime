#!/usr/bin/env bash
# Final library: PrivateTests x20 (both variants), checksums of the six workloads (default and as-run) and losmany.
set -uo pipefail
root=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-fluffy-pancake
D=$root/artifacts/obj/coreclr/linux.x64.Release/old/gc_lxr
out=/root/dl/val2
mkdir -p $out
ls -l $D/libclrlxrgc*.so
for so in libclrlxrgc.so libclrlxrgc-bitmap.so; do
  echo "##### PrivateTests $so"
  bash $root/docs/design/lxr-port/P32-privatetests-failure/repeat.sh $D/$so 20 $out/pt-$so all 2 13
done
cd /root/prof/frame-c4
declare -A W=( [requests]="8192 200000 27134172608" [binarytrees]="18 1 68332294" [listsuffix]="8192 600000 159636632672" [mixedmedium]="12000 200000 40586599707" [losarrays]="1500 100000 13936826922" [mediumarrays]="20000 300000 7032863679" )
for so in libclrlxrgc.so libclrlxrgc-bitmap.so; do
  for w in requests binarytrees listsuffix mixedmedium losarrays mediumarrays; do
    read s o c <<< "${W[$w]}"
    for mode in default asrun; do
      rm -rf /tmp/smk; mkdir /tmp/smk
      extra=""; [[ $w == mediumarrays && $mode == asrun ]] && extra="DOTNET_LXRImmixInitialMB=200 DOTNET_LXRImmixReserveMB=400"
      env DOTNET_gcServer=1 DOTNET_GCPath=$D/$so $extra ./corerun /root/prof/drv/bin/CompareDriver.dll /tmp/smk $w $s $o > /dev/null 2>&1
      got=$(grep -o '"checksum":[0-9]*' /tmp/smk/result.json | cut -d: -f2)
      [[ "$got" == "$c" ]] && r=OK || r="BAD($got)"
      echo "$so $w $mode $r"
    done
  done
done
rm -rf /tmp/smk; mkdir /tmp/smk
env DOTNET_gcServer=1 DOTNET_GCPath=$D/libclrlxrgc.so DOTNET_LXRLOSInitialMB=1000 DOTNET_LXRLOSReserveMB=1600 DOTNET_LXRNativePlaneLimitMB=16000 ./corerun /root/p44/drv/bin/CompareDriver.dll /tmp/smk losmany 2000 60000 > /dev/null 2>&1
echo "losmany explicit: $(grep -o '"checksum":[0-9]*' /tmp/smk/result.json) expected 42674603309"
rm -rf /tmp/smk; mkdir /tmp/smk
env DOTNET_gcServer=1 DOTNET_GCPath=$D/libclrlxrgc.so DOTNET_LXRLOSInitialMB=1000 DOTNET_LXRLOSReserveMB=1600 ./corerun /root/p44/drv/bin/CompareDriver.dll /tmp/smk losmany 2000 60000 > /dev/null 2>&1
echo "losmany native-limit-default: $(grep -o '"checksum":[0-9]*' /tmp/smk/result.json) expected 42674603309"
echo ALLDONE-DL2
