# Swift-Stack: A Data-Oriented Swift & C23 Toolchain

> A clean-room implementation of Swift 6.x and ISO C23: frontends, semantic analysis, optimizer, code generators, assemblers, linker, debug-info format and runtimes. Every persistent compiler data structure is a flat, index-addressed table (Data-Oriented Design).

**Status:** Milestone M0 (Foundation & Measurement) and Milestone M0.5 (Vertical Slice) complete. The toolchain compiles, links, and runs a C subset corpus end-to-end to standalone static Linux x86-64 executables with zero external dependencies, passing all 5 CI verification gates. See [M0.5 Vertical Slice Report](docs/architecture/milestones/M0.5-vertical-slice.md) and [Baselines](Benchmarks/baselines/).

---

## 1. Summary

Production compilers such as `swiftc`, Clang and LLVM represent programs as graphs of heap-allocated, pointer-linked objects. Swift-Stack stores the same information in struct-of-arrays tables addressed by 32-bit handles (`TokenId`, `NodeId`, `TypeId`, `InstId`). The tables are arena-backed, and work is processed in batches across cores.

The bet is that this layout, together with a deliberately small optimizer, gives an order-of-magnitude faster compile and acceptable runtime performance. Both halves of that bet are measured, not assumed ([14](docs/architecture/14-measurement-methodology.md)).

### Goals

1. **Languages.**
   - Swift 6.x in two tiers: Tier 0, the Embedded subset; Tier 1, full Swift within the stated non-goals.
   - Swift macros, through executable compiler plugins. Todhchai's IPC and audio SDK are the first-party users.
   - Portable SIMD (`SIMDn<T>`, C vector extensions) lowered to native vector code on every target. Auto-vectorization is an optional add-on.
   - ISO/IEC 9899:2024 (C23), plus the GNU/Clang extensions needed to parse system headers.
2. **A self-contained toolchain.** Built-in assemblers (x86-64, AArch64, RV64) and linker. No LLVM, GNU `as` or external linker.
3. **Compile-time throughput** and bounded memory: see the budgets below.
4. **Runtime performance hypothesis.** Optimized code within 80–90% of `clang -O2` (C) and `swiftc -O` (Swift), from a small, well-chosen set of optimizations.
5. **First-class debugging.** A memory-mappable debug format (SDI) and cheap frame-pointer-based unwinding.
6. **Determinism.** Identical inputs give bitwise-identical outputs at any thread count.
7. **Self-hosting.**

### Targets

- **Primary:** Todhchai OS on the croi capability microkernel (x86-64, AArch64, RV64). Static ELF images at `0x1000000`, port-driven Swift concurrency.
- **Secondary / hosts:** Linux, FreeBSD, macOS.
- **ISA floors:** x86-64 at the 2013 Mac Pro (Ivy Bridge) class, i.e. `x86-64-v2` + AVX; AArch64 `armv8-a`; RV64 RVA23.

### Notable non-goals (v1)

C++, Objective-C interop, Windows, binary compatibility with `swiftc`-built Swift libraries, in-process (library) macro plugins, C intrinsics headers. Auto-vectorization is optional rather than required. The full list and the decisions behind it are in [00 §4–5](docs/architecture/00-overview-and-principles.md).

---

## 2. Architecture

```
  Swift (*.swift)            C23 (*.c, *.h)                 Assembly (*.s, *.S)
        │                          │                                  │
        ▼                          ▼                                  ▼
┌──────────────────────────────────────────────────┐   ┌──────────────────────────┐
│ FRONTEND                                    01   │   │ ASSEMBLERS           05  │
│ SourceManager (sentinel-padded buffers)          │   │ x86-64: AT&T, Intel later│
│ SoA TokenBuffer · C23 preprocessor (#embed)      │   │ AArch64 · RV64 (RVA23)   │
│ Postorder SoA ParseTree                          │   │ .S via C23 preprocessor  │
└──────────────────────────────────────────────────┘   └──────────────────────────┘
        │                                                             │
        ▼                                                             │
┌──────────────────────────────────────────────────┐                  │
│ SEMANTIC ANALYSIS                       02 · 10  │                  │
│ Name resolution · TypePool (32-bit TypeId)       │                  │
│ Swift staged type checker (swiftc-equivalent)    │                  │
│ C23 semantics · Clang-free C import into Swift   │                  │
│ Macro expansion via plugin processes (16)        │                  │
│ Typed SemIR                                      │                  │
└──────────────────────────────────────────────────┘                  │
        │                                                             │
        ▼                                                             │
┌──────────────────────────────────────────────────┐                  │
│ AIR — flat SSA IR + OPTIMIZER           03 · 11  │                  │
│ Ownership, lifetime & no-alloc checks · ARC      │                  │
│ Core: Mem2Reg, SROA, SCCP, GVN, LICM, idioms     │                  │
│ Swift: specialize, inline, ARC opt, check elim.  │                  │
│ SIMD vector ops · optional loop vectorizer (17)  │                  │
└──────────────────────────────────────────────────┘                  │
        │                                                             │
        ▼                                                             │
┌──────────────────────────────────────────────────┐                  │
│ BACKEND                                     04   │                  │
│ LIR · tiling isel · SSA linear-scan regalloc     │                  │
│ Encode: shared encoders (also used by Asm)       │                  │
└──────────────────────────────────────────────────┘                  │
        │  in-memory RelocatableObject (Object module)                │
        └────────────────────────────┬────────────────────────────────┘
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│ LINKER                                                                       06 │
│ In-memory objects + foreign .o/.a · optional link-time type checks              │
│ Parallel per-input-section relocation · deterministic layout                    │
│ Todhchai static ELF · Linux/FreeBSD ELF · macOS Mach-O                          │
└─────────────────────────────────────────────────────────────────────────────────┘
        │                                               │
        ▼                                               ▼
┌──────────────────────────────────────┐   ┌──────────────────────────────────────┐
│ RUNTIMES & STDLIB            08 · 12 │   │ DEBUGGING                         07 │
│ Tier 0 (Embedded) · Tier 1 (Full)    │   │ SDI (.ss_debug), mmap-able           │
│ Upstream stdlib sources as input     │   │ Compact unwind descriptors (CUD)     │
│ Executor: croi port/kqueue/epoll     │   │ DWARF for host debuggers             │
└──────────────────────────────────────┘   └──────────────────────────────────────┘
```

---

## 3. Architecture documents

All chapters are in [`docs/architecture/`](docs/architecture/). Each one has a Status, Goals, Non-goals, Design, Alternatives considered, and Open questions.

| # | Chapter | Covers |
|---|---|---|
| 00 | [Overview, Principles, and Key Decisions](docs/architecture/00-overview-and-principles.md) | Goals, non-goals, decision log D1–D11, DOD principles (layout follows transforms, zero is nil, hot-path rules), `Column` storage, targets, execution model |
| 01 | [Frontend](docs/architecture/01-frontend.md) | Source buffers, SWAR lexing, SoA tokens, C23 preprocessor and `#embed`, postorder parse tree |
| 02 | [Semantic Analysis](docs/architecture/02-semantic-analysis.md) | TypePool, C23 semantics, Swift staged type checking, Todhchai feature profile, strict concurrency, C/Swift interop |
| 03 | [AIR and Optimizer](docs/architecture/03-intermediate-representation.md) | Flat SSA IR, mandatory lowering (ownership, lifetime, performance-annotation checks), optimization pipeline, `-Osize` |
| 04 | [Backend](docs/architecture/04-backend.md) | LIR, instruction selection, register allocation, calling conventions, encoders |
| 05 | [Assemblers](docs/architecture/05-assembler.md) | x86-64, AArch64, RV64 assemblers; directives, macros, relaxation |
| 06 | [Linker](docs/architecture/06-linker.md) | Object model, symbol resolution and type checks, layout, relocation, output formats |
| 07 | [Debugging and SDI](docs/architecture/07-debugging-and-sdi.md) | SDI format, location lists, CUD unwinding, debugger tooling |
| 08 | [Runtime](docs/architecture/08-runtime-and-stdlib.md) | Tier 0/1 runtimes, executors, process startup, TLS |
| 09 | [Roadmap and Verification](docs/architecture/09-roadmap.md) | Module graph, milestones M0–M8 and optional track V, differential testing, fuzzing |
| 10 | [Semantic IR and Name Resolution](docs/architecture/10-semantic-ir-and-name-resolution.md) | Typed SemIR, scopes and lookup, operator folding, deterministic IDs |
| 11 | [Generics and Runtime Metadata](docs/architecture/11-generics-and-runtime-metadata.md) | Monomorphization vs metadata passing, witness tables, existentials, mangling, Swift CC |
| 12 | [Standard Library Strategy](docs/architecture/12-standard-library-strategy.md) | Upstream stdlib sources (pinned to Swift 6.4), compiler-known entities, runtime entry points, Embedded subset |
| 13 | [Modules and Incremental Builds](docs/architecture/13-modules-and-incremental-builds.md) | `.ssmodule` format, separate compilation, dependency tracking, caching |
| 14 | [Measurement Methodology](docs/architecture/14-measurement-methodology.md) | Budgets, metric definitions, corpora, CI gates |
| 15 | [Driver and Diagnostics](docs/architecture/15-driver-and-diagnostics.md) | Personalities, job scheduling, plugin host, diagnostics engine, build-system integration |
| 16 | [Swift Macros](docs/architecture/16-macros.md) | Plugin protocol, expansion buffers, lookup ordering, caching, Todhchai use cases |
| 17 | [SIMD and Vectorization](docs/architecture/17-simd-and-vectorization.md) | ISA floors, portable SIMD lowering, legalization tables, loop idioms, optional auto-vectorizer |
| 18 | [Data Catalog](docs/architecture/18-data-catalog.md) | Every persistent table: producers, consumers, access patterns, sizes, layout choice (hypotheses until measured) |

---

## 4. Performance budgets & Empirical Status

Budgets from [14](docs/architecture/14-measurement-methodology.md) are tracked continuously against the reference machine ([reference-x86_64.md](Benchmarks/machines/reference-x86_64.md)):

| ID | Metric | Budget Target | Measured Swift-Stack | Baseline Comparison | Status |
|---|---|---|---|---|---|
| **B1** | Lexing throughput (single core) | ≥ 600 MB/s (≤ 5.8 cyc/B) | **727 MB/s** (Swift)<br>**774 MB/s** (C23) | `swiftc`: ~11.6 MB/s<br>`clang -E`: ~65.6 MB/s | **MET** |
| **B2** | Lex + parse throughput (single core) | ≥ 300 MB/s (≤ 11.7 cyc/B) | **322 MB/s** (9.37 cyc/B combined) | `clang -fsyntax-only`: ~45 MB/s | **MET** |
| **B3** | End-to-end debug build (single core) | ≥ 100,000 lines/s (≤ 35,000 cyc/line) | **13.5 – 14.4 ms** total ($1.5 – 2.0\text{ ms}$ in-process pipeline) | `clang -O0` + external linker: 23 – 28 ms | **MET** ($1.7\times$ faster) |
| **B5** | Link time, system-service image | < 50 ms | **< 1 ms** (in-process static ELF writer) | External `ld.bfd` / `ld.lld` | **MET** (slice) |
| **B8** | Peak RSS (100K-line build) | < 256 MB | **21.3 MB** RSS (cold) | `swiftc` + LLVM (> 500 MB) | **MET** |
| **D6** | Output Determinism | 100% bitwise reproducible | Verified byte-identical across runs | Clang / LLD | **MET** |

---

## 5. Building & Verification

Requires a Swift 6.2+ toolchain on Linux (x86-64).

### Build the toolchain
```sh
swift build -c release
```

### Run the test suite
```sh
swift test
```

### Run Continuous Integration (all 5 gates)
```sh
bash Scripts/ci-check.sh
```

### Compile & run C programs end-to-end
```sh
# Compile and execute natively in one step:
./.build/release/swift-stack Benchmarks/corpora/c-subset/08_recursion.c -o /tmp/fib --run

# Inspect stage timings and compiler table statistics:
./.build/release/swift-stack Benchmarks/corpora/c-subset/10_collatz.c --stats --time-phases

# Run micro-benchmark repetition tests:
./.build/release/swift-stack Benchmarks/corpora/c-synth/synth_50k.c --bench
```

