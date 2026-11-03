#!/usr/bin/env bash
# 13-thread PrivateTests failure rate per collector (the inherited stock-LXR failure shows up here).
#   usage: p13-matrix.sh <runs> <out>
# Needs /root/laxori/pt.sh (PrivateTests on frame-c4) and the .so files named below.
runs=${1:-12}; out=${2:-/root/laxori/p31/p13.txt}
: > "$out"
run() {  # label so extra...
  lab=$1; so=$2; shift 2; f=0; msgs=""
  for i in $(seq "$runs"); do
    o=$(EXTRA="$*" TAILN=40 TMO=600 bash /root/laxori/pt.sh "$so" all 2 13 2>&1)
    if ! echo "$o" | grep -q '^rc=0'; then f=$((f+1)); msgs="$msgs | $(echo "$o" | grep -m1 -iE 'fail|engine|assert|abort|rc=' | cut -c1-90)"; fi
  done
  echo "$lab: $f/$runs failed $msgs" >> "$out"
}
V=/root/laxori/v
run laxori-count-L2 $V/libclrlaxorigc-count.so DOTNET_LAXORIVerifyPrivate=1
run laxori-bitmap-L2 $V/libclrlaxorigc-bitmap.so DOTNET_LAXORIVerifyPrivate=1
run lxr-count /root/p31/so/libclrlxrgc-walk.so
run lxr-bitmap /root/p31/so/libclrlxrgc-base.so
run laxori-count-L1 $V/libclrlaxorigc-count.so DOTNET_LAXORIVerifyPrivate=1 DOTNET_LAXORIEscapedInPlace=0
run laxori-bitmap-L1 $V/libclrlaxorigc-bitmap.so DOTNET_LAXORIVerifyPrivate=1 DOTNET_LAXORIEscapedInPlace=0
echo done >> "$out"
