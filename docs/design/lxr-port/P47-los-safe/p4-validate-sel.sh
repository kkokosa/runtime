#!/usr/bin/env bash
# usage: p4-validate-sel.sh <lxr-rc-validation binary> <outfile>   Runs every P4 selector with LXR_LOS_VALIDATE=1 and counts the validation reports.
binary="$1"; out="$2"
: > "$out"
export LXR_LOS_VALIDATE=1
for s in "" --pause-trace --lazy-sweep --d2-spans --prezero --fresh-block-race --s7-pins --s6-registry --s5b-overshoot \
    --s4-sweep --s3-bookkeeping --lazy-large-release --inline-metadata --log-storage --mature --mature-remset \
    --mature-reader --mature-retained-owner --mature-released-candidate --mature-headroom --mature-completed-scan \
    --mature-remset-whole --mature-remset-wrap --mature-remset-same-shape --mature-remset-boundaries --nursery \
    --nursery-reader --root-batching --trace-batching --aux-retirement --object-planes --storage-diagnostics \
    --lifetime --p8-policy --p8-storage --zero-rc-control --f1-trace --f2-pause --f8-lazy --f4b-scheduler \
    --f4-scheduler --f10-rc --item3 --f5-policy --trace --release-stage --object-start; do
    timeout 600 "$binary" $s > /tmp/p4v.$$.log 2>&1
    echo "[${s:-default}] rc=$? reports=$(grep -c 'LXR LOS validation' /tmp/p4v.$$.log) $(grep -E '^(PASS|FAIL: [0-9])' /tmp/p4v.$$.log | tail -1)" >> "$out"
done
rm -f /tmp/p4v.$$.log
echo done >> "$out"
