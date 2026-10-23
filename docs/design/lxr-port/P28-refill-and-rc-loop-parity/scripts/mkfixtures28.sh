#!/bin/bash
# P28: build the managed fixture (docs/design/lxr-port/P5/runtime-tests) from the worktree for Release and Debug.
# usage: mkfixtures28.sh <repo-root> <output-dir> [dotnet-path]
set -euo pipefail
W=$1
OUT=$2
DOTNET=${3:-$W/.dotnet/dotnet}
mkdir -p "$OUT"
S=$(mktemp -d "$OUT/source-XXXXXX")
cp "$W"/docs/design/lxr-port/P5/runtime-tests/*.cs "$W/docs/design/lxr-port/P5/runtime-tests/runtime-tests.csproj" "$S/"
sed -i 's/\r$//' "$S"/*.cs "$S"/*.csproj
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
for C in Release Debug; do
  "$DOTNET" build "$S/runtime-tests.csproj" -c "$C" -o "$OUT/fixture-scope5-$C" 2>&1 | tail -3
done
