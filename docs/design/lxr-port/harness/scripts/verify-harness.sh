#!/usr/bin/env bash
# P0.4 verification gate.
#
# Audits the artifact it ships with. The root is derived from ${BASH_SOURCE[0]}, so this script
# always checks the tree it is part of; an explicit argument overrides. There is no absolute machine
# path anywhere in here - that is precisely the defect that made P0.3's gate silently audit a
# different, mid-edit checkout, reporting a failure the committed tree did not have and equally able
# to report a pass it had not earned.
#
# Expected counts are DERIVED, never repeated as literals. The scenario count comes from three
# independent places that must agree: the matrix table in P0.4-harness.md, the catalogue in source,
# and the ids present in the smoke results. Writing "10" at three assertion sites would let two drift
# from the third unnoticed.
#
# Usage: verify-harness.sh [repo-root]

set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $# -ge 1 ]]; then
    ROOT=$(cd "$1" && pwd)
else
    # scripts -> harness -> lxr-port -> design -> docs -> repo root
    ROOT=$(cd "$SELF_DIR/../../../../.." && pwd)
fi

DOC="$ROOT/docs/design/lxr-port/P0.4-harness.md"
HARNESS="$ROOT/docs/design/lxr-port/harness"
SRC="$HARNESS/src"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }

section() { printf '\n== %s ==\n' "$1"; }

printf 'P0.4 harness gate\n'
printf 'root: %s\n' "$ROOT"
printf 'self: %s\n' "$SELF_DIR"

# ---------------------------------------------------------------------------
section 'artifacts exist'

for required in \
    "$DOC" \
    "$HARNESS/README.md" \
    "$HARNESS/Directory.Build.props" \
    "$HARNESS/Directory.Build.targets" \
    "$HARNESS/NuGet.config" \
    "$SRC/Lxr.Harness.Core/ScenarioCatalog.cs" \
    "$SRC/Lxr.Harness.Core/ResultConformance.cs" \
    "$SRC/Lxr.Harness.Runner/ControlSuite.cs" \
    "$HARNESS/scripts/run-smoke.ps1" \
    "$HARNESS/scripts/verify-harness.sh" \
    "$HARNESS/scripts/verify-harness-control.sh"
do
    if [[ -f "$required" ]]; then
        ok "present: ${required#"$ROOT/"}"
    else
        bad "missing: ${required#"$ROOT/"}"
    fi
done

if [[ $FAIL -gt 0 ]]; then
    printf '\nartifacts missing; the remaining checks would be meaningless.\n'
    printf 'RESULT: FAIL (%d passed, %d failed)\n' "$PASS" "$FAIL"
    exit 1
fi

# ---------------------------------------------------------------------------
section 'scenario count agrees across three independent derivations'

# (1) the document's matrix table: rows of the form "| <n> | `id` | ..."
DOC_IDS=$(grep -oE '^\| [0-9]+ \| `[a-z-]+`' "$DOC" | grep -oE '`[a-z-]+`' | tr -d '`' | sort -u)
DOC_COUNT=$(printf '%s\n' "$DOC_IDS" | grep -c . || true)

# (2) the catalogue in source
SRC_IDS=$(grep -oE 'Id = "[a-z-]+"' "$SRC/Lxr.Harness.Core/ScenarioCatalog.cs" \
    | sed -E 's/Id = "([a-z-]+)"/\1/' | sort -u)
SRC_COUNT=$(printf '%s\n' "$SRC_IDS" | grep -c . || true)

note "document matrix: $DOC_COUNT scenario(s)"
note "source catalogue: $SRC_COUNT scenario(s)"

if [[ "$DOC_COUNT" -eq 0 ]]; then
    bad "the document's scenario matrix parsed to zero rows; the parser or the table changed"
elif [[ "$DOC_COUNT" -eq "$SRC_COUNT" ]]; then
    ok "document and source agree on $DOC_COUNT scenarios"
else
    bad "document has $DOC_COUNT scenarios, source catalogue has $SRC_COUNT"
fi

if [[ "$DOC_IDS" == "$SRC_IDS" ]]; then
    ok "document and source name the same scenario ids"
else
    bad "scenario ids differ between document and source"
    note "only in document: $(comm -23 <(printf '%s\n' "$DOC_IDS") <(printf '%s\n' "$SRC_IDS") | tr '\n' ' ')"
    note "only in source:   $(comm -13 <(printf '%s\n' "$DOC_IDS") <(printf '%s\n' "$SRC_IDS") | tr '\n' ' ')"
fi

# (3) the smoke results, when present. Absent results are reported, never silently skipped.
RESULTS=$(find "$ROOT/artifacts/lxr-harness/runs" -name results.json 2>/dev/null | sort || true)
if [[ -z "$RESULTS" ]]; then
    note "no smoke results found under artifacts/lxr-harness/runs (third derivation not available)"
    note "run scripts/run-smoke.ps1 to produce them; this is not a gate failure on a fresh clone"
else
    RESULT_IDS=$(grep -ohE '"scenario": *"[a-z-]+"' $RESULTS \
        | sed -E 's/.*"scenario": *"([a-z-]+)".*/\1/' | sort -u)
    RESULT_COUNT=$(printf '%s\n' "$RESULT_IDS" | grep -c . || true)
    note "smoke results: $RESULT_COUNT distinct scenario(s) across $(printf '%s\n' "$RESULTS" | grep -c .) file(s)"

    UNKNOWN=$(comm -23 <(printf '%s\n' "$RESULT_IDS") <(printf '%s\n' "$SRC_IDS") | tr '\n' ' ')
    if [[ -z "${UNKNOWN// /}" ]]; then
        ok "every scenario id in the smoke results is in the catalogue"
    else
        bad "smoke results contain scenario ids absent from the catalogue: $UNKNOWN"
    fi

    if [[ "$RESULT_COUNT" -eq "$SRC_COUNT" ]]; then
        ok "smoke results cover all $SRC_COUNT catalogued scenarios"
    else
        MISSING=$(comm -13 <(printf '%s\n' "$RESULT_IDS") <(printf '%s\n' "$SRC_IDS") | tr '\n' ' ')
        bad "smoke results cover $RESULT_COUNT of $SRC_COUNT scenarios; never run: $MISSING"
    fi
fi

# ---------------------------------------------------------------------------
section 'every scenario is fully specified'

while read -r id; do
    [[ -z "$id" ]] && continue

    # a rationale in the document: the matrix row must carry prose beyond the id
    ROW=$(grep -E "^\| [0-9]+ \| \`$id\` \|" "$DOC" || true)
    RATIONALE=$(printf '%s' "$ROW" | awk -F'|' '{print $4}' | sed 's/^ *//; s/ *$//')
    if [[ ${#RATIONALE} -ge 60 ]]; then
        ok "$id: rationale (${#RATIONALE} chars)"
    else
        bad "$id: rationale is missing or too thin (${#RATIONALE} chars)"
    fi

    # a declared timeout in the catalogue, and it must MATCH the document's table. The document
    # column and the catalogue are two independent statements of the same fact, so checking they
    # agree is worth more than checking each exists.
    DOC_TIMEOUT=$(printf '%s' "$ROW" | awk -F'|' '{print $6}' | tr -cd '0-9')
    SRC_TIMEOUT=$(grep -A8 "Id = \"$id\"," "$SRC/Lxr.Harness.Core/ScenarioCatalog.cs" \
        | grep -oE 'DefaultTimeoutSeconds = [0-9]+' | head -n 1 | grep -oE '[0-9]+')
    if [[ -z "$SRC_TIMEOUT" ]]; then
        bad "$id: no DefaultTimeoutSeconds in the catalogue"
    elif [[ "$DOC_TIMEOUT" == "$SRC_TIMEOUT" ]]; then
        ok "$id: timeout ${SRC_TIMEOUT}s, document and catalogue agree"
    else
        bad "$id: document says timeout '$DOC_TIMEOUT', catalogue says '$SRC_TIMEOUT'"
    fi

    # the primary metric, same two-source treatment
    DOC_PRIMARY=$(printf '%s' "$ROW" | awk -F'|' '{print $5}' | tr -d ' ')
    SRC_PRIMARY=$(grep -A8 "Id = \"$id\"," "$SRC/Lxr.Harness.Core/ScenarioCatalog.cs" \
        | grep -oE 'Primary = PrimaryMetric\.[A-Za-z]+' | head -n 1 | sed 's/.*\.//' | tr 'A-Z' 'a-z')
    if [[ "$DOC_PRIMARY" == "$SRC_PRIMARY" ]]; then
        ok "$id: primary metric '$SRC_PRIMARY', document and catalogue agree"
    else
        bad "$id: document says primary '$DOC_PRIMARY', catalogue says '$SRC_PRIMARY'"
    fi

    # a declared host requirement. Spelled out on every row including the default, because a
    # requirement declared by omission is indistinguishable from one nobody thought about.
    if grep -A8 "Id = \"$id\"," "$SRC/Lxr.Harness.Core/ScenarioCatalog.cs" \
        | grep -q 'RequiredCapabilities'; then
        ok "$id: declared host requirement"
    else
        bad "$id: no RequiredCapabilities in the catalogue"
    fi
done <<< "$SRC_IDS"

# a success marker mechanism must exist and be asserted, not merely defined
if grep -rq 'LXR-HARNESS-COMPLETE' "$SRC"; then
    ok "success marker prefix is defined"
else
    bad "no success marker prefix found in source"
fi
if grep -rq 'marker-missing' "$SRC"; then
    ok "a missing success marker has a named failure reason"
else
    bad "nothing in source rejects a run for a missing marker"
fi

# ---------------------------------------------------------------------------
section 'every control has recorded evidence that it fired'

CONTROL_NUMBERS=$(grep -oE '^### Control [0-9]+' "$DOC" | grep -oE '[0-9]+' | sort -n -u)
CONTROL_COUNT=$(printf '%s\n' "$CONTROL_NUMBERS" | grep -c . || true)
note "document describes $CONTROL_COUNT control(s)"

if [[ "$CONTROL_COUNT" -lt 7 ]]; then
    bad "the brief requires seven controls; the document describes $CONTROL_COUNT"
else
    ok "$CONTROL_COUNT controls described"
fi

FIRED=$(grep -cE '^control [0-9]+ - .*: FIRED' "$DOC" || true)
note "document contains $FIRED verbatim FIRED line(s)"
if [[ "$FIRED" -eq "$CONTROL_COUNT" ]]; then
    ok "every described control has pasted evidence that it fired"
else
    bad "$CONTROL_COUNT controls described but $FIRED pasted FIRED lines"
fi

# the control suite must be able to fail. A suite that can only pass is not a suite.
if grep -q 'Fired = false' "$SRC/Lxr.Harness.Runner/ControlSuite.cs" \
    || grep -qE 'Fired *=[^;]*(==|!=|&&|>=|<=)' "$SRC/Lxr.Harness.Runner/ControlSuite.cs"; then
    ok "control outcomes are computed from observations, not hard-coded true"
else
    bad "ControlSuite never computes a Fired value from an observation"
fi

if grep -qE '^\s*bool\s+allFired|AllFired|control\.Fired' "$SRC/Lxr.Harness.Runner/ControlSuite.cs" \
    || grep -qE 'Fired' "$SRC/Lxr.Harness.Runner/Program.cs"; then
    ok "the control suite reports an aggregate outcome"
else
    bad "the control suite has no aggregate pass/fail"
fi

# ---------------------------------------------------------------------------
section 'results are schema-conformant and carry identity'

if [[ -n "$RESULTS" ]]; then
    while read -r file; do
        [[ -z "$file" ]] && continue
        rel=${file#"$ROOT/"}

        if grep -q '"schemaVersion": *2' "$file"; then
            ok "$rel: schemaVersion 2"
        else
            bad "$rel: missing or wrong schemaVersion"
        fi

        # every ok run must carry a confirmed collector and a runtime build identity
        OK_RUNS=$(grep -c '"status": *"ok"' "$file" || true)
        CONFIRMED=$(grep -c '"collectorConfirmed": *true' "$file" || true)
        BUILD_IDS=$(grep -c '"runtimeBuildId": *"' "$file" || true)

        if [[ "$OK_RUNS" -eq 0 ]]; then
            note "$rel: no ok runs to check"
        elif [[ "$CONFIRMED" -ge "$OK_RUNS" ]]; then
            ok "$rel: all $OK_RUNS ok run(s) confirmed their collector"
        else
            bad "$rel: $OK_RUNS ok run(s) but only $CONFIRMED confirmed collector identity"
        fi

        if [[ "$OK_RUNS" -eq 0 ]]; then
            :
        elif [[ "$BUILD_IDS" -ge "$OK_RUNS" ]]; then
            ok "$rel: all $OK_RUNS ok run(s) carry a runtime build identity"
        else
            bad "$rel: $OK_RUNS ok run(s) but only $BUILD_IDS runtime build id(s)"
        fi

        # a skip must be declared, never a silent absence
        SKIPS=$(grep -c '"status": *"skipped"' "$file" || true)
        SKIP_REASONS=$(grep -c '"skipReason": *"' "$file" || true)
        if [[ "$SKIPS" -eq 0 ]]; then
            :
        elif [[ "$SKIP_REASONS" -ge "$SKIPS" ]]; then
            ok "$rel: all $SKIPS skip(s) are declared with a reason"
        else
            bad "$rel: $SKIPS skip(s) but only $SKIP_REASONS reason(s)"
        fi
    done <<< "$RESULTS"
else
    note "no results to check"
fi

# ---------------------------------------------------------------------------
section 'no result was written outside the harness output directory'

STRAY=$(find "$ROOT/.github/extensions/lxr-gc-roadmap/benchmark-results" -newer "$DOC" -name '*.json' 2>/dev/null || true)
if [[ -z "$STRAY" ]]; then
    ok "nothing newer than the document was written into benchmark-results/"
else
    bad "the harness appears to have written into benchmark-results/, which is P0.5's job:"
    note "$STRAY"
fi

# the harness must default its output to the gitignored artifacts tree
if grep -rqE 'lxr-harness' "$SRC/Lxr.Harness.Runner" 2>/dev/null; then
    ok "harness output is rooted at artifacts/lxr-harness"
else
    bad "could not find the harness output root in the runner"
fi

if grep -rniE '\bC:\\+temp\b' "$SRC" "$HARNESS/scripts" 2>/dev/null | grep -vi 'not the shared temp' | grep -q .; then
    bad "something writes to the shared temp directory, which already holds gigabytes of stale dumps"
else
    ok "nothing targets the shared temp directory"
fi

# ---------------------------------------------------------------------------
section 'shell scripts are LF in the index'

if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    EOL=$(git -C "$ROOT" ls-files --eol -- 'docs/design/lxr-port/harness/scripts/*.sh' 2>/dev/null || true)
    if [[ -z "$EOL" ]]; then
        note "scripts are not tracked yet, so there is no index to check"
    elif printf '%s\n' "$EOL" | grep -q 'i/crlf'; then
        bad "a .sh file is CRLF in the index; bash cannot execute it"
        note "$EOL"
    else
        ok "every harness .sh is LF in the index"
        while read -r line; do note "$line"; done <<< "$EOL"
    fi
else
    note "not a git checkout (this is expected when auditing a git archive extract)"
fi

# ---------------------------------------------------------------------------
section 'build isolation'

if [[ -f "$HARNESS/Directory.Build.props" ]] && ! grep -qE '<Import|Sdk=' "$HARNESS/Directory.Build.props"; then
    ok "Directory.Build.props stops inheritance rather than importing Arcade"
else
    bad "Directory.Build.props does not stop inheritance"
fi

if grep -q '<clear' "$HARNESS/NuGet.config"; then
    ok "NuGet.config clears feeds; the harness has no package dependencies"
else
    bad "NuGet.config does not clear feeds"
fi

# Match the XML element, not the bare word - a comment saying "no PackageReference here" must not
# read as a violation.
if grep -rqE '<PackageReference' "$SRC" 2>/dev/null; then
    bad "a project has a PackageReference; the harness must build offline and run on corerun"
    note "$(grep -rlE '<PackageReference' "$SRC")"
else
    ok "no PackageReference anywhere in the harness"
fi

# The harness deliberately has no global.json: it builds with the repository's pinned SDK so its
# assemblies are in the same version band as a locally built runtime and can be loaded by it. One
# that rolled to a different SDK would break the corerun and testhost hosts, so its absence is
# asserted rather than merely tolerated - and the reason has to be written down where someone
# "fixing" the omission will see it.
if [[ -f "$HARNESS/global.json" ]]; then
    bad "harness/global.json exists; it would retarget the SDK away from the runtime under test"
elif grep -q 'no .global.json. here' "$HARNESS/README.md"; then
    ok "no harness global.json, and the README says why"
else
    bad "no harness global.json, but the README does not explain why one must not be added"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [[ $FAIL -eq 0 ]]; then
    printf 'RESULT: PASS (%d checks)\n' "$PASS"
    exit 0
fi
printf 'RESULT: FAIL (%d passed, %d failed)\n' "$PASS" "$FAIL"
exit 1
