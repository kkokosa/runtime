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
import math
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


def all_n_forms(n):
    """Renderings of an 'all N' claim.

    "All 8 throughput comparisons agree" conveys both the total and the count with one phrase, so
    demanding two occurrences of "8" would fail a document that is correct. Binding the count to the
    universal quantifier is the honest expectation here: stricter than a bare count, satisfiable
    once.
    """
    return ["all %s" % form for form in count_word_forms(n)]


def pattern_for(form):
    pattern = re.escape(form)
    if form[:1].isalnum() or form[:1] == "_":
        pattern = r"\b" + pattern
    if form[-1:].isalnum() or form[-1:] == "_":
        pattern = pattern + r"\b"
    return pattern


def matches(form, sentence):
    """Word-boundary match, but only where a boundary is meaningful.

    Many expected forms begin or end with a non-word character — `` `long-lived-cache` ``,
    ``**8.74%**``, ``14.48%``. A blind `\\b` on those sides never matches, so the boundary is applied
    only where the form's own edge is a word character. A bare `\\b3\\b` still finds the 3 in "3.3x",
    which is why counts with a total go through n_of_m_forms rather than through here alone.
    """
    return re.search(pattern_for(form), sentence, re.IGNORECASE) is not None


def occurrence_count(forms, text):
    """How many distinct places in the text satisfy any of these forms.

    Presence is not enough when one claim asserts two facts that happen to share a value. The
    section 5.1 claim asserts both that the heap-limit formula holds in 30 of 30 rows and that srv
    is the binding arm in 30 of 30 rows. A checker asking only whether "30 of 30" appears is
    satisfied by either sentence alone, so falsifying one of them passes — which is exactly what the
    first version of this check did when the binding-arm count was perturbed to 29 of 30.

    This is the same defect as expecting "3" and matching the "3" in "3.3x": asking whether a string
    is present where the real question is how many times. Counting non-overlapping occurrences and
    requiring one per expectation is the general form of the fix.
    """
    pattern = "|".join(pattern_for(f) for f in forms)
    return len(list(re.finditer(pattern, text, re.IGNORECASE)))


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
    # The prose only gets to say "all" while the counts agree; if they ever diverge the expected
    # form changes with them rather than the checker quietly accepting the weaker phrasing.
    forms = all_n_forms(len(data)) if len(faster) == len(data) else n_of_m_forms(len(faster), len(data))
    return (
        [("throughput comparisons all moving the same way", forms)],
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


def _heap_facts(paths):
    data = rows(paths["achieved"])
    formula_ok = sum(
        1 for r in data
        if int(r["heapLimitMb"]) == math.ceil(int(r["sharedMinimumMb"]) * float(r["nominalFactor"])))
    shared_ok = sum(
        1 for r in data
        if int(r["sharedMinimumMb"]) == max(int(r["wksMinimumMb"]), int(r["srvMinimumMb"])))
    # SharedMinimumMb is a Math.Max, so the binding arm is whichever equals the shared minimum, and
    # on a tie both arms bind. A strict `srv > wks` test reports a *true* document as false the first
    # time the two arms agree; there are no ties in this matrix, so the two definitions currently
    # coincide at 30 and the divergence is invisible. P0.6 adds a third collector and makes ties
    # materially more likely, at which point the strict form would fail correct prose.
    srv_binds = sum(1 for r in data if int(r["sharedMinimumMb"]) == int(r["srvMinimumMb"]))
    wks_binds = sum(1 for r in data if int(r["sharedMinimumMb"]) == int(r["wksMinimumMb"]))
    ties = sum(1 for r in data if int(r["srvMinimumMb"]) == int(r["wksMinimumMb"]))
    return len(data), formula_ok, shared_ok, srv_binds, wks_binds, ties


def _heap_arm_spread(paths):
    """The distinct Workstation minima and the Server range, per scenario rather than per row.

    The matrix carries three rows per scenario, one per nominal factor, and the minima are a
    property of the scenario. Counting over rows would triple every population without changing
    the value set, so the deduplication is deliberate and is stated here because a reader
    recomputing over all 30 rows gets the same sets by luck rather than by construction.
    """
    per_scenario = {}
    for r in rows(paths["achieved"]):
        per_scenario[r["scenario"]] = (int(r["wksMinimumMb"]), int(r["srvMinimumMb"]))
    wks = sorted({v[0] for v in per_scenario.values()})
    srv = sorted({v[1] for v in per_scenario.values()})
    return per_scenario, wks, srv


def derive_heap_arm_spread(paths):
    """Section 5.1 states what the two arms' minima actually are.

    This claim exists because the sentence it checks shipped false: the bullet gave Workstation a
    flat 4 MiB against a Server range of 35-43, which is true of exactly the four scenarios where
    Workstation sits at 4 and false of the ten-scenario matrix. Both figures are derived here so the
    document cannot drift from the CSV again.
    """
    per_scenario, wks, srv = _heap_arm_spread(paths)
    wks_forms = [", ".join(str(v) for v in wks[:-1]) + " and %d" % wks[-1]]
    srv_forms = ["%d to %d" % (srv[0], srv[-1]), "%d-%d" % (srv[0], srv[-1])]
    return (
        [("the distinct Workstation minima", wks_forms),
         ("the Server range", srv_forms)],
        ["scenarios=%d wks minima=%s srv minima=%s"
         % (len(per_scenario), wks, srv),
         "the false form this check exists to catch: wks flat 4 against srv 35-43, "
         "which holds over the %d scenario(s) where wks == 4"
         % sum(1 for v in per_scenario.values() if v[0] == 4)],
    )


def derive_heap_formula(paths):
    """Section 5.1's forward argument rests on arithmetic; it is derived here, not asserted there."""
    total, formula_ok, _, _, _, _ = _heap_facts(paths)
    mismatches = total - formula_ok
    forms = ["%s rows, %d %s" % (f, mismatches, word)
             for f in n_of_m_forms(formula_ok, total)
             for word in ("mismatch", "mismatches")]
    return (
        [("rows for which the limit is ceil(shared x factor)", forms)],
        ["rows=%d, formula holds=%d, mismatches=%d" % (total, formula_ok, mismatches)],
    )


def derive_heap_binding(paths):
    """Which arm sets the shared minimum. The whole forward claim turns on this being srv.

    Both facts here are '30 of 30', and they sit in one sentence. An expectation of a bare "30 of
    30" is satisfied by whichever of them the prose still states truthfully, so falsifying the other
    passes - which is what happened when the binding count was first perturbed to 29 of 30. Each
    count is therefore bound to the words that state it.
    """
    total, _, shared_ok, srv_binds, wks_binds, ties = _heap_facts(paths)
    return (
        [("rows where the shared minimum is max(wks, srv)",
          ["max(wks, srv)` in %s" % f for f in n_of_m_forms(shared_ok, total)]),
         ("rows where srv is the binding arm",
          ["binding arm in %s" % f for f in n_of_m_forms(srv_binds, total)])],
        ["rows=%d, shared == max(wks,srv)=%d" % (total, shared_ok),
         "srv binds=%d, wks binds=%d, ties=%d (binding == equals the shared minimum, so a tie "
         "would count for both arms)" % (srv_binds, wks_binds, ties)],
    )


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
    Claim("heap-formula", r"`heapLimitMb == ceil", derive_heap_formula,
          "section 5.1: every cell's limit is ceil(shared minimum x nominal factor)"),
    Claim("heap-binding", r"is the binding arm in", derive_heap_binding,
          "section 5.1: srv sets the shared minimum in every cell"),
    Claim("heap-arm-spread", r"Its minima range over", derive_heap_arm_spread,
          "section 5.1: the distinct Workstation minima and the Server range"),
]


def main():
    # The document is UTF-8 and this script prints its sentences back. On a cp1252 console that
    # raises UnicodeEncodeError on the first arrow or dash, which would abort the gate mid-run and
    # report nothing rather than reporting a result - a checker that dies on the characters of the
    # thing it checks. Degrade the rendering, never the run.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
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
        "achieved": os.path.join(args.results, "raw", "achieved-heap-factors.csv"),
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
        groups = []
        for label, forms in checks:
            key = tuple(forms)
            for existing in groups:
                if existing[0] == key:
                    existing[1].append(label)
                    break
            else:
                groups.append((key, [label]))
        for forms, labels in groups:
            found = occurrence_count(forms, sentence)
            if found < len(labels):
                bad.append("%s (expected %d occurrence(s) of %s, found %d)"
                           % (" and ".join(labels), len(labels), " / ".join(forms), found))
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
