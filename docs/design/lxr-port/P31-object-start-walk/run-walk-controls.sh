#!/usr/bin/env bash
# Mutation checks of the walk variant: each control breaks one rule, and the check that tests the rule has to fail.
R=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-supreme-goggles
cd $R
unset LXR_OBJECT_START_WALK
for c in WalkNoContinuationSkip WalkOneWord WalkNoExtent WalkNoPinnedSpan WalkTrustedResolve WalkEnumContinuation; do
  rm -rf /root/p31/ctl-$c
  echo "== $c: $(bash docs/design/lxr-port/P4/run-lxr-rc-vertical.sh Release /root/p31/ctl-$c $c 2>&1 | tail -1 | cut -c1-200)"
  grep -m3 'FAIL' /root/p31/ctl-$c/run.log | cut -c1-200
done
# P2.4: the walk variant must not write the ValidObject plane
export LXR_OBJECT_START_WALK=1
rm -rf /root/p31/ctl-p24
P2_4_EXTRA_DEFINES="-DLXR_WALK_WRITE_VALID_CONTROL" bash docs/design/lxr-port/P2.4/run-immix-allocation-validation.sh $R /root/p31/ctl-p24 > /root/p31/ctl-p24.out 2>&1
echo "== P2.4 WalkWriteValid: rc=$? $(grep -m2 FAIL /root/p31/ctl-p24/run.log | cut -c1-200)"
