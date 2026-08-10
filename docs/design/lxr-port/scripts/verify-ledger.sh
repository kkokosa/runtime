#!/bin/bash
# P0.3 verification - resolve EVERY "<oracle> <hash> <path>:<line>" citation in the ledger and the
# probes document against the actual oracle source, and check the ledger's structural completeness.
# Exits non-zero if any citation does not resolve.
set -uo pipefail
PLDI=/root/.cargo/git/checkouts/mmtk-core-10faf03793f704d0/df8d30a
HEAD=/root/.cargo/git/checkouts/mmtk-core-91cf05d634be0a1e/304ce69
PLDI_BIND=/root/lxr/pldi/mmtk-openjdk
HEAD_BIND=/root/lxr/head/mmtk-openjdk
DOCS=${1:-/mnt/c/Users/konradkokosa/.copilot/repos/copilot-worktrees/runtime-fork/kkokosa-cautious-sniffle/docs/design/lxr-port}
FAIL=0

# Emits "<root>|<path>|<line>" for every citation in the documents.  Handles three forms:
#   full     <hash> `src/foo.rs:123`      /  <hash> `openjdk/bar.cpp:12`
#   shorthand `:456` continuing the most recent full citation on the SAME line
#   ranges    `src/foo.rs:116-126`        -> first line of the range
# Both core hashes (df8d30a / 304ce69) and binding hashes (abbdd1d / 0682434) are resolved.
extract () {
  python3 - "$PLDI" "$HEAD" "$PLDI_BIND" "$HEAD_BIND" "$@" <<'PY'
import re, sys
pldi, head, pldi_b, head_b = sys.argv[1:5]
# a revision hash selects the SIDE; the path prefix selects the REPO (core vs binding)
side = {'df8d30a': 'pldi', 'abbdd1d': 'pldi', '304ce69': 'head', '0682434': 'head'}
repo = {('pldi', 'src'): pldi, ('pldi', 'openjdk'): pldi_b,
        ('head', 'src'): head, ('head', 'openjdk'): head_b}
HASH = r'(df8d30a|304ce69|abbdd1d|0682434)'
PATH = r'`((?:src|openjdk)/[\w/.\-]+\.(?:rs|cpp|toml)):(\d+)(?:[-\u2013]\d+)?`'
BARE = r'`:(\d+)(?:[-\u2013]\d+)?`'
tok = re.compile(rf'\b{HASH}\w*\b|{PATH}|{BARE}')
out = set()

def emit(s, p, l):
    key = (s, p.split('/')[0])
    if key in repo:
        out.add((repo[key], p, l))

for path in sys.argv[5:]:
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
for r, p, l in sorted(out):
    print(f"{r}|{p}|{l}")
PY
}

echo "########## 1. citation resolution ##########"
n=0
while IFS='|' read -r root path line; do
  [ -z "$root" ] && continue
  n=$((n+1))
  f="$root/$path"
  if [ ! -f "$f" ]; then
    echo "  FAIL  missing file      $path  (in $(basename "$root"))"; FAIL=1; continue
  fi
  total=$(wc -l < "$f")
  if [ "$line" -gt "$total" ] || [ "$line" -lt 1 ]; then
    echo "  FAIL  line out of range $path:$line  (file has $total lines)"; FAIL=1; continue
  fi
  txt=$(sed -n "${line}p" "$f" | sed 's/^[[:space:]]*//' | cut -c1-72)
  printf '  ok    %-46s :%-5s %s\n' "$path" "$line" "$txt"
done < <(extract "$DOCS/P0.3-parity-ledger.md" "$DOCS/P0.3-oracle-probes.md")
echo "  -> $n distinct citations checked"

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
