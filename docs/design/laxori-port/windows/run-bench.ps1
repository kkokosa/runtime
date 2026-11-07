# Windows benchmark of the five collectors (WKS, SVR, Satori, LXR, Laxori) plus LXR+copylog-fix.
# One repetition (7 workloads) per lock grant, 8 s sleep between grants (bench-windows.py defaults: --block 7 --sleep 8).
# usage: run-s0.ps1 <outdir> <reps> [<laxori library>]
param([string]$Out = 'C:\lx-run\bench-s0', [int]$Reps = 9)
$py = 'C:\Users\konradkokosa\AppData\Local\Programs\Python\Python312\python.exe'
& $py "$PSScriptRoot\bench-windows.py" $Out $Reps 'wks,svr,satori,lxr,lxr-fix,laxori' 'requests,binarytrees,listsuffix,mixedmedium,losarrays,mediumarrays,losmany' 'laxori:lxr,laxori:lxr-fix,lxr-fix:lxr,laxori:wks,laxori:svr,laxori:satori' --block 7
