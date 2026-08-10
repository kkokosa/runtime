<!-- lxr-gc-roadmap:v1 -->
# LXR GC implementation roadmap

This roadmap tracks a greenfield port of LXR, described in Zhao, Blackburn, and McKinley's
[Low-Latency, High-Throughput Garbage Collection](https://arxiv.org/abs/2210.17175), to CoreCLR as a
standalone GC plus a set of generic runtime capabilities. The reference implementation is checked out at
`C:\github\lxr-reference`: [`mmtk-core`](https://github.com/wenyuzhao/mmtk-core) and
[`mmtk-openjdk`](https://github.com/wenyuzhao/mmtk-openjdk).

Two revisions are in scope as parity oracles. The oracle basis is the **binding-pinned pair** — the configuration
you get by checking out the binding and building it with no override: PLDI is binding `abbdd1d` (tag
`lxr-pldi-2022`) resolving core `df8d30a3`, and head is binding `0682434` (branch `lxr`) resolving core
`304ce69d`. This is deliberately *not* the core tag `4d4e516c` nor the core branch head `9625c174`: the binding
does not reference either, so building them requires a manual override, whereas the pinned pair is what a reader
of the paper reproduces without intervention. Since a multi-year port will be rebuilt by many future sessions,
reproducibility-without-intervention is the deciding property. The oracle is chosen **per mechanism** between the
two pairs and recorded in the P0.3 ledger with its reason.

The core tag and branch head were also built and measured, and are **behaviorally indistinguishable** from their
pinned counterparts: P0.1 found agreement in all 24 antlr/`-n 5` cells and identical pass sets across the DaCapo
matrix on both revisions. The choice above is therefore provenance, not behavior, and **every P0.1 number is
valid under either reading**. Those runs are retained as labelled secondary evidence and never share a table with
oracle numbers.

Beware the author date when reasoning about these revisions: `df8d30a3` was authored 2022-03-14 but committed
2022-04-10 after a rebase, so it is 9 commits **ahead** of `4d4e516c` despite appearing older; `9625c174` is 9
commits ahead of `304ce69d`. The PLDI nine are inert specifically under `--features lxr` — verified mechanically,
not just empirically: `014368ef` changes `LAZY_MU_REUSE_BLOCK_SWEEPING` from `true` to `cfg!(feature =
"lxr_lazy")`, which still evaluates true because `lxr` implies `lxr_lazy`, and `518e9bc2`/`c2657a63` gate
`max_copy` on `!cfg!(feature = "lxr")` so the else branch is byte-identical. "stw LXR" names the stop-the-world
variants, a different configuration. They nevertheless contain `rc_bits`, which makes `LOG_REF_COUNT_BITS`
feature-selectable (`lxr_rc_bits_{2,4,8}`) while preserving the default — so **RC width is a designed tunable,
default 2 bits with `MAX_REF_COUNT == 3`, and a port must parameterize it rather than hardcode it.** The head
nine are structural and not inert: the `plan/lxr` relocation trio, the concurrent-plan rework, the upstream
concurrent-marking interface switch, and bucket states, at 32 files and +1357/-1575.

`lxr-x/simplified` is explicitly **excluded**: it is a reduced fork (+1568/-2216 across 19 files versus
`lxr`) and measuring parity against it is a defect.

Full parity with the reference is a requirement, not an aspiration. Runtime changes are permitted and
preferred over GC-side approximation, but only as generic capability extensions for which LXR is the first
consumer rather than the definition.

## Operating rules

1. A step becomes `done` only in a separate verification pass after implementation, and only when the cited reference mechanism is present with the same ordering and transition provenance. Statuses are `planned`, `in_progress`, `done`, and `failed`; `in_progress` is set automatically when the Implement button spawns a child session, and is what prevents a second session being spawned for the same step.
2. Similar observable behavior is not acceptance evidence. Approximations, heuristics, and GC-side workarounds do not substitute for a reference mechanism; if a mechanism cannot be reproduced, the step fails rather than silently degrading.
3. Every mechanism declares which oracle it follows (`pldi-2022` = binding `abbdd1d` + core `df8d30a3`, or `lxr-head` = binding `0682434` + core `304ce69d`) and why; coupled mechanisms must share one oracle, because mixing revisions inside a coupled set produces a hybrid that is self-consistent nowhere. Where a claim was read from the core tag `4d4e516c` or branch head `9625c174` instead, the row says so — those builds are behaviorally indistinguishable from the pinned pairs but are not the declared basis.
4. Sweeping never parses objects. Nursery and mature reclamation read only the RC table, line/straddle metadata, and mark bits, walking at 8-byte granularity; any design that requires object-by-object heap parsing during a sweep is rejected.
5. Runtime changes follow R1-R5: generalize the mechanism not the client; zero measured cost when unused, by init-time selection rather than branching; additive and version-gated; independently defensible without LXR; performance evidence per change.
6. Every performance checkpoint compares the same binaries, machine state, workload input, duration, warmup, and run count across LXR, Workstation GC, and Server GC; pin DATAS, heap count/limit, concurrency, tiering, PGO, and ReadyToRun, then interleave collectors across invocations.
7. Report failures and excluded runs. Never select only successful LXR runs when a workload is flaky.
8. No code, status, or measurement is inherited from the abandoned `C:\github\runtimelab` prototype.
9. `src/plan/lxr/...` paths in the References fields below are **head-only**. At the PLDI oracle there is no LXR plan at all: LXR is a compile-time feature configuration of the Immix plan (`lxr = ["lxr_basic", "lxr_cm", "lxr_lazy", "lxr_evac"]` over `ix_ref_count`/`ix_concurrent_marking`), with `args.rs` at the crate root, block allocation under `policy/immix/`, concurrent marking in `util/cm.rs`, and the barrier in `mmtkFieldLoggingBarrier.cpp`. A missing PLDI path therefore never means a missing mechanism, and cross-revision comparison is mechanism-to-mechanism, never path-to-path. The compile-time-feature to runtime-`MMTK_PLAN` shift between the two oracles is itself a portability-relevant difference, since .NET selects a standalone GC at init time.
10. Never trust a reference build's exit code as evidence of what it built. `CompileThirdPartyHeap.gmk` expands `GC_FEATURES=--features $(MMTK_PLAN)` into `CARGO_BUILD_FEATURES = --features $(GC_FEATURES)`, so setting `MMTK_PLAN` emits `cargo build --features --features lxr`, which is silently ignored and yields **NoGC while appearing to be LXR**. Pass `GC_FEATURES=lxr,immix` with `MMTK_PLAN` unset — `immix` is required because the binding's `lib.rs` has no `lxr` case and the default `PlanSelector` is NoGC. Confirm the emitted `cargo build` line and the runtime banner (`barrier: FieldLoggingBarrier`, `ix_ref_count`, `lxr_*` features) before believing any measurement. Two further traps: the reference's own CI runs DaCapo at `-Xms500M -Xmx500M`, and the MarkCompact minheap table describes MarkCompact rather than LXR, so undersized heaps mimic total breakage; and under WSL `ulimit -c 0` does not stop the `core_pattern` capture pipe turning each SIGSEGV into a ~155 s stall that looks like a hang (`echo core > /proc/sys/kernel/core_pattern`).
11. Classify every reference claim by how it was obtained: `[obs-oracle]` observed on a shipped pair, `[obs-override]` observed on a build that never shipped, `[read-only]` read but never executed. Order revisions with `git merge-base`, never by date — `df8d30a3` was rebased and its author date reverses the true topology. Scan **all** log directories before asserting a clean run; a release build with `cfg(debug_assertions)` checks compiled out carries the same corrupt state silently, so absence of a panic in release is not absence of a violation. A fix-shaped commit message does not imply the fix applies to your configuration: expand the feature gates before attributing a behavior change to a commit, and confirm with a differential run rather than inference.
12. Read the artifact, never a proxy for it. This failure mode has now recurred three times across P0.1 and P0.2: a TLS failure against the public PyPI CDN was generalized into "`pip install` is blocked" without ever running the command, which also produced "no PDF rasterizer exists" from the absence of standalone binaries when the `pymupdf` package renders in-process and made the step's own rendered-page check look impossible; a positional column index silently read `SATB%` in place of `!Lazy%` on rows with a different cell count; and Table 6's column membership was argued from prose when the page could simply be rendered and read. Never record a capability as unavailable without running it to completion and pasting the failure, never index a table column by position where row shapes vary, and prefer rendering a PDF page over trusting extracted text for anything structural. A claim about an artifact must cite the artifact.
13. Absence of a check is not evidence of an invariant. The two oracles do not carry the same assertions: at PLDI the RC invariant is asserted in the write barrier slow path (`src/plan/barriers.rs:317`, gated `cfg(any(feature = "sanity", debug_assertions))`), while at `304ce69d` no barrier-side check exists and the only `zero rc count` assertion lives in `src/util/sanity/sanity_checker.rs:313` behind `cfg(feature = "sanity")` — a non-default feature the build recipe never enabled. So "HEAD never trips it" recorded an uncompiled check as a passing one, and validate-against-lxr-head must first re-instate the invariant at the validating revision before a clean run means anything. Before citing a clean run as validation, confirm the check exists and was compiled into the binary that produced it.
14. Cite reference locations at the declared oracle revision, never from the checkout. `C:\github\lxr-reference/mmtk-core` is checked out at the named `9625c174`, not at the declared oracle `304ce69d`, and the two differ in tree shape: `304ce69d` has a flat 9-file `src/plan/lxr/` with `cm.rs`, `gc_work.rs` and `remset.rs`, while `9625c174` has 13 files with a `gc_work/` subdirectory plus `block_allocation.rs`. A path read from the working tree can therefore name a file that does not exist at the oracle. All four revisions exist as objects in that clone, so cite with `git show <rev>:<path>` in `<rev>:<path>` form.
15. A citation is not evidence unless the cited code is compiled in the configuration under discussion. Locating text at a line proves only that the text is there. P0.3 cited `plan/immix/global.rs:532-534` and `plan/lxr/global.rs:377-379` as both oracles ignoring `System.gc()`; both are `cfg(feature = "nogc_no_zeroing")`, a feature in neither oracle's default set and never enabled by the build recipe, so neither line is compiled. The live paths are `memory_manager.rs:686` to `mmtk.rs:436` to `util/heap/gc_trigger.rs:143` at HEAD, which sets the flag and requests the collection, and at PLDI the trait default `plan/global.rs:590-598`, whose body is entirely commented out. Dead code that reads correctly is the sharpest form of this trap, and a mechanical citation checker cannot catch it because the text resolves. Establish that a cited line is reachable in the built configuration before treating it as behavior, and state the configuration alongside the citation.

## P0 — Parity contract, reference oracle, and measurement baseline

- **Status:** planned
- **Summary:** Establish what parity means before writing any collector code: build both candidate oracles, extract the paper's real acceptance targets, enumerate every mechanism to be ported, and capture honest built-in GC baselines.

### P0.1 — Pin and build both reference revisions

- **Status:** done
- **Summary:** Both oracle pairs built under WSL2 and verified genuinely LXR by runtime banner rather than exit code; HEAD is fully observable, PLDI is not, and the mechanism-organized diff with per-mechanism oracle recommendations and coupled sets is delivered in `docs/design/lxr-port/`.
- **Correctness:** HEAD `(0682434, 304ce69d)` passes 96/96 release runs with zero crashes or panics; PLDI `(abbdd1d, df8d30a3)` **fails outright** at 3/8 and 5/8 single-iteration and 1/8 and 2/8 sustained, tripping its own barrier assertion `assert!(old.is_null() || rc::count(old) != 0, "zero rc count")` at `plan/barriers.rs:317` in `FieldLoggingBarrier::slow` — a field overwrite whose old target already has RC zero, gated by `cfg(any(sanity, debug_assertions))`, which is why release SIGSEGVs on the same corrupt state instead of panicking. The instability is **not** explained by revision skew: a differential run at core `4d4e516c` agreed with the pin in all 24 antlr/`-n 5` cells and produced the same pass set, disproving the hypothesis that the pin's `Fix stw LXR` commits were the difference. **Corrected in P0.3:** HEAD's clean runs are not evidence that the RC invariant holds there, because at `304ce69d` no barrier-side check exists at all — the only `zero rc count` assertion is in `util/sanity/sanity_checker.rs:313` behind `cfg(feature = "sanity")`, which is not a default feature and was not enabled by the build recipe, so it was compiled out. The comparison was never run.
- **Benchmarks:** Reference-only numbers, no .NET comparison; recorded per configuration with invocation counts and every failure listed. Open anomaly carried to P0.3: hsqldb p99 of 0.34-0.40 ms on PLDI versus 54-56 ms on HEAD like-for-like at `-n 5` and 2000 MB, two orders of magnitude on the metric LXR exists for, from one benchmark on a noisy host.
- **Dependencies:** none
- **References:** `docs/design/lxr-port/`; oracle pairs (`abbdd1d`, `df8d30a3`) and (`0682434`, `304ce69d`); secondary builds at core `4d4e516c` and `9625c174`, behaviorally indistinguishable; `plan/barriers.rs:315`; `src/args.rs` `LAZY_MU_REUSE_BLOCK_SWEEPING`

### P0.2 — Extract paper acceptance targets from the PDF

- **Status:** done
- **Summary:** Targets extracted and independently re-verified against the local PDF; the paper is the arXiv Extended Version of 1 Nov 2022, not the PLDI proceedings, so citations name arXiv table and page numbers and proceedings numbering is not assumed to match.
- **Correctness:** Every quoted number cites a table or figure in the local PDF, cross-read four ways including a rendered-page check, with the coordinator independently confirming Tables 1, 5, 6 and 7 from the pixels; two errata were found in the paper itself, Table 7's `!Lazy%` summary rows printing a minimum of 22 above a maximum of 2 against a true range of 0 to 22, and a 90th-percentile column that section 4 promises "in tabular form" but Table 4 does not contain.
- **Benchmarks:** Verified targets are throughput geomean `0.958` versus G1 at 2x heap, LXR-only pause p50/p95 of `5.0`/`7.5` ms mean and `3.0`/`4.7` ms geomean, reclamation split `94.3`/`0.6`/`5.1` from the mean row, and barrier overhead `1.016` geomean measured against a no-barrier full-heap Immix build rather than against G1.
- **Dependencies:** P0.1
- **References:** `C:\github\lxr-reference\paper\2210.17175.pdf`; `docs/design/lxr-port/P0.2-paper-targets.md`; Tables 1, 4, 5, 6, 7

### P0.3 — Build the mechanism parity ledger

- **Status:** in_progress
- **Summary:** One row per reference mechanism recording the declared oracle, its coupled-mechanism group, file and line in that revision, the required .NET realization, and the evidence that will close it.
- **Correctness:** A row with no recorded oracle or group is incomplete; rows in a coupled group share one oracle, every row carries an `[obs-oracle]`/`[obs-override]`/`[read-only]` provenance tag, and the ledger rather than prose is what P9.1 audits. Because PLDI trips its own `zero rc count` barrier assertion under load, RC and SATB rows follow a specify-from-PLDI, validate-against-HEAD rule, and this step decides explicitly whether root-causing that violation is on the critical path.
- **Benchmarks:** None directly; the ledger defines which mechanisms later benchmark deltas must be attributable to. It also inherits P0.1's open hsqldb p99 anomaly (PLDI 0.34-0.40 ms versus HEAD 54-56 ms) as a question to resolve or retire rather than carry silently.
- **Dependencies:** P0.1, P0.2
- **References:** `docs/design/lxr-port/P0.1-mechanism-diff.md`; paper §2-§3; head `mmtk-core/src/plan/lxr/*` versus the PLDI `lxr` feature closure over `src/policy/immix/*`, `src/util/rc.rs`, `src/util/cm.rs`; `mmtk-openjdk/openjdk/barriers/*`

### P0.4 — Build the benchmark harness and scenario matrix

- **Status:** planned
- **Summary:** Stand up a harness in this repository covering low-allocation compute, allocation churn, long-lived cache, cyclic garbage, pointer chasing, multi-thread throughput, ASP.NET request load, pinning-heavy I/O, lifecycle semantics, and large-object pressure.
- **Correctness:** Each scenario has a deterministic success marker, timeout, crash capture, and collector-identity check; a run whose collector cannot be confirmed is invalid.
- **Benchmarks:** Coordinated-omission-free latency; pin `GCDynamicAdaptationMode`, heap count/limit, concurrency, tiering, PGO, and ReadyToRun; interleave collectors and publish ratios with confidence intervals alongside raw distributions.
- **Dependencies:** none
- **References:** paper §4 methodology

### P0.5 — Measure Workstation and Server GC baselines

- **Status:** planned
- **Summary:** Capture baselines for both built-in collectors across the full scenario matrix.
- **Correctness:** Baselines are reproducible across repeated sessions on the same machine state, with variance recorded rather than averaged away.
- **Benchmarks:** Workstation and Server GC only; LXR does not exist yet, so this phase deliberately has no LXR column and no early number can be mistaken for progress.
- **Dependencies:** P0.4
- **References:** paper §4; `docs/design/coreclr/botr/garbage-collection.md`

## P1 — Runtime enablement as generic GC-contract capabilities

- **Status:** planned
- **Summary:** Extend the GC contract with capabilities any collector could use — a parameterized barrier family, exact allocation notification, object reference enumeration, and negotiated header bits — then prove they cost nothing when unused.

### P1.1 — GC capability negotiation and barrier-family contract

- **Status:** planned
- **Summary:** Let a GC declare which barrier family and optional runtime services it requires, and have the EE select and patch the corresponding implementations at initialization.
- **Correctness:** The built-in GC declares the existing card-table family and its generated code does not move; existing standalone GCs build and run unchanged against the extended contract.
- **Benchmarks:** Codegen diff proving byte-identical output for the built-in collectors, plus the P0.4 matrix as a regression check.
- **Runtime changes:** Adds a capability-declaration surface and a structurally described side-metadata slot-log barrier family parameterized by metadata base, granularity shift, polarity, and slow-path helper, covering LXR's unlog bit, SATB/deletion barriers, and generational field-log barriers; additive and gated by a `GC_INTERFACE_MINOR_VERSION` bump, never reshaping existing members.
- **Dependencies:** P0.3
- **References:** `src/coreclr/gc/gcinterface.h:9,14,49-56`; `mmtk-core/src/plan/barriers.rs`

### P1.2 — Implement the slot-log barrier family on x64

- **Status:** planned
- **Summary:** Implement the family on x64 in MASM and GAS, reproducing the reference fast path's shape while reading its parameters from the descriptor rather than hardcoding them.
- **Correctness:** Barrier stress shows no lost or duplicated log entries under contention; volatile and SIMD state is preserved across the fast and slow paths; an unused family leaves the built-in barrier untouched.
- **Benchmarks:** Barrier-only microbenchmark and allocation rate against the stock barrier, plus end-to-end low-allocation compute and allocation churn scenarios.
- **Runtime changes:** Adds x64 Windows and Linux assembly for the family — side byte load at base plus slot shifted right, zero-byte early-out, bit extract, polarity compare, tail-call to the configured slow helper — selected through the existing write-barrier patching path so an unused family costs nothing.
- **Dependencies:** P1.1
- **References:** `mmtk-openjdk/openjdk/barriers/mmtkFieldBarrier.cpp:78-127`; `src/coreclr/vm/writebarriermanager.cpp`; `src/coreclr/vm/amd64/JitHelpers_FastWriteBarriers.asm`

### P1.3 — Cover all reference-store paths for the family

- **Status:** planned
- **Summary:** Emit the family barrier on every managed reference-store path and generalize the reference's bulk fast path into a family-level operation.
- **Correctness:** A store-path audit shows no reference write reaching the heap without its barrier, including struct copies containing references and interlocked reference operations.
- **Benchmarks:** Array copy, span fill, and struct-copy microbenchmarks against the stock barrier, plus the multi-thread throughput scenario.
- **Runtime changes:** Extends RyuJIT emission and the helper set across `CORINFO_HELP_ASSIGN_REF`, checked and unchecked variants, `CORINFO_HELP_BULK_WRITEBARRIER`, `Array.Copy`, `Span`/`Unsafe`, and interlocked reference operations; adds a family-level bulk operation that scans the destination metadata a machine word at a time and skips when already fully set, so any slot-log consumer inherits it.
- **Dependencies:** P1.2
- **References:** `mmtk-core/src/plan/lxr/barrier.rs:209-232`; `src/coreclr/jit/`; `src/coreclr/inc/corinfo.h`

### P1.4 — Add an exact allocation-complete notification service

- **Status:** planned
- **Summary:** Provide an opt-in per-object callback fired after header initialization and before the object escapes to managed code, because neither existing hook establishes exact birth metadata.
- **Correctness:** Every allocation path — object, array, string, boxed value, fast and slow — delivers exactly one notification, and no object becomes reachable from managed code before its notification completes.
- **Benchmarks:** Allocation microbenchmarks at several object sizes and the allocation churn scenario, comparing registered and unregistered configurations.
- **Runtime changes:** Adds an opt-in allocation-complete callback carrying object, size, and flags across the x64 fast helpers and slow paths, generalizing beyond LXR to any RC collector, exact allocation sampling, and heap-birth metadata; the inline allocator keeps its bump-pointer shape and the unregistered path targets byte-identical codegen, with any residual cost measured in P1.7 rather than assumed negligible.
- **Dependencies:** P1.1
- **References:** `src/coreclr/gc/gcinterface.h`; `src/coreclr/vm/gchelpers.cpp`; `src/coreclr/vm/amd64/JitHelpers_Fast.asm`

### P1.5 — Add GC-side object reference enumeration

- **Status:** planned
- **Summary:** Let GC code enumerate an object's reference slots without an EE round trip per object, closing a plain gap in the standalone-GC contract that every such collector pays for.
- **Correctness:** Enumeration matches the EE's own view for every layout — arrays of references, structs with references, generics, and collectible types — verified against the existing scanning path.
- **Benchmarks:** Scan-rate microbenchmark over representative object graphs, plus pointer chasing and long-lived cache scenarios where scanning dominates.
- **Runtime changes:** Exposes an inlinable, bulk/streaming reference-slot enumeration API to GC code; confirmed absent from this fork today, and required because RC increment processing and tracing both sit directly on this path.
- **Dependencies:** P1.1
- **References:** `src/coreclr/vm/object.h`; `src/coreclr/vm/methodtable.h`; `src/coreclr/gc/gcinterface.h`

### P1.6 — Define negotiated GC-reserved object header bits

- **Status:** planned
- **Summary:** Define how a GC reserves object-header bits and how those bits coexist with the sync block index, thin lock, and hash code, then prove the placement before any copying code exists.
- **Correctness:** Reserved bits survive every runtime operation that touches the header — thin lock inflation, hash code assignment, sync block creation — under targeted stress, with no observable interference in either direction.
- **Benchmarks:** Lock and hash-code microbenchmarks proving no regression, since these paths are contended and header-sensitive.
- **Runtime changes:** Adds a header-bit negotiation mechanism serving any copying or concurrent collector; MMTk keeps two forwarding bits in header available bits and spins on a `BEING_FORWARDED` state, whereas .NET's `ObjHeader` is already contended, making this the highest-risk unknown in the port and the gate on all of P6.
- **Dependencies:** P1.1
- **References:** `mmtk-core/src/util/object_forwarding.rs:8-11`; `src/coreclr/vm/syncblk.h`; `src/coreclr/vm/object.h:106`

### P1.7 — Gate runtime changes on measured zero regression

- **Status:** planned
- **Summary:** Prove that the contract changes cost nothing measurable on the built-in collectors before any LXR code depends on the new surface.
- **Correctness:** Codegen diffs are byte-identical wherever that was claimed in P1.1-P1.6; any divergence is investigated as a design defect rather than annotated as acceptable.
- **Benchmarks:** Workstation and Server GC across the full P0.4 matrix, plus barrier and allocation microbenchmarks, compared against the P0.5 baselines on identical machine state.
- **Runtime changes:** No new surface; this is the enforcement point for the R2 no-cost-when-unused and R5 evidence-per-change rules, and a regression here is fixed in P1.1-P1.6 rather than accepted.
- **Dependencies:** P0.5, P1.2, P1.3, P1.4, P1.5, P1.6
- **References:** paper §5.1 barrier overhead; P0.5 baselines

## P2 — Side metadata and Immix substrate

- **Status:** planned
- **Summary:** Build the address-to-metadata layer and the Immix block/line heap the whole collector sits on, at the reference's exact geometry and granularity.

### P2.1 — Build the side metadata framework

- **Status:** planned
- **Summary:** Provide address-to-metadata mapping with atomic bit and byte operations plus bulk word reads for every metadata spec the collector needs.
- **Correctness:** Concurrent updates to neighboring bits within one byte never lose an update, verified by a dedicated contention stress test at every declared granularity.
- **Benchmarks:** Metadata access microbenchmarks for single-bit, single-byte, and bulk word paths, since RC and sweeping are dominated by them.
- **Dependencies:** P1.1
- **References:** `mmtk-core/src/util/metadata/side_metadata/`; `mmtk-core/src/util/rc.rs:13-26`

### P2.2 — Implement block and line geometry and the state machine

- **Status:** planned
- **Summary:** Implement 32 KiB blocks, 256 B lines, 128 lines per block, the block state machine, and the phase epoch that distinguishes mutator from GC phases.
- **Correctness:** Block state transitions match the reference's allowed set; the phase epoch is bumped at both pause start and release, and drives nursery, reusing, and GC-reusing predicates identically.
- **Benchmarks:** Block acquisition and release rates under allocation churn.
- **Dependencies:** P2.1
- **References:** `mmtk-core/src/policy/immix/block.rs:76-98,300-374`; `mmtk-core/src/policy/immix/line.rs:20-29`

### P2.3 — Implement the sticky 2-bit RC table and straddle lines

- **Status:** planned
- **Summary:** Implement two reference-count bits per 8-byte granule, saturating at 3 and never decremented once sticky, plus straddle-line marking for objects spanning lines.
- **Correctness:** Neighboring counts in the same byte survive every compare-and-swap; sticky counts are never decremented; straddle lines and the continuation sentinel match the reference for multi-line objects.
- **Benchmarks:** RC update microbenchmark under contention, and the allocation churn scenario where increment volume dominates.
- **Dependencies:** P2.1, P2.2
- **References:** `mmtk-core/src/util/rc.rs:13-26`; `mmtk-core/src/util/constants.rs:122-124`; note .NET's `MIN_OBJECT_SIZE` is 24 B versus MMTk's 8 B

### P2.4 — Implement allocation, holes, and recycled lines

- **Status:** planned
- **Summary:** Implement bump allocation within holes, hole discovery by bulk RC-table read, fresh versus recycled block acquisition, and mutator block ownership.
- **Correctness:** Hole discovery finds exactly the free line runs the reference would find, and a line handed out during concurrent marking bumps its reuse counter, which P6.4 depends on.
- **Benchmarks:** Allocation throughput on fresh versus recycled blocks, and the long-lived cache scenario where recycling dominates.
- **Dependencies:** P2.2
- **References:** `mmtk-core/src/policy/immix/block_allocation.rs`; `mmtk-core/src/policy/immix/line.rs`

### P2.5 — Implement the large object space

- **Status:** planned
- **Summary:** Implement a large object space for allocations at or above 32 KiB, with its own mark and nursery bits and a page reuse counter.
- **Correctness:** The threshold is the full block size, matching `MAX_IMMIX_OBJECT_SIZE`; large objects are never placed in Immix blocks and are released independently of block sweeping.
- **Benchmarks:** Large-object pressure scenario against both baselines.
- **Dependencies:** P2.2
- **References:** `mmtk-core/src/plan/lxr/mod.rs:11-19`; `mmtk-core/src/policy/largeobjectspace.rs`

## P3 — Work-packet scheduler and pause taxonomy

- **Status:** planned
- **Summary:** Build the ordered bucket scheduler and the four pause kinds before any RC or tracing code depends on them, because bucket ordering is the reference collector's RC correctness proof.

### P3.1 — Implement work packets and strictly ordered buckets

- **Status:** planned
- **Summary:** Implement the ordered bucket sequence in which each stage opens only once all prior stages have drained, with work stealing and reference-sized packet granularity.
- **Correctness:** Bucket opening order is enforced and asserted, since reordering or renaming buckets silently breaks RC correctness with no compile-time signal; increments land in the first STW bucket and decrements in the last.
- **Benchmarks:** Scheduler overhead and parallel scaling on the multi-thread throughput scenario.
- **Dependencies:** P2.1
- **References:** `mmtk-core/src/scheduler/work_bucket.rs:456`; stage order Unconstrained, Concurrent, ConcurrentResumable, FinishConcurrentWork, Initial, Prepare, Closure, Release, STWRCDecsAndSweep, Final

### P3.2 — Implement the pause taxonomy and per-pause schedules

- **Status:** planned
- **Summary:** Implement the four pause kinds — Full, InitialMark, FinalMark, RefCount — and the schedule each one installs.
- **Correctness:** Each pause kind schedules exactly the reference's bucket set, including disabling unnecessary buckets for RefCount pauses.
- **Benchmarks:** Pause count and duration distribution by kind across the scenario matrix.
- **Dependencies:** P3.1
- **References:** `mmtk-core/src/plan/concurrent/mod.rs:16-31`; `mmtk-core/src/plan/lxr/global.rs:738-789`

### P3.3 — Implement the deferred concurrent bucket

- **Status:** planned
- **Summary:** Implement the double-buffered bucket queue where deferred work is added to the inactive queue and published by a flip once mutators resume.
- **Correctness:** Work deferred during a pause becomes visible only after the flip at GC finish; getting the buffering backwards either defeats laziness or drops the work entirely, so both directions are tested explicitly.
- **Benchmarks:** Pause duration with lazy decrements enabled versus disabled, isolating what deferral actually buys.
- **Dependencies:** P3.1
- **References:** `mmtk-core/src/scheduler/`; `mmtk-core/src/plan/lxr/args.rs:109`

### P3.4 — Implement lazy sweeping completion counters

- **Status:** planned
- **Summary:** Implement the RAII completion counter with a decrement-specific sub-counter that schedules mature block sweeping at decrement-zero and runs the next-GC decision at overall-zero.
- **Correctness:** No block is released while lazy work referencing it remains outstanding, and the next pause's kind is decided only after the previous GC's lazy work drains; this is also the mechanism that keeps finalizable promotion ahead of block release.
- **Benchmarks:** Lazy-decrement backlog depth and its effect on subsequent pause times.
- **Dependencies:** P3.3
- **References:** `mmtk-core/src/lib.rs:79-143`

## P4 — Coalescing reference counting core

- **Status:** planned
- **Summary:** Implement the coalescing RC engine — log buffers, increment and decrement packets, delayed root decrements, and metadata-only nursery reclamation.

### P4.1 — Implement mutator log buffers and flush

- **Status:** planned
- **Summary:** Implement the per-mutator increment and decrement buffers the barrier feeds, with the reference's capacity and flush points.
- **Correctness:** Increments carry slot addresses and decrements carry old target objects, not the reverse; buffers flush on full, at every pause start, and at thread teardown, with no entries lost at teardown.
- **Benchmarks:** Barrier take rate and buffer flush frequency under allocation churn and multi-thread throughput.
- **Dependencies:** P1.7, P2.3, P3.1
- **References:** `mmtk-core/src/plan/lxr/barrier.rs:61-116`; `mmtk-core/src/plan/lxr/args.rs:86-98`

### P4.2 — Implement increment packets and first promotion

- **Status:** planned
- **Summary:** Process increment slots by loading the current target, unlogging that exact slot, and incrementing, treating a zero-to-one transition as first promotion.
- **Correctness:** First promotion stamps the object start, arms field unlog bits in bulk, marks straddle lines, and recursively enqueues child slots; recursive increments drain synchronously within the packet so they cannot leak past the bucket boundary.
- **Benchmarks:** Increment rate and promotion rate against the paper's reported figures.
- **Dependencies:** P4.1
- **References:** `304ce69d:src/plan/lxr/rc.rs:40` (`ProcessIncs`); paper §3.1

### P4.3 — Implement decrement packets and recursive death

- **Status:** planned
- **Summary:** Process decrements so that a one-to-zero transition runs dead-object handling, recursively decrementing children and queueing the containing mature block.
- **Correctness:** No object memory is zeroed and only metadata is cleared; large objects are released through their own path; sticky counts are never decremented.
- **Benchmarks:** Decrement processing cost and its share of pause time, plus the cyclic garbage scenario where RC alone cannot reclaim.
- **Dependencies:** P4.1
- **References:** `304ce69d:src/plan/lxr/rc.rs:669` (`ProcessDecs`); PLDI `df8d30a3:src/util/rc.rs:747` (`impl ProcessDecs`)

### P4.4 — Implement one-epoch-delayed root decrements

- **Status:** planned
- **Summary:** Delay root decrements exactly one epoch by swapping the current and previous root sets at release and draining the previous set in the following pause.
- **Correctness:** Roots incremented in an epoch are never decremented in that same epoch, because doing so races recursive increments; the swap happens at release and nowhere else.
- **Benchmarks:** Root set size over time and its effect on pause duration.
- **Dependencies:** P4.2, P4.3
- **References:** `mmtk-core/src/plan/lxr/global.rs:314-318,911-931`

### P4.5 — Implement nursery sweeping without object parsing

- **Status:** planned
- **Summary:** Reclaim young objects purely from block state and bulk RC-table reads, never parsing the heap.
- **Correctness:** The sweep never calls any size or layout query and walks at 8-byte granularity; reclaimed regions match what the reference would reclaim on identical heaps.
- **Benchmarks:** Nursery reclamation rate and sweep cost as a share of pause time; this path is where an object-parsing design would show up as cost proportional to live heap.
- **Dependencies:** P2.4, P4.2
- **References:** `304ce69d:src/policy/immix/rc_work.rs:128` (`SweepBlocksAfterDecs`); `304ce69d:src/policy/immix/block.rs:634` (`rc_dead`), `:658` (`sweep`)

## P5 — SATB concurrent trace and cycle reclamation

- **Status:** planned
- **Summary:** Add the concurrent snapshot-at-the-beginning trace that reclaims the cycles reference counting cannot, including the safety invariant that binds it to the RC path.

### P5.1 — Implement the InitialMark snapshot

- **Status:** planned
- **Summary:** Turn the incremented root set into the concurrent trace's initial worklist and enable concurrent-marking state as mutators resume.
- **Correctness:** Concurrent marking state and remembered-set recording turn on at pause end, not pause start, matching the reference's ordering.
- **Benchmarks:** InitialMark pause duration against the paper's reported pause distribution.
- **Dependencies:** P3.2, P4.2
- **References:** `304ce69d:src/plan/lxr/cm.rs:328` (`ProcessModBufSATB`); paper §3.2

### P5.2 — Implement concurrent, preemptible trace packets

- **Status:** planned
- **Summary:** Implement self-splitting trace packets that drain greedily between pauses and flush their remainder when an STW pause interrupts.
- **Correctness:** An interrupted packet resumes without losing or double-visiting objects; the packet count reaching zero is the termination signal that makes the next pause a FinalMark.
- **Benchmarks:** Concurrent marking duration and its mutator overhead, plus pause p99 during marking.
- **Dependencies:** P5.1
- **References:** `304ce69d:src/plan/lxr/cm.rs:32` (`LXRConcurrentTraceObjects`), `:286` (its `GCWork` impl)

### P5.3 — Implement the mark-and-scan-on-delete invariant

- **Status:** planned
- **Summary:** Ensure reference counting never deletes an unmarked object while a snapshot trace is underway, by marking the dying object and force-marking its unmarked children into the tracer's worklist.
- **Correctness:** This is the paper's core safety property; a targeted test constructs the race — an object dying by RC during concurrent marking with unmarked children — and shows the children survive. The barrier's decrement buffer is shared into both the SATB modbuf processing and decrement processing, with modbuf processing ordered before the decrement bucket.
- **Benchmarks:** Frequency of the mark-on-delete path and its cost, plus the cyclic garbage scenario.
- **Dependencies:** P4.3, P5.2
- **References:** PLDI `df8d30a3:src/util/rc.rs:747` (`impl ProcessDecs`), `:870-874` (packet dispatch); HEAD `304ce69d:src/plan/lxr/rc.rs:669` (`ProcessDecs`); paper §3.3

### P5.4 — Implement FinalMark

- **Status:** planned
- **Summary:** Flush mutator barrier buffers, clear concurrent-marking state inside the pause, rescan roots, run the weak reference closures, process the mature evacuation remembered set, and schedule mature sweeping.
- **Correctness:** An interrupting emergency GC forces the trace to finish inside the STW pause rather than being abandoned; concurrent-marking state is cleared inside the pause, not after it.
- **Benchmarks:** FinalMark pause duration against the paper's reported figures, which the paper places at a few milliseconds.
- **Dependencies:** P5.2
- **References:** `mmtk-core/src/plan/lxr/global.rs`; paper §3.2

### P5.5 — Implement dead-cycle and mature sweeping

- **Status:** planned
- **Summary:** Reclaim objects with a nonzero reference count that the trace did not mark, then release blocks whose contents are entirely dead.
- **Correctness:** Dead-cycle handling deliberately does not recurse, unlike the RC death path; sweeping parses no objects; whole-block release happens only after the bulk dead check passes.
- **Benchmarks:** Cycle reclamation share of total reclamation, compared against the paper's Young/Old-RC/SATB split.
- **Dependencies:** P3.4, P5.4
- **References:** `304ce69d:src/policy/immix/rc_work.rs:181` (`SweepDeadCycles`); `304ce69d:src/policy/immix/block.rs:658` (`sweep`)

## P6 — Evacuation and defragmentation

- **Status:** planned
- **Summary:** Add copying — nursery evacuation during increment processing and mature evacuation driven by fragmentation — on top of the header-bit decision made in P1.6.

### P6.1 — Implement the copy and forwarding protocol

- **Status:** planned
- **Summary:** Implement the three forwarding states and the claim protocol in which a thread that loses the race spins until forwarding completes.
- **Correctness:** There is no read barrier, so every reader must resolve forwarding explicitly; an audit confirms every closure and verification site resolves forwarding before testing liveness.
- **Benchmarks:** Copy throughput and forwarding contention rate under multi-thread allocation.
- **Dependencies:** P1.6, P2.2
- **References:** `mmtk-core/src/util/object_forwarding.rs:8-11`

### P6.2 — Implement nursery evacuation inside increment processing

- **Status:** planned
- **Summary:** Copy surviving nursery objects during the promotion edge operation, rewriting stable slots in place, with a pause-budget escape hatch.
- **Correctness:** Source blocks stay unavailable while forwarding metadata is still observable; exceeding the pause budget during increment processing disables evacuation for the remainder of that pause rather than truncating it mid-object.
- **Benchmarks:** Nursery survival rate, copy volume, and pause duration with and without nursery evacuation.
- **Dependencies:** P4.2, P6.1
- **References:** `304ce69d:src/plan/lxr/rc.rs:40` (`ProcessIncs`, nursery evacuation path); paper §3.1

### P6.3 — Implement mature evacuation candidate selection

- **Status:** planned
- **Summary:** Select defragmentation candidates from sparsely populated chunks and from individually fragmented blocks scored by dead bytes, greedily until the copy budget is met.
- **Correctness:** Thresholds match the reference, including the chunk occupancy threshold, its doubling under emergency, and the half-block admission floor outside a full collection.
- **Benchmarks:** Fragmentation over time and committed-versus-live ratio against both baselines.
- **Dependencies:** P5.4, P6.1
- **References:** `mmtk-core/src/plan/lxr/mature_evac.rs:230-285`

### P6.4 — Implement the reuse-counter-tagged remembered set

- **Status:** planned
- **Summary:** Record remembered-set entries tagged with the line reuse counter captured at record time and validate that tag at replay.
- **Correctness:** An entry whose reuse counter no longer matches is discarded, as are slots inside the collection set and slots in unallocated blocks; a targeted test reuses a line during concurrent marking and confirms the stale entry is rejected.
- **Benchmarks:** Remembered-set size, stale-entry rate, and replay cost.
- **Dependencies:** P2.4, P6.3
- **References:** `304ce69d:src/plan/lxr/remset.rs:39` (`MatureEvecRemSet`)

### P6.5 — Implement mature evacuation and source block release

- **Status:** planned
- **Summary:** Feed surviving remembered-set slots into the ordinary STW closure and release defragmentation source blocks once their live content has been copied out.
- **Correctness:** Source blocks are released unconditionally after evacuation, and no slot referencing them survives unforwarded, verified by a post-evacuation heap audit.
- **Benchmarks:** Defragmentation effectiveness, evacuation ratio, and its pause cost.
- **Dependencies:** P6.4
- **References:** `304ce69d:src/plan/lxr/mature_evac.rs:19` (`EvacuateMatureObjects`)

## P7 — Managed object lifecycle

- **Status:** planned
- **Summary:** Implement the .NET lifecycle semantics the reference does not have — weak reference ordering, dependent handles, finalization, and pinning — as a deliberate superset of LXR.

### P7.1 — Implement weak reference semantics

- **Status:** planned
- **Summary:** Implement CoreCLR's handle clearing order, which the reference implementation does not model.
- **Correctness:** Short weak handles clear before f-reachability and long weak and weak-interior handles clear after; ref-counted handles consult the EE callback; surviving weak locations are relocation-pinned without becoming roots.
- **Benchmarks:** Lifecycle semantics scenario, which must pass identically on all three collectors.
- **Dependencies:** P5.4
- **References:** `src/coreclr/gc/objecthandle.cpp`; `docs/design/coreclr/botr/garbage-collection.md`

### P7.2 — Implement dependent handles to a fixed point

- **Status:** planned
- **Summary:** Resolve ephemeron dependencies to a fixed point in both the mark phase and the RC increment phase, and again after finalization promotion.
- **Correctness:** A dependent-handle chain of arbitrary depth is fully resolved in one collection, not progressively across several.
- **Benchmarks:** Dependent-handle-heavy variant of the lifecycle scenario, measuring iteration count to fixed point.
- **Dependencies:** P7.1
- **References:** `src/coreclr/gc/objecthandle.cpp`

### P7.3 — Implement the finalization lifecycle

- **Status:** planned
- **Summary:** Implement registration at allocation-complete, suppression, re-registration, f-reachability, resurrection, and normal-before-critical ordering, with deferred removal from the RC world.
- **Correctness:** Block release never outruns finalizable promotion, which is why this depends on the lazy-sweeping counters; resurrection during finalization keeps the object and its transitive closure alive.
- **Benchmarks:** Lifecycle semantics scenario including resurrection and critical finalizers.
- **Dependencies:** P3.4, P7.1
- **References:** `src/coreclr/vm/finalizerthread.cpp`; `src/coreclr/gc/gcinterface.h`

### P7.4 — Honour pinning and interior pointers

- **Status:** planned
- **Summary:** Consume the pinning and interior-pointer flags the root scanning callback already reports, without extending any runtime surface.
- **Correctness:** Ordinary roots are never blanket-pinned, which would permanently exclude them from first promotion and mature evacuation; callback-local roots may still be forwarded and rewritten during the callback while the slot is valid.
- **Benchmarks:** Pinning-heavy I/O scenario, comparing pinned-object counts and fragmentation against both baselines.
- **Dependencies:** P6.2
- **References:** `src/coreclr/gc/gcinterface.h` `GC_CALL_INTERIOR` and `GC_CALL_PINNED`

## P8 — Triggers, predictors, and tunables

- **Status:** planned
- **Summary:** Implement the feedback loop that decides when to collect and which pause to run, at the reference's exact formulas and defaults.

### P8.1 — Implement survival and mature-live predictors

- **Status:** planned
- **Summary:** Implement the survival ratio predictor with its rising and falling bias variants, and the mature live predictor fed only after FinalMark or Full pauses.
- **Correctness:** Weights and update points match the reference exactly, including which pause kinds feed which predictor.
- **Benchmarks:** Prediction error over time on the allocation churn and long-lived cache scenarios.
- **Dependencies:** P4.5
- **References:** `mmtk-core/src/plan/lxr/mod.rs:24-124`

### P8.2 — Implement collection trigger conditions

- **Status:** planned
- **Summary:** Implement the ordered trigger conditions from heap-full through the young allocation cap.
- **Correctness:** Conditions are evaluated in the reference's order, since an earlier condition firing changes which pause kind is chosen.
- **Benchmarks:** Collection frequency and heap occupancy at trigger across the matrix.
- **Dependencies:** P8.1
- **References:** `mmtk-core/src/plan/lxr/global.rs:125-179`

### P8.3 — Implement the pause selection state machine

- **Status:** planned
- **Summary:** Implement pause selection: finish an in-flight marking cycle, then emergency and user-triggered collections, then the cycle hint, otherwise a RefCount pause.
- **Correctness:** The cycle hint is computed only after the previous collection's lazy sweeping completes, behind the same condition variable the reference uses.
- **Benchmarks:** Pause kind mix compared against the paper's reported distribution.
- **Dependencies:** P5.4, P8.2
- **References:** `mmtk-core/src/plan/lxr/global.rs:738-789`

### P8.4 — Expose the tunable surface and configuration

- **Status:** planned
- **Summary:** Expose the reference's tunables through `DOTNET_` configuration at the reference defaults.
- **Correctness:** Defaults match the reference exactly — trace threshold 20, RC stop percent 15, chunk defragmentation percent 32, max survival 128 MB, buffer size 1024, defragmentation headroom 5 percent, lazy decrements on, nursery and mature evacuation on.
- **Benchmarks:** Sensitivity of each tunable on at least one scenario where it is load-bearing.
- **Dependencies:** P8.3
- **References:** `mmtk-core/src/plan/lxr/args.rs`

## P9 — Parity audit and performance convergence

- **Status:** planned
- **Summary:** Independently verify every ledger row against its declared oracle, then close the gap to the paper's reported pause, throughput, and footprint behavior.

### P9.1 — Run an independent mechanism parity audit

- **Status:** planned
- **Summary:** Re-verify every ledger row against the revision that row declares as its oracle, performed by someone other than the implementer of that row.
- **Correctness:** The audit does not trust prior status text; coupled groups are checked for oracle consistency, not only row-by-row correctness, and any unrecorded deviation reopens its step.
- **Benchmarks:** None directly; the audit gates whether later performance numbers describe LXR at all.
- **Dependencies:** P0.3, P8.4
- **References:** P0.3 ledger; both oracle revisions

### P9.2 — Converge pause times

- **Status:** planned
- **Summary:** Close the gap to the paper's pause behavior: frequent light RefCount pauses with a few milliseconds for InitialMark and FinalMark.
- **Correctness:** Pause improvements never come from deferring work indefinitely; lazy backlog is reported alongside pause figures.
- **Benchmarks:** Report p50 through p99.99 and maximum, never averages alone, across the full matrix against both baselines, but read as a characterization rather than a win condition: the paper's only comparative pause table shows LXR's pauses longer than G1's at every percentile while its query latency is far better, so application-observed latency is the acceptance signal and pause distribution is reported alongside it.
- **Dependencies:** P9.1
- **References:** paper §5.2, Figure 5; Table 1 pause versus query-latency split; `docs/design/lxr-port/P0.2-paper-targets.md`

### P9.3 — Converge throughput

- **Status:** planned
- **Summary:** Close the throughput gap against both built-in collectors, isolating the barrier's own contribution.
- **Correctness:** Throughput wins are rejected if verifier offenders, crashes, hangs, or lifecycle failures increase.
- **Benchmarks:** Full matrix against Workstation and Server GC, with a barrier-isolation measurement against the paper's reported barrier overhead, noting that the paper's throughput advantage is heap-dependent — `0.97` at 1.3x, `0.96` at 2x, and `1.01` at 6x, where LXR is slower than G1 — and that its `1.016` barrier geomean sits inside a noise floor of roughly plus or minus three percent.
- **Dependencies:** P9.1
- **References:** paper §5.1, §5.3; Table 5 heap-size sensitivity; `docs/design/lxr-port/P0.2-paper-targets.md`

### P9.4 — Converge footprint and reclamation mix

- **Status:** planned
- **Summary:** Bring working set, committed-versus-live ratio, fragmentation, and the reclamation split into line with the paper.
- **Correctness:** The reclamation split is measured, not inferred, and attributed to Young, Old-RC, and SATB paths separately.
- **Benchmarks:** Compare the measured split against the paper's reported proportions, plus footprint against both baselines.
- **Dependencies:** P9.1
- **References:** paper §5.4, Tables 5-7

### P9.5 — Reproduce the paper's ablations and sensitivity study

- **Status:** planned
- **Summary:** Run the heap-size sensitivity sweep and the mechanism ablations to show each mechanism earns its place.
- **Correctness:** Each ablation degrades in the direction and rough magnitude the paper reports; an ablation that changes nothing indicates the mechanism is not actually wired in.
- **Benchmarks:** Heap-size sweep plus ablations for nursery evacuation, mature evacuation, concurrent marking, RC width, and lazy decrements.
- **Dependencies:** P9.2, P9.3, P9.4
- **References:** paper §5.5, Figure 7

## P10 — Hardening and platform matrix

- **Status:** planned
- **Summary:** Extend beyond x64, prove long-duration reliability, add diagnostics, and decompose the work into upstreamable pull requests.

### P10.1 — Port the barrier family to the remaining architectures

- **Status:** planned
- **Summary:** Extend the slot-log barrier family to the remaining five architectures and NativeAOT, as family implementations rather than LXR-specific ports.
- **Correctness:** Each architecture passes the same barrier stress and store-path audit as x64, with volatile and SIMD state preserved per calling convention.
- **Benchmarks:** Per-architecture no-regression measurement matching the gate established for x64.
- **Runtime changes:** Adds arm64, arm, i386, loongarch64, and riscv64 implementations of the barrier family in both MASM and GAS plus NativeAOT, so a future consumer of the family inherits all six architectures rather than porting again; includes the ReadyToRun implication that precompiled images bake in barrier helper calls.
- **Dependencies:** P9.1
- **References:** `src/coreclr/vm/arm64/`, `src/coreclr/vm/i386/`, `src/coreclr/vm/loongarch64/`, `src/coreclr/vm/riscv64/`; `src/coreclr/nativeaot/Runtime/`

### P10.2 — Run long-duration reliability stress

- **Status:** planned
- **Summary:** Run multi-hour stress across the scenario matrix with verifiers enabled.
- **Correctness:** No tolerated crashes, hangs, or leaks; every failure is root-caused rather than retried.
- **Benchmarks:** Drift in pause distribution, footprint, and fragmentation over hours, which short runs cannot reveal.
- **Dependencies:** P9.1
- **References:** `src/tests/GC/`; existing GC stress infrastructure

### P10.3 — Add diagnostics and observability

- **Status:** planned
- **Summary:** Emit events and counters for the pause taxonomy and the metrics the paper reports.
- **Correctness:** Emitted counters agree with internal state under stress; the pause taxonomy is representable in existing GC event schemas or is extended deliberately.
- **Benchmarks:** Increment rate, barrier take rate, sticky count distribution, reclamation split, and lazy-decrement backlog, all exposed without measurably perturbing the workload.
- **Dependencies:** P9.1
- **References:** `src/coreclr/vm/eventtrace.cpp`; `src/coreclr/gc/gcevents.h`

### P10.4 — Decompose the work into upstream-ready pull requests

- **Status:** planned
- **Summary:** Split the work so the generic runtime capabilities land independently of LXR, each defensible on its own merits.
- **Correctness:** Each runtime capability has its own issue, motivation, and performance evidence, and would be a reasonable change to make even if the collector never merges.
- **Benchmarks:** Per-pull-request performance evidence, since core-runtime changes require measurements in the description.
- **Dependencies:** P9.5, P10.1
- **References:** `CONTRIBUTING.md`; repository pull request conventions
