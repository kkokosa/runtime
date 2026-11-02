#!/usr/bin/env bash
# usage: buildpt.sh   copies PrivateTests from the worktree and builds them to /root/laxori/pt/bin
set -e
rm -rf /root/laxori/pt; mkdir -p /root/laxori/pt
cp /mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-reimagined-eureka/docs/design/laxori-port/PrivateTests/PrivateTests.* /root/laxori/pt/
cd /root/laxori/pt
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
/root/lxr-p5-1205f569/.dotnet/dotnet build -c Release -o bin 2>&1 | grep -E 'error|Elapsed'
