#!/bin/bash
# Laxori checks on Linux for the Satori sync: the native engine programs (run-native-all.sh, includes the P4 default run)
# and PrivateTests "all 2 T" (T = 1 2 4 8 13 13 13) in L2 and L1 mode with DOTNET_LAXORIVerifyPrivate=1.
# usage: [SKIP_NATIVE=1] laxori-tests-linux.sh <repo> <frame> <out>
set -u
R=$1; FRAME=$2; OUT=$3
mkdir -p $OUT
# Leave the start directory: a global.json there (for example the Windows worktree under /mnt/c) changes the dotnet host.
cd $OUT
if [ -z "${SKIP_NATIVE:-}" ]; then
bash $R/docs/design/laxori-port/run-native-all.sh $R $OUT/native > $OUT/native.out 2>&1
echo "native exit=$?" | tee -a $OUT/native.out
grep -h 'integrated P4 checks' $OUT/native/p4-release.log 2>/dev/null | head -1
fi
B=$OUT/pt-build
rm -rf $B; mkdir -p $B; cp $R/docs/design/laxori-port/PrivateTests/* $B/
env -i HOME=/root PATH=/usr/bin:/bin $R/.dotnet/dotnet build $B/PrivateTests.csproj -c Release -o $B/out > $OUT/pt-build.log 2>&1 || { echo "PrivateTests build failed"; exit 1; }
failed=0
for mode in L2 L1; do
  extra=""; [ $mode = L1 ] && extra="DOTNET_LAXORIEscapedInPlace=0"
  i=0
  for t in 1 2 4 8 13 13 13; do
    i=$((i+1))
    env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=1 DOTNET_GCPath=$FRAME/libclrlaxorigc.so DOTNET_LAXORIVerifyPrivate=1 $extra \
      timeout 600 $FRAME/corerun $B/out/PrivateTests.dll all 2 $t > $OUT/pt-$mode-t$t-$i.log 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then echo "ok   $mode threads=$t"; else echo "FAIL $mode threads=$t rc=$rc"; failed=$((failed+1)); fi
  done
done
echo "pt failed=$failed"
