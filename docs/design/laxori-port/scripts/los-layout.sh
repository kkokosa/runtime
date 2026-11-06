#!/usr/bin/env bash
# usage: los-layout.sh <repo root as WSL path> > file   Prints the record layouts of LaxoriLargeObjectSpace, its Span and SideState (clang).
# The LOS lock is contended: Span and all member offsets must not change when state is added (it goes behind one pointer at the end).
root="$1"
gc="$root/src/coreclr/gc"; lx="$root/src/coreclr/gc_laxori"; native="$root/src/native"
clang++-14 -std=c++17 -fsyntax-only -Xclang -fdump-record-layouts -DBUILD_AS_STANDALONE -DLAXORI_SIDE_METADATA_TEST_PLATFORM \
  -DLAXORI_OBJECT_START_WALK -DTARGET_UNIX -DHOST_UNIX -DTARGET_LINUX -DHOST_LINUX -DTARGET_AMD64 -DHOST_AMD64 -DTARGET_64BIT -DHOST_64BIT \
  -Wno-invalid-offsetof -I"$lx" -I"$gc" -I"$gc/env" -I"$native" -I"$native/inc" "$lx/laxori_large_object_space.cpp" 2>/dev/null |
  awk '/^\*\*\* Dumping AST Record Layout/ {keep=0; getline h; getline; if (h ~ /LaxoriLargeObjectSpace$/ || h ~ /LaxoriLargeObjectSpace::Span$/ || h ~ /LaxoriLargeObjectSpace::SideState$/) {keep=1; print "*** " h}} keep {print}'
