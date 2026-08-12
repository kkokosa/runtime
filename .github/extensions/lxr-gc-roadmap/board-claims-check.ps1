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

Write-Output "  pinning-heavy-io pause srv/wks: csv $($phRatio -join ' / '), aggregate $($phAgg -join ' / '), exact p $($phPnum -join ' / ') of $phPden"
Write-Output "  json rows $($rows.Count), valid $($valid.Count), latency $($lat.Count), throughput $($thr.Count)"
Write-Output "  csv rows $($csvRows.Count), columns $($csvCols.Count), shared with json $shared"
Write-Output "  scenarios within 0.16%: $within of $($worst.Count); largest of the nine $([Math]::Round($maxNine,3))%; aspnet $([Math]::Round($aspnet,2))%"
Write-Output ''

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
$claims = @(
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
)
$WORDS = @{ 'nine' = 9; 'ten' = 10; 'one' = 1; 'two' = 2; 'three' = 3; 'four' = 4;
            'five' = 5; 'six' = 6; 'seven' = 7; 'eight' = 8 }

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
            if ($WORDS.ContainsKey($litRaw)) {
                $lit = $WORDS[$litRaw]
            } elseif ($litRaw -match '^\d+(\.\d+)?$') {
                $lit = [double]$litRaw
            } else {
                # An unrecognised count word must fail rather than throw or coerce. Widening
                # the alternation to catch corruption is only useful if what it catches is
                # then rejected.
                $badOnes += "'$($x.Value.Trim())' says '$litRaw ', which is not a number or a count word this script knows"
                continue
            }
            $exp = $c.want[$g - 1]
            if ([Math]::Abs([double]$lit - [double]$exp) -gt 0.001) {
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
    Write-Output "RESULT: PASS ($pass claims verified against $Ref)"
    exit 0
} else {
    Write-Output "RESULT: FAIL ($pass verified, $fail failed)"
    exit 1
}
