$ErrorActionPreference = 'Continue'
$fr = 'C:\lx-run\frame'
function Lm($dll, $tag, $n) {
    $d = "C:\lx-run\dl\lm-$tag-$n"; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $d | Out-Null
    $cmd = "set DOTNET_gcServer=1&& set DOTNET_GCPath=$fr\$dll&& $fr\corerun.exe C:\lx-run\dl\drvlm\out\CompareDriver.dll $d losmany $n 60000 > $d\out.txt 2>&1"
    wsl -d Ubuntu-22.04 --exec flock /tmp/lxr-bench.lock cmd.exe /c $cmd
    $j = Get-Content "$d\result.json" -ErrorAction SilentlyContinue
    "$tag losmany $n :: " + (($j -join ' ') -replace '\s+',' ') + " :: " + ((Select-String "$d\out.txt" -Pattern 'LXR: out' | Select -First 1 | % Line))
    Start-Sleep 8
}
Lm clrlxrgc-7e4d.dll old 2000
Lm clrlxrgc-new2.dll new 2000
Lm clrlxrgc-new2.dll new 8000
"LMDONE"

