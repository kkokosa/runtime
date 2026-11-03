#!/usr/bin/env python3
"""Worker (non-main thread) CPU by leaf function from the p31prof.sh JSON files. usage: p31profsum.py <dir> [pattern]"""
import collections, glob, json, os, re, statistics, sys

d = sys.argv[1]
pat = re.compile(sys.argv[2] if len(sys.argv) > 2 else
                 r"MarkPromotedStart|DecrementWithDeath|InitializeFieldLogRange|RetireSourceChunk|SweepCycle|SweepBlock|"
                 r"FindNextValidSlot|FindCounted|ResolveForwarded|IsObjectStart|ProcessIncrement|TryCopy|FindContaining|"
                 r"PrepareRecycledHole|PrepareFreshBlock|ReleaseNursery|TryRelease|FillRange|SideMetadata")
data = collections.defaultdict(lambda: collections.defaultdict(list))
totals = collections.defaultdict(lambda: collections.defaultdict(list))
for path in sorted(glob.glob(d + "/*.json")):
    name = os.path.basename(path)[:-5]
    variant, workload, rep = name.split("-")
    j = json.load(open(path))
    totals[(workload, variant)]["other_ms"].append(j["other_ms"])
    totals[(workload, variant)]["main_ms"].append(j["main_ms"])
    seen = collections.Counter()
    for cat, fn, ms in j["top_other"]:
        if pat.search(fn):
            seen[fn] += ms
    for fn, ms in seen.items():
        data[(workload, variant)][fn].append(ms)
for workload in ["requests", "binarytrees", "listsuffix", "mixedmedium", "losarrays", "mediumarrays"]:
    print("== " + workload)
    for variant in ("base", "walk"):
        t = totals[(workload, variant)]
        if not t["other_ms"]:
            continue
        print("  %-5s worker CPU %7.0f ms (main %6.0f ms)" % (variant, statistics.mean(t["other_ms"]), statistics.mean(t["main_ms"])))
        for fn, vals in sorted(data[(workload, variant)].items(), key=lambda kv: -statistics.mean(kv[1])):
            print("      %7.1f ms  %s" % (statistics.mean(vals), fn))