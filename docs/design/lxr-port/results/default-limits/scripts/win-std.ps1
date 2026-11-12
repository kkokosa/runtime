$ErrorActionPreference = 'Continue'
# One run of each workload with the fix DLL and NO settings, under the shared lock; prints the checksum check.
$fr = 'C:\lx-run\frame'
$sums = @{ requests = 27134172608; binarytrees = 68332294; listsuffix = 159636632672; mixedmedium = 40586599707; losarrays = 13936826922; mediumarrays = 7032863679; losmany = 42674603309 }
$args2 = @{ requests = '8192 200000'; binarytrees = '18 1'; listsuffix = '8192 600000'; mixedmedium = '12000 200000'; losarrays = '1500 100000'; mediumarrays = '20000 300000'; losmany = '2000 60000' }
foreach ($dll in 'clrlxrgc-fix.dll') {
    foreach ($w in 'requests', 'losmany', 'mediumarrays', 'losarrays', 'binarytrees', 'listsuffix', 'mixedmedium') {
        $d = "C:\lx-run\dl\wf-$w"; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $d | Out-Null
        $cmd = "set DOTNET_gcServer=1&& set DOTNET_GCPath=$fr\$dll&& $fr\corerun.exe C:\lx-run\dl\drvlm\out\CompareDriver.dll $d $w $($args2[$w]) > $d\out.txt 2>&1"
        wsl -d Ubuntu-22.04 --exec flock /tmp/lxr-bench.lock cmd.exe /c $cmd
        $j = (Get-Content "$d\result.json" -Raw -ErrorAction SilentlyContinue) | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($j) { "{0} {1}: checksum {2} {3}, wall {4:N0} ms, collections {5}, peak RSS {6:N0} MB" -f $dll, $w, $j.checksum, $(if ($j.checksum -eq $sums[$w]) { 'OK' } else { 'BAD' }), $j.wall_ms, $j.collections, $j.peak_rss_mb }
        else { "$dll $w FAILED: " + ((Get-Content "$d\out.txt" -First 2) -join ' | ') }
        Start-Sleep 8
    }
}
