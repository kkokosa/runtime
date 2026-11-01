#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Builds and runs the models of the lock-free protocols of the parallel pause trace, under ThreadSanitizer, and with the
# mutations that must be detected (exit code 0 for a mutation means that it was detected).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source_file="$root/docs/design/lxr-port/P4/lxr-pause-trace-model.cpp"
output="${1:-$root/artifacts/P4/pause-trace-model}"
rounds="${2:-300}"
mkdir -p "$output"
status=0
clang++ -std=c++17 -O1 -g -pthread -fsanitize=thread "$source_file" -o "$output/model-tsan"
# ThreadSanitizer needs a fixed memory layout; some kernels randomize it too much, so ASLR is switched off for the run.
setarch "$(uname -m)" -R "$output/model-tsan" "$rounds" || status=$?
echo "model under TSan: exit=$status"
for mutation in MODEL_NO_RECHECK MODEL_PENDING_LATE; do
    clang++ -std=c++17 -O1 -g -pthread "-D$mutation" "$source_file" -o "$output/model-$mutation"
    if "$output/model-$mutation" "$rounds"; then
        echo "mutation $mutation detected"
    else
        echo "mutation $mutation was NOT detected" >&2
        status=1
    fi
done
exit "$status"
