# LXR port — design record

Working notes for a from-scratch port of the **LXR** garbage collector to .NET/CoreCLR.

LXR is described in Zhao, Blackburn & McKinley, *Low-Latency, High-Throughput Garbage Collection*
(PLDI 2022, [arXiv:2210.17175](https://arxiv.org/abs/2210.17175)). It combines coalescing reference
counting with a concurrent SATB trace over an Immix heap. The reference implementation is the
`lxr` branch of MMTk (`mmtk-core` + `mmtk-openjdk`).

These documents record research and design decisions. **No collector code has landed yet.**

## Parity contract

Full parity with the reference is a requirement, not an aspiration. Approximations, heuristics and
GC-side workarounds are not acceptable substitutes for a reference mechanism.

Two revisions are in scope as **parity oracles**:

| oracle | mmtk-core | date | role |
|---|---|---|---|
| `lxr-pldi-2022` | `4d4e516c` | 2022-04-08 | contemporaneous with the paper |
| `lxr` branch head | `9625c174` | 2026-05-06 | ~4 further years of development |

The oracle is chosen **per mechanism**, and each choice is recorded with its reason. Coupled
mechanisms share one oracle. `lxr-x/simplified` is explicitly excluded.

## Documents

| document | contents |
|---|---|
| [`P0.1-reference-build.md`](P0.1-reference-build.md) | What was pinned, the resolved (mmtk-core, mmtk-openjdk, OpenJDK, rustc) tuple per revision, the exact build recipe, and what could not be built or run |
| [`P0.1-mechanism-diff.md`](P0.1-mechanism-diff.md) | The mechanism-organised diff between the two oracles — direct input to the P0.3 parity ledger |
| [`P0.1-benchmarks.md`](P0.1-benchmarks.md) | Reference pause and throughput behaviour on both revisions, and the characterisation of the PLDI instability |
| [`scripts/`](scripts/) | The clone, build, sanity and benchmark scripts actually used |

## P0.1 outcome in one paragraph

Both revisions were pinned as independent clones and built on OpenJDK in WSL2/Ubuntu 22.04, release
and fastdebug, each against its **task-named oracle** rather than the revision its binding pins.
**HEAD runs all 8 DaCapo 2006 benchmarks cleanly** — 3 invocations × 5 iterations at 500 MB and
2000 MB, plus a fastdebug assertion pass — with no crashes and no assertion failures. **PLDI does
not**: it completes single-iteration runs of 5 of 8 benchmarks and crashes with SIGSEGV under
sustained execution, faulting alternately in the write barrier and the concurrent marking trace.
The paper-contemporaneous oracle is therefore usable for **short observation and for reading**, but
HEAD is the only revision that can be observed across the whole benchmark set. Every mechanism
recommendation that selects PLDI carries that caveat.

## Repository scope

This is design documentation in a `dotnet/runtime` fork. Bulk build state — clones, OpenJDK trees,
JDK images, benchmark jars — lives outside version control. Nothing here builds or ships as part of
the runtime.
