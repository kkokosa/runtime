# Verifies the board's quantified prose claims against the P0.5 artifacts they describe.
#
# Why this exists. board-check.ps1 has thirteen checks across contents, extent, subject and
# hygiene, and not one of them compares a SENTENCE to a NUMBER. It would pass a board whose
# every structural property was perfect and whose P0.6 directive told an implementer to code
# against a count that no longer held. That is not hypothetical here: the directive shipped
# "0 of 6 throughput-phase rows" where the set actually claimed was 69, and it was caught by
# re-reading rather than by any instrument. P0.5-baselines.md:941 names the same gap on the
# document side -- "Not one compared a *sentence* to a number" -- and check-prose-claims.py
# was written to close it there. This is that script's counterpart for the board.
#
# Design constraint, taken from check-prose-claims.py:11-14. Every expected value is DERIVED
# from the artifacts at run time and never written here as a constant. This file holds only
# the locator patterns, the predicates, and the paths. A checker holding its own copy of a
# number is a second place to be wrong, and it agrees with a stale board as readily as with
# a correct one.
#
# Each claim is checked at EVERY occurrence, not at one located sentence. The board repeats
# these figures between two and four times, which is the multi-site literal drift that
# verify-baselines.sh:10-11 forbids outright -- "never repeated as literals at several
# assertion sites, so two cannot drift from a third unnoticed". Prose cannot be de-duplicated
# the way a script's constants can, so the next best thing is to require every copy to agree
# with the derived value.
#
# A pattern that matches NOTHING fails. Rule 74: observing a pass on a perturbed input cannot
# distinguish "the check passed" from "the check never arrived", and a reworded sentence
# silently retires its own regex. The same guard applies to the populations -- an empty row
# set makes "all rows carry X" vacuously true, which this script's own first draft printed as
# "0 of 0" after reading `results` at the top level when the rows live under
# `checkpoints[].results`. A defaulted read is a non-arrival that returns a plausible value.
#
# Every claim prints the derived value, the located text and the comparison, per rule 26: a
# bare verdict hides a check that ran against the wrong thing.

param(
    [string]$Repo = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))),
    # The artifacts live on the P0.5 branch, not this one. Pinned to the reviewed tree by
    # hash rather than to a branch name: a moving ref would silently change the subject of
    # every claim below. After the pull request merges this becomes the merge commit.
    [string]$Ref = '9f054925372',
    # Parameterised only so the negative control can point this at a fabricated board, the
    # same reason board-check.ps1 parameterises $LogDir. The banner prints it, per rule 63.
    [string]$Board = (Join-Path $PSScriptRoot 'roadmap.md')
)

$ErrorActionPreference = 'Stop'

$BASE = 'docs/design/lxr-port/P0.5-baselines/'
$board = $Board
$pass = 0
$fail = 0

function ok  ($m) { $script:pass++; Write-Output "  ok    $m" }
function bad ($m) { $script:fail++; Write-Output "  FAIL  $m" }

function Show-Blob ($path) {
    $t = & git -C $Repo show "${Ref}:$path" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "cannot read '$path' at $Ref" }
    return ($t -join "`n")
}

Write-Output 'LXR board claim check'
Write-Output "  board : $board"
Write-Output "  repo  : $Repo"
Write-Output "  ref   : $Ref"

$resolved = & git -C $Repo rev-parse --verify "$Ref^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Output "  FAIL  ref '$Ref' does not resolve in $Repo"; exit 2 }
Write-Output "  tree  : $(& git -C $Repo rev-parse "$Ref^{tree}")"
Write-Output ''

if (-not (Test-Path $board)) { Write-Output "  FAIL  no board at $board"; exit 2 }
$text = Get-Content $board -Raw

# ---- derive, from the artifacts only -------------------------------------------------

Write-Output '== derived from the artifacts =='

$rows = @()
foreach ($s in 's2', 's3', 's4sdk') {
    $doc = Show-Blob "${BASE}p0-5-baselines-$s.json" | ConvertFrom-Json
    foreach ($cp in $doc.checkpoints) { $rows += $cp.results }
}
if ($rows.Count -eq 0) { Write-Output '  FAIL  no result rows parsed; every count below would be vacuous'; exit 2 }

$csvRows = @()
$csvCols = $null
foreach ($s in 's2', 's3', 's4sdk') {
    $parsed = Show-Blob "${BASE}raw/p0-5-baselines-$s-invocations.csv" | ConvertFrom-Csv
    if ($null -eq $csvCols) { $csvCols = @($parsed[0].PSObject.Properties.Name) }
    $csvRows += $parsed
}
if ($csvRows.Count -eq 0) { Write-Output '  FAIL  no CSV rows parsed'; exit 2 }

$valid   = @($rows | Where-Object { $_.status -ne 'crashed' })
$lat     = @($valid | Where-Object { $_.notes -like '*testhost.latency*' })
$thr     = @($valid | Where-Object { $_.notes -notlike '*testhost.latency*' })
$thrEx   = @($thr | Where-Object { $_.scenario -ne 'aspnet-request-load' })
$latP99  = @($lat   | Where-Object { $null -ne $_.latencyP99Ms }).Count
$thrP99  = @($thrEx | Where-Object { $null -ne $_.latencyP99Ms }).Count
$fallback = @($rows | Where-Object { $_.pauseSource -like 'total-pause-duration-only*' }).Count

$csvLat  = @($csvRows | Where-Object { $_.runId -like '*.latency*' })
$csvThr  = @($csvRows | Where-Object { $_.runId -notlike '*.latency*' })
function HasVal ($v) { $v -and $v -ne 'NA' -and $v -ne 'null' }
$csvLatP99 = @($csvLat | Where-Object { HasVal $_.latencyP99Ms }).Count
$csvThrP99 = @($csvThr | Where-Object { HasVal $_.latencyP99Ms }).Count

$jsonKeys = @($rows | ForEach-Object { $_.PSObject.Properties.Name } | Sort-Object -Unique)
$shared   = @($csvCols | Where-Object { $jsonKeys -contains $_ }).Count

# Per-scenario worst latency-phase departure from a ratio of 1.000, in percent.
$worst = @{}
foreach ($r in $lat) {
    if ($null -ne $r.ratioVsBaseline) {
        $d = [Math]::Abs([double]$r.ratioVsBaseline - 1.0) * 100
        if (-not $worst.ContainsKey($r.scenario) -or $d -gt $worst[$r.scenario]) { $worst[$r.scenario] = $d }
    }
}
$within  = @($worst.Values | Where-Object { $_ -lt 0.16 }).Count
$maxNine = ($worst.GetEnumerator() | Where-Object { $_.Key -ne 'aspnet-request-load' } |
            ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum
$aspnet  = $worst['aspnet-request-load']

# The pause signal no ratio basis reaches. Derived from the per-invocation CSV, never from
# the aggregate row: Aggregator.cs:301-305 states the published pauseP99Ms is copied out of
# a SINGLE invocation, so the aggregate and the mean of five are different estimators and
# disagree by design (6.98x against 4.05x at 1.3x). Both are checked here, separately.
$phCsv = @($csvRows | Where-Object { $_.scenario -eq 'pinning-heavy-io' -and $_.runId -notlike '*.latency*' })
if ($phCsv.Count -eq 0) { Write-Output '  FAIL  no pinning-heavy-io throughput rows in the CSV'; exit 2 }
$phHeaps = @($phCsv | ForEach-Object { [double]$_.heapFactor } | Sort-Object -Unique)
$phJson  = @($valid | Where-Object { $_.scenario -eq 'pinning-heavy-io' -and $_.notes -notlike '*testhost.latency*' })

$phRatio = @(); $phPnum = @(); $phPden = 0; $phAgg = @(); $phPublished = @()
foreach ($h in $phHeaps) {
    $w = @($phCsv | Where-Object { [double]$_.heapFactor -eq $h -and $_.collector -eq 'wks' } | ForEach-Object { [double]$_.pauseP99Ms })
    $s = @($phCsv | Where-Object { [double]$_.heapFactor -eq $h -and $_.collector -eq 'srv' } | ForEach-Object { [double]$_.pauseP99Ms })
    if ($w.Count -eq 0 -or $s.Count -eq 0) { Write-Output "  FAIL  missing an arm at heap $h"; exit 2 }
    $mw = ($w | Measure-Object -Average).Average
    $ms = ($s | Measure-Object -Average).Average
    $phRatio += [Math]::Round($ms / $mw, 2)

    # Exact one-sided permutation test: every split of the pooled samples is enumerated, so
    # there is no seed and no resampling. A bootstrap interval cannot be re-derived by a
    # checker that does not share its RNG, which would make it a claim nothing is pointed at.
    $pool = @($w + $s); $n = $pool.Count; $k = $w.Count; $obs = $ms - $mw; $ge = 0; $tot = 0
    for ($m = 0; $m -lt (1 -shl $n); $m++) {
        $idx = @(0..($n - 1) | Where-Object { $m -band (1 -shl $_) })
        if ($idx.Count -ne $k) { continue }
        $a = @($idx | ForEach-Object { $pool[$_] })
        $b = @(0..($n - 1) | Where-Object { $idx -notcontains $_ } | ForEach-Object { $pool[$_] })
        $tot++
        if ((($b | Measure-Object -Average).Average - ($a | Measure-Object -Average).Average) -ge $obs) { $ge++ }
    }
    $phPnum += $ge
    $phPden = $tot

    $jw = @($phJson | Where-Object { [double]$_.heapFactor -eq $h -and $_.collector -eq 'wks' })
    $js = @($phJson | Where-Object { [double]$_.heapFactor -eq $h -and $_.collector -eq 'srv' })
    $phAgg += [Math]::Round([double]$js[0].pauseP99Ms / [double]$jw[0].pauseP99Ms, 2)
    $phPublished += ([double]$js[0].ratioVsBaseline).ToString('0.000000')
}
# The one heap factor where the two samples overlap, so the board cannot claim separation.
$hi = $phHeaps[-1]
$ovSrv = (@($phCsv | Where-Object { [double]$_.heapFactor -eq $hi -and $_.collector -eq 'srv' } | ForEach-Object { [double]$_.pauseP99Ms }) | Measure-Object -Minimum).Minimum
$ovWks = (@($phCsv | Where-Object { [double]$_.heapFactor -eq $hi -and $_.collector -eq 'wks' } | ForEach-Object { [double]$_.pauseP99Ms }) | Measure-Object -Maximum).Maximum

# aspnet-request-load is the matrix's only latency-primary scenario, and the column carrying
# its statistics is not the column carrying its signal. Both p-values are EXACT: every one of
# the 252 arrangements is enumerated, so there is no seed to share and any language reproduces
# them. Two-sided here, because the direction is not predicted in advance.
$aspJson = @($valid | Where-Object { $_.scenario -eq 'aspnet-request-load' -and $_.notes -like '*testhost.latency*' })
# The share must come from the per-invocation CSV, not the published JSON row. Nine columns
# including pauseP99Ms are copied from ONE invocation (Aggregator.cs:262), so a JSON-derived
# share is a ratio of two single draws. Same quantity, two estimators, and the sentence has to
# say which -- rule 84 applied to estimators rather than to artifacts or file paths.
$aspCsv = @($csvRows | Where-Object { $_.scenario -eq 'aspnet-request-load' -and
                                      $_.runId -like '*.latency' -and
                                      "$($_.valid)".Trim().ToLower() -eq 'true' })
$shares = @()
foreach ($grp in ($aspCsv | Group-Object { "$($_.collector)|$([double]$_.heapFactor)" })) {
    $mp = (@($grp.Group | ForEach-Object { [double]$_.pauseP99Ms })  | Measure-Object -Average).Average
    $ml = (@($grp.Group | ForEach-Object { [double]$_.latencyP99Ms }) | Measure-Object -Average).Average
    $shares += 100 * $mp / $ml
}
$aspShareLo = [Math]::Round(($shares | Measure-Object -Minimum).Minimum, 2)
$aspShareHi = [Math]::Round(($shares | Measure-Object -Maximum).Maximum, 2)

$aspCsv = @($csvRows | Where-Object { $_.scenario -eq 'aspnet-request-load' -and $_.runId -like '*.latency*' })
if ($aspCsv.Count -eq 0) { Write-Output '  FAIL  no aspnet latency-phase rows in the CSV'; exit 2 }
$aspHeaps = @($aspCsv | ForEach-Object { [double]$_.heapFactor } | Sort-Object -Unique)
$aspLatP = @(); $aspPauP = @()
foreach ($field in 'latencyP99Ms', 'pauseP99Ms') {
    $out = @()
    foreach ($h in $aspHeaps) {
        $w = @($aspCsv | Where-Object { [double]$_.heapFactor -eq $h -and $_.collector -eq 'wks' -and (HasVal $_.$field) } | ForEach-Object { [double]$_.$field })
        $s = @($aspCsv | Where-Object { [double]$_.heapFactor -eq $h -and $_.collector -eq 'srv' -and (HasVal $_.$field) } | ForEach-Object { [double]$_.$field })
        $obs = [Math]::Abs((($s | Measure-Object -Average).Average) - (($w | Measure-Object -Average).Average))
        $pool = @($w + $s); $n = $pool.Count; $k = $w.Count; $ge = 0; $tot = 0
        for ($m = 0; $m -lt (1 -shl $n); $m++) {
            $idx = @(0..($n - 1) | Where-Object { $m -band (1 -shl $_) })
            if ($idx.Count -ne $k) { continue }
            $a = @($idx | ForEach-Object { $pool[$_] })
            $bb = @(0..($n - 1) | Where-Object { $idx -notcontains $_ } | ForEach-Object { $pool[$_] })
            $tot++
            if ([Math]::Abs((($bb | Measure-Object -Average).Average) - (($a | Measure-Object -Average).Average)) -ge $obs) { $ge++ }
        }
        $out += [Math]::Round($ge / $tot, 3)
    }
    if ($field -eq 'latencyP99Ms') { $aspLatP = $out } else { $aspPauP = $out }
}
Write-Output "  aspnet latency phase: pause is $aspShareLo-$aspShareHi% of latency p99; exact p latency $($aspLatP -join ' / '), pause $($aspPauP -join ' / ')"
Write-Output "  pinning-heavy-io pause srv/wks: csv $($phRatio -join ' / '), aggregate $($phAgg -join ' / '), exact p $($phPnum -join ' / ') of $phPden"
Write-Output "  json rows $($rows.Count), valid $($valid.Count), latency $($lat.Count), throughput $($thr.Count)"
Write-Output "  csv rows $($csvRows.Count), columns $($csvCols.Count), shared with json $shared"
Write-Output "  scenarios within 0.16%: $within of $($worst.Count); largest of the nine $([Math]::Round($maxNine,3))%; aspnet $([Math]::Round($aspnet,2))%"
Write-Output ''

# ---- section 6.4 variance table: reproduce the published rows, then extend to pause ----
# Rule 87. derive-variance-table.py takes ONE csv (load_cells(args.csv)). Unioning the three
# session CSVs charges cross-session drift to within-cell variance: the cell COUNTS still come
# out right because the partition is right, while every statistic inflates. So the control is
# not optional decoration -- it is the only thing that distinguishes this derivation from a
# plausible guess, and it is checked against the deliverable rather than against literals.
$FLOOR = 8.35
$s2Csv = @(Show-Blob "${BASE}raw/p0-5-baselines-s2-invocations.csv" | ConvertFrom-Csv)
function PhaseOf ($runId) {
    if ($runId -like '*.throughput') { return 'throughput' }
    if ($runId -like '*.latency')    { return 'latency' }
    return $null
}
function CvCells ($rowsIn, $metric, $phases) {
    $g = @{}
    foreach ($r in $rowsIn) {
        $ph = PhaseOf $r.runId
        if ($null -eq $ph -or $phases -notcontains $ph) { continue }
        if ("$($r.valid)".Trim().ToLower() -ne 'true') { continue }
        if (-not (HasVal $r.$metric)) { continue }
        $k = "$($r.scenario)|$($r.collector)|$($r.heapFactor)|$ph"
        if (-not $g.ContainsKey($k)) { $g[$k] = @() }
        $g[$k] += [double]$r.$metric
    }
    $cvs = @()
    foreach ($v in $g.Values) {
        if ($v.Count -lt 2) { continue }
        $mean = ($v | Measure-Object -Average).Average
        if ($mean -le 0) { continue }
        $ss = ($v | ForEach-Object { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum
        $cvs += 100 * [Math]::Sqrt($ss / ($v.Count - 1)) / $mean
    }
    $s = @($cvs | Sort-Object); $n = $s.Count
    $med = if ($n % 2) { $s[[int](($n - 1) / 2)] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
    return [pscustomobject]@{ Cells = $n
                              Median = [Math]::Round($med, 2)
                              Max = [Math]::Round($s[-1], 2)
                              Above = @($cvs | Where-Object { $_ -gt $FLOOR }).Count }
}
$ctlThr = CvCells $s2Csv 'operationsPerSecond' @('throughput')
$ctlLat = CvCells $s2Csv 'latencyP99Ms'        @('latency')
$vPause = CvCells $s2Csv 'pauseP99Ms'          @('throughput', 'latency')
$badPop = CvCells $csvRows 'operationsPerSecond' @('throughput')

$delivText = (Show-Blob ($BASE.TrimEnd('/') + '.md')) -join "`n"
$ctrl = 0
$ctlOk = $true
$controls = @(
    [pscustomobject]@{ Name = 'operationsPerSecond'; Got = $ctlThr }
    [pscustomobject]@{ Name = 'latencyP99Ms';        Got = $ctlLat }
)
foreach ($pair in $controls) {
    $name = $pair.Name; $got = $pair.Got
    $rx = '\| `' + $name + '` \| (\d+) \| \*\*(\d+\.\d+)%\*\* \| (\d+\.\d+)% \| \*\*(\d+) of (\d+)\*\* \|'
    $mm = [regex]::Match($delivText, $rx)
    if (-not $mm.Success) { bad "section 6.4 control: no published row for ``$name`` in the deliverable"; $ctlOk = $false; continue }
    $exp = @([int]$mm.Groups[1].Value, [double]$mm.Groups[2].Value, [double]$mm.Groups[3].Value, [int]$mm.Groups[4].Value)
    $gotA = @($got.Cells, $got.Median, $got.Max, $got.Above)
    $diff = @()
    for ($i = 0; $i -lt 4; $i++) { if ([Math]::Abs([double]$gotA[$i] - [double]$exp[$i]) -gt 0.001) { $diff += "$($gotA[$i]) vs published $($exp[$i])" } }
    if ($diff.Count) { bad "section 6.4 control: ``$name`` does not reproduce -- $($diff -join '; ')"; $ctlOk = $false }
    else {
        # A control is not a board claim: it compares two artifacts to each other and no
        # sentence anywhere states it. Counting it as a claim would break the coverage
        # script's invariant that the checker reports exactly as many claims as it defines.
        $ctrl++
        Write-Output "  ok    section 6.4 control: ``$name`` reproduces the published row exactly ($($gotA -join ' / '))"
    }
}
if (-not $ctlOk) { Write-Output '  the pause row below is therefore a guess and is not reported'; exit 1 }

# ---- the published pause column is one invocation, not a mean (Aggregator.cs:262) ----
$byCell = @{}
foreach ($r in $csvRows) {
    if (-not (HasVal $r.pauseP99Ms)) { continue }
    $k = "$($r.scenario)|$($r.collector)|$([double]$r.heapFactor)|$($r.runId)"
    if (-not $byCell.ContainsKey($k)) { $byCell[$k] = @() }
    $byCell[$k] += [pscustomobject]@{ Inv = [int]$r.invocation; V = [double]$r.pauseP99Ms }
}
$eqLast = 0; $eqMean = 0; $totPause = 0
foreach ($j in $rows) {
    if ($null -eq $j.pauseP99Ms) { continue }
    if ("$($j.notes)" -match 'runId=(\S+)') { $rid = $Matches[1] } else { continue }
    $k = "$($j.scenario)|$($j.collector)|$([double]$j.heapFactor)|$rid"
    if (-not $byCell.ContainsKey($k)) { continue }
    $vec = @($byCell[$k] | Sort-Object Inv)
    $totPause++
    if ([Math]::Abs([double]$j.pauseP99Ms - $vec[-1].V) -lt 1e-9) { $eqLast++ }
    if ([Math]::Abs([double]$j.pauseP99Ms - (($vec | Measure-Object -Property V -Average).Average)) -lt 1e-9) { $eqMean++ }
}
Write-Output "  pauseP99Ms variance (s2, published convention): $($vPause.Cells) cells, median $($vPause.Median)%, max $($vPause.Max)%, $($vPause.Above) above $FLOOR%"
Write-Output "  published pauseP99Ms == last invocation: $eqLast of $totPause; == column mean: $eqMean of $totPause"

# ---- the Kestrel attribution: presence is not causation, and no file can settle a rank ----
# Kestrel is constant across every row below, so anything that moves across them is not
# explained by the socket path. AspNetRequestLoadScenario.cs:87 establishes presence only.
$aspCell = @{}
foreach ($r in $csvRows) {
    if ($r.scenario -ne 'aspnet-request-load') { continue }
    if ("$($r.valid)".Trim().ToLower() -ne 'true' -or -not (HasVal $r.latencyP99Ms)) { continue }
    $k = "$(PhaseOf $r.runId)|$($r.collector)|$([double]$r.heapFactor)"
    if (-not $aspCell.ContainsKey($k)) { $aspCell[$k] = @() }
    $aspCell[$k] += [double]$r.latencyP99Ms
}
$aspLatM = @(); $aspThrM = @()
foreach ($k in $aspCell.Keys) {
    $m = ($aspCell[$k] | Measure-Object -Average).Average
    if ($k.StartsWith('latency|')) { $aspLatM += $m } else { $aspThrM += $m }
}
$latLo = ($aspLatM | Measure-Object -Minimum).Minimum
$latHi = ($aspLatM | Measure-Object -Maximum).Maximum
$thrLo = ($aspThrM | Measure-Object -Minimum).Minimum
$thrHi = ($aspThrM | Measure-Object -Maximum).Maximum
$aspLatLo = [Math]::Round($latLo, 1); $aspLatHi = [Math]::Round($latHi, 1)
$aspThrLo = [Math]::Round($thrLo, 2); $aspThrHi = [Math]::Round($thrHi, 2)
$kesLo = [Math]::Round($latLo / $thrHi, 0); $kesHi = [Math]::Round($latHi / $thrLo, 0)

# The rank the superlative was never checked against.
$scn = @{}
foreach ($r in $csvRows) {
    if ("$($r.valid)".Trim().ToLower() -ne 'true' -or (PhaseOf $r.runId) -ne 'latency') { continue }
    if (-not (HasVal $r.latencyP99Ms)) { continue }
    if (-not $scn.ContainsKey($r.scenario)) { $scn[$r.scenario] = @() }
    $scn[$r.scenario] += [double]$r.latencyP99Ms
}
$scnAvg = @{}
foreach ($k in $scn.Keys) { $scnAvg[$k] = ($scn[$k] | Measure-Object -Average).Average }
$aspAvg  = $scnAvg['aspnet-request-load']
$others  = @($scnAvg.Keys | Where-Object { $_ -ne 'aspnet-request-load' } | ForEach-Object { $scnAvg[$_] })
$nearest = ($others | Measure-Object -Maximum).Maximum
$nearestR = [Math]::Round($nearest, 2)
$gapNear  = [Math]::Round($aspAvg / $nearest, 1)
$othLo    = [Math]::Round(($others | Measure-Object -Minimum).Minimum, 3)
$othHi    = [Math]::Round($nearest, 1)
$twoOrd   = @($others | Where-Object { ($aspAvg / $_) -ge 100 }).Count
$notTwo   = $others.Count - $twoOrd
$aboveAsp = @($others | Where-Object { $_ -gt $thrHi }).Count
$belowAsp = @($others | Where-Object { $_ -lt $thrLo }).Count
Write-Output "  aspnet p99 with Kestrel held constant: latency $aspLatLo-$aspLatHi ms vs throughput $aspThrLo-$aspThrHi ms = ${kesLo}x-${kesHi}x"
Write-Output "  superlative rank: nearest other scenario $nearestR ms (${gapNear}x); two orders holds against $twoOrd of $($others.Count), fails against $notTwo"

# ---- compare every occurrence against the derived value ------------------------------

Write-Output '== board prose vs derived =='

# Each claim: a regex whose capture groups are numbers the board asserts, and the derived
# values they must equal. Patterns are anchored on the field or artifact they describe so
# that historical narration of a superseded figure cannot match one -- the board's rules
# quote past wrong counts deliberately, and a staleness grep that flagged those would be
# the false alarm this battery's header already records once.
# Each claim: a regex locating one SENTENCE, whose capture groups are the numbers that
# sentence asserts, paired with the derived values they must equal. Every pattern names the
# artifact it is about -- "the published JSON", "the per-invocation CSV" -- because the first
# draft of this list did not, and its JSON patterns matched the CSV's sentences and vice
# versa, reporting four failures that were entirely the checker's. Rule 84 turns out not to
# be a wording preference: a claim about a field present in both files cannot be located,
# let alone verified, until the sentence names which file it means.
#
# Patterns are anchored on surrounding prose rather than on the bare figures so that the
# board's deliberate narration of SUPERSEDED counts cannot match one. Rule 83 quotes its own
# retracted "0 of 6" on purpose; a staleness grep flagging that quotation would be the false
# alarm board-check.ps1's header already records once.
# ---------------------------------------------------------------------------
# Rule 88 -- the two retired citation predicates, and the decidable residue.
#
# These derive from artifacts the rest of this script never touches: the board's own
# git history, and the deliverable's `rule N` citations resolved against the board.
# Both figures in rule 88 are false-alarm rates measured on a HEALTHY artifact, so a
# regression here means either a citation broke or the board grew an edit whose shape
# the measurement did not anticipate -- both worth a failure.
$repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
$boardRel = '.github/extensions/lxr-gc-roadmap/roadmap.md'

# Board rules, first definition wins (a rule quoted inside another rule must not shadow it).
$ruleText = @{}
foreach ($ln in ($text -split "`r?`n")) {
    if ($ln -match '^(\d+)\. (.+)$' -and -not $ruleText.ContainsKey([int]$Matches[1])) {
        $ruleText[[int]$Matches[1]] = ($Matches[2] -replace '\s+', ' ')
    }
}

function WordRun ($a, $b) {
    $A = @(($a.ToLower() -replace '[^a-z0-9 ]', ' ') -split ' +' | Where-Object { $_ })
    $B = @(($b.ToLower() -replace '[^a-z0-9 ]', ' ') -split ' +' | Where-Object { $_ })
    $best = 0
    for ($i = 0; $i -lt $A.Count; $i++) {
        for ($j = 0; $j -lt $B.Count; $j++) {
            $k = 0
            while (($i + $k) -lt $A.Count -and ($j + $k) -lt $B.Count -and $A[$i + $k] -eq $B[$j + $k]) { $k++ }
            if ($k -gt $best) { $best = $k }
        }
    }
    return $best
}

$delivLines = (Show-Blob 'docs/design/lxr-port/P0.5-baselines.md') -split "`r?`n"
$citeOccur = 0; $citeQuote = 0; $citeDangling = 0; $citeRules = @{}
foreach ($ln in $delivLines) {
    foreach ($m in [regex]::Matches($ln, '(?i)\brules?\s+(\d+)\b')) {
        $n = [int]$m.Groups[1].Value
        $citeOccur++; $citeRules[$n] = $true
        if (-not $ruleText.ContainsKey($n)) { $citeDangling++; continue }
        if ((WordRun $ln $ruleText[$n]) -ge 5) { $citeQuote++ }
    }
}
$citeDistinct = $citeRules.Keys.Count

# Board history: an edit either extends a rule (previous text is a prefix) or replaces it.
#
# PINNED, and the pin is the whole point. This walk measures the board's own history, so
# every commit that states the result also joins the population it is a result about --
# and the commit after this measurement (5d3246b1163, which appended rule 84's fourth
# axis) pushed $extends from 22 to 23 and falsified a figure that was true when written.
# Rule 90. The pin is the state the measurement was actually taken over; leaving it
# unpinned makes the claim decay on a schedule set by unrelated future edits.
$HIST_PIN = 'a4eb4dbaedb'
$hist = @(& git -C $repoRoot log --format=%h --reverse $HIST_PIN -- $boardRel)
$prevRules = $null; $extends = 0; $replaces = 0; $replacedAt = @{}
foreach ($h in $hist) {
    $blobLines = (& git -C $repoRoot show "${h}:$boardRel" 2>$null) -split "`r?`n"
    $cur = @{}
    foreach ($ln in $blobLines) {
        if ($ln -match '^(\d+)\. (.+)$' -and -not $cur.ContainsKey([int]$Matches[1])) {
            $cur[[int]$Matches[1]] = ($Matches[2] -replace '\s+', ' ')
        }
    }
    if ($null -ne $prevRules) {
        foreach ($n in $prevRules.Keys) {
            if (-not $cur.ContainsKey($n)) { $replaces++; continue }
            $old = $prevRules[$n]; $new = $cur[$n]
            if ($new -eq $old) { continue }
            if ($new.StartsWith($old)) { $extends++ } else { $replaces++; $replacedAt["$h/$n"] = $true }
        }
    }
    $prevRules = $cur
}
# Rule 90's own evidence, derived: the same walk carried one commit past the pin.
$DRIFT_COMMIT = '5d3246b1163'
$prevRules = $null; $extendsAfter = 0
foreach ($h in @(& git -C $repoRoot log --format=%h --reverse $DRIFT_COMMIT -- $boardRel)) {
    $blobLines = (& git -C $repoRoot show "${h}:$boardRel" 2>$null) -split "`r?`n"
    $cur = @{}
    foreach ($ln in $blobLines) {
        if ($ln -match '^(\d+)\. (.+)$' -and -not $cur.ContainsKey([int]$Matches[1])) {
            $cur[[int]$Matches[1]] = ($Matches[2] -replace '\s+', ' ')
        }
    }
    if ($null -ne $prevRules) {
        foreach ($n in $prevRules.Keys) {
            if (-not $cur.ContainsKey($n)) { continue }
            $old = $prevRules[$n]; $new = $cur[$n]
            if ($new -ne $old -and $new.StartsWith($old)) { $extendsAfter++ }
        }
    }
    $prevRules = $cur
}

$replaced5051 = @(($replacedAt.Keys | Where-Object { $_ -match '/(50|51)$' })).Count
$live5051 = @([regex]::Matches($text, '(?i)\brules?\s+5[01]\b')).Count

# ---------------------------------------------------------------------------
# The cost of "compute a ratio for every comparable numeric column", measured.
#
# A comparison cell here is (scenario, heapFactor, phase) -- collector is the axis being
# compared, so it cannot also be part of the key. Both arms must carry >=3 valid
# invocations, and a (cell, column) pair exists only where the column itself has >=3
# parseable values on BOTH arms; a column present on one arm compares against nothing.
#
# Population matters and is asserted in both directions: the pair and undefined counts are
# invariant, the degenerate count is not, and the union of subset re-runs understates it.
$METRIC = @(
    'operationsPerSecond','latencyP50Ms','latencyP99Ms','latencyP999Ms','latencyP9999Ms',
    'latencyMaxMs','serviceTimeP99Ms','arrivalRatePerSecond','achievedRatePerSecond',
    'lateFraction','dispatchLagP99Ms','pauseAverageMs','pauseP99Ms','pauseMaxMs',
    'gen0Collections','gen1Collections','gen2Collections','inducedCollections',
    'workingSetMb','committedMb')

function RatioDomain ($sessions) {
    $rows = @()
    foreach ($s in $sessions) {
        $csvText = Show-Blob "docs/design/lxr-port/P0.5-baselines/raw/p0-5-baselines-$s-invocations.csv"
        $rows += @($csvText | ConvertFrom-Csv | Where-Object { $_.valid -eq 'true' })
    }
    $arm = @{}
    foreach ($r in $rows) {
        $ph = if ($r.runId -like '*latency*') { 'latency' } else { 'throughput' }
        $k  = '{0}|{1:N1}|{2}|{3}' -f $r.scenario, [double]$r.heapFactor, $ph, $r.collector
        if (-not $arm.ContainsKey($k)) { $arm[$k] = New-Object System.Collections.ArrayList }
        [void]$arm[$k].Add($r)
    }
    $cells = @{}
    foreach ($k in $arm.Keys) { $cells[($k -replace '\|(wks|srv)$', '')] = $true }
    $pairs = 0; $undef = 0; $degen = 0; $well = 0; $byCol = @{}
    foreach ($c in $cells.Keys) {
        $wRows = $arm["$c|wks"]; $sRows = $arm["$c|srv"]
        if (-not $wRows -or -not $sRows -or $wRows.Count -lt 3 -or $sRows.Count -lt 3) { continue }
        foreach ($m in $METRIC) {
            $w = @(); $sv = @()
            foreach ($r in $wRows) { $x = $r.$m; if ($x -and $x.Trim() -and $x -ne 'NA') { $w  += [double]$x } }
            foreach ($r in $sRows) { $x = $r.$m; if ($x -and $x.Trim() -and $x -ne 'NA') { $sv += [double]$x } }
            if ($w.Count -lt 3 -or $sv.Count -lt 3) { continue }
            $pairs++
            $mw = ($w | Measure-Object -Average).Average
            if ($mw -eq 0) { $undef++; if ($m -eq 'inducedCollections') { $byCol['induced']++ }; continue }
            if ((($w | Sort-Object -Unique).Count -eq 1) -and (($sv | Sort-Object -Unique).Count -eq 1)) {
                $degen++
                if ($m -eq 'arrivalRatePerSecond') { $byCol['arrival']++ }
                continue
            }
            $well++
        }
    }
    return @{ pairs = $pairs; undef = $undef; degen = $degen; well = $well
              induced = [int]$byCol['induced']; arrival = [int]$byCol['arrival'] }
}
$domS2  = RatioDomain @('s2')
$domAll = RatioDomain @('s2', 's3', 's4sdk')

# inducedCollections is an assertion, not a measurement: one distinct value over every
# valid invocation in every session. Counted as rows, which is NOT the same 699 as the
# well-formed pair count -- the collision rule 84 now carries as its fourth axis.
$allInvRows = @()
foreach ($s in @('s2', 's3', 's4sdk')) {
    $allInvRows += @((Show-Blob "docs/design/lxr-port/P0.5-baselines/raw/p0-5-baselines-$s-invocations.csv") |
                     ConvertFrom-Csv | Where-Object { $_.valid -eq 'true' })
}
$inducedDistinct = @($allInvRows | ForEach-Object { $_.inducedCollections } | Sort-Object -Unique)
$validInvocations = $allInvRows.Count

# ---------------------------------------------------------------------------
# Rule 89 -- the attainable range of the instrument, computed rather than asserted.
#
# Everything here is a property of the DESIGN (n per arm, alpha, the correction), not of
# the measurements, so it is derived from first principles with no artifact read. That is
# the point of the rule: the floor is knowable before any data exists.
function Choose ([int]$n, [int]$k) {
    $r = [double]1
    for ($i = 1; $i -le $k; $i++) { $r = $r * ($n - $k + $i) / $i }
    return [int][Math]::Round($r)
}
$ARRANGEMENTS_5v5 = Choose 10 5                       # 252
$EXACT_FLOOR      = 1.0 / $ARRANGEMENTS_5v5           # smallest attainable one-sided p
$LARGEST_USABLE_K = 0
for ($k = 1; $k -le $ARRANGEMENTS_5v5; $k++) { if (($k / $ARRANGEMENTS_5v5) -le 0.05) { $LARGEST_USABLE_K = $k } }
# Largest Bonferroni family in which the floor is still reachable.
$FAMILY_5 = 0
for ($m = 1; $m -le 5000; $m++) { if ($EXACT_FLOOR -le (0.05 / $m)) { $FAMILY_5 = $m } }
$ARRANGEMENTS_6v6 = Choose 12 6                       # 924
$FLOOR_6          = 1.0 / $ARRANGEMENTS_6v6
$FAMILY_6 = 0
for ($m = 1; $m -le 5000; $m++) { if ($FLOOR_6 -le (0.05 / $m)) { $FAMILY_6 = $m } }
# How far the literal directive sits below the floor, in multiples.
$SHORTFALL_693 = [int][Math]::Round($EXACT_FLOOR / (0.05 / $domS2.well))

$claims = @(
    @{ name = 'rule 89: the floor of the exact test at five against five'
       re   = 'enumerates `C\(10,5\) = (\d+)` arrangements, so the smallest attainable p is \*\*1/(\d+) = ([\d.]+)\*\* and the largest usable one is (\d+)/'
       sites = 1
       want = @($ARRANGEMENTS_5v5, $ARRANGEMENTS_5v5, [Math]::Round($EXACT_FLOOR,6), $LARGEST_USABLE_K) }

    @{ name = 'rule 89: the largest interpreted family the design admits'
       re   = 'at \*\*m = (\d+)\*\* that is ([\d.e-]+) and the floor clears it; at \*\*m = (\d+)\*\* it is ([\d.e-]+) and the floor does not'
       sites = 1
       want = @($FAMILY_5, (0.05 / $FAMILY_5), ($FAMILY_5 + 1), (0.05 / ($FAMILY_5 + 1))) }

    @{ name = 'rule 89: how far the literal directive sits below the floor'
       re   = 'over (\d+) well-formed pairs would need ([\d.e-]+), which is \*\*(\d+)\*\* times below the floor'
       sites = 1
       want = @($domS2.well, (0.05 / $domS2.well), $SHORTFALL_693) }

    @{ name = 'rule 89: the escape at six invocations per arm'
       re   = '`C\(12,6\) = (\d+)` moves the floor to ([\d.e-]+) and the budget to \*\*(\d+)\*\*'
       sites = 1
       want = @($ARRANGEMENTS_6v6, $FLOOR_6, $FAMILY_6) }

    # "Three orders of magnitude past the budget" was written, not computed; it is 1.76.
    # Gating the multiple rather than a vague magnitude is the only version of this
    # sentence a checker can hold, and it is the one the argument actually needs.
    @{ name = 'P0.6 amendment: how far each candidate population sits past the budget'
       re   = 'sit at \*\*([\d.]+)x\*\* and \*\*([\d.]+)x\*\* the budget of twelve'
       sites = 1
       want = @(($domS2.well / $FAMILY_5), ($domAll.well / $FAMILY_5)) }

    @{ name = 'P0.6 amendment: the budget the design must fit, restated in the entry'
       re   = 'can hold at most \*\*(\d+) comparisons\*\* before no cell can be significant'
       sites = 1
       want = @($FAMILY_5) }

    @{ name = 'P0.6 amendment: the arrangement-level hazard is real and currently vacuous'
       re   = 'exactly (\d+) of (\d+) arrangements goes undefined in that case.*?coincide on the committed data at \*\*(\d+) of (\d+)\*\*'
       sites = 1
       want = @(1, $ARRANGEMENTS_5v5, 0, $domS2.well) }

    @{ name = 'P0.6 amendment: the directive applied literally, s2 population'
       re   = 'yields \*\*(\d+) \(cell, column\) pairs, of which (\d+) are undefined and (\d+) are well-formed\*\*'
       sites = 1
       want = @($domS2.pairs, $domS2.undef, $domS2.well) }

    @{ name = 'P0.6 amendment: inducedCollections is an assertion, not a measurement'
       re   = 'undefined in (\d+) of (\d+) cells\*\* because the column is the string `0` in \*\*all (\d+) valid invocations'
       sites = 1
       want = @($domS2.induced, $domS2.induced, $validInvocations) }

    @{ name = 'P0.6 amendment: the pinned field the directive re-admits'
       re   = 'contributes (\d+) zero-width intervals\*\*.*?re-admits it (\d+) times'
       sites = 1
       want = @($domS2.arrival, $domS2.arrival) }

    @{ name = 'P0.6 amendment: family size against the well-formed count'
       re   = 'at (\d+) well-formed pairs, roughly (\d+) exclude 1\.000 by chance'
       sites = 1
       want = @($domS2.well, [int][Math]::Round($domS2.well * 0.05)) }

    @{ name = 'P0.6 amendment: population invariance, and where it fails'
       re   = 'invariant to which sessions are included — (\d+) and (\d+) either way'
       sites = 1
       want = @($domS2.pairs, $domS2.undef) }

    @{ name = 'P0.6 amendment: the union understates the degeneracy it demonstrates'
       re   = 'the zero-width count is (\d+) and `arrivalRatePerSecond` contributes (\d+); derived over s2 alone.*?they are \*\*(\d+) and (\d+)\*\*'
       sites = 1
       want = @($domAll.degen, $domAll.arrival, $domS2.degen, $domS2.arrival) }

    @{ name = 'rule 84 fourth axis: the two quantities that collided on one integer'
       re   = 'constant across \*\*(\d+) valid invocations\*\* and, in the same message.*?\*\*(\d+) well-formed pairs\*\*'
       sites = 1
       want = @($validInvocations, $domAll.well) }

    @{ name = 'rule 88: quote-overlap predicate, false alarms on a healthy document'
       re   = 'only \*\*(\d+) of (\d+)\*\* carry a 5-or-more word verbatim run'
       sites = 1
       want = @($citeQuote, $citeOccur) }

    @{ name = 'rule 88: the citations the predicate would have flagged are correct'
       re   = 'independently verified as \*\*(\d+) of (\d+) distinct rules correct\*\*'
       sites = 1
       want = @($citeDistinct, $citeDistinct) }

    @{ name = 'rule 88: append-only predicate, extensions against replacements'
       re   = 'across the \*\*(\d+)\*\* commits touching this board up to `([0-9a-f]+)`, \*\*(\d+)\*\* edits extend a rule and \*\*(\d+)\*\* replace text in place'
       sites = 1
       want = @($hist.Count, $HIST_PIN, $extends, $replaces) }

    # Rule 90 states the drift that made the pin necessary, so the drift itself is derived
    # rather than remembered: walk the SAME history one commit further and show the count move.
    @{ name = 'rule 90: the unrelated commit that falsified a correct figure'
       re   = 'the one after it, `([0-9a-f]+)`, appended rule 84.s fourth axis in place, which is an extension, and the count became (\d+)'
       sites = 1
       want = @($DRIFT_COMMIT, $extendsAfter) }

    @{ name = 'P0.6 post-merge: the one decidable residue, measured'
       re   = 'every cited rule number must exist on the board\*\*.{0,6}currently (\d+) dangling'
       sites = 1
       want = @($citeDangling) }

    @{ name = 'P0.6 post-merge: the single identity change and its blast radius'
       re   = 'rules \*\*(\d+) and (\d+) were replaced\*\* at `be5bc610e00`.*?with \*\*(\d+)\*\* live citations'
       sites = 1
       want = @(50, 51, $live5051) }

    @{ name = 'rule 83: latencyP99Ms coverage by phase, published JSON'
       re   = 'is populated in \*\*(\d+) of (\d+)\*\* latency-phase rows of the published JSON, against \*\*(\d+) of (\d+)\*\*'
       sites = 1
       want = @($latP99, $lat.Count, $thrP99, $thrEx.Count) }

    @{ name = 'rule 84: the figure the weak claim rested on, published JSON'
       re   = 'being \*\*(\d+) of (\d+)\*\* in the published JSON'
       sites = 1
       want = @($latP99, $lat.Count) }

    @{ name = 'rule 84: the figure that settles it, per-invocation CSV'
       re   = 'CSV settles it properly at \*\*(\d+) of (\d+)\*\* latency-phase against \*\*(\d+) of (\d+)\*\* throughput-phase'
       sites = 1
       want = @($csvLatP99, $csvLat.Count, $csvThrP99, $csvThr.Count) }

    @{ name = 'P0.6 directive: published JSON coverage'
       re   = 'present in \*\*(\d+) of (\d+)\*\* latency-phase, \*\*(\d+) of (\d+)\*\* throughput-phase excluding'
       sites = 1
       want = @($latP99, $lat.Count, $thrP99, $thrEx.Count) }

    @{ name = 'P0.6 directive: per-invocation CSV coverage'
       re   = 'settles it:\*\* \*\*(\d+) of (\d+)\*\* latency-phase rows, \*\*(\d+) of (\d+)\*\* throughput-phase'
       sites = 1
       want = @($csvLatP99, $csvLat.Count, $csvThrP99, $csvThr.Count) }

    @{ name = 'rule 84: the ambiguity surface between the two artifacts'
       re   = "of the CSV's (\d+) columns, \*\*(\d+) appear in the JSON"
       sites = 1
       want = @($csvCols.Count, $shared) }

    @{ name = 'F24 generalisation: scenarios inside the 0.16% band'
       re   = '\*\*([A-Za-z]+|\d+) of ([A-Za-z]+|\d+) scenarios publish a latency-phase'
       sites = 2
       want = @($within, $worst.Count) }

    @{ name = 'F24 generalisation: the sole exception and its magnitude'
       re   = '`aspnet-request-load` at (\d+\.\d+)%'
       sites = 2
       want = @([Math]::Round($aspnet, 2)) }

    @{ name = 'F24 generalisation: the margin by which the 0.16% bound clears'
       re   = 'the largest of the nine is `long-lived-cache` at \*\*(\d+\.\d+)%\*\*'
       sites = 1
       want = @([Math]::Round($maxNine, 3)) }
    @{ name = 'rule 80: rows carrying the fallback pauseSource label'
       re   = '(\d+) of (\d+) rows are \*labelled\*'
       sites = 1
       want = @($fallback, $rows.Count) }

    @{ name = 'P0.6 amendment: pinning-heavy-io aggregate pause ratios, published JSON'
       re   = 'its `pauseP99Ms` differs srv/wks by \*\*(\d+\.\d+)x / (\d+\.\d+)x / (\d+\.\d+)x\*\*'
       sites = 1
       want = @($phAgg[0], $phAgg[1], $phAgg[2]) }

    @{ name = 'P0.6 amendment: the ratios published beside that pause difference'
       re   = 'publishes `ratioVsBaseline` of (\d+\.\d+) / (\d+\.\d+) / (\d+\.\d+) in the throughput phase'
       sites = 1
       want = @($phPublished[0], $phPublished[1], $phPublished[2]) }

    @{ name = 'P0.6 amendment: exact permutation test over the per-invocation CSV'
       re   = 'point ratios of \*\*(\d+\.\d+)x\*\*, \*\*(\d+\.\d+)x\*\* and \*\*(\d+\.\d+)x\*\* at p = \*\*(\d+)/(\d+)\*\*, \*\*(\d+)/(\d+)\*\* and \*\*(\d+)/(\d+)\*\*'
       sites = 1
       want = @($phRatio[0], $phRatio[1], $phRatio[2], $phPnum[0], $phPden, $phPnum[1], $phPden, $phPnum[2], $phPden) }

    @{ name = 'P0.6 amendment: the overlap that forbids a separation claim'
       re   = "srv's minimum of (\d+\.\d+) falls below wks's maximum of (\d+\.\d+)"
       sites = 1
       want = @($ovSrv, $ovWks) }

    @{ name = 'P0.6 correction: aspnet pause as a share of its latency p99'
       re   = '`pauseP99Ms` is \*\*(\d+\.\d+)% to (\d+\.\d+)%\*\* of `latencyP99Ms`'
       sites = 1
       want = @($aspShareLo, $aspShareHi) }

    @{ name = 'P0.6 correction: exact p for the column that HAS the statistics'
       re   = 'gives p = \*\*(\d+\.\d+) / (\d+\.\d+) / (\d+\.\d+)\*\*, significant at no heap factor'
       sites = 1
       want = @($aspLatP[0], $aspLatP[1], $aspLatP[2]) }

    @{ name = 'P0.6 correction: exact p for the column that has NONE of them'
       re   = 'gives p = \*\*(\d+\.\d+) / (\d+\.\d+) / (\d+\.\d+)\*\*, significant at all of them'
       sites = 1
       want = @($aspPauP[0], $aspPauP[1], $aspPauP[2]) }

    @{ name = 'rule 87: the control rows the extension had to reproduce, s2 CSV'
       re   = '`operationsPerSecond` (\d+) / (\d+\.\d+)% / (\d+\.\d+)% / (\d+) of (\d+) and `latencyP99Ms` (\d+) / (\d+\.\d+)% / (\d+\.\d+)% / (\d+) of (\d+)'
       sites = 1
       want = @($ctlThr.Cells, $ctlThr.Median, $ctlThr.Max, $ctlThr.Above, $ctlThr.Cells,
                $ctlLat.Cells, $ctlLat.Median, $ctlLat.Max, $ctlLat.Above, $ctlLat.Cells) }

    @{ name = 'rule 87: what the WRONG population produced, three sessions unioned'
       re   = '\(median (\d+\.\d+)%, max (\d+\.\d+)%, (\d+) above the floor instead of 0\)'
       sites = 1
       want = @($badPop.Median, $badPop.Max, $badPop.Above) }

    @{ name = 'P0.6 gap: the section 6.4 row that does not exist, derived under its convention'
       re   = '`pauseP99Ms` is \*\*(\d+) cells, median within-cell CV (\d+\.\d+)%, max (\d+\.\d+)%, (\d+) of (\d+)'
       sites = 1
       want = @($vPause.Cells, $vPause.Median, $vPause.Max, $vPause.Above, $vPause.Cells) }

    @{ name = 'P0.6 gap: the published pause column is one invocation, not a mean'
       re   = 'equals the last valid invocation in \*\*(\d+) of (\d+)\*\* cells and the column mean in \*\*(\d+) of (\d+)\*\*'
       sites = 1
       want = @($eqLast, $totPause, $eqMean, $totPause) }

    @{ name = 'P0.6 post-merge: aspnet p99 with the Kestrel socket path held constant'
       re   = 'mean `latencyP99Ms` of \*\*(\d+\.\d+)-(\d+\.\d+) ms\*\* in the latency phase at 7,996 op/s and \*\*(\d+\.\d+)-(\d+\.\d+) ms\*\* in the throughput phase'
       sites = 1
       want = @($aspLatLo, $aspLatHi, $aspThrLo, $aspThrHi) }

    @{ name = 'P0.6 post-merge: the factor Kestrel cannot explain because it is constant'
       re   = 'a factor of \*\*(\d+)x to (\d+)x\*\* with Kestrel unchanged'
       sites = 1
       want = @($kesLo, $kesHi) }

    @{ name = 'P0.6 post-merge: where the low-rate p99 sits among the non-Kestrel scenarios'
       re   = 'the (\d+\.\d+)-(\d+\.\d+) ms range of the nine non-Kestrel scenarios, below (\w+) of them and above (\w+)'
       sites = 1
       want = @($othLo, $othHi, $aboveAsp, $belowAsp) }

    @{ name = 'P0.6 post-merge: the superlative ranked against its nearest member'
       re   = '`lifecycle-semantics` at (\d+\.\d+) ms, the gap is \*\*(\d+\.\d+)x\*\*'
       sites = 1
       want = @($nearestR, $gapNear) }

    @{ name = 'P0.6 post-merge: how far the superlative actually reaches'
       re   = 'holds against (\d+) of the (\d+) other scenarios and fails against (\d+)'
       sites = 1
       want = @($twoOrd, $others.Count, $notTwo) }
)
$WORDS = @{ 'nine' = 9; 'ten' = 10; 'one' = 1; 'two' = 2; 'three' = 3; 'four' = 4;
            'five' = 5; 'six' = 6; 'seven' = 7; 'eight' = 8; 'eleven' = 11; 'twelve' = 12;
            'thirteen' = 13; 'twenty' = 20 }

foreach ($c in $claims) {
    $m = [regex]::Matches($text, $c.re)
    if ($m.Count -eq 0) {
        # Not a pass. The claim may still be in the board under different wording, in which
        # case nothing is checking it, which is the state this whole script exists to end.
        bad "$($c.name): pattern matched nothing -- the sentence was reworded and its check silently retired"
        continue
    }
    # Zero matches is the loud failure; FEWER matches than the board is known to contain is
    # the quiet one, and it was real. Perturbing "nine of ten" to "three of ten" moved that
    # site outside a closed `(nine|\d+)` alternation, so the site stopped matching, the
    # surviving correct site still agreed, and the checker printed "1 occurrence(s), all
    # agree" over a corrupted board. Rule 74 one level up: not zero arrival but PARTIAL
    # arrival, which no non-empty guard can see. The site count is a property of how many
    # times the board chooses to state a fact, so it cannot be derived from the artifacts
    # the way every value below is; it is declared here and the coverage control proves it
    # fires.
    if ($m.Count -ne $c.sites) {
        bad "$($c.name): matched $($m.Count) site(s) where the board declares $($c.sites); a site was reworded out of its own pattern"
        continue
    }
    $badOnes = @()
    foreach ($x in $m) {
        for ($g = 1; $g -lt $x.Groups.Count; $g++) {
            $litRaw = $x.Groups[$g].Value
            $exp = $c.want[$g - 1]
            # Not every gated literal is a quantity. Rule 90's whole content is that a
            # self-referential count is only meaningful beside the revision it was taken
            # over, so the pin itself has to be gated -- otherwise the hash in the prose
            # and the hash the walk actually used could drift apart and every number below
            # would still agree. A non-numeric expectation is compared verbatim.
            if (([string]$exp) -notmatch '^\d+(\.\d+)?([eE][+-]?\d+)?$') {
                # Same SHAPE as the numeric message below, deliberately: the coverage
                # battery proves a perturbation arrived by looking for "says <payload> "
                # in this output, so a message that quotes the literal differently would
                # make every non-numeric claim un-coverable while still reading correctly
                # to a human.
                if ($litRaw -cne ([string]$exp)) {
                    $badOnes += "'$($x.Value.Trim())' says $litRaw where the artifacts give $exp"
                }
                continue
            }
            if ($WORDS.ContainsKey($litRaw)) {
                $lit = $WORDS[$litRaw]
            } elseif ($litRaw -match '^\d+(\.\d+)?([eE][+-]?\d+)?$') {
                $lit = [double]$litRaw
            } else {
                # An unrecognised count word must fail rather than throw or coerce. Widening
                # the alternation to catch corruption is only useful if what it catches is
                # then rejected.
                $badOnes += "'$($x.Value.Trim())' says '$litRaw ', which is not a number or a count word this script knows"
                continue
            }
            # An ABSOLUTE tolerance alone cannot discriminate small-magnitude figures: at
            # 0.001 absolute, a board claiming 9.9e-5 would agree with an artifact giving
            # 7.2e-5, a 37% error passing as a match. Rule 89's alpha values live exactly
            # there. So both bounds must hold, making the effective tolerance
            # min(0.001, 0.5% of expected) -- strictly tighter everywhere, never looser, so
            # no figure that passed under the old rule is loosened by this one.
            $diff = [Math]::Abs([double]$lit - [double]$exp)
            $agrees = if ([double]$exp -eq 0) { [double]$lit -eq 0 }
                      else { ($diff -le 0.001) -and (($diff / [Math]::Abs([double]$exp)) -le 0.005) }
            if (-not $agrees) {
                $badOnes += "'$($x.Value.Trim())' says $litRaw where the artifacts give $exp"
            }
        }
    }
    if ($badOnes.Count -eq 0) {
        ok "$($c.name): $($m.Count) occurrence(s), all agree with $($c.want -join ' / ')"
    } else {
        bad "$($c.name): $($badOnes.Count) of $($m.Count) occurrence(s) disagree"
        $badOnes | ForEach-Object { Write-Output "          $_" }
    }
}

Write-Output ''
if ($fail -eq 0) {
    Write-Output "RESULT: PASS ($pass claims verified against $Ref; $ctrl section 6.4 controls reproduced)"
    exit 0
} else {
    Write-Output "RESULT: FAIL ($pass verified, $fail failed)"
    exit 1
}
