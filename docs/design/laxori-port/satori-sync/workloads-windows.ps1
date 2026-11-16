# Run the seven standard CompareDriver workloads with stock WKS/SVR, Satori, LXR and Laxori and check the checksums.
# usage: workloads-windows.ps1 -Frame <dir> -Driver <CompareDriver.dll> -Out <dir> [-Repeats 1] [-Configs wks,svr,satori,lxr,laxori]
# Writes one CSV line for each run to <Out>\runs.csv. Exit code 1 if a run fails or a checksum differs.
param(
    [Parameter(Mandatory)] [string] $Frame,
    [Parameter(Mandatory)] [string] $Driver,
    [Parameter(Mandatory)] [string] $Out,
    [int] $Repeats = 1,
    [string[]] $Configs = @('wks', 'svr', 'satori', 'lxr', 'laxori'),
    [string[]] $Workloads = @('requests', 'binarytrees', 'listsuffix', 'mixedmedium', 'losarrays', 'mediumarrays', 'losmany'),
    # Without this switch, LXR and Laxori get the usual heap settings of bench-windows.py for mediumarrays and losmany.
    [switch] $NoSettings
)
$Configs = $Configs -split ','
$Workloads = $Workloads -split ','
$heapEnv = 'ImmixInitialMB', 'ImmixReserveMB', 'LOSInitialMB', 'LOSReserveMB', 'NativePlaneLimitMB'
function Clear-GcEnv {
    Remove-Item Env:DOTNET_gcServer, Env:DOTNET_GCPath -ErrorAction SilentlyContinue
    foreach ($p in 'LXR', 'LAXORI') { foreach ($n in $heapEnv) { Remove-Item "Env:DOTNET_$p$n" -ErrorAction SilentlyContinue } }
}
function Set-HeapEnv([string] $c, [string] $w) {
    if ($NoSettings -or ($c -notin 'lxr', 'laxori')) { return }
    $p = if ($c -eq 'laxori') { 'LAXORI' } else { 'LXR' }
    if ($w -eq 'mediumarrays') { Set-Item "Env:DOTNET_${p}ImmixInitialMB" 200; Set-Item "Env:DOTNET_${p}ImmixReserveMB" 400 }
    if ($w -eq 'losmany') { Set-Item "Env:DOTNET_${p}LOSInitialMB" 1000; Set-Item "Env:DOTNET_${p}LOSReserveMB" 1600; Set-Item "Env:DOTNET_${p}NativePlaneLimitMB" 16000 }
}

$args7 = @{
    requests     = @(8192, 200000, 27134172608)
    binarytrees  = @(18, 1, 68332294)
    listsuffix   = @(8192, 600000, 159636632672)
    mixedmedium  = @(12000, 200000, 40586599707)
    losarrays    = @(1500, 100000, 13936826922)
    mediumarrays = @(20000, 300000, 7032863679)
    losmany      = @(2000, 60000, 42674603309)
}
$gc = @{
    wks    = @('0', $null)
    svr    = @('1', $null)
    satori = @($null, 'satorigc.dll')
    lxr    = @('1', 'clrlxrgc.dll')
    laxori = @('1', 'clrlaxorigc.dll')
}

New-Item -ItemType Directory -Force $Out | Out-Null
$csv = Join-Path $Out 'runs.csv'
if (-not (Test-Path $csv)) { 'repeat,config,workload,exit,checksum,ok,wall_ms,cpu_ms,pause_ms,collections,peak_rss_mb' | Set-Content $csv }
$failed = 0
for ($r = 1; $r -le $Repeats; $r++) {
    foreach ($w in $Workloads) {
        # Interleave the collectors for each workload so that host noise is spread over all of them.
        foreach ($c in $Configs) {
            Clear-GcEnv
            Set-HeapEnv $c $w
            if ($gc[$c][0]) { $env:DOTNET_gcServer = $gc[$c][0] }
            if ($gc[$c][1]) { $env:DOTNET_GCPath = Join-Path $Frame $gc[$c][1] }
            $dir = Join-Path $Out "$c-$w-$r"
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
            $a = $args7[$w]
            & (Join-Path $Frame 'corerun.exe') $Driver $dir $w $a[0] $a[1] > "$dir.log" 2>&1
            $code = $LASTEXITCODE
            $j = $null
            if (Test-Path "$dir\result.json") { $j = Get-Content "$dir\result.json" -Raw | ConvertFrom-Json }
            $ok = ($code -eq 0) -and $j -and ([int64]$j.checksum -eq [int64]$a[2])
            if (-not $ok) { $failed++ }
            $line = "$r,$c,$w,$code,$($j.checksum),$ok,$($j.wall_ms),$($j.cpu_ms),$($j.pause_ms),$($j.collections),$($j.peak_rss_mb)"
            Add-Content $csv $line
            Write-Output $line
        }
    }
}
Clear-GcEnv
Write-Output "failed=$failed"
exit [int]($failed -ne 0)
