# LXR port — design record

Working notes for a from-scratch port of the **LXR** garbage collector to .NET/CoreCLR.

LXR is described in Zhao, Blackburn & McKinley, *Low-Latency, High-Throughput Garbage Collection*
(PLDI 2022). It combines coalescing reference counting with a concurrent SATB trace over an Immix
heap. The reference implementation is the `lxr` branch of MMTk (`mmtk-core` + `mmtk-openjdk`).

The copy of the paper held locally is the **extended version**,
[arXiv:2210.17175](https://arxiv.org/abs/2210.17175) of 1 November 2022 — *not* the PLDI proceedings
paper, and its table and figure numbering cannot be assumed to match. Cite it accordingly; see
[`P0.2-paper-targets.md`](P0.2-paper-targets.md) §1.

These documents record research and design decisions. **No collector code has landed yet.**

## Parity contract

Full parity with the reference is a requirement, not an aspiration. Approximations, heuristics and
GC-side workarounds are not acceptable substitutes for a reference mechanism.

Two revisions are in scope as **parity oracles**, and an oracle is a **shipped build pair** — a
binding together with the `mmtk-core` revision that binding actually pins — not a tag or branch name:

| oracle | mmtk-openjdk | mmtk-core (**the oracle**) | roadmap name | relationship |
|---|---|---|---|---|
| PLDI 2022 | `abbdd1d` | **`df8d30a3`** | `lxr-pldi-2022` = `4d4e516c` | the named revision is 9 commits **behind** |
| `lxr` head | `0682434` | **`304ce69d`** | `lxr` head = `9625c174` | the named revision is 9 commits **ahead** |

Neither roadmap-named revision is what its binding builds. All eighteen skew commits are classified
in [`P0.1-mechanism-diff.md`](P0.1-mechanism-diff.md) §18.

The oracle is chosen **per mechanism**, and each choice is recorded with its reason. Coupled
mechanisms share one oracle. `lxr-x/simplified` is explicitly excluded.

> **Three conventions worth carrying forward.** `src/plan/lxr/…` paths exist **only at HEAD** — at PLDI
> LXR is a compile-time feature configuration of the Immix plan, so a missing PLDI path is never a
> missing mechanism. MMTk revisions must be ordered with `git merge-base`, never by author date:
> `df8d30a3` is dated *earlier* than `4d4e516c` yet is nine commits *after* it, having been rebased.
> And **no working tree anywhere is checked out at either oracle** — every `mmtk-core` working tree
> sits at a *named* revision nine commits away, so a citation taken from a checked-out tree silently
> names the wrong revision. Cite instead with `git show <rev>:<path>` against the read-only reference
> clone, which holds all four revisions as objects:
> `git -C C:\github\lxr-reference\mmtk-core show 304ce69d:src/plan/lxr/barrier.rs`. That is read-only,
> needs no checkout, and is reproducible on any machine that has the clone. See
> [`P0.3-oracle-probes.md`](P0.3-oracle-probes.md) §1.1; `scripts/verify-ledger.sh` enforces it.

## Documents

| document | contents |
|---|---|
| [`P0.1-reference-build.md`](P0.1-reference-build.md) | What was pinned, the resolved (mmtk-core, mmtk-openjdk, OpenJDK, rustc) tuple per revision, the exact build recipe, and what could not be built or run |
| [`P0.1-mechanism-diff.md`](P0.1-mechanism-diff.md) | The mechanism-organised diff between the two oracles — direct input to the P0.3 parity ledger. **Its location tables cite the roadmap-*named* revisions on both sides**; P0.3 re-derives every citation at the oracles |
| [`P0.1-benchmarks.md`](P0.1-benchmarks.md) | Reference pause and throughput behaviour on both revisions, and the characterisation of the PLDI instability |
| [`P0.2-paper-targets.md`](P0.2-paper-targets.md) | The paper's own acceptance targets — throughput vs G1, pause p50/p95, the reclamation split and barrier overhead — each cited to a table and page, with the measurement context and the paper's errata |
| [`P0.3-parity-ledger.md`](P0.3-parity-ledger.md) | **The mechanism parity ledger** — 26 rows, each with its declared oracle and reason, coupled group, validation oracle, citation at the declared oracle revision, provenance tag, required .NET realization and closure evidence. This is the artifact P9.1 audits |
| [`P0.3-oracle-probes.md`](P0.3-oracle-probes.md) | The evidence behind the ledger: the citation-basis correction, three P0.1 open items resolved from source, the two oracle probes, and the two questions P0.3 had to close |
| [`scripts/`](scripts/) | The clone, build, sanity, benchmark and probe scripts actually used |

## P0.1 outcome in one paragraph

Both revisions were pinned as independent clones and built on OpenJDK in WSL2/Ubuntu 22.04, release
and fastdebug, as the **shipped pairs** above; the roadmap-named revisions were additionally built via
a path override as a buildability experiment, and those numbers are quarantined separately.
**HEAD meets P0.1's correctness criterion**: all 8 DaCapo 2006 benchmarks, 3 invocations × {1, 5}
iterations at 500 MB and 2000 MB, plus a fastdebug pass — 96/96 runs, no crashes, and no assertion
failure in any of seven log directories. **PLDI does not.** It completes single-iteration runs of 5
of 8 benchmarks, crashes with SIGSEGV under sustained execution, and — the finding that matters most
for the port — in fastdebug it **fails its own barrier assertion**, `assert!(old.is_null() ||
rc::count(old) != 0)`, i.e. a field being overwritten still refers to an object whose reference count
has already reached zero. Release builds compile that check out, which is why the same defect appears
there as a segfault. The paper-contemporaneous oracle therefore remains the clearest **statement** of
the algorithm but is not a runnable specification: a port cannot be differentially tested against it.
Every mechanism recommendation that selects PLDI carries that caveat explicitly.

## P0.3 outcome in one paragraph

P0.3 converted P0.1's prose diff into a **26-row ledger** and, in doing so, corrected the basis on
which P0.1's citations rested: no working tree is checked out at either oracle, and P0.1's location
tables describe the roadmap-*named* revisions on **both** sides, so every citation was re-derived at
the oracle revisions. Two probes were run rather than reasoned about. **Probe 1** found that P0.1's
claim "HEAD never trips the `zero rc count` assertion" was *vacuous* — the assertion is absent from
HEAD's source and, verified with `strings`, from HEAD's shipped binary — so the invariant was
re-instated at the HEAD oracle and run under load: **48/48 DaCapo runs pass with zero violations** at
2000 MB and 500 MB. Root-causing PLDI's violation is therefore **not** on the critical path, and the
obligation is transferred to the port, which must carry the assertion from its first commit.
**Probe 2 resolved the hsqldb p99 anomaly rather than retiring it.** It is not an LXR mechanism
difference at all: hsqldb's `MemoryWatcherThread` is the only caller of `System.gc()` in DaCapo 2006,
and while *neither* oracle services the request, HEAD promotes any user-triggered collection to a
full-heap stop-the-world `Pause::Full` where PLDI deliberately excludes it from pause selection.
Running HEAD with `-XX:+DisableExplicitGC` removes all 25 pauses and 39 % of wall time. Seven
candidate causes were eliminated with evidence along the way. The finding is directly
portability-relevant — `GC.Collect()` is a public .NET API that can be neither ignored nor made
unconditionally full-heap — and became its own ledger row.



This is design documentation in a `dotnet/runtime` fork. Bulk build state — clones, OpenJDK trees,
JDK images, benchmark jars — lives outside version control. Nothing here builds or ships as part of
the runtime.
