# 00. Overview, Principles, and Key Decisions

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | — (root chapter) |

## 1. Summary

Swift-Stack is a clean-room toolchain for Swift 6.x and ISO C23: frontends, semantic analysis, a shared SSA IR and optimizer, code generators for x86-64, AArch64 and RV64, built-in assemblers, a linker, a native debug-info format, and the language runtimes. Every persistent compiler data structure is a flat, index-addressed table (Data-Oriented Design, DOD) rather than a graph of heap objects.

The primary target is **Todhchai OS** on the **croi** capability microkernel. FreeBSD, Linux and macOS are secondary targets and development hosts.

This chapter records the project-wide goals, non-goals, decisions and principles that every other chapter assumes. Where a later chapter disagrees with this one, this one wins until it is amended.

## 2. Problem Statement

Production compilers for Swift and C (`swiftc`, Clang, LLVM) are built around heap-allocated, pointer-linked object hierarchies:

```
[Clang/swiftc object model, simplified]
ASTContext ──► Decl (polymorphic class)
                ├──► VarDecl ──► TypeSourceInfo ──► QualType ──► Type (heap pointer)
                └──► Expr (polymorphic class)
                      ├──► BinaryOperator (pointers to LHS, RHS, Type)
                      └──► CallExpr (vector of pointers to argument Exprs)
```

The costs this project is betting against are:

1. **Pointer chasing.** Traversals follow pointers into scattered allocations; cache lines carry vtable pointers, padding and rarely-used fields alongside the hot payload.
2. **Allocation volume.** Millions of small allocations per large compile, each with allocator and (in Swift-hosted code) reference-counting overhead.
3. **Reference counting and copy-on-write** in compiler code written in idiomatic Swift (`swift_retain`/`swift_release`, uniqueness checks in inner loops).
4. **Optimizer cost.** LLVM's `-O2` pipeline runs on the order of a hundred passes over a pointer-linked IR. Much of the code-quality benefit comes from a small subset of them (see Principle 4).
5. **Swift type-checking cost.** `swiftc`'s constraint solver can spend disproportionate time on expressions with many overloaded operators and literals. This is a major contributor to slow Swift debug builds, independent of LLVM.
6. **Debug-info duplication.** Per-translation-unit DWARF type information is duplicated and must be deduplicated or carried by the linker.

None of these costs is quantified here; each is a hypothesis to be measured against the baseline compilers using the methodology in [14](14-measurement-methodology.md).

## 3. Goals

- **G1 — Language coverage.** Swift 6.x in two tiers (Tier 0: Embedded Swift subset; Tier 1: full Swift as scoped by the non-goals below), **including Swift macros** (D4, [16](16-macros.md)), and ISO/IEC 9899:2024 (C23), plus the host-header extension profile (D7).
- **G2 — Native toolchain.** No external assembler, linker or LLVM at build time on any supported target.
- **G3 — Compile-time throughput** an order of magnitude above `swiftc`+LLVM for debug and optimized builds, with bounded peak memory. Concrete budgets are in [14](14-measurement-methodology.md) and are targets, not claims.
- **G4 — Acceptable runtime performance.** Optimized code within 80–90% of LLVM `-O2` on the project benchmark suite (hypothesis; see Principle 4).
- **G5 — First-class debugging** through a memory-mappable debug format (SDI, [07](07-debugging-and-sdi.md)) and cheap unwinding.
- **G6 — Determinism** (D6).
- **G7 — Self-hosting.** Swift-Stack eventually compiles itself.

## 4. Non-goals

These are out of scope for v1. Listing them is a decision, not an omission; each can be revisited by amending this chapter.

| Non-goal | Consequence |
|---|---|
| C++ (any version) | No C++ frontend. The upstream Swift runtime (C++) is reimplemented ([12](12-standard-library-strategy.md)). |
| Objective-C and Objective-C interop | No `@objc`, no bridging; Darwin Foundation is not used. |
| Windows / PE-COFF | No COFF objects, PDB, or Windows ABIs. |
| Binary compatibility with `swiftc`-built Swift modules | See D1. Swift-Stack Swift code cannot link against Apple- or swift.org-built Swift libraries. |
| In-process (library) macro plugins | Executable plugins are supported (D4, [16](16-macros.md)); `-load-plugin-library` would need `swiftc` ABI compatibility. |
| Auto-vectorization *as a requirement* | It is an optional track, not a v1 exit criterion (D9). Portable SIMD lowering and loop idioms are required. |
| C intrinsics headers (`<immintrin.h>`, `<arm_neon.h>`, `<riscv_vector.h>`) | Portable SIMD types cover the first-party need ([17](17-simd-and-vectorization.md)). |
| Full GNU C dialect, Blocks, C optional features (VLAs, `_Decimal*`) | See D7 and [01](01-frontend.md). |
| ASLR on the Todhchai fixed-address image format | Recorded as a security trade-off in [06](06-linker.md); open question. |

## 5. Key Decisions

Each decision has an ID that other chapters cite. Status is **Proposed** until the project owner accepts it.

| ID | Decision | Rationale | Status |
|---|---|---|---|
| **D1** | **ABI.** v1 is *not* binary-compatible with `swiftc`-built Swift modules. C ABI compatibility (SysV x86-64, AAPCS64 including Apple's arm64 variant, RISC-V LP64D) is required. Swift functions use the `swiftcc` register assignments. Swift symbols use Swift-Stack's own mangling (prefix `_SS`, [11](11-generics-and-runtime-metadata.md)); overloads are distinguished by mangled name. Link-time type-signature hashes live in a side section `.ss_symtypes` ([06](06-linker.md)). | Apple's Swift ABI (mangling, metadata layout, runtime entry points) is large and only partially documented. C compatibility is what the OS and host libraries require. | Proposed |
| **D2** | **Standard library.** The upstream Swift stdlib and swift-foundation FoundationEssentials *sources* are compiled as inputs. The compiler, linker and runtime contain no vendored code. The upstream C++ runtime is reimplemented in Swift/C23. | Swift semantics are partly defined by the stdlib (`Int`, `Optional`, operators, literal protocols). Rewriting it is a multi-year effort with no design benefit. | Proposed |
| **D3** | **Generics.** Tier 0 fully monomorphizes (Embedded Swift model). Tier 1 passes type metadata and witness tables at runtime, with specialization as an optimization. Metadata layout is Swift-Stack's own (follows from D1). | Matches Swift semantics (separate compilation, existentials, dynamic casts) while keeping Tier 0 metadata-free. | Proposed |
| **D4** | **Swift macros are a goal**, supported through the out-of-process compiler-plugin protocol (executable plugins, `-load-plugin-executable`). The compiler implements the protocol as an interface and never links swift-syntax. Plugins are separate programs, built by the host `swiftc` until Swift-Stack can build them itself from swift-syntax sources treated as inputs (as in D2). Built-in macros (`#file`, `#line`, …) are native. In-process library plugins are a non-goal. ([16](16-macros.md)) | Todhchai is the first-party user: its IPC layer (`@IPCLibrary`) and audio SDK (`@AudioRenderer`) are macros, compiled as Tier 0. The process boundary keeps plugin ABI out of scope (D1). | Proposed |
| **D5** | **Type-checking semantics.** For every supported feature, the set of accepted programs and the chosen overloads MUST match `swiftc`. Any divergence is a bug. Staged solving ([02](02-semantic-analysis.md)) is an optimization only. | Otherwise Swift-Stack implements a dialect, and differential testing ([09](09-roadmap.md)) loses its oracle. | Proposed |
| **D6** | **Determinism.** Identical inputs and flags produce bitwise-identical outputs regardless of thread count or scheduling. | Required for self-hosting verification, caching ([13](13-modules-and-incremental-builds.md)), and reproducible builds. | Proposed |
| **D7** | **C dialect.** ISO C23 plus a documented "host-header profile" of GNU/Clang extensions (attributes, `__builtin_*`, asm labels, `_Nullable`, `__has_feature`, basic inline asm) sufficient to parse glibc, FreeBSD libc and macOS SDK headers. | Without it, C interop on POSIX hosts is impossible; full GNU C is unbounded. | Proposed |
| **D8** | **Storage.** Persistent compiler tables use `Column<Element>` (§6, Principle 2), not Swift `Array`. Transient scratch code may use `Array`. | Keeps ARC and copy-on-write out of hot tables. Gives stable addresses and O(1) reset. | Proposed |
| **D9** | **SIMD and vectorization.** Portable SIMD is required: Swift `SIMDn<T>` and C `vector_size`/`ext_vector_type` lower to native vector code at each ISA baseline, at every optimization level. The baselines are: x86-64 at the 2013 Mac Pro-class floor (`x86-64-v2` + AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, FSGSBASE; AVX2/FMA/BMI opt-in); AArch64 `armv8-a` with NEON; RV64 **RVA23** (RVV 1.0, Zba/Zbb/Zbs, Zicond, …). Loop idiom recognition is required at `-O`. Auto-vectorization of inner loops is an **optional** track (`-vectorize`), built on the same AIR vector operations and legalization tables, and becomes default only when it meets its compile-time budget. ([17](17-simd-and-vectorization.md)) | Hand-written per-architecture SIMD is tedious. Todhchai already writes its codec kernels with `SIMDn` types and guards out RV64. Making portable SIMD good everywhere removes the per-architecture work for experts. Auto-vectorization helps ordinary code, but it is the most complex pass in a conventional optimizer, so it is not a spec requirement. | Proposed |

## 6. Core Principles

### Principle 1: Arrays over objects

Compiler entities (tokens, parse nodes, types, declarations, instructions, symbols) are rows in typed tables addressed by 32-bit handles (`TokenId`, `NodeId`, `TypeId`, `InstId`, `BlockId`, `SymbolId`). Tables are stored as **struct-of-arrays (SoA)**: one contiguous column per field, so a pass that reads only `kind` touches only the `kind` column.

```
ParseTree (postorder, SoA)
                 NodeId:  0      1      2      3      4     ...
kinds:        [u8]       [k0]   [k1]   [k2]   [k3]   [k4]   ...   1 byte/node
tokens:       [u32]      [t0]   [t1]   [t2]   [t3]   [t4]   ...   4 bytes/node
subtreeSizes: [u32]      [s0]   [s1]   [s2]   [s3]   [s4]   ...   4 bytes/node
```

- **No polymorphism in storage.** Node "type" is a `kind` byte; behavior lives in `switch` statements over kinds.
- **Handles, not pointers,** in every persistent structure. Handles are half the size of pointers on 64-bit hosts, serialize directly ([13](13-modules-and-incremental-builds.md)), and are trivially relocatable.
- **Byte counts are per row, summed over columns.** Where a doc shows a Swift `struct` used as an array element, it states the real stride (alignment padding included).

The often-quoted "3–5% compile-time cost per pointer indirection" comes from practitioner experience (Jonathan Blow, in discussion with Sean Barrett), not from a controlled study. Swift-Stack treats it as motivation and measures its own data-layout decisions ([14](14-measurement-methodology.md)).

### Principle 2: Arenas, columns and scratch lifetimes

Memory is owned by a small number of lifetimes:

- **Session arena:** interned strings, canonical types, module-level symbol tables. Lives for the whole compilation.
- **Per-file / per-function scratch arenas:** owned by one worker thread at a time. Reset in O(1) when the file or function is finished.
- **Output arenas:** machine code, relocations and debug fragments handed to the linker without copying.

Persistent tables use a single column abstraction:

```swift
/// A growable, arena-backed column of trivially copyable rows, indexed by a typed handle.
/// Backed by a reserved virtual-address range that is committed on demand, so growth
/// never moves existing rows (addresses stay stable across appends).
public struct Column<Id: TypedId, Element: BitwiseCopyable>: ~Copyable {
    private let base: UnsafeMutablePointer<Element>   // start of reserved range
    private var committedBytes: Int
    public private(set) var count: UInt32

    public mutating func append(_ value: Element) -> Id
    public subscript(id: Id) -> Element { get set }
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R
}
```

- Other chapters write `Column<Element>` as shorthand when the handle type is clear from context.
- `~Copyable` makes ownership explicit and prevents accidental deep copies.
- `BitwiseCopyable` rows mean no ARC traffic when reading or writing.
- Reserve-then-commit gives stable addresses, which is what makes lock-free concurrent append feasible ([10](10-semantic-ir-and-name-resolution.md)). On hosts without overcommit-friendly reservation, the fallback is chunked storage with an extra index indirection.

### Principle 3: Clean-room implementation, scoped

The compiler, assemblers, linker, debug format and runtime are written from public specifications: The Swift Programming Language reference, Swift Evolution proposals, ISO/IEC 9899:2024, the ELF, Mach-O and DWARF specifications, and the platform C ABI documents. No LLVM, Clang, swift-syntax or lld code is linked or copied.

Two clarifications:

- **The Swift standard library is an input, not part of the compiler** (D2). It is Swift source defining library semantics, compiled like any user module.
- **Macro plugins and swift-syntax are inputs too** (D4). They run in separate processes behind the plugin protocol, which Swift-Stack implements as an interface, the same way it implements ELF ([16](16-macros.md)).
- **The Swift reference is not a complete specification.** Where it is silent, `swiftc` behavior is the reference (D5). Behavior is learned by black-box differential testing, not by reading `swiftc` sources.

### Principle 4: The 80–90% parity hypothesis

> Optimized output within 80–90% of LLVM `-O2` performance is acceptable when it substantially reduces compiler complexity and compile time.

The hypothesis rests on the observation that a small set of transformations delivers most of the runtime benefit. For Swift-Stack that set is ([03](03-intermediate-representation.md)):

- **Core:** Mem2Reg, SROA, SCCP, GVN/CSE with basic alias analysis, LICM with simple unrolling, ADCE and CFG simplification, and switch-lowering hints (jump tables).
- **Interprocedural:** generic specialization, then inlining and devirtualization. These run bottom-up over call-graph SCCs.
- **Swift-specific:** ARC optimization (pairing and code motion across blocks), stack promotion of non-escaping objects and closures, bounds-check and exclusivity-check elimination.
- **Backend:** SSA linear-scan register allocation with interval splitting ([04](04-backend.md)).

Known risks to the hypothesis:

- **No auto-vectorization by default.** Scalar C numeric kernels and byte-loop code may fall well below 80% unless they are written with portable SIMD, hit a loop idiom, or are built with `-vectorize` (D9).
- **Weak alias analysis** limits load elimination and LICM of loads.
- **Swift performance depends heavily on specialization and ARC optimization quality.** These are the most complex passes in the list.

Whether the hypothesis holds is decided by benchmarks ([14](14-measurement-methodology.md)), per language and per benchmark category, not asserted.

### Principle 5: Determinism

Parallelism is only allowed where it cannot change the output (D6). In practice:

- **Handles assigned during parallel phases are provisional.** They are canonically renumbered by stable keys (module, file, source offset, mangled name) before anything is emitted ([10](10-semantic-ir-and-name-resolution.md)).
- **Hash tables are never iterated to produce output** unless iteration order is defined.
- **Output layout is a pure function of the canonical inputs:** sections, symbols, relocations and debug tables ([06](06-linker.md)).

## 7. Targets

### Primary: Todhchai OS on croi

- **Image format:** static `ET_EXEC` ELF64 images at fixed base `0x1000000`, 4 KiB pages, separate R-X / R / RW segments, `PT_TLS`, 256 KiB default main-thread stack. ([06](06-linker.md))
- **Runtime tiers:** Tier 0 (Embedded) and Tier 1 (Full). ([08](08-runtime-and-stdlib.md))
- **Concurrency:** the Swift concurrency executor sleeps on a croi port (`td_executor_port`). ([08](08-runtime-and-stdlib.md))
- **Debug info:** native SDI in a `.todh_debug` section. ([07](07-debugging-and-sdi.md))

### Secondary: POSIX hosts

| Host | Triples | Notes |
|---|---|---|
| Linux | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `riscv64-unknown-linux-gnu` | glibc, dynamic linking, `epoll` |
| FreeBSD | `x86_64-unknown-freebsd`, `aarch64-unknown-freebsd`, `riscv64-unknown-freebsd` | FreeBSD libc, `kqueue` |
| macOS | `x86_64-apple-darwin`, `arm64-apple-darwin` | Mach-O, dynamic `libSystem` only, mandatory code signing on arm64 |

**ISA baselines** are deliberate floors, chosen for the hardware Todhchai will ship on, and apply to every OS on that architecture:

- **x86-64:** 2013 Mac Pro-class (Ivy Bridge feature set: `x86-64-v2` + AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, FSGSBASE).
- **AArch64:** `armv8-a`.
- **RV64:** RVA23.

Older CPUs are not supported. The details and the opt-in features above each floor are in [17](17-simd-and-vectorization.md) §5.4 (D9).

Targets are brought up in order: **Todhchai static ELF → Linux → FreeBSD → macOS** ([09](09-roadmap.md)). The driver supports cross-compilation from the start ([15](15-driver-and-diagnostics.md)). Selecting a triple selects the encoder, ABI rules, object format and sysroot.

## 8. Execution Model

```
Phase 1  Lex + parse + declaration collection         parallel per file
           │  per-file ParseTrees, provisional handles
           ▼
Phase 2  Name binding, conformance tables,            parallel per declaration,
         type checking of signatures                   with dependency waits
           │  canonical renumbering (D6)               serial barrier
           ▼
Phase 3  Body type checking → SemIR → AIR             parallel per function
           │
           ▼
Phase 4  Interprocedural optimization                 parallel per call-graph SCC,
         (specialization, inlining)                    bottom-up order
           ▼
Phase 5  Intraprocedural optimization → LIR →         parallel per function
         register allocation → encoding
           │  in-memory RelocatableObjects
           ▼
Phase 6  Link: resolve, lay out, relocate, emit       parallel per input section
```

Scaling is bounded by the serial barriers and by the dependency structure of Phases 2 and 4 (Amdahl). Speed-up curves by core count are part of the benchmark suite. "Linear scaling" is not assumed.

## 9. Alternatives Considered

- **Reuse LLVM as the backend.** This would give mature codegen and close the 10–20% gap immediately. Rejected: it contradicts G2/G3 and reintroduces the IR and compile-time costs the project exists to avoid. It could serve as a temporary oracle for codegen correctness.
- **Apple Swift ABI compatibility from day one.** This would allow linking existing Swift binaries. Deferred (D1): it multiplies scope (mangling, metadata, runtime) before the compiler works at all.
- **Array-of-structs tables with Swift `Array`.** Simpler code. Rejected for persistent tables (D8) because of copy-on-write and ARC overhead and the lack of stable addresses. Still fine for scratch data.

## 10. Open Questions

1. Is ASLR required for Todhchai user processes, which would mean PIE images instead of fixed `0x1000000`? ([06](06-linker.md))
2. Should Tier 1 eventually pursue Apple Swift ABI compatibility on macOS, or remain self-contained?
3. What is the minimum host Swift toolchain for bootstrapping before self-hosting? Currently Swift 6.2+.
4. How will the D1–D9 decisions be accepted and versioned? This doc's table, or separate ADR files?
