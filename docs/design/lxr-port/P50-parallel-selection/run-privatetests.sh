#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# PrivateTests `all 2 13` (docs/design/lxr-port/P32-privatetests-failure/repeat.sh) on one library, in four settings: the default,
# DOTNET_LXRTraceThreshold=1 (a trace in every pause), and both again with the parallel selection forced and validated against
# the serial one (DOTNET_LXRSelectParallelBlocks=0, DOTNET_LXRSelectValidate=1).
#   usage: run-privatetests.sh <libclrlxrgc.so> <runs> <output root>
set -u
lib="$1"; runs="$2"; out="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repeat="$here/../P32-privatetests-failure/repeat.sh"
status=0
export DOTNET_LXRImmixInitialMB=200 DOTNET_LXRImmixReserveMB=400
bash "$repeat" "$lib" "$runs" "$out/default" || status=1
DOTNET_LXRTraceThreshold=1 bash "$repeat" "$lib" "$runs" "$out/trace1" || status=1
DOTNET_LXRSelectParallelBlocks=0 DOTNET_LXRSelectValidate=1 bash "$repeat" "$lib" "$runs" "$out/forced" || status=1
DOTNET_LXRSelectParallelBlocks=0 DOTNET_LXRSelectValidate=1 DOTNET_LXRTraceThreshold=1 bash "$repeat" "$lib" "$runs" "$out/forced-trace1" || status=1
exit $status
