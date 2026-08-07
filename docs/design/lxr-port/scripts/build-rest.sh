#!/bin/bash
# P0.1 - build the remaining three JDK configurations sequentially.
set -uo pipefail
SF=/mnt/c/Users/konradkokosa/.copilot/session-state/8d853da5-db52-44ad-84cc-bf102a4df700/files
STATUS=/root/lxr/logs/build-status.txt
mkdir -p /root/lxr/logs
: > "$STATUS"

for combo in "head release" "pldi fastdebug" "head fastdebug"; do
  set -- $combo
  rev=$1; lvl=$2
  echo "########## BUILDING $rev $lvl ##########"
  if bash "$SF/build-jdk.sh" "$rev" "$lvl" > "/root/lxr/logs/build-$rev-$lvl.out" 2>&1; then
    echo "$rev/$lvl=OK" >> "$STATUS"
    tail -6 "/root/lxr/logs/build-$rev-$lvl.out"
  else
    echo "$rev/$lvl=FAILED" >> "$STATUS"
    tail -30 "/root/lxr/logs/build-$rev-$lvl.out"
  fi
done

echo "########## ALL DONE ##########"
cat "$STATUS"
