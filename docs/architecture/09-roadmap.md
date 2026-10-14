# 09. Project Roadmap, Milestones, and Verification Strategy

## 1. Directory Structure

Swift-Stack is organized as a unified, modular Swift package adhering to strict data-oriented layer separation:

```
swift-stack/
├── Package.swift
├── README.md
├── docs/
│   └── architecture/
│       ├── 00-overview-and-principles.md       # DOD philosophy, pointer tax, 80-90% parity rule
│       ├── 01-frontend.md                      # SourceManager, SWAR lexer, SoA TokenBuffer, ParseTree
│       ├── 02-semantic-analysis.md             # TypePool, canonical TypeId, C23 semantics, staged checker
│       ├── 03-intermediate-representation.md   # AIR flat SSA, Swift semantics, 7 core optimizer passes
│       ├── 04-backend.md                       # LIR, maximal munch tiling, linear scan regalloc, encoders
│       ├── 05-assembler.md                     # Native assemblers (AMD64, ARM64, RV64) & extensible targets
│       ├── 06-linker.md                        # Modern linker, typed symbols, redundancy elimination
│       ├── 07-debugging-and-sdi.md             # SDI format (RDI inspired), CUD unwinding, expression eval
│       ├── 08-runtime-and-stdlib.md            # Tier 0/1 runtimes, port concurrency, system floor
│       └── 09-roadmap.md                       # Milestones M0-M5, verification & testing strategy
├── Sources/
│   ├── Driver/               # CLI driver, target triple dispatch, multi-core worker coordinator
│   ├── Source/               # SourceManager, sentinel padding, 32-bit SourceLocations
│   ├── Lex/                  # SWAR token scanner, TokenBuffer (SoA), C23 preprocessor & #embed
│   ├── Parse/                # Carbon-style postorder ParseTree, Pratt expression parser
│   ├── Sem/                  # Symbol tables, TypePool, TypeId handles, staged constraint solver
│   ├── AIR/                  # Arena IR instruction arrays, basic blocks, SSA value handles
│   ├── Opt/                  # 7 high-throughput passes (Mem2Reg, SCCP, GVN, ARC, Inliner, LICM, ADCE)
│   ├── LIR/                  # Low-Level Machine IR, virtual registers, live intervals
│   ├── Codegen/              # Instruction selection, linear scan regalloc, encoders (AMD64, ARM64, RV64)
│   ├── Asm/                  # Native assemblers (AMD64, ARM64, RV64) & extensible target framework
│   ├── Linker/               # Data-oriented linker, typed symbols, chunk relocations, SDI emission
│   └── Runtime/
│       ├── Tier0/            # Freestanding Embedded Swift runtime shims (0 heap allocation)
│       └── Tier1/            # Concurrency TaskExecutor (croi port / kqueue / epoll), witness tables
└── Tests/
    ├── Unit/                 # Subsystem unit tests (Lexer, Parser, TypePool, RegAlloc, Linker)
    ├── Differential/         # Automated differential testing against swiftc & clang
    ├── Corpora/              # Benchmark sources (Todhchai OS, ISO C23 test suite, assembly stubs)
    └── Bench/                # Performance parity & compilation throughput benchmarking harnesses
```

---

## 2. Phased Implementation Milestones

```
M0: In-Memory Foundation & SWAR Lexer (Weeks 1–3)
  ├── Sentinel SourceManager & SWAR Lexer (> 600 MB/s per core)
  └── Postorder Carbon-style ParseTree (> 300 MB/s per core)
           │
           ▼
M1: C23 Preprocessor & Native Assemblers (Weeks 4–7)
  ├── Full ISO C23 preprocessor with zero-copy #embed binary slices
  ├── Standalone Native Assemblers: AMD64, ARM64, RV64
  └── Pluggable AssemblerTarget framework for future architectures
           │
           ▼
M2: Modern Linker & SDI Debug Format (Weeks 8–11)
  ├── Typed, module-scoped symbol resolution (ModuleId, AtomId, TypeSignatureHash)
  ├── Single-emission debug info (.todh_debug / SDI) & Compact Unwind Descriptors (CUD)
  └── Target layouts: Todhchai (0x1000000 static ELF), FreeBSD, Linux, macOS
           │
           ▼
M3: Tier 0 Embedded Swift Pipeline (Weeks 12–15)
  ├── Swift grammar in postorder ParseTree & Staged Bidirectional Type Checker
  ├── Non-copyable types (~Copyable), ownership (consume/borrow), and deinit barriers
  └── Compile Todhchai kernel-adjacent services (userboot, devmgr, fs)
           │
           ▼
M4: 80–90% Optimizer & Multi-Target Codegen (Weeks 16–19)
  ├── The 7 core optimization passes (Mem2Reg, SCCP, GVN, ARC cancel, Inliner, LICM, ADCE)
  ├── Linear scan regalloc with interval splitting; AMD64, ARM64, RV64 encoders
  └── Benchmark binary runtime performance parity against LLVM -O2
           │
           ▼
M5: Tier 1 Full Swift, Port Concurrency & Self-Hosting (Weeks 20–25)
  ├── Port-driven TaskExecutor: croi port (td_executor_port), FreeBSD kqueue, Linux epoll
  ├── Metatype tables, standard collections, FoundationEssentials
  └── Full Self-Hosting: Swift-Stack compiles Swift-Stack!
```

### Detailed Milestone Objectives

#### Milestone 0: In-Memory Foundation & SWAR Lexer
- **Deliverables:**
  - `SourceManager` with 64-byte sentinel zero-padding.
  - SoA `TokenBuffer` (10 bytes/token) with SWAR scanner.
  - Carbon-style `ParseTree` (9 bytes/node) with postorder array construction.
- **Success Criteria:** Lexing throughput $\ge 600$ MB/s per core; parsing throughput $\ge 300$ MB/s per core; zero heap allocations per token/node.

#### Milestone 1: C23 Preprocessor & Native Assemblers
- **Deliverables:**
  - Complete ISO/IEC 9899:2024 C23 preprocessor with zero-copy `#embed`.
  - C23 type analysis in `TypePool` (`_BitInt`, `constexpr`, `nullptr`, attributes).
  - Standalone assemblers for **AMD64** (Intel/AT&T), **ARM64** (UAL), and **RV64** (with compressed C extension).
  - Pluggable `AssemblerTarget` protocol for future architecture expansion.
- **Success Criteria:** Assembles OS entry stubs (`system/sys/floor/start.S`), context switches, and vector routines into relocatable sections without external assemblers.

#### Milestone 2: Modern Linker & SDI Debug Format
- **Deliverables:**
  - In-process, multi-threaded native linker (`swift-ld` / `todh-ld`).
  - Typed, module-scoped symbol resolution (`ModuleId, AtomId, TypeSignatureHash`) preventing silent aliasing.
  - Direct emission of memory-mappable SDI (`.todh_debug`) in $< 5$ ms.
  - Compact Unwind Descriptors (CUD) providing microsecond stack unwinding.
  - Verified static ELF emission for Todhchai (base `0x1000000`, 256 KiB stack, PT_TLS) and hosted linking on FreeBSD, Linux, and macOS.
- **Success Criteria:** Links full system binaries in $< 50$ ms; zero DWARF duplication tax.

#### Milestone 3: Tier 0 Embedded Swift Pipeline
- **Deliverables:**
  - Swift grammar support in postorder `ParseTree`.
  - Staged bidirectional type checker (Stage 1 fast path).
  - Non-copyable types (`~Copyable`), `consuming`/`borrowing` parameter validation.
  - Static `.rodata` metadata emission (zero dynamic metadata).
- **Success Criteria:** Successfully compiles Todhchai's Tier 0 Embedded Swift components (`userboot`, `devmgr`, `fs`) producing identical execution behavior to `swiftc -enable-experimental-feature Embedded`.

#### Milestone 4: 80–90% Optimizer & Multi-Target Codegen
- **Deliverables:**
  - Implement the 7 core optimization passes in `Opt/`: Mem2Reg, SCCP, GVN, ARC cancellation, Inlining, LICM, ADCE.
  - Linear scan register allocator with loop boundary interval splitting.
  - Machine encoders for AMD64 (x86-64-v2), ARM64 (AArch64), and RV64 (RV64GC with 16-bit compressed instructions).
- **Success Criteria:** Binary benchmark execution speed reaches **80% to 90% of LLVM `-O2`** across compute and string benchmarks, while compile throughput exceeds **100,000 lines/sec per core**.

#### Milestone 5: Tier 1 Full Swift, Port Concurrency & Self-Hosting
- **Deliverables:**
  - Full Swift runtime integration: generics, protocol witness tables, and standard collections.
  - Port-driven `TaskExecutor` sleeping on `td_executor_port` (croi), `kqueue` (FreeBSD/macOS), and `epoll` (Linux).
  - Compile Todhchai's desktop shell (Tracker, Deskbar, Terminal).
  - **Self-Hosting Verification:** Swift-Stack compiles its own complete codebase; the resulting self-hosted binary builds the compiler suite with bitwise-identical output.

---

## 3. Verification & Testing Strategy

### 1. Differential Testing Oracle

Following Todhchai Principle 29, host `swiftc` and `clang` serve as differential testing oracles:
- **Test Runner:** An automated harness takes thousands of test cases from:
  - The official Swift test suite (`test/`).
  - The GCC / Clang C23 conformance test suite.
  - Todhchai OS native source tree and standalone assembly stubs.
- **Differential Execution:**
  ```
  Source ──┬──► swiftc / clang  ──► Binary A ──► Execute ──► stdout / exit code A
           │                                                        ▲
           │                                                        │ Assert Equal
           └──► swift-stack     ──► Binary B ──► Execute ──► stdout / exit code B
  ```
- Any discrepancy in exit codes, stdout, or floating-point precision is flagged immediately as a defect.

### 2. Compilation Throughput & Memory Budgets

Every commit is benchmarked in continuous integration against fixed performance budgets:
- **Zero Regression Rule:** If a commit decreases lexing/parsing throughput or increases peak resident memory (RSS) by more than 2%, CI fails.
- **Artifact Metrics Tracked:**
  - Lexing MB/s
  - Parsing MB/s
  - Peak RSS during 100K LOC build
  - Link time in milliseconds
  - Final executable binary size and runtime benchmark score.
