#!/bin/bash
# Build the libraries and the Satori regression tests (priority 1) on Linux, then run them on Satori.
# usage: [SKIP_LIBS=1] satori-tests-linux.sh <repo> <out>
set -u
R=$1; OUT=$2
mkdir -p $OUT
cd $R
export CC=/usr/bin/clang-14 CXX=/usr/bin/clang++-14
if [ -z "${SKIP_LIBS:-}" ]; then
./build.sh -s libs -c Release -rc Release /p:CrossgenOldValueWriteBarriers=true > $OUT/build-libs.log 2>&1
echo "libs exit=$?"
fi
src/tests/build.sh x64 Release -priority1 -tree:GC/Regressions/Satori > $OUT/build-tests.log 2>&1
echo "tests build exit=$?"
T=$R/artifacts/tests/coreclr/linux.x64.Release
cp $R/artifacts/obj/coreclr/linux.x64.Release/gc_satori/libsatorigc.so $T/Tests/Core_Root/
failed=0
for s in $(find $T/GC/Regressions/Satori -name '*.sh' | sort); do
  n=$(basename $s .sh)
  env -i HOME=/root PATH=/usr/bin:/bin CORE_ROOT=$T/Tests/Core_Root DOTNET_GCName=libsatorigc.so DOTNET_TieredCompilation=0 \
    timeout 900 bash $s > $OUT/$n.log 2>&1
  rc=$?
  if [ $rc -eq 0 ] && grep -q 'END EXECUTION - PASSED' $OUT/$n.log; then echo "PASS $n"; else echo "FAIL $n rc=$rc"; failed=$((failed+1)); fi
done
echo "satori tests failed=$failed"
