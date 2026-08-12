#!/usr/bin/env python3
"""Verify the document's quantified prose claims against the CSVs shipped beside them.

Why this exists. The gate verified data against data — checkpoint against raw CSV, published means
against re-derived means, row counts against files — and 30 checks passed over a sentence in section
6.5 that said "all four throughput ratios ... drift by less than the 8.35% floor" while the CSV
sitting beside it published `long-lived-cache` at 8.744%. Three of four, not four. Rule 25 said a
gate auditing an artifact against itself cannot catch the artifact lying about the code; this is its
twin, that the artifact can also lie about its own data.

Design constraint. Every expected value is DERIVED FROM THE CSV at run time and never written as a
constant here. A checker holding its own copy of the number is a second place to be wrong, and it
would agree with a stale document as happily as with a correct one. This file holds only the CSV
column names, the predicate, and a regex locating the sentence.

Every claim prints the derived value, the located sentence, and the comparison, per rule 26 — a bare
pass/verdict hides a check that ran against the wrong thing.
"""
import argparse
import csv
import json
import os
import re
import statistics
import sys

FLOOR_PERCENT = 8.35
WORDS = {0: "zero", 1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six",
         7: "seven", 8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve"}


def count_word_forms(n):
    """A count may be written as a digit or a word; accept either, case-insensitively."""
    forms = [str(n)]
    if n in WORDS:
        forms.append(WORDS[n])
    return forms


def n_of_m_forms(n, m):
    """Renderings of an 'N of M' claim, binding the count to its total.

    Checking a bare count is not safe. A perturbation that changed "Three of the four" to "All four
    of the four" passed the first version of this checker, because the expected form "3" matched the
    "3.3x" in the following sentence. Requiring the pair cannot be satisfied by a stray decimal.
    """
    forms = []
    for a in count_word_forms(n):
        for b in count_word_forms(m):
            forms.append("%s of %s" % (a, b))
            forms.append("%s of the %s" % (a, b))
    return forms


def matches(form, sentence):
    """Word-boundary match, but only where a boundary is meaningful.

    Many expected forms begin or end with a non-word character — `` `long-lived-cache` ``,
    ``**8.74%**``, ``14.48%``. A blind `\\b` on those sides never matches, so the boundary is applied
    only where the form's own edge is a word character. A bare `\\b3\\b` still finds the 3 in "3.3x",
    which is why counts with a total go through n_of_m_forms rather than through here alone.
    """
    pattern = re.escape(form)
    if form[:1].isalnum() or form[:1] == "_":
        pattern = r"\b" + pattern
    if form[-1:].isalnum() or form[-1:] == "_":
        pattern = pattern + r"\b"
    return re.search(pattern, sentence, re.IGNORECASE) is not None


def rows(path):
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def is_true(value):
    return value.strip().lower() == "true"


class Claim:
    """One quantified prose claim: where it lives, and what the data says it must contain."""

    def __init__(self, claim_id, anchor, derive, description):
        self.claim_id = claim_id
        self.anchor = anchor
        self.derive = derive
        self.description = description


def find_anchor(doc_lines, anchor):
    """Locate a claim's sentence, ignoring blockquotes.

    Blockquotes in this document are rule 22 corrections: text quoted precisely because it is
    false. Binding a claim check to one would test the wrong sentence and, worse, would keep
    passing after the live claim was edited. The floor claim did exactly this on first run — the
    anchor matched the quoted false sentence four lines above the corrected one.
    """
    pattern = re.compile(anchor, re.IGNORECASE)
    for index, line in enumerate(doc_lines):
        if line.lstrip().startswith(">"):
            continue
        if pattern.search(line):
            # Claims routinely wrap across a line break; give the predicate the neighbourhood,
            # excluding any quoted-and-corrected text that happens to sit beside it.
            start = max(0, index - 1)
            window = [l for l in doc_lines[start:index + 3] if not l.lstrip().startswith(">")]
            return index + 1, " ".join(l.strip() for l in window)
    return None, None


# ---------------------------------------------------------------------------------------------
# Derivations. Each returns (list of (label, [acceptable strings]), list of printable evidence).
# ---------------------------------------------------------------------------------------------

def derive_repro_cells(paths):
    data = rows(paths["repro"])
    exceeding = [r for r in data if is_true(r["exceedsBothSpreadAndFloor"])]
    # Median over ALL cells, not over the disagreeing subset. Both readings of the sentence are
    # grammatical and they differ materially (14.48% over 16 against 17.94% over the 12), which is
    # why the prose was made explicit about its population rather than left to be inferred.
    diffs = [abs(float(r["differencePercent"])) for r in data]
    subset = [abs(float(r["differencePercent"])) for r in exceeding]
    return (
        [("disagreeing cells bound to the total", n_of_m_forms(len(exceeding), len(data))),
         ("median difference over all cells", ["%.2f%%" % statistics.median(diffs)]),
         ("max difference", ["%.2f%%" % max(diffs)])],
        ["cells=%d exceeding=%d median(all)=%.2f%% median(exceeding)=%.2f%% max=%.2f%%"
         % (len(data), len(exceeding), statistics.median(diffs), statistics.median(subset),
            max(diffs))],
    )


def derive_offered_load(paths):
    data = rows(paths["repro"])
    differing = [r for r in data if not is_true(r["sameOfferedLoad"])]
    return (
        [("cells with a different offered load", count_word_forms(len(differing)))],
        ["total=%d sameOfferedLoad=false -> %d (difference %d)"
         % (len(data), len(differing), len(data) - len(differing))],
    )


def derive_comparable(paths):
    data = rows(paths["repro"])
    comparable = [r for r in data if is_true(r["sameOfferedLoad"])]
    disagreeing = [r for r in comparable if is_true(r["exceedsBothSpreadAndFloor"])]
    # As above: median over all comparable cells, not over the disagreeing subset.
    diffs = [abs(float(r["differencePercent"])) for r in comparable]
    subset = [abs(float(r["differencePercent"])) for r in disagreeing]
    return (
        [("comparable cells", count_word_forms(len(comparable))),
         ("still disagreeing", count_word_forms(len(disagreeing))),
         ("median over all comparable", ["%.2f%%" % statistics.median(diffs)])],
        ["comparable=%d disagreeing=%d median(comparable)=%.2f%% median(disagreeing)=%.2f%%"
         % (len(comparable), len(disagreeing), statistics.median(diffs),
            statistics.median(subset))],
    )


def derive_direction(paths):
    data = [r for r in rows(paths["repro"]) if r["metric"] == "operationsPerSecond"]
    faster = [r for r in data if float(r["otherMean"]) > float(r["baselineMean"])]
    return (
        [("throughput comparisons", count_word_forms(len(data))),
         ("all moving the same way", count_word_forms(len(faster)))],
        ["throughput comparisons=%d s3-faster=%d s3-slower=%d"
         % (len(data), len(faster), len(data) - len(faster))],
    )


def _ratio_stability(path):
    data = rows(path)
    ratio = [float(r["ratioDriftPercent"]) for r in data]
    absolute = [float(r["largestAbsoluteDriftPercent"]) for r in data]
    more_stable = [r for r in data if is_true(r["ratioMoreStableThanAbsolute"])]
    return data, statistics.median(ratio), statistics.median(absolute), len(more_stable)


def derive_stability_s3(paths):
    data, med_ratio, med_abs, more = _ratio_stability(paths["ratio_s3"])
    return (
        [("median ratio drift", ["**%.2f%%**" % med_ratio]),
         ("median absolute drift", ["%.2f%%" % med_abs]),
         ("more stable", ["%d of %d" % (more, len(data))])],
        ["rows=%d medianRatio=%.2f%% medianAbs=%.2f%% moreStable=%d"
         % (len(data), med_ratio, med_abs, more)],
    )


def derive_stability_s4(paths):
    data, med_ratio, med_abs, more = _ratio_stability(paths["ratio_s4"])
    return (
        [("median ratio drift", ["**%.2f%%**" % med_ratio]),
         ("median absolute drift", ["%.2f%%" % med_abs]),
         ("more stable", ["%d of %d" % (more, len(data))])],
        ["rows=%d medianRatio=%.2f%% medianAbs=%.2f%% moreStable=%d"
         % (len(data), med_ratio, med_abs, more)],
    )


def derive_floor_claim(paths):
    """The claim that was false. Both counts are derived and both must appear."""
    data = [r for r in rows(paths["ratio_s3"]) if r["metric"] == "operationsPerSecond"]
    below = [r for r in data if float(r["ratioDriftPercent"]) < FLOOR_PERCENT]
    above = [r for r in data if float(r["ratioDriftPercent"]) >= FLOOR_PERCENT]
    checks = [("throughput ratios below the floor, bound to the total",
               n_of_m_forms(len(below), len(data)))]
    evidence = ["throughput rows=%d below %.2f%%=%d at-or-above=%d (difference %d)"
                % (len(data), FLOOR_PERCENT, len(below), len(above), len(data) - len(below))]
    for r in above:
        # A row above the floor must be named, with its drift, so it cannot be quietly averaged in.
        checks.append(("named above-floor scenario", ["`%s`" % r["scenario"]]))
        checks.append(("its ratio drift", ["**%.2f%%**" % float(r["ratioDriftPercent"])]))
        checks.append(("its absolute drift", ["**%.2f%%**" % float(r["largestAbsoluteDriftPercent"])]))
        evidence.append("above floor: %s ratio=%.3f%% absolute=%.3f%%"
                        % (r["scenario"], float(r["ratioDriftPercent"]),
                           float(r["largestAbsoluteDriftPercent"])))
    return checks, evidence


def derive_calibration(paths):
    with open(paths["calibration"], encoding="utf-8") as handle:
        baselines = json.load(handle)["baselines"]
    provisional = [b for b in baselines if b.get("provisional")]
    return (
        [("calibrated scenarios", count_word_forms(len(baselines)))],
        ["baselines=%d provisional=%d converged=%d"
         % (len(baselines), len(provisional), len(baselines) - len(provisional))],
    )


CLAIMS = [
    Claim("repro-cells", r"cells disagree with s2 by more than both", derive_repro_cells,
          "section 6.5 headline: N of M cells disagree, with median and max"),
    Claim("offered-load", r"cells had a different offered load", derive_offered_load,
          "section 6.5 decomposition 1: cells excluded for differing offered load"),
    Claim("comparable", r"genuinely comparable cells", derive_comparable,
          "section 6.5 decomposition 2: comparable cells still disagreeing"),
    Claim("direction", r"throughput comparisons moved the same way", derive_direction,
          "section 6.5 decomposition 3: sign test over throughput comparisons"),
    Claim("stability-s3", r"^\| s2 vs s3 ", derive_stability_s3,
          "section 6.5 ratio-stability table, s2 vs s3 row"),
    Claim("stability-s4", r"^\| s2 vs s4sdk ", derive_stability_s4,
          "section 6.5 ratio-stability table, s2 vs s4sdk row"),
    Claim("floor-claim", r"throughput ratios in the s2/s3 comparison drift by less than",
          derive_floor_claim,
          "section 6.5: how many throughput ratios clear the resolution floor"),
    Claim("calibration", r"All ten converged and every entry is", derive_calibration,
          "section 5: every calibrated scenario converged"),
]


def main():
    parser = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    parser.add_argument("--doc", default=os.path.join(os.path.dirname(root), "P0.5-baselines.md"))
    parser.add_argument("--results", default=root)
    args = parser.parse_args()

    paths = {
        "repro": os.path.join(args.results, "raw", "reproducibility-s2-vs-s3.csv"),
        "ratio_s3": os.path.join(args.results, "raw", "arm-ratio-stability-s2-vs-s3.csv"),
        "ratio_s4": os.path.join(args.results, "raw", "arm-ratio-stability-s2-vs-s4sdk.csv"),
        "calibration": os.path.join(args.results, "calibration.json"),
    }
    missing = [p for p in paths.values() if not os.path.isfile(p)]
    if missing:
        for p in missing:
            print("FAIL missing input: %s" % p)
        return 1
    if not os.path.isfile(args.doc):
        print("FAIL missing document: %s" % args.doc)
        return 1

    with open(args.doc, encoding="utf-8") as handle:
        doc_lines = handle.read().splitlines()

    failures = 0
    for claim in CLAIMS:
        print("claim %-14s %s" % (claim.claim_id, claim.description))
        line_number, sentence = find_anchor(doc_lines, claim.anchor)
        if sentence is None:
            # A claim whose sentence has been deleted must fail, not silently pass.
            print("  FAIL  no sentence in the document matches /%s/" % claim.anchor)
            failures += 1
            print()
            continue
        checks, evidence = claim.derive(paths)
        for line in evidence:
            print("  data   %s" % line)
        print("  doc    :%d %s" % (line_number, sentence[:150]))
        bad = []
        for label, forms in checks:
            if not any(matches(f, sentence) for f in forms):
                bad.append("%s (expected one of %s)" % (label, " / ".join(forms)))
        if bad:
            for b in bad:
                print("  FAIL  prose does not carry %s" % b)
            failures += 1
        else:
            print("  ok     all %d derived figures present in the prose" % len(checks))
        print()

    checked = len(CLAIMS)
    if failures:
        print("RESULT: FAIL (%d of %d prose claims disagree with the data)" % (failures, checked))
        return 1
    print("RESULT: PASS (%d prose claims re-derived from the shipped CSVs)" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
