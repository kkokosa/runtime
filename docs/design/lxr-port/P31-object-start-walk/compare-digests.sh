#!/usr/bin/env bash
# Runs the object-start checks of both variants and compares the DIGEST lines (cycle sweep and heap walk results).
#   usage: compare-digests.sh [Release|Debug]
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
configuration="${1:-Release}"
out=/root/p31/digest-$configuration
rm -rf "$out"; mkdir -p "$out"
for v in default bitmap; do
    if [[ $v == bitmap ]]; then export LXR_OBJECT_START_BITMAP=1; else unset LXR_OBJECT_START_BITMAP; fi
    bash "$root/docs/design/lxr-port/P4/run-lxr-rc-vertical.sh" "$configuration" "$out/$v" > "$out/$v.build.log" 2>&1
    "$out/$v/lxr-rc-validation" --object-start > "$out/$v.log" 2>&1
    grep -E '^PASS|^FAIL' "$out/$v.log" | tail -1
    grep '^DIGEST' "$out/$v.log" > "$out/$v.digest"
done
if diff -q "$out/default.digest" "$out/bitmap.digest" > /dev/null && [[ -s "$out/default.digest" ]]; then
    echo "DIGESTS EQUAL ($(wc -l < "$out/default.digest") lines)"
else
    echo "DIGESTS DIFFER"; diff "$out/default.digest" "$out/bitmap.digest"; exit 1
fi