#!/usr/bin/env bash
# The gate of the gate.
#
# A verification script that has not been shown to fail is indistinguishable from one that always
# passes. This runs verify-harness.sh three times:
#
#   A  against a clean extract of committed content, outside any worktree   -> expect PASS
#   B  against a copy of that extract with exactly one thing perturbed      -> expect FAIL
#   C  against the untouched original again                                 -> expect PASS
#
# B is the whole point. A and C alone would pass equally happily if the gate were reading a
# different tree than the one it was pointed at - which is exactly what happened to P0.3's gate.
#
# Usage: verify-harness-control.sh [repo-root]

set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ $# -ge 1 ]]; then
    REPO=$(cd "$1" && pwd)
else
    REPO=$(cd "$SELF_DIR/../../../../.." && pwd)
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'not a git checkout: %s\n' "$REPO"
    exit 2
fi

# Extract outside any worktree, so a gate that ignored its argument and walked up to a worktree
# would be caught rather than accidentally succeeding.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

printf 'gate-of-the-gate\n'
printf 'repo:    %s\n' "$REPO"
printf 'scratch: %s\n' "$WORK"

EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"

# Extract committed content only. Whatever is in the working tree is irrelevant: the artifact under
# audit is what is committed.
if ! git -C "$REPO" archive HEAD docs/design/lxr-port | tar -x -C "$EXTRACT"; then
    printf 'git archive failed - are the P0.4 artifacts committed?\n'
    exit 2
fi

GATE="$EXTRACT/docs/design/lxr-port/harness/scripts/verify-harness.sh"
if [[ ! -f "$GATE" ]]; then
    printf 'the extract has no gate at %s\n' "${GATE#"$WORK/"}"
    exit 2
fi

printf '\nextracted %d file(s) under docs/design/lxr-port\n' "$(find "$EXTRACT" -type f | wc -l)"
printf 'gate line endings in the extract: '
if grep -q $'\r' "$GATE"; then
    printf 'CRLF - bash cannot execute this, so any pass would attest to a conversion, not the artifact\n'
    exit 2
fi
printf 'LF\n'

# The extract has no smoke results (they live in the gitignored artifacts tree), so point the gate
# at a root that has both the extracted committed content and the real results directory. Symlink
# rather than copy, and fall back to a copy where symlinks are unavailable.
prepare_root() {
    local dest="$1"
    if [[ -d "$REPO/artifacts/lxr-harness" ]]; then
        mkdir -p "$dest/artifacts"
        ln -s "$REPO/artifacts/lxr-harness" "$dest/artifacts/lxr-harness" 2>/dev/null \
            || cp -r "$REPO/artifacts/lxr-harness" "$dest/artifacts/lxr-harness"
    fi
}

prepare_root "$EXTRACT"

run_gate() {
    local root="$1"
    local label="$2"
    local out
    out=$(bash "$root/docs/design/lxr-port/harness/scripts/verify-harness.sh" "$root" 2>&1)
    local code=$?
    printf '%s\n' "$out" | tail -n 3 | sed 's/^/      /'
    printf '      exit=%d\n' "$code"
    LAST_OUTPUT="$out"
    return $code
}

STATUS=0

# --- A ---------------------------------------------------------------------
printf '\n[A] committed extract, untouched\n'
if run_gate "$EXTRACT" "A"; then
    printf '  A PASSED as expected\n'
else
    printf '  A FAILED - the committed artifact does not pass its own gate\n'
    printf '%s\n' "$LAST_OUTPUT" | grep -E '^  FAIL' | sed 's/^/      /'
    STATUS=1
fi

# --- B ---------------------------------------------------------------------
# Perturb exactly one thing: delete one scenario row from the document's matrix table. That should
# break the "document and source agree" check and nothing else, so a gate that fails here for some
# other reason is also caught.
printf '\n[B] perturbed copy - one scenario row removed from the matrix table\n'
COPY="$WORK/perturbed"
cp -r "$EXTRACT" "$COPY"
rm -f "$COPY/artifacts/lxr-harness"
prepare_root "$COPY"

DOC_COPY="$COPY/docs/design/lxr-port/P0.4-harness.md"
VICTIM=$(grep -nE '^\| [0-9]+ \| `[a-z-]+` \|' "$DOC_COPY" | tail -n 1 | cut -d: -f1)
if [[ -z "$VICTIM" ]]; then
    printf '  could not find a scenario row to remove; the table format changed\n'
    STATUS=1
else
    VICTIM_ID=$(sed -n "${VICTIM}p" "$DOC_COPY" | grep -oE '`[a-z-]+`' | head -n 1 | tr -d '`')
    printf '  removing line %s (%s)\n' "$VICTIM" "$VICTIM_ID"
    sed -i "${VICTIM}d" "$DOC_COPY"

    if run_gate "$COPY" "B"; then
        printf '  B PASSED, which means the gate did not notice a missing scenario.\n'
        printf '  A gate that cannot fail is indistinguishable from an absent one.\n'
        STATUS=1
    else
        printf '  B FAILED as required. The gate detects a scenario missing from the document.\n'
        printf '%s\n' "$LAST_OUTPUT" | grep -E '^  FAIL' | head -n 4 | sed 's/^/      /'
    fi
fi

# --- C ---------------------------------------------------------------------
printf '\n[C] original extract again, to prove B did not contaminate it\n'
if run_gate "$EXTRACT" "C"; then
    printf '  C PASSED as expected\n'
else
    printf '  C FAILED - the perturbation leaked into the original\n'
    STATUS=1
fi

printf '\n'
if [[ $STATUS -eq 0 ]]; then
    printf 'GATE CONTROL: PASS - the gate passes committed content, fails a single perturbation, and recovers.\n'
else
    printf 'GATE CONTROL: FAIL\n'
fi
exit $STATUS
