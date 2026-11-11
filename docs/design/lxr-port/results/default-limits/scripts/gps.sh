#!/usr/bin/env bash
# usage: gps.sh <lib> <tagb> <log> [VAR=value ...]   (GCPerfSim, Jan's command line, 28 threads)
lib=$1; tagb=$2; log=$3; shift 3
export DOTNET_gcServer=1 DOTNET_GCPath=$lib
for kv in "$@"; do export "$kv"; done
frame=/root/prof/frame-c4
echo "start $(date +%T) lib=$(basename $lib) tagb=$tagb extra=$*" > $log
$frame/corerun /root/gcoom/GCPerfSim.dll -tc 28 -tagb $tagb -tlgb 2 -lohar 0 -pohar 0 -sohsr 100-4000 -lohsr 102400-204800 -pohsr 100-204800 -sohsi 50 -lohsi 0 -pohsi 0 -sohpi 0 -lohpi 0 -sohfi 0 -lohfi 0 -pohfi 0 -ramb 20 -rlmb 2 -allocType reference -testKind time >> $log 2>&1
echo "exit $? $(date +%T)" >> $log
