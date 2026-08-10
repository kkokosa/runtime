#!/bin/bash
# Gate-of-the-gate: prove that verify-ledger.sh audits the tree it is run in.
#
# verify-ledger.sh once defaulted its documents directory to an absolute path into one worktree, so
# running it from a fresh extract silently audited a different checkout and reported a clean result
# about an artifact the operator was not looking at (probes 8, correction 6).  A passing run is not
# evidence that a check is reading anything, so this script does three things:
#
#   A. run the COMMITTED verify-ledger.sh from a clean tree with NO argument
#   B. perturb THAT tree only, and require the gate to FAIL on it
#   C. confirm the working tree was never touched and still passes
#
# Step B is the point.  Without it, A and C would both have passed just as happily when the default
# path was hardcoded - which is exactly how the defect survived.
#
# Usage:  verify-gate.sh [<tree-root>]
#   <tree-root> contains docs/design/lxr-port/...  Supply an extract of the COMMITTED tree, e.g.
#       git archive HEAD docs/design/lxr-port -o /tmp/gate.tar
#       mkdir -p /tmp/gate && tar -xf /tmp/gate.tar -C /tmp/gate
#       docs/design/lxr-port/scripts/verify-gate.sh /tmp/gate
#   With no argument the script makes that extract itself.  Note that a git worktree checked out from
#   Windows has a .git gitlink holding a Windows path, which git inside WSL cannot follow - in that
#   case create the tar on the Windows side and pass the extract explicitly.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIVE=$(cd "$SELF_DIR/.." && pwd)
ROW=${ROW:-E02}                      # the index row the control deletes; must exist exactly once
FAIL=0
TMP=

if [ $# -ge 1 ]; then
  TREE=$1
else
  REPO=$(cd "$LIVE/../../.." && pwd)
  TMP=$(mktemp -d)
  git -C "$REPO" archive HEAD docs/design/lxr-port | tar -x -C "$TMP" || {
    echo "could not archive HEAD from $REPO - pass an extract as an argument instead"; exit 2; }
  TREE=$TMP
fi
G=$TREE/docs/design/lxr-port/scripts/verify-ledger.sh
L=$TREE/docs/design/lxr-port/P0.3-parity-ledger.md
[ -f "$G" ] || { echo "no verify-ledger.sh under $TREE"; exit 2; }

echo "########## A. committed gate, clean tree, no argument ##########"
if grep -q $'\r' "$G"; then echo "  FAIL  CRLF in the committed script - bash cannot run it"; FAIL=1
else echo "  line endings: LF, runs without conversion"; fi
bash "$G" > /tmp/gate-A.log 2>&1; a=$?
grep -E 'index rows|self-reported|detail blocks|distinct citations|UNACK|VERIFY' /tmp/gate-A.log | sed 's/^/  /'
echo "  exit=$a"
[ "$a" -eq 0 ] || { echo "  FAIL  the committed tree does not pass its own gate"; FAIL=1; }

echo
echo "########## B. positive control: perturb THAT tree only ##########"
before=$(grep -c "^| $ROW |" "$L")
echo "  $ROW index rows before: $before"
if [ "$before" -ne 1 ]; then
  echo "  FAIL  control invalid - $ROW is not present exactly once, so the control deletes nothing"
  FAIL=1
else
  sed -i "/^| $ROW | /d" "$L"
  echo "  $ROW index rows after : $(grep -c "^| $ROW |" "$L")"
  bash "$G" > /tmp/gate-B.log 2>&1; b=$?
  grep -E 'index rows|self-reported|detail blocks|FAIL|VERIFY' /tmp/gate-B.log | sed 's/^/  /'
  echo "  exit=$b"
  if [ "$b" -eq 0 ]; then
    echo "  FAIL  the gate passed on a perturbed tree - it is not reading that tree"; FAIL=1
  else
    echo "  control fired: the gate saw a change made ONLY in the tree under test"
  fi
fi

echo
echo "########## C. the working tree was never touched ##########"
bash "$LIVE/scripts/verify-ledger.sh" > /tmp/gate-C.log 2>&1; c=$?
grep -E 'index rows|detail blocks|UNACK|VERIFY' /tmp/gate-C.log | sed 's/^/  /'
echo "  exit=$c"
[ "$c" -eq 0 ] || { echo "  FAIL  the working tree no longer passes"; FAIL=1; }

[ -n "$TMP" ] && rm -rf "$TMP"
echo
[ "$FAIL" -eq 0 ] && { echo "GATE-OF-GATE: PASS"; exit 0; } || { echo "GATE-OF-GATE: FAIL"; exit 1; }
