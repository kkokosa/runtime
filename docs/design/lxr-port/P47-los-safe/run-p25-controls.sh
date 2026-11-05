#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Mutation controls of the P47 checks in P2.5. Each control breaks one piece of the young list or of the mature totals in
# large_object_space.cpp (a -D macro) and builds the P2.5 harness with it. The harness must fail; a control that does not fail
# means that the checks do not see that piece.
#   usage: run-p25-controls.sh [repository root] [output directory]
set -u
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="${1:-$(cd "$script_root/../../../.." && pwd)}"
output_root="${2:-$repository_root/artifacts/P47/controls-$(date -u +%Y%m%dT%H%M%SZ)}"
status=0
mkdir -p "$output_root"
for control in LXR_LOS_CONTROL_YOUNG_NO_RECORD LXR_LOS_CONTROL_YOUNG_KEEP_PROMOTED \
               LXR_LOS_CONTROL_TOTALS_NO_PROMOTE LXR_LOS_CONTROL_TOTALS_NO_RELEASE; do
    out="$output_root/$control"
    rm -rf "$out"
    LXR_LOS_EXTRA_FLAGS="-D$control" bash "$repository_root/docs/design/lxr-port/P2.5/run-large-object-space-validation.sh" \
        "$repository_root" "$out" > "$output_root/$control.log" 2>&1
    rc=$?
    failed="$(grep -c '^FAIL' "$out/run.log" 2>/dev/null || true)"
    if [[ "$rc" != 0 && "${failed:-0}" != 0 ]]; then
        echo "CONTROL $control detected: $failed failing lines, $(grep -E 'checks passed' "$out/run.log")"
    else
        echo "CONTROL $control NOT detected (rc=$rc)"
        status=1
    fi
done
exit $status
