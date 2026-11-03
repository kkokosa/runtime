#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Runs the selectors of the P4 validation binary one by one and prints the last PASS or FAIL line of each.
#   usage: run-p4-selectors.sh <path to laxori-rc-validation> [selector ...]
# Without selectors it runs the default run and every selector that checks the engine (not the benchmarks and studies).
set -u
binary="$1"; shift
selectors=("$@")
if [[ ${#selectors[@]} -eq 0 ]]; then
    selectors=(
        "" --pause-trace --lazy-sweep --d2-spans --prezero --fresh-block-race --s7-pins --s6-registry --s5b-overshoot
        --s4-sweep --s3-bookkeeping --lazy-large-release --inline-metadata --log-storage --mature --mature-remset
        --mature-reader --mature-retained-owner --mature-released-candidate --mature-headroom --mature-completed-scan
        --mature-remset-whole --mature-remset-wrap --mature-remset-same-shape --mature-remset-boundaries --nursery
        --nursery-reader --root-batching --trace-batching --aux-retirement --object-planes --storage-diagnostics
        --lifetime --p8-policy --p8-storage --zero-rc-control --f1-trace --f2-pause --f8-lazy --f4b-scheduler
        --f4-scheduler --f10-rc --item3 --f5-policy --trace --release-stage --object-start
    )
fi
status=0
for s in "${selectors[@]}"; do
    if timeout 600 "$binary" $s > /tmp/p4-sel.$$.log 2>&1; then rc=0; else rc=$?; fi
    line="$(grep -E '^(PASS|FAIL)' /tmp/p4-sel.$$.log | tail -1)"
    echo "[${s:-default}] rc=$rc ${line:-no result line}"
    if [[ $rc != 0 ]]; then status=1; grep -m5 'FAIL' /tmp/p4-sel.$$.log | cut -c1-240; fi
done
rm -f /tmp/p4-sel.$$.log
exit $status
