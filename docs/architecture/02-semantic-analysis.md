# 02. Semantic Analysis, Type Systems, and C23/Swift Interop

## 1. Overview

Semantic analysis validates syntactic structures against language type rules, builds symbol tables, resolves overload sets, and verifies ownership semantics. In conventional compilers, this phase is notoriously memory-heavy and slow:
- `swiftc` allocates polymorphic `TypeBase` objects on the heap, and its multi-stage constraint solver frequently suffers from exponential backtracking when resolving overloaded operators and polymorphic literals.
- Clang relies on deep, recursive AST visitor patterns and maintains heavyweight `ASTContext` hierarchies.
- Interoperability between Swift and C traditionally requires **ClangImporter**, dragging the entire Clang frontend and its massive object graphs into `swiftc`.

Swift-Stack designs semantic analysis around **canonicalized 32-bit `TypeId` handles**, a **dense `TypePool`**, a **staged bidirectional constraint solver**, and **direct Clang-free C23 header ingestion**.

```
ParseTree (Swift or C23)
           │
           ▼
     Name Resolution ◄─── Global Symbol Table & Scope Ranges
           │
           ▼
     Type Checking   ◄─── Canonical TypePool (32-bit TypeId)
     - C23: ISO 9899:2024 Rules, constexpr eval, _BitInt
     - Swift: Staged Bidirectional Solver (Fast path + Local solver)
           │
           ▼
  Ownership & Borrow Checker (~Copyable, consume/borrow, deinit)
           │
           ▼
    SemIR / Lowering Queue
```

---

## 2. The Type System: Data-Oriented `TypePool`

### Canonical 32-bit `TypeId`

Types are never represented as pointers to polymorphic classes. Every distinct type in the compilation unit is assigned a canonical 32-bit `TypeId`:

```swift
public struct TypeId: Hashable, Equatable, Sendable {
    public var rawValue: UInt32

    public static let void       = TypeId(rawValue: 0)
    public static let bool       = TypeId(rawValue: 1)
    public static let int8       = TypeId(rawValue: 2)
    public static let uint8      = TypeId(rawValue: 3)
    public static let int16      = TypeId(rawValue: 4)
    public static let uint16     = TypeId(rawValue: 5)
    public static let int32      = TypeId(rawValue: 6)
    public static let uint32     = TypeId(rawValue: 7)
    public static let int64      = TypeId(rawValue: 8)
    public static let uint64     = TypeId(rawValue: 9)
    public static let float32    = TypeId(rawValue: 10)
    public static let float64    = TypeId(rawValue: 11)
    public static let rawPointer = TypeId(rawValue: 12)
    public static let nullptr    = TypeId(rawValue: 13) // C23 nullptr_t
    // ... Reserved primitive slots up to 31
}
```

- **Instant Equality:** Checking if two types are equal is a single-cycle 32-bit integer comparison: `typeA.rawValue == typeB.rawValue`.
- **Zero Cache Misses on Primitives:** The first 32 slots are statically pre-allocated and immutable.

### Orthogonal Struct-of-Arrays Layout

Composite types (structs, functions, tuples, generics, arrays) are stored in orthogonal arenas inside the global `TypePool`:

```swift
public struct TypePool {
    // Array indexed by TypeId.rawValue:
    public var kinds: [TypeKind]              // 1 byte: struct, enum, func, tuple, pointer, etc.
    public var sizesInBytes: [UInt32]         // 4 bytes: Target ABI size
    public var alignmentsInBytes: [UInt16]    // 2 bytes: Target ABI alignment
    public var flags: [TypeFlags]             // 2 bytes: isTrivial, isCopyable, isGeneric, etc.
    public var payloadIndices: [UInt32]       // 4 bytes: Index into specific descriptor arena
}
```

When checking whether a type is trivial, non-copyable, or its alignment for structure packing, the compiler reads contiguous arrays directly without chasing pointers into composite type trees.

---

## 3. C23 Semantic Architecture (ISO/IEC 9899:2024)

Swift-Stack implements complete semantic analysis for modern C23:

### Arbitrary Bit-Width Integers: `_BitInt(N)`
- C23 introduces `_BitInt(N)` (and `unsigned _BitInt(N)`) for integer precision from 1 up to `BITINT_MAXWIDTH` (at least 65,535 bits, practically capped at 8,192 bits for compiler efficiency).
- For $N \le 64$, operations lower directly to native CPU registers with mask truncation.
- For $N > 64$, the `TypePool` stores the width, and arithmetic operations lower to multi-word vector/array loops.

### C23 `constexpr` and Compile-Time Evaluator
- In C23, `constexpr` objects must be initialized by constant expressions evaluated at compile time.
- Swift-Stack contains an allocation-free **Constant Evaluator** that walks the postorder parse tree, evaluates arithmetic, bitwise, struct member projections, and pointer offsets directly, storing the resulting bytes in a contiguous constant buffer.

### Standard Attributes (`[[...]]`)
- Complete parsing and semantic validation of C23 standard attributes:
  - `[[nodiscard]]`, `[[nodiscard("reason")]]`
  - `[[maybe_unused]]`
  - `[[deprecated]]`, `[[deprecated("reason")]]`
  - `[[fallthrough]]`
  - `[[reproducible]]`, `[[unsequenced]]` (informs middle-end optimizer of pure/const semantics)

### `typeof` and `typeof_unqual`
- Evaluates expression types without executing runtime code. Resolves immediately to the expression's canonical `TypeId`, with `typeof_unqual` stripping `const`, `volatile`, and `_Atomic` qualifiers.

---

## 4. Swift Semantic Analysis & Staged Type Checking

### The Dilemma of `swiftc` Type Checking

In official `swiftc`, type checking relies on a global constraint solver (the `ConstraintSystem` class). It represents every sub-expression, literal, and overload as a constraint variable, constructing a vast graph of relational constraints. When expressions contain multiple overloaded operators (`+`, `-`, `*`) and polymorphic numeric literals (`0`, `1`), the solver performs exponential backtracking over candidate combinations, frequently exceeding time budgets.

### The Staged Bidirectional Solution

Swift-Stack decouples type checking into three deterministic stages:

```
                  Input Expression / Statement
                               │
                               ▼
        ┌──────────────────────────────────────────────┐
        │ Stage 1: Fast-Path Bidirectional Inference   │
        │ - Bottom-up synthesizer & Top-down checker   │
        │ - Resolves non-overloaded functions, vars,   │
        │   explicit types, and known literals.        │
        └──────────────────────────────────────────────┘
                               │
               Has Unresolved Overloads/Ambiguities?
                               ├─── No ──► [Done: Instant Resolution]
                               │
                              Yes
                               ▼
        ┌──────────────────────────────────────────────┐
        │ Stage 2: Localized Component Constraint Solver│
        │ - Extracts only the ambiguous sub-tree.      │
        │ - Bounded search depth with ranking heuristics│
        │ - Fallback to contextual type immediately.   │
        └──────────────────────────────────────────────┘
                               │
                               ▼
        ┌──────────────────────────────────────────────┐
        │ Stage 3: Protocol Conformance & Witnesses     │
        │ - Check requirements against ConformanceTable│
        │ - Monomorphize generics or synthesize witness│
        └──────────────────────────────────────────────┘
```

1. **Stage 1: Fast-Path Bidirectional Walk (95% of Real Code):**
   - Most Swift code is typed with contextual expectations (e.g., `let x: Int = y + 1`).
   - The type checker runs a fast top-down push and bottom-up synthesize pass. If all sub-nodes have unambiguous types, the expression is resolved in a single linear pass ($O(N)$) with zero backtracking.
2. **Stage 2: Localized Constraint Solver:**
   - Only expressions that contain true overload ambiguities (such as user-defined overloaded operators) are partitioned into isolated connected components.
   - The solver runs bounded constraint satisfaction using domain pruning:
     - Discard candidates that fail contextual types immediately.
     - Rank standard library integer and floating-point default types before arbitrary generic conformances.
3. **Stage 3: Protocol Conformance Tables:**
   - Protocol conformances are recorded in a flat, cache-optimized `ConformanceTable`.
   - Conformance checking is an $O(1)$ hash table probe or binary search over sorted `(TypeId, ProtocolId)` pairs.

---

## 5. Swift Ownership & Non-Copyable Types (`~Copyable`)

Modern Swift requires explicit ownership tracking:
- **`~Copyable` (Non-Copyable Structs/Enums):** Must not be implicitly duplicated.
- **`consuming` Parameters:** The function takes ownership of the value; the caller's value is invalidated after the call.
- **`borrowing` Parameters:** The callee receives a read-only borrow without copying or incrementing reference counts.
- **`inout` (Mutating Borrows):** Exclusive read-write access enforced across the duration of the call.

### The DOD Borrow Checker

The borrow checker operates directly on basic-block control flow graphs:
1. **Liveness & Initialization Bitsets:** Every non-copyable local variable is assigned a bit in a 64-bit integer bitset.
2. **Path Analysis:** A forward dataflow sweep verifies that a consumed variable is never read or borrowed along any subsequent branch.
3. **Deinit Insertion:** The compiler automatically emits an explicit destruction call (`deinit`) at the exact point where a non-copyable value's scope ends without being consumed.

---

## 6. Seamless C23 & Swift Interoperability (No ClangImporter)

In `swiftc`, importing a C header invokes Clang to parse the header into Clang ASTs, and then `ClangImporter` walks those ASTs to generate Swift AST shadows. This is why importing `<stdio.h>` or system headers adds seconds to Swift compile times.

Swift-Stack implements **direct, unified interop**:

```
[Traditional swiftc]
C Header ──► Clang Lexer ──► Clang Parser ──► Clang AST ──► ClangImporter ──► Swift AST

[Swift-Stack]
C Header ──► Swift-Stack C23 Parser ──► Shared SymbolTable & TypePool
                                            ▲
                                            │ Direct Query (0 overhead)
Swift Source ───────────────────────────────┘
```

1. **Shared `TypePool`:** A C `int` is mapped directly to `TypeId.int32` (`CInt`); `double` is `TypeId.float64` (`CDouble`); `void*` is `TypeId.rawPointer` (`UnsafeMutableRawPointer`).
2. **Zero-Copy Struct Layout:** C `struct` declarations are parsed by the C23 frontend and recorded in the same `TypePool` with C ABI layout rules (`#pragma pack`, alignment). When Swift code accesses a C struct, it sees the exact same memory layout without translation.
3. **Inline Function Generation:** C `static inline` functions are parsed directly into the shared Arena Intermediate Representation (AIR), allowing the Swift optimizer to inline C functions directly into Swift caller bodies!
