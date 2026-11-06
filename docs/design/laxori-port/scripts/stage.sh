#!/usr/bin/env bash
# One validation stage of a port, run in the background. Usage: stage.sh <tag> [skip-native]
#   needs /root/laxori/v/libclrlaxorigc-count-<tag>.so and -bitmap-<tag>.so (copy them first, see stage-copy.sh)
# Native: validate-variant.sh for both builds (all 10 programs and all P4 selectors) into /root/laxori/stage/<tag>/
# Managed: PrivateTests all 2 at 1/2/4/8/13 threads (L1, L2, both builds); all 2 13 x20 interleaved (4 configs); crash hunt (180 runs);
#          six checksums (one interleaved run of the benchmark).
tag=$1; skipnative=${2:-}
R=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-reimagined-eureka
V=/root/laxori/v; O=/root/laxori/stage/$tag; mkdir -p $O
cd /root/laxori
if [ -z "$skipnative" ]; then
  nice bash $R/docs/design/laxori-port/P31-object-start-walk/validate-variant.sh default Release $O/nat-default > $O/native-count.txt 2>&1
  nice bash $R/docs/design/laxori-port/P31-object-start-walk/validate-variant.sh bitmap Release $O/nat-bitmap > $O/native-bitmap.txt 2>&1
fi
(for v in count bitmap; do bash ptmatrix.sh $V/libclrlaxorigc-$v-$tag.so $v-L2; bash ptmatrix.sh $V/libclrlaxorigc-$v-$tag.so $v-L1 DOTNET_LAXORIEscapedInPlace=0; done) > $O/pt-matrix.txt 2>&1
bash p13-multi.sh 20 $O/p13.txt count-L2=$V/libclrlaxorigc-count-$tag.so bitmap-L2=$V/libclrlaxorigc-bitmap-$tag.so \
  count-L1=$V/libclrlaxorigc-count-$tag.so:DOTNET_LAXORIEscapedInPlace=0 bitmap-L1=$V/libclrlaxorigc-bitmap-$tag.so:DOTNET_LAXORIEscapedInPlace=0
cp $O/p13.txt $O/p13.txt.keep 2>/dev/null
bash hunt3.sh $V/libclrlaxorigc-count-$tag.so 54 $O/hunt-count-L2.txt 0 DOTNET_LAXORIVerifyPrivate=1
bash hunt3.sh $V/libclrlaxorigc-bitmap-$tag.so 54 $O/hunt-bitmap-L2.txt 0 DOTNET_LAXORIVerifyPrivate=1
bash hunt3.sh $V/libclrlaxorigc-count-$tag.so 36 $O/hunt-count-L1.txt 0 DOTNET_LAXORIVerifyPrivate=1 DOTNET_LAXORIEscapedInPlace=0
bash hunt3.sh $V/libclrlaxorigc-bitmap-$tag.so 36 $O/hunt-bitmap-L1.txt 0 DOTNET_LAXORIVerifyPrivate=1 DOTNET_LAXORIEscapedInPlace=0
LAXORI_SO_WALK=$V/libclrlaxorigc-count-$tag.so LAXORI_SO_BITMAP=$V/libclrlaxorigc-bitmap-$tag.so DRIVER=/root/laxori/drv4/bin/CompareDriver.dll flock /tmp/lxr-bench.lock \
  python3 bench3.py $O/checksums 1 laxori-walk,laxori-bitmap binarytrees,requests,listsuffix,mixedmedium,losarrays,mediumarrays,losmany > $O/checksums.txt 2>&1
echo STAGE-DONE > $O/done
