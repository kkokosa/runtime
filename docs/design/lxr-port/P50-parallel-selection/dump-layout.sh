#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Dumps the record layout of LxrReferenceCounting, LxrRcConfiguration and LxrPauseTimers (clang -fdump-record-layouts) with the
# compile command of the product build of one worktree, so that the offsets of two builds can be compared.
#   usage: dump-layout.sh <worktree root> <build subdir> <output file>
set -eu
wt="$1"; sub="$2"; out="$3"
build="$wt/artifacts/obj/coreclr/linux.x64.Release/$sub"
cd "$build"
cmd="$(ninja -t commands gc_lxr/CMakeFiles/clrlxrgc.dir/lxr_reference_counting.cpp.o | tail -1)"
# Replace the output and the compile mode: syntax only, with the layout dump on stdout.
cmd="${cmd/ -o /  -fsyntax-only -Xclang -fdump-record-layouts -o /}"
cmd="$(echo "$cmd" | sed -E 's/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -c [^ ]+$//')"
src="$wt/src/coreclr/gc_lxr/lxr_reference_counting.cpp"
eval "$cmd -c $src" 2>/dev/null | awk '/^\*\*\* Dumping AST Record Layout/{keep=0} /\| (class|struct) (LxrReferenceCounting|LxrRcConfiguration|LxrPauseTimers)$/{keep=1} keep' > "$out"
wc -l "$out"
