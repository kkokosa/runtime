#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Runs the five mutation controls of the parallel selection (P4 selector --select-parallel). Each control builds the P4 binary
# with one injected defect and must fail the selector: run-lxr-rc-vertical.sh prints "CONTROL <name> detected".
#   usage: run-select-controls.sh [output root]
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="${1:-/root/p50/controls}"
mkdir -p "$out"
status=0
for control in SelectLoseChunk SelectSkipChunk SelectGatherReversed SelectDeadLines SelectOccupied; do
    rm -rf "$out/$control"
    bash "$root/docs/design/lxr-port/P4/run-lxr-rc-vertical.sh" Release "$out/$control" "$control" 2>&1 | tail -2 || status=1
    grep -m3 'FAIL' "$out/$control/run.log" | cut -c1-200
done
exit $status
