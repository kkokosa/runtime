#!/usr/bin/env bash
# Policy trace (capK) for old and new default. usage: pt.sh   (one lock grant per run)
F=/root/prof/frame-c4
declare -A W=( [requests]="8192 200000" [binarytrees]="18 1" [listsuffix]="8192 600000" [mixedmedium]="12000 200000" [losarrays]="1500 100000" )
for w in listsuffix requests losarrays binarytrees mixedmedium; do
  read s o <<< "${W[$w]}"
  for v in old new; do
    flock /tmp/lxr-bench.lock bash -c "rm -rf /tmp/pt; mkdir /tmp/pt; DOTNET_LXRPolicyTrace=1 DOTNET_gcServer=1 DOTNET_GCPath=/root/dl/libs/libclrlxrgc-$v.so $F/corerun /root/prof/drv/bin/CompareDriver.dll /tmp/pt $w $s $o > /tmp/pt/out.txt 2> /tmp/pt/err.txt"
    n=$(grep -c '^LXRPOLICY' /tmp/pt/err.txt)
    maxcap=$(grep -o 'capK=[0-9]*' /tmp/pt/err.txt | cut -d= -f2 | sort -n | tail -1)
    maxlive=$(grep -o 'liveK=[0-9]*' /tmp/pt/err.txt | cut -d= -f2 | sort -n | tail -1)
    heapfull=$(grep -c 'heapFull=1' /tmp/pt/err.txt)
    echo "$w $v policy_lines=$n max_capK=$maxcap max_liveK=$maxlive heapFull=$heapfull"
    cp /tmp/pt/err.txt /root/dl/out/pt-$w-$v.txt
    sleep 8
  done
done
