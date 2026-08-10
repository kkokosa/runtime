#!/bin/bash
# P0.3 verification - resolve EVERY "<oracle> <hash> <path>:<line>" citation in the ledger and the
# probes document against the READ-ONLY reference oracle, and check the ledger's structural
# completeness.  Exits non-zero if any citation does not resolve.
#
# Citations resolve with `git show <rev>:<path>` against C:\github\lxr-reference, which holds all
# four revisions as objects.  Nothing is checked out and nothing is written: `git show`, `ls-tree`
# and `cat-file` are read-only.  This is preferred over the cargo git checkouts because the clone
# is the declared oracle and is reproducible on any machine that has it, whereas a cargo checkout
# is a machine-local cache that cargo may prune.  Section 1b proves the two agree byte for byte
# for every cited file, so citations derived from the cargo checkouts transfer unchanged.
set -uo pipefail
REF=${REF:-/mnt/c/github/lxr-reference}
PLDI=/root/.cargo/git/checkouts/mmtk-core-10faf03793f704d0/df8d30a
HEAD=/root/.cargo/git/checkouts/mmtk-core-91cf05d634be0a1e/304ce69
PLDI_BIND=/root/lxr/pldi/mmtk-openjdk
HEAD_BIND=/root/lxr/head/mmtk-openjdk
DOCS=${1:-/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-cautious-sniffle/docs/design/lxr-port}
FAIL=0

# Emits "<repo>|<rev>|<path>|<line>" for every citation in the documents.  Handles three forms:
#   full     <hash> `src/foo.rs:123`      /  <hash> `openjdk/bar.cpp:12`
#   shorthand `:456` continuing the most recent full citation in the SAME bullet
#   ranges    `src/foo.rs:116-126`        -> first line of the range
# A revision hash selects the SIDE; the path prefix selects the REPO.
extract () {
  python3 - "$@" <<'PY'
import re, sys
# a revision hash selects the SIDE; the path prefix selects the REPO
side = {'df8d30a': 'pldi', 'abbdd1d': 'pldi', '304ce69': 'head', '0682434': 'head'}
repo = {('pldi', 'src'): ('mmtk-core', 'df8d30a3'),
        ('pldi', 'openjdk'): ('mmtk-openjdk', 'abbdd1d'),
        ('head', 'src'): ('mmtk-core', '304ce69d'),
        ('head', 'openjdk'): ('mmtk-openjdk', '0682434')}
HASH = r'(df8d30a|304ce69|abbdd1d|0682434)'
PATH = r'`((?:src|openjdk)/[\w/.\-]+\.(?:rs|cpp|toml)):(\d+)(?:[-\u2013]\d+)?`'
BARE = r'`:(\d+)(?:[-\u2013]\d+)?`'
tok = re.compile(rf'\b{HASH}\w*\b|{PATH}|{BARE}')
out = set()

def emit(s, p, l):
    key = (s, p.split('/')[0])
    if key in repo:
        r, rev = repo[key]
        out.add((r, rev, p, l))

for path in sys.argv[1:]:
    cur_side = cur_path = None      # context, scoped to one bullet
    col_side = {}                   # for comparison tables: column index -> side
    for line in open(path, encoding='utf-8'):
        # a comparison table whose header names a revision per column binds each
        # column to that revision for the rows that follow
        if line.lstrip().startswith('|'):
            cells = line.split('|')
            if re.search(r'\|\s*-+\s*\|', line):
                continue
            hdr = {i: side[m.group(1)] for i, c in enumerate(cells)
                   if (m := re.search(HASH, c))}
            if hdr and not re.search(PATH, line):
                col_side = hdr
                continue
            if col_side:
                last = None
                for i, c in enumerate(cells):
                    s = col_side.get(i)
                    for m in re.finditer(rf'{PATH}|{BARE}', c):
                        if m.group(1):
                            last = m.group(1)
                            if s: emit(s, last, m.group(2))
                        elif s and last:
                            emit(s, last, m.group(3))
                continue
        # a blank line or a new bullet ends the citation context, so a bare `:NN`
        # can never bind to a file named in an unrelated earlier row
        if not line.strip() or re.match(r'\s*[-*]\s+\*\*', line) or line.startswith('**'):
            cur_side = cur_path = None
            col_side = {}
        for m in tok.finditer(line):
            if m.group(1):
                cur_side = side[m.group(1)]
            elif m.group(2):
                cur_path = m.group(2)
                if cur_side: emit(cur_side, cur_path, m.group(3))
            elif m.group(4) and cur_side and cur_path:
                emit(cur_side, cur_path, m.group(4))
for r, rev, p, l in sorted(out):
    print(f"{r}|{rev}|{p}|{l}")
PY
}

echo "########## 1. citation resolution (read-only, against $REF) ##########"
n=0
CITED=$(mktemp)
while IFS='|' read -r gitrepo rev path line; do
  [ -z "$gitrepo" ] && continue
  n=$((n+1))
  echo "$gitrepo|$rev|$path" >> "$CITED"
  blob=$(git -C "$REF/$gitrepo" show "$rev:$path" 2>/dev/null)
  if [ -z "$blob" ]; then
    echo "  FAIL  missing file      $path  (at $rev)"; FAIL=1; continue
  fi
  total=$(printf '%s\n' "$blob" | wc -l)
  if [ "$line" -gt "$total" ] || [ "$line" -lt 1 ]; then
    echo "  FAIL  line out of range $path:$line  (at $rev the file has $total lines)"; FAIL=1; continue
  fi
  txt=$(printf '%s\n' "$blob" | sed -n "${line}p" | sed 's/^[[:space:]]*//' | cut -c1-64)
  printf '  ok    %-8s %-40s :%-5s %s\n' "$rev" "$path" "$line" "$txt"
done < <(extract "$DOCS/P0.3-parity-ledger.md" "$DOCS/P0.3-oracle-probes.md")
echo "  -> $n distinct citations checked"

echo
echo "########## 1b. cargo checkouts vs the reference clone, for every cited file ##########"
# P0.3's citations were derived from the cargo git checkouts.  This proves those trees are
# byte-identical to the reference clone at the pinned revision, so the citations transfer.
same=0; diffn=0; absent=0
while IFS='|' read -r gitrepo rev path; do
  case "$gitrepo|$rev" in
    "mmtk-core|df8d30a3")    local_f="$PLDI/$path" ;;
    "mmtk-core|304ce69d")    local_f="$HEAD/$path" ;;
    "mmtk-openjdk|abbdd1d")  local_f="$PLDI_BIND/$path" ;;
    "mmtk-openjdk|0682434")  local_f="$HEAD_BIND/$path" ;;
    *) continue ;;
  esac
  if [ ! -f "$local_f" ]; then absent=$((absent+1)); echo "  absent locally  $rev $path"; continue; fi
  if git -C "$REF/$gitrepo" show "$rev:$path" 2>/dev/null | diff -q - "$local_f" >/dev/null 2>&1; then
    same=$((same+1))
  else
    diffn=$((diffn+1)); echo "  DIFFERS  $rev $path"; FAIL=1
  fi
done < <(sort -u "$CITED")
rm -f "$CITED"
echo "  identical: $same   differing: $diffn   absent locally: $absent"

echo
echo "########## 2. ledger structural completeness ##########"
L=$DOCS/P0.3-parity-ledger.md
idx=$(grep -cE '^\| (A0|B0|C0|D0|E0|S0|R0)[0-9] \|' "$L")
echo "  index rows                 : $idx"
for f in "Reason:" "Citation:" "Validation:" "Provenance:" ".NET realization:" "Closure evidence:" "Status:"; do
  c=$(grep -cF "**$f**" "$L")
  printf '  rows carrying %-20s: %s\n' "$f" "$c"
  # R rows use "Declared oracle:" in place of a separate Reason line; 26 expected for the rest
  [ "$c" -lt 26 ] && { echo "     FAIL  expected 26"; FAIL=1; }
done
det=$(grep -cE '^\*\*(A|B|C|D|E|S|R)0[0-9] — ' "$L")
echo "  detail blocks              : $det"
[ "$idx" -eq 26 ] || { echo "  FAIL index rows != 26"; FAIL=1; }
[ "$det" -eq 26 ] || { echo "  FAIL detail blocks != 26"; FAIL=1; }
[ "$idx" -eq "$det" ] || { echo "  FAIL index/detail mismatch"; FAIL=1; }

echo
echo "  every index row has a provenance tag:"
bad=$(grep -E '^\| (A0|B0|C0|D0|E0|S0|R0)[0-9] \|' "$L" | grep -vcE '\[(obs-oracle|obs-override|read-only)\]')
echo "    rows missing a tag       : $bad"; [ "$bad" -eq 0 ] || FAIL=1
echo "  every index row has a group and a declared oracle:"
bad=$(grep -E '^\| (A0|B0|C0|D0|E0|S0|R0)[0-9] \|' "$L" | awk -F'|' '$4 !~ /[A-ES R]/ || $5 !~ /(PLDI|HEAD|none)/' | wc -l)
echo "    rows missing either      : $bad"; [ "$bad" -eq 0 ] || FAIL=1

echo
echo "  one declared oracle per coupled group:"
for g in A B C D E; do
  o=$(grep -E "^\| ${g}0[0-9] \|" "$L" | awk -F'|' '{gsub(/ /,"",$5); print $5}' | sort -u | tr '\n' ',')
  cnt=$(grep -E "^\| ${g}0[0-9] \|" "$L" | awk -F'|' '{gsub(/ /,"",$5); print $5}' | sort -u | wc -l)
  printf '    group %s -> %-12s (%s distinct)\n' "$g" "$o" "$cnt"
  [ "$cnt" -eq 1 ] || { echo "      FAIL group $g has $cnt declared oracles"; FAIL=1; }
done

echo
echo "########## 3. markdown hygiene ##########"
for f in "$DOCS"/P0.3-*.md "$DOCS"/README.md; do
  t=$(grep -cE ' +$' "$f")
  printf '  %-28s trailing-whitespace lines: %s\n' "$(basename "$f")" "$t"
  [ "$t" -eq 0 ] || FAIL=1
done

echo
[ $FAIL -eq 0 ] && echo "VERIFY: PASS" || echo "VERIFY: FAIL"
exit $FAIL
