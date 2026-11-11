$ErrorActionPreference = 'Continue'
function Run($dll, $env, $tag) {
    $log = "C:\lx-run\dl\w2-$tag.log"
    wsl -d Ubuntu-22.04 --exec flock /tmp/lxr-bench.lock cmd.exe /c "C:\lx-run\dl\run-win.cmd $dll 540 $log 2 $env"
    $s = (Get-Content $log -First 1); $e = (Get-Content $log -Last 1)
    "$tag :: $s :: $e"
    Start-Sleep 8
}
Run clrlxrgc-new.dll "" new-default-a
Run clrlxrgc-7e4d.dll C:\lx-run\dl\env-r6000.cmd old-r6000-a
Run clrlxrgc-new.dll C:\lx-run\dl\env-r6000.cmd new-r6000-a
Run clrlxrgc-7e4d.dll C:\lx-run\dl\env-r6000.cmd old-r6000-b
Run clrlxrgc-new.dll "" new-default-b
Run clrlxrgc-new.dll C:\lx-run\dl\env-r6000.cmd new-r6000-b
"WINDONE"
