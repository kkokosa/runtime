$fr = 'C:\lx-run\frame'; $probe = 'C:\lx-run\dl\commit\out\CommitProbe.dll'
foreach ($c in @(@('d67c','clrlxrgc-d67c.dll'), @('fix','clrlxrgc-fix.dll'))) {
    foreach ($res in 8000, 60000, 250000) {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'DOTNET_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
        $env:DOTNET_gcServer = '1'; $env:DOTNET_GCPath = "$fr\$($c[1])"
        $env:DOTNET_LXRImmixReserveMB = "$res"; $env:DOTNET_LXRLOSReserveMB = "$res"; $env:DOTNET_LXRNativePlaneLimitMB = '2000000'
        $out = & "$fr\corerun.exe" $probe 2>&1 | Select-Object -First 1
        "$($c[0]) reserves $res/$res MB : $out"
    }
}
