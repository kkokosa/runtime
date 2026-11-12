# Start-up commit charge and working set of a trivial program, for several DLLs and settings. Interleaved, N runs each.
# usage: commit-ab.ps1 [-Runs 5] [-Regions]   (no lock: the program does nothing but start)
param([int]$Runs = 5, [switch]$Regions)
$fr = 'C:\lx-run\frame'
$probe = 'C:\lx-run\dl\commit\out\CommitProbe.dll'
$job = 'C:\Users\konradkokosa\.copilot\repos\copilot-worktrees\runtime-fork\kkokosa-refactored-journey\docs\design\laxori-port\windows\run-in-job.ps1'
$cases = @(
    @{ n = 'old-7e4d'; dll = 'clrlxrgc-7e4d.dll'; env = @{}; job = 0 },
    @{ n = 'd67c';     dll = 'clrlxrgc-d67c.dll'; env = @{}; job = 0 },
    @{ n = 'fix';      dll = 'clrlxrgc-fix.dll';  env = @{}; job = 0 },
    @{ n = 'old-7e4d-job700'; dll = 'clrlxrgc-7e4d.dll'; env = @{}; job = 700 },
    @{ n = 'd67c-job700';     dll = 'clrlxrgc-d67c.dll'; env = @{}; job = 700 },
    @{ n = 'fix-job700';      dll = 'clrlxrgc-fix.dll';  env = @{}; job = 700 },
    @{ n = 'd67c-r128/256';   dll = 'clrlxrgc-d67c.dll'; env = @{ DOTNET_LXRImmixReserveMB = '128'; DOTNET_LXRLOSReserveMB = '256' }; job = 0 },
    @{ n = 'fix-r128/256';    dll = 'clrlxrgc-fix.dll';  env = @{ DOTNET_LXRImmixReserveMB = '128'; DOTNET_LXRLOSReserveMB = '256' }; job = 0 },
    @{ n = 'old-r128/256';    dll = 'clrlxrgc-7e4d.dll'; env = @{ DOTNET_LXRImmixReserveMB = '128'; DOTNET_LXRLOSReserveMB = '256' }; job = 0 }
)
$results = @{}
foreach ($rep in 1..$Runs) {
    foreach ($c in ($cases | Sort-Object { Get-Random })) {
        Get-ChildItem Env: | Where-Object { $_.Name -like 'DOTNET_*' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
        $env:DOTNET_gcServer = '1'
        $env:DOTNET_GCPath = "$fr\$($c.dll)"
        foreach ($k in $c.env.Keys) { Set-Item "Env:$k" $c.env[$k] }
        $arg = if ($Regions -and $rep -eq 1) { 'regions' } else { '' }
        if ($c.job -gt 0) {
            $pa = @("$fr\corerun.exe", $probe); if ($arg) { $pa += $arg }; $out = & powershell -NoProfile -File $job -LimitMB $c.job @pa 2>&1
        } else {
            $out = & "$fr\corerun.exe" $probe $arg 2>&1
        }
        $line = ($out | Where-Object { $_ -match 'private_mb' } | Select-Object -First 1)
        if ($line -match 'private_mb=([\d.]+) ws_mb=([\d.]+)') {
            if (-not $results.ContainsKey($c.n)) { $results[$c.n] = @() }
            $results[$c.n] += , @([double]$Matches[1], [double]$Matches[2])
        } else {
            "FAILED $($c.n): $($out -join ' | ')"
        }
        if ($arg -eq 'regions') { "== regions $($c.n)"; $out }
    }
}
function Med($v) { $s = $v | Sort-Object; $s[[int][math]::Floor(($s.Count - 1) / 2)] }
"| case | private (commit) MB median [min-max] | working set MB median [min-max] | runs |"
"|---|---|---|---|"
foreach ($c in $cases) {
    $r = $results[$c.n]
    if ($null -eq $r) { "| $($c.n) | failed | | 0 |"; continue }
    $p = $r | ForEach-Object { $_[0] }; $w = $r | ForEach-Object { $_[1] }
    "| $($c.n) | $(Med $p) [$(($p | Measure-Object -Minimum).Minimum)-$(($p | Measure-Object -Maximum).Maximum)] | $(Med $w) [$(($w | Measure-Object -Minimum).Minimum)-$(($w | Measure-Object -Maximum).Maximum)] | $($r.Count) |"
}

