#!/usr/bin/env bash
# usage: layout.sh <source root> > file   Prints the record layouts of LxrLargeObjectSpace and its Span (clang).
root="$1"
gc="$root/src/coreclr/gc"; lxr="$root/src/coreclr/gc_lxr"; native="$root/src/native"
clang++-14 -std=c++17 -fsyntax-only -Xclang -fdump-record-layouts -DBUILD_AS_STANDALONE -DLXR_SIDE_METADATA_TEST_PLATFORM \
  -DLXR_OBJECT_START_WALK -DTARGET_UNIX -DHOST_UNIX -DTARGET_LINUX -DHOST_LINUX -DTARGET_AMD64 -DHOST_AMD64 -DTARGET_64BIT -DHOST_64BIT \
  -Wno-invalid-offsetof -I"$lxr" -I"$gc" -I"$gc/env" -I"$native" -I"$native/inc" "$lxr/large_object_space.cpp" 2>/dev/null |
  awk '/^\*\*\* Dumping AST Record Layout/ {keep=0; getline h; getline; if (h ~ /LxrLargeObjectSpace$/ || h ~ /LxrLargeObjectSpace::Span$/ || h ~ /LxrLargeObjectSpace::SideState$/) {keep=1; print "*** " h}} keep {print}'
