param([int]$Live = 12000, [int]$Reps = 2)
$e = 'C:\lx-run\frame\corerun.exe'
foreach ($r in 1..$Reps) {
    foreach ($lib in 'clrlaxorigc.dll', 'clrlaxorigc-chunk.dll') {
        $cap = [int]($Live * 1.8)
        $env:DOTNET_gcServer = 1; $env:DOTNET_GCPath = "C:\lx-run\frame\$lib"
        $env:DOTNET_LAXORIImmixInitialMB = 4000; $env:DOTNET_LAXORIImmixReserveMB = $cap
        $env:DOTNET_LAXORINativePlaneLimitMB = 200000; $env:DOTNET_LAXORITraceThreshold = 2
        $d = "C:\lx-run\diag\chunk-$lib-$r"; Remove-Item $d -Recurse -Force -EA 0
        $out = & $e C:\lx-run\drv-scale\out\ScalingDriver.dll $d bigheap $Live 5 2 30 300 2>&1 | Out-String
        $ok = Test-Path "$d\result.json"
        $setup = if ($ok) { (Get-Content "$d\result.json" | ConvertFrom-Json).setup_ms } else { -1 }
        "{0,-22} rep{1} live={2} ok={3} setup_ms={4} {5}" -f $lib, $r, $Live, $ok, $setup, (($out -split "`n" | ? { $_ -match 'fatal|could not' } | Select -First 1))
    }
}
