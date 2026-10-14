# Swift-Stack: High-Performance Data-Oriented Swift & C23 Toolchain

> **Mission:** A clean-room, full-specification implementation of the modern Swift (6.x+) and C23 language stacks—from frontend parsers to native assemblers, middle-end optimizers, code generators, and linkers—architected entirely on **Data-Oriented Design (DOD)** principles.

---

## 1. Executive Summary

Current production compiler stacks (LLVM, Clang, and `swiftc`) are dominated by deeply nested object graphs, pointer-chasing abstract syntax trees (ASTs), polymorphic node hierarchies, and heavy intermediate representations that thrash hardware CPU caches and incur massive compilation overhead.

**Swift-Stack** discards the object-oriented compiler model in favor of flat arrays, struct-of-arrays (SoA) memory layouts, index handles (`TokenId`, `NodeId`, `TypeId`, `InstId`), contiguous arena allocators, and batch-processing dataflow pipelines.

### Primary Objectives & Tradeoffs

1. **Full Specification Compliance:**
   - **Modern Swift (6.x+):** Embedded Swift (Tier 0) and Full Swift (Tier 1), covering value semantics, non-copyable types (`~Copyable`), ownership, generics, protocol witnesses, async/await concurrency, and Swift ABI calling conventions.
   - **ISO/IEC 9899:2024 (C23):** Modern C23 features including `constexpr`, `typeof`, `nullptr`, attributes (`[[...]]`), `_BitInt(N)`, `#embed`, auto type inference, and preprocessor enhancements.
   - **Native Standalone Assemblers:** Built-in assemblers for AMD64, ARM64, and RV64 to assemble OS entry stubs (`_start`), context switching routines, and vector kernels without GNU `as` or external tools.
2. **Data-Oriented Architecture (DOD):**
   - Zero per-node heap allocation. Zero reference-counted AST objects.
   - Elimination of the **"Pointer Tax"** (3–5% compile-time penalty per layer of pointer indirection).
   - Cache-conscious postorder parse arrays and dense linear SSA instruction tables.
   - Highly parallel multi-core batch processing using work-stealing job schedulers.
3. **The 80–90% Binary Parity Rule:**
   - Achieving 80–90% of LLVM `-O2` runtime performance is accepted and prioritized whenever it yields 10x–50x faster compilation speeds and eliminates hundreds of thousands of lines of fragile optimization passes.
4. **Target Platforms:**
   - **Primary Native Target:** [Todhchai OS](file:///home/jkane/Projects/OS/todhchai) running on the [croi](file:///home/jkane/Projects/OS/croi) capability microkernel (x86_64, AArch64, RISC-V 64). Produces static ELF executables mapped at `0x1000000`, 256 KiB stack, `--eh-frame-hdr`, static TLS, and direct integration with croi port-driven concurrency.
   - **Secondary Target & Hosts:** POSIX systems (**FreeBSD**, **Linux**, **macOS**) for hosted builds, cross-compilation, and developer workstations.
5. **Radical Linker Modernization (Handmade Hero Insights):**
   - Eliminates redundant work between the compiler, linker, and OS loader.
   - Introduces **typed, module-scoped symbol binding** (`ModuleId, SymbolId, TypeSignatureHash`), permanently preventing silent symbol hijacking and link-time type mismatches.
   - Single-emission debug info: types declared in headers are written once per module, eliminating the DWARF DIE deduplication tax.
6. **First-Class Zero-Latency Debugging (RAD Debugger / RDI Insights):**
   - Generates native **SDI (Swift-Stack Debug Info)** / `.todh_debug` directly from the linker in $< 5$ ms.
   - Flat, memory-mappable binary layout with $O(\log N)$ address lookup in nanoseconds, compact zero-bytecode unwind descriptors (CUD), and microsecond expression evaluation.

---

## 2. Architectural Blueprint

```
+---------------------------------------------------------------------------------------------------+
|                                          SOURCE INPUTS                                            |
|   Swift Source (*.swift)      |       C23 Source (*.c, *.h)       |     Assembly Source (*.s, *.S)|
+---------------------------------------------------------------------------------------------------+
             │                                   │                                     │
             ▼                                   ▼                                     ▼
+-----------------------------------------------------------------+   +-----------------------------+
|                         FRONTEND TIER                           |   |      NATIVE ASSEMBLERS      |
|  - SourceManager: Contiguous buffers with 64 zero-sentinel bytes|   |  - AMD64 (Intel & AT&T)     |
|  - TokenBuffer (SoA): 1-byte kind, 1-byte trivia, 4-byte offsets|   |  - ARM64 (Standard UAL)     |
|  - ParseTree: Postorder Carbon-style flat array (kind, tok, sz) |   |  - RV64 (Base + 16-bit C)   |
|  - C23 Preprocessor: Zero-alloc token stream & #embed slices    |   |  - Extensible Target Engine |
+-----------------------------------------------------------------+   +-----------------------------+
                                 │                                                     │
                                 ▼                                                     │
+-----------------------------------------------------------------+                    │
|                 SEMANTIC ANALYSIS & TYPE POOL                   |                    │
|  - InternPool: Dense string interning, atom tables              |                    │
|  - TypePool: 32-bit TypeId handles into dense descriptor arenas |                    │
|  - Swift Staged Type Checker: Bidirectional fast path + solver  |                    │
|  - C23 Semantic Analyzer: ISO C23 rules, _BitInt, constexpr     |                    │
|  - Zero-Cost C/Swift Bridge: Direct C symbol import (No Clang)  |                    │
+-----------------------------------------------------------------+                    │
                                 │                                                     │
                                 ▼                                                     │
+-----------------------------------------------------------------+                    │
|           ARENA INTERMEDIATE REPRESENTATION (AIR / SSA)         |                    │
|  - Flat instruction table: InstId, Opcode, ValueId, BlockId     |                    │
|  - Swift Lowering: Ownership, borrowing, ARC, witness tables    |                    │
|  - High-Efficiency Optimizer (80-90% Parity):                   |                    │
|      * Mem2Reg / SSA Construction     * Constant Prop (SCCP)    |                    │
|      * Global Value Numbering (GVN)   * ARC / Borrow Cancel     |                    │
|      * ADCE & CFG Simplification      * Fast Inlining & Devirt  |                    │
+-----------------------------------------------------------------+                    │
                                 │                                                     │
                                 ▼                                                     │
+-----------------------------------------------------------------+                    │
|                     BACKEND CODE GENERATION                     |                    │
|  - LIR (Low-level Machine IR): Architecture register instrs     |                    │
|  - Instruction Selection: Fast maximal-munch DAG/tree tiling    |                    │
|  - Register Allocation: Linear Scan with loop interval splitting|                    │
|  - Target Encoders: x86-64-v2, AArch64 (ARM64), RISC-V (RV64GC) │                    │
|  - In-Memory Relocatable Sections (.text, .rodata, .rela.text)  |                    │
+-----------------------------------------------------------------+                    │
                                 │                                                     │
                                 ▼ (Zero-Copy Buffer Handoff)                          │
                                 └──────────────────────┬──────────────────────────────┘
                                                        │
                                                        ▼
+---------------------------------------------------------------------------------------------------+
|                                 DATA-ORIENTED NATIVE LINKER                                       |
|  - Direct in-memory buffer consumption (zero intermediate disk .o files)                          |
|  - Typed, module-scoped symbol binding (ModuleId, AtomId, TypeSignatureHash)                     |
|  - Parallel section layout and concurrent relocation chunk processing                             |
|  - Target Formats:                                                                                |
|      * Todhchai Native: Static ELF64 (base 0x1000000, 256 KiB stack, PT_TLS)                      |
|      * FreeBSD Host: FreeBSD ELF64 (ELFOSABI_FREEBSD, .note.tag, /libexec/ld-elf.so.1)            |
|      * Linux Host: Standard ELF64 (/lib64/ld-linux-x86-64.so.2)                                  |
|      * macOS Host: Mach-O 64-bit                                                                  |
+---------------------------------------------------------------------------------------------------+
                                 │                                       │
                                 ▼                                       ▼
+---------------------------------------------------+ +---------------------------------------------+
|               EXECUTABLE & RUNTIMES               | |       FIRST-CLASS DEBUGGING (SDI)           |
|  - Tier 0 Embedded Swift: 0 heap overhead, libsys | |  - SDI (.todh_debug): Memory-mapped layout  |
|  - Tier 1 Full Swift: Port TaskExecutor          | |  - Zero DWARF merging tax; < 5 ms emission  |
|    (croi td_executor_port / kqueue / epoll)       | |  - Compact Unwind Descriptors (CUD): < 2 us |
|  - C23 Libc & System Floor startup (_start)       | |  - Microsecond live expression evaluator    |
+---------------------------------------------------+ +---------------------------------------------+
```

---

## 3. Detailed Architecture Specifications

The complete architectural design is documented across 10 cohesive chapters in [`docs/architecture/`](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/):

1. [**00. Overview, Philosophy & DOD Principles**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/00-overview-and-principles.md): Core tenets, memory layout invariants, the "Pointer Tax" elimination, 80–90% binary parity rule, and target platforms (Todhchai OS, FreeBSD, Linux, macOS).
2. [**01. Frontend: Source, Lexing, and Parsing**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/01-frontend.md): Sentinel-padded source buffers, SWAR lexing, 10-byte SoA `TokenBuffer`, postorder 9-byte `ParseTree`, and C23 preprocessor with zero-copy `#embed`.
3. [**02. Semantic Analysis, Type Systems & Interop**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/02-semantic-analysis.md): Canonical `TypeId` and dense `TypePool`, staged bidirectional type checking, complete C23 semantics (`_BitInt`, `constexpr`), ownership verification (`~Copyable`), and Clang-free C/Swift bridging.
4. [**03. Middle-End IR & High-Throughput Optimizer**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/03-intermediate-representation.md): Flat SSA instruction table (`AIR`), native Swift ARC and borrowing semantics, and the 7 core optimization passes for 80–90% parity.
5. [**04. Machine Codegen & Target Backends**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/04-backend.md): Tiling instruction selection, linear-scan register allocation with loop interval splitting, and native machine encoders for AMD64, ARM64, and RV64.
6. [**05. Native Assembler Architecture**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/05-assembler.md): Built-in assemblers for AMD64 (Intel & AT&T), ARM64 (UAL), and RV64 (with compressed 16-bit C extension) with an extensible target framework.
7. [**06. Data-Oriented Native Linker**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/06-linker.md): Radical elimination of linker redundancies (Handmade insights), typed module-scoped symbol binding, single-emission debug info, concurrent relocations, and zero-copy in-memory object handoff.
8. [**07. First-Class Debugging & SDI Architecture**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/07-debugging-and-sdi.md): Memory-mapped SDI format (RAD Debugger inspired), direct linker emission in $< 5$ ms, compact zero-bytecode unwind descriptors (CUD), and microsecond expression evaluation.
9. [**08. Runtime Systems & Todhchai OS Integration**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/08-runtime-and-stdlib.md): Tier 0 Embedded runtime (0 heap allocations), Tier 1 port-driven concurrency executor (croi `td_executor_port`, FreeBSD/macOS `kqueue`, Linux `epoll`), and the system floor startup contract.
10. [**09. Project Roadmap, Milestones & Testing**](file:///home/jkane/Projects/lang/swift-stack/docs/architecture/09-roadmap.md): Staged milestones from M0 (foundation) to M5 (self-hosting), differential testing against `swiftc`/`clang`, and performance benchmarks.

---

## 4. Key Performance Budgets

Following Todhchai's principle 28 ("Slower is a claim to measure, not assume") and principle 4 ("Memory is the app's to arrange"):

| Metric | Target Budget | Reference Comparison |
|---|---|---|
| **Lexing Throughput** | > 600 MB/s per core (> 5 GB/s on 8 cores) | `swiftc`: ~40 MB/s |
| **Parsing Throughput** | > 300 MB/s per core (> 2.5 GB/s on 8 cores) | `swiftc`: ~35 MB/s |
| **End-to-End Build Speed** | > 100,000 lines/sec per core | `swiftc` + `clang`: ~2,000–5,000 lines/sec |
| **Link Time (Todhchai Image)** | < 50 ms for full kernel/system service | `ld.lld`: ~200–500 ms |
| **Debug Info Emission** | < 5 ms for 100K LOC (SDI / `.todh_debug`) | `ld.lld` (DWARF 5): ~250–600 ms |
| **Stack Unwind Latency** | < 2 microseconds for 100 frames (CUD) | DWARF CFI / LLDB: ~500–2,000 us |
| **Peak Resident Memory** | < 256 MB for 100K LOC build | `swiftc` + LLVM: 1.5–4.0 GB |
| **Runtime Binary Parity** | 80% to 90% of LLVM `-O2` speed | 100% of LLVM `-O2` (baseline) |
