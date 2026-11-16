#!/bin/bash
# Make a Linux test frame: a copy of an old frame (libraries) with the runtime, JIT, CoreLib and the GC libraries of a new build.
# usage: make-frame-linux.sh <old frame> <repo with a Release clr build> <new frame>
set -eu
OLD=$1; R=$2; NEW=$3
BIN=$R/artifacts/bin/coreclr/linux.x64.Release
OBJ=$R/artifacts/obj/coreclr/linux.x64.Release
rm -rf $NEW
cp -a $OLD $NEW
rm -f $NEW/lib*gc*.so $NEW/lib*gc*.so.dbg
cp $BIN/corerun $BIN/libcoreclr.so $BIN/libclrjit.so $BIN/System.Private.CoreLib.dll $BIN/libclrgc.so $BIN/libclrgcexp.so $BIN/libcoreclrtraceptprovider.so $NEW/
cp $OBJ/gc_lxr/libclrlxrgc.so $OBJ/gc_laxori/libclrlaxorigc.so $OBJ/gc_laxori/libclrlaxorigc-bitmap.so $OBJ/gc_satori/libsatorigc.so $NEW/
ls -l $NEW/corerun $NEW/libcoreclr.so $NEW/System.Private.CoreLib.dll $NEW/lib*gc*.so
