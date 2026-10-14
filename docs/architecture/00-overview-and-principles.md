# 00. Overview, Philosophy, and Data-Oriented Design Principles

## 1. Context and Problem Statement

Modern programming language infrastructure is in a productivity and scalability crisis. Both `swiftc` (the official Swift compiler) and `clang` (the LLVM C/C++ compiler) are built on deep, object-oriented class hierarchies established in the early 2000s:

```
[Clang/swiftc Object Hierarchy]
ASTContext ──► Decl (Polymorphic Class, ~120-256 bytes)
                ├──► VarDecl (Heap-allocated, Virtual Methods)
                │     └──► TypeSourceInfo ──► QualType ──► Type (Heap Pointer)
                └──► Expr (Polymorphic Class)
                      ├──► BinaryOperator (Pointers to LHS, RHS, Type)
                      └──► CallExpr (Vector of Heap Pointers to Arg Exprs)
```

### The Inherent Flaws of the OOP Compiler Model

1. **Pointer Chasing & Cache Starvation:** Every node traversal requires following cold heap pointers across disparate memory pages. CPU cache lines are packed with vtables, alignment padding, and metadata rather than dense payload data.
2. **Allocation & Deallocation Storms:** Compiling a 100,000-line Swift program triggers millions of individual heap allocations and deallocations. Swift's `ASTContext` and `swift-syntax` allocate billions of bytes across small nodes, placing unbearable pressure on general-purpose allocators (`malloc`/`free`).
3. **Reference Counting and CoW Overhead:** When written in idiomatic modern Swift, naive compiler architectures suffer severe performance degradation from Automatic Reference Counting (`swift_retain`/`swift_release`) and Copy-on-Write (`isKnownUniquelyReferenced`) checks inside tight parsing and AST walks.
4. **The LLVM Optimization Cliff:** LLVM IR is an immensely heavy, pointer-linked graph. To squeeze out the final 5–10% of binary performance, LLVM executes hundreds of deeply coupled passes (e.g., polyhedral loop vectorization, interprocedural alias analysis, instruction combining). As a consequence, Swift debug builds take tens of seconds, stalling the inner development feedback loop.
5. **DWARF Deduplication Tax:** Traditional toolchains emit duplicate DWARF debugging types per compilation unit, requiring the linker to spend hundreds of milliseconds parsing and deduplicating DWARF strings and DIE trees.

---

## 2. Core Architectural Principles

Swift-Stack adopts a radically different philosophy inspired by Data-Oriented Design (DOD), modern game engine architecture, and pioneering compilers such as Zig and Carbon.

### Principle 1: Arrays Over Objects (Struct of Arrays & The "Pointer Tax")

In compiler engineering discussions within the Handmade community (notably Sean Barrett and Jonathan Blow), empirical profiling revealed that **every layer of pointer indirection in compiler data structures incurs a 3–5% compile-time performance tax**:
> *"It could cost easily three to five percent of compile time to have something be a pointer versus not be a pointer... even if I'm just doing bump allocation. Just going through that pointer was a problem... I slowly put more and more things on the host struct rather than being a pointer because I could measure the difference."* — Jonathan Blow

All Swift-Stack compiler data structures are stored in dense, contiguous flat arrays. An "AST node", "Type", or "Instruction" is never an object on the heap or a pointer; it is a 32-bit integer handle indexing into a typed arena.

```
[Swift-Stack DOD Representation]

ParseTree (Carbon Postorder Array):
┌───────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│ NodeId 0  │ NodeId 1  │ NodeId 2  │ NodeId 3  │ NodeId 4  │ ...       │
├───────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│ kind: u8  │ kind: u8  │ kind: u8  │ kind: u8  │ kind: u8  │ ...       │
│ tok: u32  │ tok: u32  │ tok: u32  │ tok: u32  │ tok: u32  │ ...       │
│ size: u32 │ size: u32 │ size: u32 │ size: u32 │ size: u32 │ ...       │
└───────────┴───────────┴───────────┴───────────┴───────────┴───────────┘
```

- **Zero Polymorphism & Zero Pointer Tax:** No virtual method tables, no `vptr` overhead, and no pointer dereference penalties.
- **Sequential Streaming:** Traversal is a linear sweep through cache-contiguous memory, maximizing hardware prefetching and SIMD vectorization.
- **Index Handles (`Id` types):** Pointers are forbidden in persistent data structures. All references use strongly-typed 32-bit indices (`TokenId`, `NodeId`, `TypeId`, `InstId`, `BlockId`, `SymbolId`). This cuts pointer memory consumption in half on 64-bit architectures (4 bytes vs 8 bytes) and ensures deterministic relocatability.

### Principle 2: Arenas and Scratch Lifetimes

Dynamic memory is strictly governed by generational arena allocators:
- **Module Lifetime Arena:** Allocates persistent artifacts (interned identifiers, canonical types, global symbol tables).
- **File / Worker Scratch Arenas:** Each parallel worker thread owns a scratch arena for lexing, parsing, and local lowering. When a file or function lowering completes, the scratch offset is reset to zero in $O(1)$ time without calling `free`.
- **`~Copyable` Resource Wrappers:** Buffers and arenas are wrapped in Swift's non-copyable types (`~Copyable`), enforcing strict compile-time ownership and eliminating accidental ARC overhead or deep copies.

### Principle 3: Clean-Room Specification Implementation

In accordance with Todhchai Principle 29:
- The entire stack is clean-room: written exclusively from the **Swift Language Reference**, published Swift Evolution proposals, the **ISO/IEC 9899:2024 (C23)** specification, and standard ELF/DWARF/ABI documents.
- Zero vendored code: No LLVM, Clang, `swift-syntax`, `lld`, or external libraries are linked. The host `swiftc` and `clang` compilers serve solely as differential testing oracles and baseline benchmarks during early development.

### Principle 4: The 80–90% Binary Parity Rule

A central design axiom of Swift-Stack is:

> **80–90% performance parity in the resulting binaries is acceptable when it considerably simplifies architecture and implementation code.**

The performance of compiled binaries follows a steep Pareto distribution:
- **The First 80–90% of Performance:** Achieved by a lean, high-throughput pipeline:
  1. SSA-based register allocation with clean interval splitting (no spilling in hot loops).
  2. Sparse Conditional Constant Propagation (SCCP) + Constant Folding.
  3. Mem2Reg (SSA promotion of local stack variables).
  4. Global Value Numbering (GVN) / Common Subexpression Elimination (CSE).
  5. Inlining of trivial accessors, witness calls, and closures.
  6. Swift ARC optimization (pairing and cancellation of local retain/release pairs).
  7. Dead Code Elimination (ADCE) and branch folding.
- **The Remaining 10–20% of Performance:** Requires millions of lines of complex compiler code: polyhedral loop transforms, profile-guided layout, vectorization heuristics, and complex alias analyses that increase compilation time by 10x–50x and make the compiler codebase brittle and hard to maintain.

By intentionally targeting the 80–90% sweet spot, Swift-Stack keeps the compiler code lean, auditable, and blazing fast (100K+ lines per second per core).

---

## 3. System Target: Todhchai OS & POSIX Interop

### The Primary Target: Todhchai OS

Todhchai is a desktop operating system written natively in Swift on top of the **croi** capability microkernel. The compiler stack must directly satisfy Todhchai's operational contracts:

1. **Static ELF Images at `0x1000000`:** Native Todhchai executables are static `ET_EXEC` ELF64 binaries loaded at fixed address `0x1000000` with 4 KiB page alignment, separate loadable segments (`RX` for text, `R` for rodata, `RW` for data/bss), a 256 KiB stack, and `--eh-frame-hdr`.
2. **Dual Swift Runtime Tiers:**
   - **Tier 0 (Embedded Swift):** Zero heap allocation, freestanding, no dynamic metadata, no existentials, no key paths, no libm. Directly targets kernel-adjacent services, device drivers, and microkernel subsystems.
   - **Tier 1 (Full Swift):** Complete Swift runtime with standard collections, FoundationEssentials, and Concurrency.
3. **croi Port-Driven Concurrency:** The Swift concurrency runtime must not spawn traditional OS worker threads sleeping on condition variables. Instead, Todhchai's TaskExecutor sleeps directly on a microkernel **port** (`td_executor_port`). A packet delivered from a timer, channel, or IPC wake resumes an async Swift Task with zero thread context switching.
4. **Native Fast Debug Format:** Instead of bloated DWARF 5, Todhchai supports a native, single-pass debug index (`.todh_debug`) emitted directly by the backend and linker, enabling instant debugger startup.

### Secondary Target: POSIX Host Systems

For bootstrapping, cross-compilation, and developer workstations, Swift-Stack natively targets:
- **FreeBSD:** (`x86_64-unknown-freebsd`, `aarch64-unknown-freebsd`, `riscv64-unknown-freebsd`) utilizing native `kqueue`/`kevent` event engines, `libthr` 1:1 threading over `_umtx_op`, and FreeBSD ELF64 conventions.
- **Linux:** (`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `riscv64-unknown-linux-gnu`) with `epoll` event loops.
- **macOS:** (`x86_64-apple-darwin`, `arm64-apple-darwin`) with Mach-O 64 and `kqueue`.

Cross-compilation is built into the driver from day one: target triple selection simply switches the machine encoder, ABI layout rules, and standard library sysroot path.

---

## 4. Multi-Core Execution Model

Compilation is inherently parallelizable when data dependencies are decoupled:

```
[Parallel Compilation Pipeline]

Phase 1: Concurrent Parsing & Interning
  Worker 0 ──► Lex & Parse File 0..n  ──► Thread-local ParseTrees
  Worker 1 ──► Lex & Parse File n..2n ──► Thread-local ParseTrees
  Worker 2 ──► Lex & Parse File 2n..3n──► Thread-local ParseTrees
  Worker 3 ──► Lex & Parse File 3n..4n──► Thread-local ParseTrees
       │
       ▼ (Merge into Module Decl Table via concurrent radix hash map)
Phase 2: Global Declaration & Type Resolution (Parallel by Module)
       │
       ▼ (Batch function queue)
Phase 3: Concurrent Function Lowering, AIR Optimization & Codegen
  Job Queue: [Func 0, Func 1, Func 2, ..., Func M]
  Workers pull functions concurrently:
    AIR Lowering ──► Mem2Reg ──► GVN ──► LIR ──► Machine Code Bytes
       │
       ▼ (Zero-copy in-memory buffers)
Phase 4: Concurrent Linker Pass
  - Section layout (atomic counter offsets)
  - Concurrent relocation processing (split by target section chunk)
  - Direct output file writing via memory-mapped file
```

This ensures compilation scales linearly with CPU core counts, delivering sub-second cold builds and near-instant incremental builds.
