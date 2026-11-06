#!/usr/bin/env bash
# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

# One repetition of the suspension test on both OS, run while the caller holds the shared lock.
# usage (in WSL2): suspend-inner.sh <outfile> <rep>
out="$1"; r="$2"
W=/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-refactored-journey/docs/design/laxori-port/windows
/mnt/c/Windows/System32/cmd.exe /c 'C:\Users\konradkokosa\AppData\Local\Programs\Python\Python312\python.exe' 'K:\docs\design\laxori-port\windows\suspend.py' win 'C:\lx-run\suspend' "$r" | tr -d '\r' >> "$out"
python3 $W/suspend.py lin /root/laxori/suspend "$r" >> "$out"
