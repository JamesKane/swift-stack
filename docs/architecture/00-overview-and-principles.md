# 00. Overview, Principles, and Key Decisions

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | — (root chapter) |

## 1. Summary

Swift-Stack is a clean-room toolchain for Swift 6.x and ISO C23: frontends, semantic analysis, a shared SSA IR and optimizer, code generators for x86-64, AArch64 and RV64, built-in assemblers, a linker, a native debug-info format, and the language runtimes. Every persistent compiler data structure is a flat, index-addressed table (Data-Oriented Design, DOD) rather than a graph of heap objects.

The primary target is **VectraOS**, a capability microkernel OS for edge hardware written in Embedded Swift and C23 ([§7](#7-targets)). It is also Swift-Stack's first-party consumer. FreeBSD, Linux and macOS are secondary targets and development hosts.

This chapter records the project-wide goals, non-goals, decisions and principles that every other chapter assumes. Where a later chapter disagrees with this one, this one wins until it is amended.

## 2. Problem statement

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
- **G4 — Acceptable runtime performance.** Optimized code within 80–90% of LLVM `-O2` (C) and `swiftc -O` (Swift) on the project benchmark suite, per category (hypothesis; see Principle 4).
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
| AVX-512 and SVE code generation | Wider vector features above the ISA floors are opt-in only up to AVX2 ([17](17-simd-and-vectorization.md)). |
| Dynamic linking and shared objects on VectraOS | VectraOS programs are static ELF images (`ET_EXEC` or static PIE, [06](06-linker.md)); shared objects wait for a VectraOS decision (open question 1). |

## 5. Key decisions

Each decision has an ID that other chapters cite. Status is **Proposed** until the project owner accepts it.

| ID | Decision | Rationale | Status |
|---|---|---|---|
| **D1** | **ABI.** v1 is *not* binary-compatible with `swiftc`-built Swift modules. C ABI compatibility (SysV x86-64, AAPCS64 including Apple's arm64 variant, RISC-V LP64D) is required. Swift functions use the `swiftcc` register assignments. Swift symbols use Swift-Stack's own mangling (prefix `_SS`, [11](11-generics-and-runtime-metadata.md)); overloads are distinguished by mangled name. Link-time type-signature hashes live in a side section `.ss_symtypes` ([06](06-linker.md)). | Apple's Swift ABI (mangling, metadata layout, runtime entry points) is large and only partially documented. C compatibility is what the OS and host libraries require. | Proposed |
| **D2** | **Standard library.** The upstream Swift stdlib and swift-foundation FoundationEssentials *sources* are compiled as inputs. The compiler, linker and runtime contain no vendored code. The upstream C++ runtime is reimplemented in Swift/C23. | Swift semantics are partly defined by the stdlib (`Int`, `Optional`, operators, literal protocols). Rewriting it is a multi-year effort with no design benefit. | Proposed |
| **D3** | **Generics.** Tier 0 fully monomorphizes (Embedded Swift model). Tier 1 passes type metadata and witness tables at runtime, with specialization as an optimization. Metadata layout is Swift-Stack's own (follows from D1). | Matches Swift semantics (separate compilation, existentials, dynamic casts) while keeping Tier 0 metadata-free. | Proposed |
| **D4** | **Swift macros are a goal**, supported through the out-of-process compiler-plugin protocol (executable plugins, `-load-plugin-executable`). The compiler implements the protocol as an interface and never links swift-syntax. Plugins are separate programs, built by the host `swiftc` until Swift-Stack can build them itself from swift-syntax sources treated as inputs (as in D2). Built-in macros (`#file`, `#line`, …) are native. In-process library plugins are a non-goal. ([16](16-macros.md)) | VectraOS is the first-party user: its typed IPC (`@IPCLibrary`, VectraOS roadmap V2) and its SDK's audio callbacks (`@AudioRenderer`, V6) are macros, compiled as Tier 0. The process boundary keeps plugin ABI out of scope (D1). | Proposed |
| **D5** | **Type-checking semantics.** For every supported feature, the set of accepted programs and the chosen overloads MUST match `swiftc`. Any divergence is a bug. Staged solving ([02](02-semantic-analysis.md)) is an optimization only. | Otherwise Swift-Stack implements a dialect, and differential testing ([09](09-roadmap.md)) loses its oracle. | Proposed |
| **D6** | **Determinism.** Identical inputs and flags produce bitwise-identical outputs regardless of thread count or scheduling. | Required for self-hosting verification, caching ([13](13-modules-and-incremental-builds.md)), and reproducible builds. | Proposed |
| **D7** | **C dialect.** ISO C23 plus a documented "host-header profile" of GNU/Clang extensions (attributes, `__builtin_*`, asm labels, `_Nullable`, `__has_feature`, inline asm, vector types) sufficient to parse glibc, FreeBSD libc and macOS SDK headers. | Without it, C interop on POSIX hosts is impossible; full GNU C is unbounded. | Proposed |
| **D8** | **Storage.** Persistent compiler tables use `Column<Element>` (§6, Principle 2), not Swift `Array`. Transient scratch code may use `Array`. | Keeps ARC and copy-on-write out of hot tables. Gives stable addresses and O(1) reset. | Proposed |
| **D9** | **SIMD and vectorization.** Portable SIMD is required: Swift `SIMDn<T>` and C `vector_size`/`ext_vector_type` lower to native vector code at each ISA baseline, at every optimization level. The baselines are: x86-64 at the 2013 Mac Pro-class floor (`x86-64-v2` + AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, FSGSBASE; AVX2/FMA/BMI opt-in); AArch64 `armv8-a` with NEON; RV64 **RVA23** (RVV 1.0, Zba/Zbb/Zbs, Zicond, …). Loop idiom recognition is required at `-O`. Auto-vectorization of inner loops is an **optional** track (`-vectorize`), built on the same AIR vector operations and legalization tables, and becomes default only when it meets its compile-time budget. ([17](17-simd-and-vectorization.md)) | Hand-written per-architecture SIMD is tedious. VectraOS has no SIMD code yet, but it plans two portable-SIMD users: the codec kernels it lifts in roadmap V6 (written with `SIMDn` types, with RV64 guarded out, when surveyed) and the NEON/SSE CPU backend of its TOSA executor (V8). Making portable SIMD good everywhere removes the per-architecture work for experts. Auto-vectorization helps ordinary code, but it is the most complex pass in a conventional optimizer, so it is not a spec requirement. | Proposed |
| **D10** | **Compiler module structure.** The compiler, assemblers and linker are **one Swift library module, `SwiftStack`**, organized by folders (`Source/`, `Lex/`, `Parse/`, `Sem/`, `AIR/`, `Opt/`, `LIR/`, `Codegen/`, `Encode/`, `Object/`, `Asm/`, `Linker/`), plus a thin `Driver` executable target. Hot generic types (`Column`, handles) are `@frozen`, with `@inlinable` accessors. Release builds use whole-module optimization. Swift-Stack's own build time is budgeted (B14, [14](14-measurement-methodology.md)). | Swift does not specialize or inline non-`@inlinable` generic code across module boundaries. A 13-module split would put unspecialized `Column` accessors on every hot path, and it builds slower. A single module is Swift's version of a unity build. | Proposed |
| **D11** | **Parallelism: lanes, not a job system.** Every worker runs the same phase function over a deterministic partition of that phase's input, identified by `(laneIndex, laneCount)` and separated by barriers. The partition is by stable key and sized by estimated cost. Irregular phases (per-function optimization and codegen, call-graph SCC levels) take items from a pre-sorted work array through a shared atomic cursor, and write results by item index. There is no general job graph and no work-stealing deque in v1. ([15](15-driver-and-diagnostics.md) §4.3) | "Multi-core by default" (Fleury). There is no scheduler to build or debug, determinism (D6) follows from fixed partitioning, and the phase structure is visible in the code. | Proposed |

## 6. Core principles

### Principle 1: Arrays over objects

Compiler entities (tokens, parse nodes, types, declarations, instructions, symbols) are rows in typed tables addressed by 32-bit handles (`TokenId`, `NodeId`, `TypeId`, `InstId`, `BlockId`, `SymbolId`). Tables are stored in contiguous arena memory. Where passes sweep or filter one field at a time, a table is stored as **struct-of-arrays (SoA)**, one contiguous column per field, so a pass that reads only `kind` touches only the `kind` column. Tables consumed whole-row use array-of-structs instead (Principle 6).

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
- Reserve-then-commit gives stable addresses, so references into a column stay valid while it grows. Parallel phases intern into worker-local overlays that are merged at barriers ([10](10-semantic-ir-and-name-resolution.md) §4.6). On hosts without overcommit-friendly reservation, the fallback is chunked storage with an extra index indirection.

### Principle 3: Clean-room implementation, scoped

The compiler, assemblers, linker, debug format and runtime are written from public specifications: The Swift Programming Language reference, Swift Evolution proposals, ISO/IEC 9899:2024, the ELF, Mach-O and DWARF specifications, and the platform C ABI documents. No LLVM, Clang, swift-syntax or lld code is linked or copied.

Three clarifications:

- **The Swift standard library is an input, not part of the compiler** (D2). It is Swift source defining library semantics, compiled like any user module.
- **Macro plugins and swift-syntax are inputs too** (D4). They run in separate processes behind the plugin protocol, which Swift-Stack implements as an interface, the same way it implements ELF ([16](16-macros.md)).
- **The Swift reference is not a complete specification.** Where it is silent, `swiftc` behavior is the reference (D5). Behavior is learned by black-box differential testing, not by reading `swiftc` sources.

### Principle 4: The 80–90% parity hypothesis

> Optimized output within 80–90% of LLVM `-O2` performance is acceptable when it substantially reduces compiler complexity and compile time.

The hypothesis rests on the observation that a small set of transformations delivers most of the runtime benefit. For Swift-Stack that set is ([03](03-intermediate-representation.md)):

- **Core:** Mem2Reg, SROA, SCCP, GVN/CSE with basic alias analysis, LICM with simple unrolling, ADCE and CFG simplification, switch-lowering hints (jump tables), and loop idiom recognition.
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

### Principle 6: Layout follows transforms

"The purpose of all programs is to transform data" (Acton). A table's layout is chosen from the passes that read and write it, the fields each one touches, and the row counts. It is not chosen by blanket rule:

- **Struct-of-arrays** suits tables that passes filter or sweep one field at a time, such as token kinds, parse-node kinds, and type kinds and flags.
- **Array-of-structs** (or hybrid AoSoA) suits tables that are consumed whole-row, such as LIR instructions in the encoder and register allocator, relocations, and live intervals.

Every persistent table is listed in the data catalog ([18](18-data-catalog.md)) with its producers, consumers, access pattern, expected size and current layout. Layouts in the chapters are **initial hypotheses**, to be revised from the M0.5 vertical slice ([09](09-roadmap.md)) with the built-in profiler ([14](14-measurement-methodology.md)). A layout change needs an attached measurement. APIs come in batch form ("where there's one, there's many"): append ranges, lookup batches, and diagnostics in bulk.

### Principle 7: Zero is nil

Row 0 of every table is a valid **nil row**, with default field values and a self-referencing parent. Handle value 0 means "none" everywhere (zero-is-initialization):

- Looking up a nil handle returns harmless defaults instead of trapping.
- Most `Optional<Id>` branches disappear.
- Error recovery reduces to propagating nil. `TypeId 0` is the nil/error type that suppresses cascading diagnostics ([02](02-semantic-analysis.md), [10](10-semantic-ir-and-name-resolution.md) §4.8).

Freshly reserved arena memory is zero, so a zeroed row is always a valid (nil) row.

### Principle 8: Hot-path discipline for the compiler's own Swift

D8 keeps ARC out of the tables. These rules keep it out of the code that walks them, and apply in every pass inner loop:

- No class instances, existentials (`any P`), `String`, `Array`/`Dictionary` growth, or escaping closures. Use interned `AtomId`s instead of strings, and arena scratch buffers instead of `Array`.
- Dispatch with `switch` over kind enums, not protocol witnesses. Closed `enum`s replace protocols for target selection ([05](05-assembler.md), [08](08-runtime-and-stdlib.md)).
- Hot generics are `@frozen`/`@inlinable` and specialized (D10).
- **Enforced, not reviewed:** lexer, parser, register-allocator and encoder inner loops are marked `@_noAllocation`. `swiftc` already checks this attribute, and Swift-Stack will too once self-hosted, so unwanted allocation or retain/release fails the build instead of showing up in a profile.

### Principle 9: Measure from first principles, with built-in tools

- **Budgets are stated in cycles per byte or per item** next to the hardware limit, not only relative to other compilers ([14](14-measurement-methodology.md)).
- **The profiler is part of the compiler** (always compiled in, cycle-counter timed blocks, per-lane timelines), and so is a repetition tester for kernels. Measurement then works the same on VectraOS, where `perf` does not exist.
- **Every compile is recordable.** `--record` captures all inputs, including macro-plugin responses, into one bundle, and `--replay` reproduces the compile bit for bit (D6, [15](15-driver-and-diagnostics.md)). Bug reports and fuzzer finds become one file each.

## 7. Targets

### Primary: VectraOS

VectraOS (`~/Projects/OS/VectraOS-swift`) is a capability microkernel OS for edge hardware: maker SBCs, desktop PCs and the GPUs and NPUs attached to them. It runs on x86-64, AArch64 and RV64 in QEMU today; its first hardware target is the Radxa Dragon Q8B (Qualcomm SC8280XP). It is built with Swift 6.4 and the clang and lld bundled with it, and Swift-Stack's differential corpora are its assembly and C ([09](09-roadmap.md)).

- **Image format:** ELF64 throughout, 4 KiB pages, separate page-aligned `R-X` / `R--` / `RW-` segments (`-zseparate-loadable-segments`), a 256 KiB default main-thread stack recorded in `PT_GNU_STACK`. User programs are either `ET_EXEC` at `0x1000000` or static PIEs linked at 0 and loaded at a random base, with only `R_*_RELATIVE` relocations and `PT_GNU_RELRO` made read-only after relocation. The kernel is a static PIE linked at `0xffffffff80000000` and placed at a random base by the loader (KASLR); the UEFI loader is a static PIE converted to PE32+. ([06](06-linker.md))
- **Runtime tiers:** Tier 0 (Embedded Swift with `-strict-memory-safety`: kernel, services, drivers, every real-time path) and Tier 1 (full Swift: apps, kits, host tools). Today only Tier 0 runs on the device. ([08](08-runtime-and-stdlib.md))
- **Concurrency:** a thread waits on one port for everything, with an absolute deadline and a leeway (`port_wait`). VectraOS has no Swift concurrency executor yet; Swift-Stack's executor backend sleeps on a VectraOS port ([08](08-runtime-and-stdlib.md)).
- **Debug info:** native SDI in an `.ss_debug` section (CUD unwind table in `.ss_unwind`). ([07](07-debugging-and-sdi.md))

### Secondary: POSIX hosts

| Host | Triples | Notes |
|---|---|---|
| Linux | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `riscv64-unknown-linux-gnu` | glibc, dynamic linking, `epoll` |
| FreeBSD | `x86_64-unknown-freebsd`, `aarch64-unknown-freebsd`, `riscv64-unknown-freebsd` | FreeBSD libc, `kqueue` |
| macOS | `x86_64-apple-darwin`, `arm64-apple-darwin` | Mach-O, dynamic `libSystem` only, mandatory code signing on arm64 |

**ISA baselines** are deliberate floors for code Swift-Stack generates by default, and apply to every OS on that architecture. VectraOS builds below them where it has to: its kernels use no FP or vector registers, its x86-64 user code targets baseline x86-64 today but inherits the 2013 Mac Pro-class floor (decided 2026-10-15), its RV64 kernel is `rv64imac_zicsr_zifencei` (soft-float `lp64`), and its RV64 user code `rv64gc` with V checked at run time. Each such build selects its ISA explicitly ([17](17-simd-and-vectorization.md) §5.4):

- **x86-64:** 2013 Mac Pro-class (Ivy Bridge feature set: `x86-64-v2` + AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, XSAVE/XSAVEOPT, FSGSBASE).
- **AArch64:** `armv8-a`.
- **RV64:** RVA23.

Older CPUs are not supported by default code generation; a build that selects a lower ISA explicitly, as VectraOS's do, gets scalar code where the floor would use vectors. On x86-64, VectraOS adopts Swift-Stack's floor rather than the reverse; whether RV64 should do the same is [17](17-simd-and-vectorization.md) §8, question 6. The details and the opt-in features above each floor are in [17](17-simd-and-vectorization.md) §5.4 (D9).

Targets are brought up in order: **VectraOS static ELF → Linux → FreeBSD → macOS** ([09](09-roadmap.md)). The driver supports cross-compilation from the start ([15](15-driver-and-diagnostics.md)). Selecting a triple selects the encoder, ABI rules, object format and sysroot.

## 8. Execution model

Every phase runs on all lanes (D11). "Lanes over X" means a deterministic partition of X by stable key. "Cursor over X" means lanes take items from a pre-sorted array through an atomic cursor and write results by index.

```
Phase 1  Lex + parse + declaration collection         lanes over files (by size)
           │  per-file ParseTrees, provisional handles
           ▼  barrier
Phase 2  Name binding, extensions, operators,         sequential in v1
         eager macro expansion, signatures,            (memoized requests)
         conformances
           │  canonical renumbering (D6)               barrier
           ▼
Phase 3  Body type checking → SemIR → AIR             cursor over functions
         (incl. mandatory lowering)
           ▼  barrier
Phase 4  Interprocedural optimization                 cursor over each SCC level,
         (specialization, inlining)                    bottom-up, barrier per level
           ▼  barrier
Phase 5  Intraprocedural optimization → LIR →         cursor over functions
         register allocation → encoding
           │  in-memory RelocatableObjects
           ▼  barrier
Phase 6  Link: resolve, lay out, relocate, emit       lanes over input sections
```

Scaling is bounded by the barriers, by Phase 2 (sequential in v1, to be parallelized only if measurement shows it matters), and by the depth of the SCC levels in Phase 4 (Amdahl). The detailed semantic-phase breakdown is in [10](10-semantic-ir-and-name-resolution.md) §4.6. Speed-up curves by core count are part of the benchmark suite, and the built-in profiler shows per-lane idle time at each barrier. "Linear scaling" is not assumed.

## 9. Alternatives considered

- **Reuse LLVM as the backend.** This would give mature codegen and close the 10–20% gap immediately. Rejected: it contradicts G2/G3 and reintroduces the IR and compile-time costs the project exists to avoid. It could serve as a temporary oracle for codegen correctness.
- **Apple Swift ABI compatibility from day one.** This would allow linking existing Swift binaries. Deferred (D1): it multiplies scope (mangling, metadata, runtime) before the compiler works at all.
- **Swift `Array` for persistent tables.** Simpler code. Rejected (D8) because of copy-on-write and ARC overhead and the lack of stable addresses. Still fine for scratch data. (Array-of-structs as a *layout* is a separate question, decided per table under Principle 6.)
- **Struct-of-arrays for every table.** Rejected (Principle 6). It costs several cache streams per item for tables consumed whole-row.
- **One Swift module per subsystem (13 modules).** Rejected (D10). Module boundaries block generic specialization and inlining in Swift, and slow the compiler's own build.
- **A work-stealing job graph.** Rejected as the default (D11). It is more machinery than phase-structured lanes, and its scheduling order has to be engineered out of the output to keep D6.
- **Design every subsystem fully before writing code.** Rejected in favor of an early vertical slice (M0.5, [09](09-roadmap.md)). Byte-level layouts in this document set are hypotheses until the slice and profiler confirm them ("compression-oriented programming", Muratori).

## 10. Open questions

1. ~~Is ASLR required for user processes?~~ Resolved by VectraOS: its loaders place static PIEs at a random base, and `ET_EXEC` images still load where linked, so the linker emits both ([06](06-linker.md)). Shared objects remain open: VectraOS has no dynamic linker yet.
2. Should Tier 1 eventually pursue Apple Swift ABI compatibility on macOS, or remain self-contained?
3. What is the minimum host Swift toolchain for bootstrapping before self-hosting? Currently Swift 6.2+.
4. How will the D1–D11 decisions be accepted and versioned? This doc's table, or separate ADR files?
5. Should relocatable, patchable code modules (live code editing in the Handmade Hero style, VectraOS principle 23: "debugging and hot reload are OS services") be prioritized ahead of macOS Mach-O output ([06](06-linker.md), [09](09-roadmap.md))?
