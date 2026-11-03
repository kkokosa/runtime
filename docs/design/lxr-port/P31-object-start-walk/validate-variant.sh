#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Runs the validation suites P2.1-P2.5, P3.1-P3.4 and P4 (all selectors) for one variant of the LXR collector.
#   usage: validate-variant.sh <default|bitmap> [Release|Debug] [output directory]
# "default" is the count-plane build (no ValidObject plane). "bitmap" is built with LXR_OBJECT_START_BITMAP=1.
# The scripts of the suites take the variable.
set -u
variant="$1"
configuration="${2:-Release}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
d="$root/docs/design/lxr-port"
out="${3:-/root/p31/val-$variant-$configuration}"
rm -rf "$out"; mkdir -p "$out"
if [[ "$variant" == bitmap ]]; then export LXR_OBJECT_START_BITMAP=1; else unset LXR_OBJECT_START_BITMAP; fi
status=0
run() { # name, command...
    local name="$1"; shift
    if "$@" > "$out/$name.log" 2>&1; then
        echo "$name: $(grep -E '^PASS' "$out/$name.log" | tail -1)"
    else
        echo "$name: FAILED"; tail -5 "$out/$name.log" | cut -c1-240; status=1
    fi
}
run p21 bash "$d/P2.1/run-side-metadata-validation.sh" "$root" "$out/p21"
run p22 bash "$d/P2.2/run-immix-block-validation.sh" "$root" "$out/p22"
run p23 bash "$d/P2.3/run-reference-count-validation.sh" "$root" "$out/p23"
run p24 bash "$d/P2.4/run-immix-allocation-validation.sh" "$root" "$out/p24"
run p25 bash "$d/P2.5/run-large-object-space-validation.sh" "$root" "$out/p25"
run p31 bash "$d/P3.1/run-lxr-work-packet-validation.sh" "$root" "$out/p31x"
run p32 bash "$d/P3.2/run-lxr-pause-validation.sh" "$root" "$out/p32"
run p33 bash "$d/P3.3/run-lxr-deferred-bucket-validation.sh" "$root" "$out/p33"
run p34 bash "$d/P3.4/run-lxr-completion-counter-validation.sh" "$root" "$out/p34"
run p4 bash "$d/P4/run-lxr-rc-vertical.sh" "$configuration" "$out/p4"
echo "--- P4 selectors"
bash "$d/P31-object-start-walk/run-p4-selectors.sh" "$out/p4/lxr-rc-validation" | grep -v 'zero-rc-control' || status=1
exit $status
