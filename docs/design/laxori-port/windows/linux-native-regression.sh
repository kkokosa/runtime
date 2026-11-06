#!/usr/bin/env bash
# Linux regression after the Windows changes in shared Laxori code: the 10 native engine programs of run-native-all.sh, under the
# shared benchmark lock. usage (in WSL2): linux-native-regression.sh <repo root as WSL path> <output dir>
root="$1"; out="${2:-/tmp/laxori-native-linux}"
flock /tmp/lxr-bench.lock bash "$root/docs/design/laxori-port/run-native-all.sh" "$root" "$out"
