#!/usr/bin/env bash
# usage: rc-layout.sh <repo root WSL> <gc_laxori dir WSL> <build subdir> <out>   record layouts of LaxoriReferenceCounting, LaxoriRcConfiguration, LaxoriPauseTimers
# with the compile command of the product build, so that the offsets of two source trees can be compared.
set -eu
wt="$1"; dir="$2"; sub="$3"; out="$4"
cd "$wt/artifacts/obj/coreclr/linux.x64.Release/$sub"
cmd="$(ninja -t commands gc_laxori/CMakeFiles/clrlaxorigc.dir/laxori_reference_counting.cpp.o | tail -1)"
cmd="${cmd/ -o /  -fsyntax-only -Xclang -fdump-record-layouts -o /}"
cmd="$(echo "$cmd" | sed -E 's/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -c [^ ]+$//')"
eval "$cmd -c $dir/laxori_reference_counting.cpp" 2>/dev/null | awk '/^\*\*\* Dumping AST Record Layout/{keep=0} /\| (class|struct) (LaxoriReferenceCounting|LaxoriRcConfiguration|LaxoriPauseTimers)$/{keep=1} keep' > "$out"
wc -l "$out"
