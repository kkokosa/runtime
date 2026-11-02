#!/usr/bin/env python3
"""Leaf-function category summary of a windowed perf profile (frame-c4, any collector).
usage: summary-laxori.py <perf.data> [--tag NAME] [--json file] [--frame DIR] [--laxori-so PATH]
Adapted from summary5.py: frame-c4, the Laxori library with its .dbg, and categories for the private tier."""
import collections, json, os, re, subprocess, sys

PERF = "/usr/lib/linux-tools/5.15.0-202-generic/perf"
args = sys.argv
opt = lambda k, d=None: args[args.index(k) + 1] if k in args else d
data = args[1]
tag = opt("--tag", os.path.basename(data))
jout = opt("--json")
FRAME = opt("--frame", "/root/prof/frame-c4")
HZ = float(os.environ.get("HZ", 4000))
LAXORI_SO = opt("--laxori-so", "/root/laxori/prof/libclrlaxorigc.so")
DBGS = {"libclrlxrgc.so": FRAME + "/libclrlxrgc.so.dbg", "libsatorigc.so": FRAME + "/libsatorigc.so.dbg",
        "libclrlaxorigc.so": LAXORI_SO + ".dbg",
        "libcoreclr.so": FRAME + "/libcoreclr.so.dbg"}

mm = subprocess.run([PERF, "script", "-i", data, "--show-mmap-events", "-F", "pid"], stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True).stdout
maps = collections.defaultdict(list)
for line in mm.splitlines():
    if "r-xp" not in line:
        continue
    for d in DBGS:
        if d in line:
            m = re.search(r"\[0x([0-9a-f]+)\(0x([0-9a-f]+)\) @ (?:0x)?([0-9a-f]+) ", line)
            if m:
                maps[d].append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)))

out = subprocess.run([PERF, "script", "-i", data, "-F", "pid,tid,ip,sym,dso"], stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True).stdout
HDR = re.compile(r"^\s*(\d+)/(\d+)\s*$")
FR = re.compile(r"^\s+([0-9a-f]+)\s+(.*?)\s+\((.*)\)\s*$")
blocks, cur = [], None
for line in out.splitlines():
    if not line.strip():
        cur = None
        continue
    h = HDR.match(line)
    if h:
        cur = {"main": h.group(1) == h.group(2), "fr": []}
        blocks.append(cur)
        continue
    m = FR.match(line)
    if m and cur is not None:
        cur["fr"].append((int(m.group(1), 16), m.group(2), m.group(3)))


def dso_key(dso):
    b = os.path.basename(dso)
    return b if b in DBGS else None


def file_off(d, ip):
    for base, size, pgoff in maps[d]:
        if base <= ip < base + size:
            return ip - base + pgoff
    return None


# batch addr2line of leaf ips per dso
need = collections.defaultdict(set)
for b in blocks:
    if b["fr"]:
        ip, sym, dso = b["fr"][0]
        d = dso_key(dso)
        if d:
            o = file_off(d, ip)
            if o is not None:
                need[d].add(o)
names = {}
for d, offs in need.items():
    offs = sorted(offs)
    r = subprocess.run(["addr2line", "-f", "-C", "-e", DBGS[d]] + [hex(o) for o in offs], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, text=True).stdout.splitlines()
    fn = r[0::2]
    for o, n in zip(offs, fn):
        names[(d, o)] = n


def leaf_name(fr):
    ip, sym, dso = fr
    d = dso_key(dso)
    if d:
        o = file_off(d, ip)
        n = names.get((d, o)) if o is not None else None
        if n and n != "??":
            return n, d
        return sym, d
    if dso.endswith(".map") or "[CompareDriver]" in sym or sym.startswith("stub "):
        return sym, "managed"
    return sym, os.path.basename(dso)


RULES = [
    ("memset / zeroing", re.compile(r"memset|bzero|clear_page|ZeroMemory")),
    ("memcpy / memmove", re.compile(r"memmove|memcpy")),
    ("TLS lookup (ld.so)", re.compile(r"tls_get_addr|_dl_update_slotinfo|update_get_addr|__tls_")),
    ("thread-local GC (Laxori)", re.compile(r"LocalMark|LocalPlan|LocalUpdate|LocalCompact|LocalCollect|MarkFn|UpdateFn|ClearPads|WalkRegion|AppendGaps|OpenGap|FindObject|NextMarked|PushMarkStack|PopMarkStack")),
    ("escape tracking (Laxori)", re.compile(r"EscapeRecursively|EscapeInCurrentRegion|EscapeSlowPath|EscapeCheck|EscapeBulk|EscapeObject|LaxoriEscape")),
    ("write barrier", re.compile(r"WriteBarrier|LogOld|LogBefore|BulkBarrier|memmoveGCRefs|RememberMature|CheckedWriteBarrier|ByRefWriteBarrier")),
    ("allocation path", re.compile(
        r"Rhp(New|Alloc|GcAlloc)|JIT_New|AllocateObject|AllocateSzArray|Allocate\(|::Alloc\(|TryRefill|PrepareRecycledHole|PrepareFreshBlock|"
        r"AcquireBlock|TryAcquire|allocate_more_space|adjust_limit|gc_heap::allocate|a_fit|soh_try_fit|try_allocate|"
        r"GCHeap::Alloc|alloc_context|bump_pointer|FindNextHole|TryFindNextHole|CloseSpan|AllocateMedium|ImmixBumpAllocator|"
        r"Satori.*(Alloc|alloc)|::alloc|Alloc[A-Z]")),
    ("kernel", re.compile(r"kernel|_raw_spin|finish_task_switch|do_syscall|entry_SYSCALL|futex")),
]
GCISH = re.compile(r"Lxr|Laxori|Immix|ReferenceCount|WKS::|SVR::|gc_heap|GCHeap|SideMetadata|LargeObject|Satori|mark_object|plan_phase|relocate|compact|sweep|Sweep|Mark")


def categorize(name, kind):
    if kind == "managed":
        return "managed code (incl. JIT'd helpers)"
    for cat, rx in RULES:
        if rx.search(name):
            return cat
    if kind.startswith("[kernel") or kind == "[vdso]":
        return "kernel"
    if kind in ("libclrlxrgc.so", "libsatorigc.so", "libclrlaxorigc.so") or GCISH.search(name):
        return "GC work (mark/sweep/RC/other)"
    if kind.startswith("libclrjit"):
        return "JIT"
    return "runtime/other (" + kind[:18] + ")"


res = {"main": collections.Counter(), "other": collections.Counter()}
tot = collections.Counter()
top = {"main": collections.Counter(), "other": collections.Counter()}
for b in blocks:
    if not b["fr"]:
        continue
    who = "main" if b["main"] else "other"
    name, kind = leaf_name(b["fr"][0])
    cat = categorize(name, kind)
    res[who][cat] += 1
    top[who][(cat, name[:70])] += 1
    tot[who] += 1

ms = lambda n: 1000.0 * n / HZ
print(f"## {tag}: main thread {ms(tot['main']):.0f} ms, other threads {ms(tot['other']):.0f} ms (total CPU {ms(tot['main'] + tot['other']):.0f} ms)")
for who in ("main", "other"):
    print(f"  [{who}]")
    for cat, n in res[who].most_common(9):
        print(f"    {ms(n):7.1f} ms {100 * n / max(1, tot[who]):5.1f}%  {cat}")
    for (cat, n), v in top[who].most_common(6):
        print(f"        top: {ms(v):7.1f} ms  {n}")
if jout:
    json.dump({"tag": tag, "main_ms": ms(tot["main"]), "other_ms": ms(tot["other"]),
               "main": {k: ms(v) for k, v in res["main"].items()}, "other": {k: ms(v) for k, v in res["other"].items()},
               "top_main": [[c, n, ms(v)] for (c, n), v in top["main"].most_common(40)],
               "top_other": [[c, n, ms(v)] for (c, n), v in top["other"].most_common(40)]}, open(jout, "w"), indent=1)
