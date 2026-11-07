#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# A/B of the S1 library against the library of the branch base (same toolchain, same build directory).
# 15 pairs of the six standard workloads, then pairs 16 to 30 of listsuffix and binarytrees. One block (one pair of one workload) for each lock hold.
#   usage: pipeline-ab.sh <repo root WSL> <outdir>
set -uo pipefail
root="$1"; out="$2"
here="$root/docs/design/laxori-port/results/s1-prefetch/scripts"
python3 "$here/run-ab2.py" run "$out" 15 "$here/configs-ab.json" requests,binarytrees,listsuffix,mixedmedium,losarrays,mediumarrays --seed 71
python3 "$here/run-ab2.py" run "$out" 30 "$here/configs-ab.json" listsuffix,binarytrees --seed 71 --start 16
echo AB_DONE
