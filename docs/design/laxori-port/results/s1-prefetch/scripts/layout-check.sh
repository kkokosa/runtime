#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.
#
# Layout check of the hot classes (clang -Xclang -fdump-record-layouts, the compile command of the product build of this worktree).
# Compares the member offsets and sizes of LaxoriReferenceCounting, LaxoriRcConfiguration, LaxoriPauseTimers and of the large-object-space
# classes (LaxoriLargeObjectSpace, Span, SideState) of
#   ref    the sources of a reference commit (git show <commit>:src/coreclr/gc_laxori/...)
#   cur    the sources of the working tree
# usage: REFSRC=<dir> layout-check.sh <repo root WSL> <ref commit (label only)> <outdir>
set -eu
root="$1"; ref="$2"; out="$3"
mkdir -p "$out" /root/s1/src-ref
rm -rf /root/s1/src-ref/gc_laxori; mkdir -p /root/s1/src-ref/gc_laxori
# The worktree .git file points to a Windows path, so git cannot run in WSL: REFSRC is a directory with the reference sources
# (extracted with Windows git: git archive <commit> src/coreclr/gc_laxori | tar -x -C <dir>).
cp -r "${REFSRC:?set REFSRC to the extracted reference gc_laxori directory}"/* /root/s1/src-ref/gc_laxori/
cd "$root"
cd "$root/artifacts/obj/coreclr/linux.x64.Release/s1"
layout() {  # layout <source file> <extra defines> <class regex> <outfile>
  local src="$1" defs="$2" classes="$3" outfile="$4" target cmd
  target="gc_laxori/CMakeFiles/clrlaxorigc.dir/$(basename "$src").o"
  cmd="$(ninja -t commands "$target" | tail -1)"
  cmd="${cmd/ -o /  -fsyntax-only -Xclang -fdump-record-layouts -o /}"
  cmd="$(echo "$cmd" | sed -E 's/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -c [^ ]+$//')"
  eval "$cmd $defs -c $src" 2>/dev/null |
    awk -v re="$classes" '/^\*\*\* Dumping AST Record Layout/{keep=0} $0 ~ re {keep=1} keep' > "$outfile"
  wc -l "$outfile"
}
RC='[|] (class|struct) (LaxoriReferenceCounting|LaxoriRcConfiguration|LaxoriPauseTimers)$'
LOS='[|] (class|struct) (LaxoriLargeObjectSpace|LaxoriLargeObjectSpace::Span|LaxoriLargeObjectSpace::SideState)$'
declare -A SRC=( [ref]=/root/s1/src-ref/gc_laxori [cur]="$root/src/coreclr/gc_laxori" )
declare -A DEFS=( [ref]="" [cur]="" )
for v in ref cur; do
  layout "${SRC[$v]}/laxori_reference_counting.cpp" "${DEFS[$v]}" "$RC" "$out/rc-$v.txt"
  layout "${SRC[$v]}/laxori_large_object_space.cpp" "${DEFS[$v]}" "$LOS" "$out/los-$v.txt"
done
for v in cur; do
  for k in rc los; do
    if diff -q "$out/$k-ref.txt" "$out/$k-$v.txt" > /dev/null; then echo "$k $v: IDENTICAL to ref"; else echo "$k $v: DIFFERENT"; diff "$out/$k-ref.txt" "$out/$k-$v.txt" | head -20; fi
  done
done
