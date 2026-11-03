#!/usr/bin/env bash
# Mutation checks of the walk variant: each control breaks one rule, and the check that tests the rule has to fail.
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd $R
unset LAXORI_OBJECT_START_BITMAP
for c in WalkNoContinuationSkip WalkOneWord WalkNoExtent WalkNoPinnedSpan WalkTrustedResolve WalkEnumContinuation; do
  rm -rf /root/laxori/p31/ctl-$c
  echo "== $c: $(bash docs/design/laxori-port/P4/run-laxori-rc-vertical.sh Release /root/laxori/p31/ctl-$c $c 2>&1 | tail -1 | cut -c1-200)"
  grep -m3 'FAIL' /root/laxori/p31/ctl-$c/run.log | cut -c1-200
done
# P2.4: the walk variant (now the default) must not write the ValidObject plane
unset LAXORI_OBJECT_START_BITMAP
rm -rf /root/laxori/p31/ctl-p24
P2_4_EXTRA_DEFINES="-DLAXORI_WALK_WRITE_VALID_CONTROL" bash docs/design/laxori-port/P2.4/run-immix-allocation-validation.sh $R /root/laxori/p31/ctl-p24 > /root/laxori/p31/ctl-p24.out 2>&1
echo "== P2.4 WalkWriteValid: rc=$? $(grep -m2 FAIL /root/laxori/p31/ctl-p24/run.log | cut -c1-200)"
