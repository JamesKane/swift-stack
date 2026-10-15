# 02. Semantic Analysis: Type System, C23 Semantics, Swift Type Checking, and Interop

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [01](01-frontend.md), [10](10-semantic-ir-and-name-resolution.md), [11](11-generics-and-runtime-metadata.md), [12](12-standard-library-strategy.md), [16](16-macros.md), [17](17-simd-and-vectorization.md) |
| **Consumed by** | [03](03-intermediate-representation.md), [07](07-debugging-and-sdi.md), [13](13-modules-and-incremental-builds.md) |

## 1. Summary

Semantic analysis (Sem) checks parse trees against the language rules and produces typed **SemIR**. This chapter covers the *language rules*:

- the shared `TypePool`
- C23 semantics
- Swift type checking
- Swift 6 concurrency checking
- the type-level side of ownership
- C↔Swift interop without ClangImporter

The *machinery* that applies these rules is in [10](10-semantic-ir-and-name-resolution.md): the SemIR representation, the postorder walk, name lookup, interning, determinism, and diagnostics. Flow-sensitive checks (ownership and borrow checking, definite initialization, region-based isolation) run on the control-flow graph in AIR as mandatory passes ([03](03-intermediate-representation.md)). They are not Sem's job.

```
ParseTree ──► [10] declaration collection, name resolution, SequenceExpr folding
                    │
                    ▼
             type checking   ◄── TypePool (§4.1), ConformanceTable, generic signatures
             - C23 rules (§4.2)
             - Swift staged solver (§4.3)
             - Isolation & Sendable checking (§4.4)
                    │
                    ▼
                 SemIR ──► lowering queue ──► AIR mandatory passes:
                                              ownership, definite init, region isolation
```

## 2. Goals

- G1. **Swift conformance (D5).** For every supported Swift feature, the set of accepted programs and the overload chosen at every call site MUST match `swiftc` in the same language mode. Any divergence is a bug, and staged solving is purely an optimization.
- G2. **C conformance.** C units MUST conform to ISO/IEC 9899:2024, plus the host-header profile (D7). §4.2.6 lists the deferred optional features.
- G3. **Type equality.** Equality of canonical types MUST be a 32-bit integer compare.
- G4. **Shared type storage.** C and Swift types MUST share one `TypePool`, so that interop involves no translation layer. They remain *distinct types* connected by an explicit import mapping (§4.6).

## 3. Non-goals

- Binary compatibility with `swiftc`-built modules (D1).
- C++ and Objective-C. (Swift macros are in scope; see D4 and [16](16-macros.md).)
- Library evolution (resilience) in v1. Resilient layouts are anticipated by the "layout unknown" sentinel, but not implemented.
- Matching `swiftc`'s *diagnostic wording*. Only acceptance and resolution must match.

## 4. Design

### 4.1 The TypePool

#### Handles

```swift
/// Canonical or sugared type. Upper 29 bits: index into TypePool. Low 3 bits: C qualifiers.
public struct QualType: Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt32
    public var typeId: TypeId   { TypeId(rawValue: rawValue >> 3) }
    public var isConst: Bool    { rawValue & 0b001 != 0 }
    public var isVolatile: Bool { rawValue & 0b010 != 0 }
    public var isRestrict: Bool { rawValue & 0b100 != 0 }
}
public struct TypeId: Hashable, Sendable, BitwiseCopyable { public var rawValue: UInt32 } // < 2^29
```

- **Qualifiers.** `const`, `volatile`, and `restrict` are qualifier bits on the handle, since they do not change layout. Swift types always have zero qualifier bits. `_Atomic(T)` is a distinct **type constructor**, not a bit, because an atomic type may have a different size and alignment from `T`. `typeof_unqual` strips the qualifier bits and the atomic constructor, giving the non-atomic, unqualified type.
- **Sugar.** Typedefs, `typealias`es, and sugar such as `[Int]` and `Int?` get their own `TypeId`s. Each records its canonical `TypeId` in a column. Equality (G3) compares *canonical* IDs, while diagnostics print the sugared spelling (for example `size_t` rather than `unsigned long`).

#### Reserved slots (0–63): Builtin and C types

The reserved slots are **compiler-builtin** types, not Swift standard-library types. Swift's `Int`, `Bool`, `Double`, `Optional`, and so on are ordinary nominal types declared in the standard library, each wrapping a `Builtin` type. For example, `struct Int { var _value: Builtin.Int64 }` on 64-bit targets ([12](12-standard-library-strategy.md)).

| Range | Contents |
|---|---|
| 0 | `error`: the nil row (see below) and the poison type of [10](10-semantic-ir-and-name-resolution.md) §4.8 |
| 1 | `void` / `()` |
| 2–15 | `Builtin.Int1/8/16/32/64/128`, `Builtin.Word`, `Builtin.IntLiteral`, `Builtin.FPIEEE16/32/64`, `Builtin.FPIEEE80` (x86 only), `Builtin.RawPointer`, `Builtin.NativeObject` |
| 16–40 | C types, all distinct: `_Bool`, `char`, `signed char`, `unsigned char`, `short`, `unsigned short`, `int`, `unsigned`, `long`, `unsigned long`, `long long`, `unsigned long long`, `float`, `double`, `long double`, `nullptr_t`, `void` (C) |
| 41–63 | reserved |

**Slot 0 is the nil row** ([00](00-overview-and-principles.md) Principle 7). `TypeId(rawValue: 0)` is the zero value of every `TypeId` column, so an unset or failed type is the error type by construction. Its row holds valid defaults: kind `error`, size 0, alignment 1, canonical type itself, every flag clear, and no payload. Any query on it (layout, conformance, member lookup, import mapping) returns a harmless answer instead of trapping. Because every operation on `error` yields `error` and no diagnostics, errors do not cascade, and the type checker needs no `Optional<TypeId>` branches. The error type described in [10](10-semantic-ir-and-name-resolution.md) §4.8 *is* this slot.

Builtin vector types `Vec<N × E>` (behind `Builtin.Vec*`, Swift `SIMDn<T>`, and C `vector_size`/`ext_vector_type`) are parametric, so they are not reserved slots. They are interned structurally with kind `vector` ([17](17-simd-and-vectorization.md) §5.1).

- **Distinct C integer types.** Every C integer type is distinct, even when its representation coincides with another's: `long` and `long long` are both 64-bit on LP64, and `char` matches either `signed char` or `unsigned char`. Each records its *representation* Builtin type in a column. This is required by `_Generic`, by pointer compatibility (`long *` is not compatible with `long long *`), and by diagnostics.
- **C character typedefs.** `char8_t`, `char16_t`, and `char32_t` are typedefs in C23 (sugar over `unsigned char`, `uint_least16_t`, and `uint_least32_t`).
- **Target dependence.** The `char` signedness and the sizes of `long` and `long double` are target-dependent. The pool is built for one target triple per compilation.

#### Columns

```swift
public struct TypePool: ~Copyable {
    public var kinds:      Column<TypeKind>  // 1 byte: builtin, cInt, pointer, struct, enum, class,
                                             //         tuple, function, generic param, atomic, bitInt, vector, …
    public var flags:      Column<UInt16>    // 2 bytes: isTrivial, isCopyable, isEscapable, isSendable(cached),
                                             //          hasGenericParams, isSugar, isC, …
    public var canonical:  Column<TypeId>    // 4 bytes: self if canonical
    public var payload:    Column<UInt32>    // 4 bytes: index into kind-specific descriptor arena
    public var sizes:      Column<UInt32>    // 4 bytes: ABI size, or layoutUnknown
    public var aligns:     Column<UInt8>     // 1 byte: log2(alignment), or layoutUnknown8
}
public let layoutUnknown: UInt32 = .max
```

That is 16 bytes per type across six columns.

- **Lazy layout.** Layout is computed on first request and cached.
- **Unknown layout.** Types whose layout cannot be known statically report `layoutUnknown`. These are generic type parameters, types that depend on them, and (later) resilient types. In Tier 0 such types never reach code generation, because everything is monomorphized. In Tier 1 they are handled through runtime metadata and value witnesses ([11](11-generics-and-runtime-metadata.md)).
- **Descriptor arenas.** These are per kind: nominal declarations, tuple element lists, function signatures (parameter conventions, effects such as `async`/`throws(E)`/isolation), pointer pointee, `_BitInt` width, and generic arguments.

#### Interning and concurrency

- **Structural interning.** Types are interned structurally. A pointer to `T` and the same generic instantiation always get the same `TypeId`.
- **Parallel phases.** During parallel phases, each worker interns into a local overlay. At the next phase barrier, the overlays are merged, and new types are assigned **canonical IDs** by sorting on a stable structural key. Worker-local IDs are then rewritten, which keeps IDs independent of thread scheduling (D6). The full protocol is in [10](10-semantic-ir-and-name-resolution.md) §4.6.

### 4.2 C23 semantics (ISO/IEC 9899:2024)

#### 4.2.1 Required language features

| Area | Features |
|---|---|
| Keywords and types | `bool`/`true`/`false`; `nullptr`/`nullptr_t`; `alignas`/`alignof`; `static_assert` (message optional); `thread_local`; `typeof`/`typeof_unqual`; `_Generic`; `auto` type inference (single declarator, C23 rules); enums with fixed underlying type (`enum E : unsigned char`) |
| Declarations | Unprototyped `f()` means `f(void)`; K&R definitions are removed; improved tag compatibility (redeclaring an identical `struct` in the same scope; Clang, the M1 reference, does not implement it yet, so a same-scope redefinition is currently diagnosed as Clang does); empty initializer `{}`; compound literals with storage-class specifiers (`static`, `constexpr`, `register`, `thread_local`); labels before declarations and at the end of compound statements |
| Integers | Two's complement; `_BitInt(N)` (§4.2.2); checked arithmetic `ckd_add`/`ckd_sub`/`ckd_mul` as builtins |
| Constants | `constexpr` objects (§4.2.3); `u8` character literals; binary literals; digit separators |
| Attributes | `[[nodiscard]]`, `[[nodiscard("…")]]`, `[[maybe_unused]]`, `[[deprecated]]`, `[[deprecated("…")]]`, `[[fallthrough]]`, `[[noreturn]]` (and deprecated `[[_Noreturn]]`), `[[reproducible]]`, `[[unsequenced]]`; unknown vendor attributes warn and are ignored; `__has_c_attribute` reports the supported set |
| Library-facing builtins | `unreachable()`, the `<stdbit.h>` operations (`stdc_count_ones`, `stdc_leading_zeros`, …) as intrinsics, `memset_explicit` recognized as non-elidable |
| Atomics | `_Atomic` and `<stdatomic.h>` via builtins. `__STDC_NO_ATOMICS__` is **not** defined, because VectraOS's runtime needs atomics |
| Variably modified types | Pointers to VLA types and VM parameters are mandatory in C23 and supported |

`[[reproducible]]` and `[[unsequenced]]` are recorded as function effects and passed to the optimizer as `readonly`/`readnone`-style facts ([03](03-intermediate-representation.md)).

#### 4.2.2 `_BitInt(N)`

- **Width limit.** C23 only requires `BITINT_MAXWIDTH ≥ ULLONG_WIDTH` (64). Swift-Stack sets **`BITINT_MAXWIDTH = 8192`**:
  - That covers common large-integer uses such as 4096-bit cryptographic operands.
  - It bounds the cost of constant evaluation and of the per-operation lowering loops.
  - Raising it later is source-compatible.
- **Layout.** Size, alignment, and calling convention MUST follow each psABI's `_BitInt` rules: the x86-64 psABI, AAPCS64, and the RISC-V psABI. These differ for N > 64 (for example, chunk size and alignment on AArch64). They are not left to choice.
- **Lowering.** For N ≤ 64, operations lower to native integer operations, with explicit truncation or extension to N bits. For N > 64, they lower to multi-word loops or runtime helper calls ([03](03-intermediate-representation.md)).

#### 4.2.3 `constexpr` and constant evaluation

- **Input is typed SemIR.** The constant evaluator runs on typed SemIR, not on the raw parse tree. It needs resolved types, implicit conversions, and member offsets.
- **C23 rules.** It implements C23's restrictions:
  - The initializer must be a constant expression.
  - Arithmetic values must be exactly representable in the target type, with no truncation.
  - Pointers are restricted to null.
  - Any operation with undefined behavior is a diagnostic.
- **Current implementation.** Two evaluators, to be merged:
  - The M1 evaluator folds integer constant expressions over the parse tree with C's typing: literal types from value, base and suffix (C23 6.4.4.1), the integer promotions and usual arithmetic conversions, conversion by casts, and `sizeof`/`alignof` of any type or expression (typed by the checker). `constexpr` integer objects are named constants.
  - The static-initializer evaluator (M3, `StaticInitializer.swift`) folds the SemIR initializer of every static-storage object into a data image: integers in their type's width (`APInt`), floating values in their format (`SoftFloat`, so `long double` is the x87 80-bit type on x86-64 and binary128 elsewhere), and address constants as relocations against objects, functions, string literals, compound literals and GNU label addresses. A static flexible array member's initializer (GNU) grows the object. Its images match `clang -c -O0` byte for byte on generated initializers and on every global of the C corpora (`M3ClangProbeTests`).
- **Shared evaluator.** The same evaluator handles integer constant expressions (array bounds, `case` labels, `static_assert`, enumerators, bit-field widths), `_BitInt` constants, and constant initializers of static-storage objects. Results go into a contiguous constant buffer that becomes initialized data in `.rodata`/`.data`.

#### 4.2.4 `typeof` and `typeof_unqual`

Both are resolved by type-checking the operand without evaluating it, except that VLA-typed operands are evaluated as C23 requires. `typeof_unqual` removes the qualifier bits and the `_Atomic` constructor.

#### 4.2.5 Host-header profile (D7), semantic side

- **Attributes** (`__attribute__`). Implemented: `aligned`, `packed`, `noreturn`, `unused`, `used`, `visibility`, `always_inline`, `noinline`, `section`, `weak`, `alias`, `nonnull`, `warn_unused_result`, `deprecated`, and `format` (checked loosely). Recorded but not enforced: `availability` and `swift_name`.
- **Asm labels.** `__asm__("sym")` on a declaration overrides its symbol name. macOS uses this for `$INODE64` and similar variants, and glibc's `__REDIRECT` for `stat` → `stat64` under `_FILE_OFFSET_BITS=64`, so it is required for correct linking. The label applies to the name's later redeclarations too (`SemModule.asmLabels`).
- **`#pragma pack`.** `pack(N)`, `pack()`, `pack(push[, N])` and `pack(pop)`, with Clang's Itanium layout rules (§4.2.7).
- **Case ranges.** GNU `case low ... high:` (a `caseRange` statement in SemIR); a range that overlaps another label is a duplicate case value.
- **Builtins.** A documented `__builtin_*` catalog, covering what the profiled headers reference: `__builtin_va_*`, `__builtin_expect`, `__builtin_bswap*`, `__builtin_clz*`, `__builtin_offsetof`, `__builtin_unreachable`, and the overflow builtins.
- **Inline `asm`.** Basic and extended inline `asm`, with the constraint subset that VectraOS's C needs (`r`, `m`, `i`, `=`, `+`, `&`, register-pinned operands, `memory`/`cc` clobbers).
- **Nullability qualifiers** (`_Nonnull`, `_Nullable`, `_Nullable_result`, `_Null_unspecified`) are kept as type sugar for Swift import (§4.6). VectraOS's kernel, loader and runtime headers annotate every pointer with them, including inside array parameter brackets (`uint32_t out[_Nonnull 4]`).
- **Vector extensions.** `__attribute__((vector_size(N)))`, `ext_vector_type(N)`, `__builtin_shufflevector` and `__builtin_convertvector`. They map to the TypePool's builtin vector types, shared with Swift `SIMDn` ([17](17-simd-and-vectorization.md) §5.7), and macOS `<simd/simd.h>` needs them. Target intrinsics headers are a non-goal.

#### 4.2.6 Deferred optional features

- **Automatic-storage VLA objects.** `__STDC_NO_VLA__` is defined to 1 in v1. (VM types themselves are supported; §4.2.1.)
- **`_Complex`.** `__STDC_NO_COMPLEX__` is defined to 1.
- **Decimal floating point** (`_Decimal32/64/128`). Not supported; `__STDC_IEC_60559_DFP__` is not defined.
- **`<threads.h>`.** A library concern for the C runtime ([08](08-runtime-and-stdlib.md)).

#### 4.2.7 Tags and layout

- **Tag scopes.** Struct, union and enum tags live in the scope stack, not in the TypePool. A definition, or a bare `struct S;`, introduces a new type in the current scope that hides an outer tag; a reference resolves to the innermost visible tag, or declares a new incomplete one. Completing a forward declaration keeps its `TypeId`, so a tentative definition whose type is completed later in the unit is valid (6.9.2).
- **Layout.** A per-target `DataLayout` gives the scalar sizes and alignments, the `long double` format, each psABI's `_BitInt` rule, and `char` signedness. Members are placed by the x86-64 System V rules, which the AArch64 and RISC-V psABIs share for ordinary members and bit-fields. A bit-field shares the storage unit of its declared type with the preceding bits unless it would cross that unit's boundary, and a zero-width bit-field closes the unit. On x86-64 and RISC-V unnamed bit-fields do not affect alignment; AAPCS64 counts them as named ones, and its zero-width bit-field raises the alignment to its type's even in a packed record. `packed`, `aligned`, `alignas` and `mode` are applied; an explicit member alignment survives `packed`.
- **`#pragma pack(N)`** (Clang's Itanium rules) caps every member's alignment at N, an explicit member alignment included but not the record's own; places bit-fields without padding, so they may straddle units; and gives a bit-field of a packed record its unpacked alignment, capped. The preprocessor records each change at its token (`TokenBuffer.packChanges`), and a definition takes the value in effect at its tag.
- **Checked against Clang.** `sizeof`, `_Alignof` and `offsetof` of generated types match clang 22 on x86-64, AArch64 and RISC-V (`M3ClangProbeTests`).
- **Bit-field promotion** (C23 6.3.1.1p2, as Clang's `isPromotableBitField`, compatible with GCC): an integer or enumeration bit-field narrower than `int` promotes to `int` whatever its declared type, one as wide as `int` to `int` or `unsigned int` by its signedness, and a wider or `_BitInt` one is not promoted. The rule applies wherever the integer promotions or usual arithmetic conversions do: `unsigned f : 3` compares with `-1` as an `int`.
- **Enumerations.** Without a fixed underlying type, the enumerated type is compatible with `unsigned int` when no value is negative and with `int` otherwise (64-bit types when a value needs them), as in GCC and Clang. An enumeration constant has type `int` when its value fits.

### 4.3 Swift type checking

#### 4.3.1 Compiler-known entities

Literals, operators, `Optional` sugar, `for`-`in`, `try`/`throws`, and implicit conversions all depend on declarations in the standard library. Sem resolves them through a **known-entity registry**: for example, `ExpressibleByIntegerLiteral`, `IntegerLiteralType`, `Optional`, `Sequence.makeIterator()`, and `Error`. The registry is populated when the stdlib module loads ([12](12-standard-library-strategy.md)). Sem never hard-codes `Int` as a primitive.

#### 4.3.2 Staged solving

`swiftc` builds a constraint system per expression, and its overload resolution behavior *is* the effective specification. Swift-Stack reproduces that behavior (G1), and adds two cheaper stages that are allowed to finish only when their answer is provably the same:

```
                Expression (contiguous parse-tree range + expected type)
                                     │
                                     ▼
       ┌───────────────────────────────────────────────────────────────┐
       │ Stage 1: direct bidirectional checking                         │
       │ Finishes only if every reference has exactly one viable        │
       │ candidate after admissible pruning (see below).                │
       └───────────────────────────────────────────────────────────────┘
                     │ finished                     │ not provable
                     ▼                              ▼
                   done        ┌───────────────────────────────────────────┐
                               │ Stage 2: constraint solver                 │
                               │ Over connected components of type          │
                               │ variables. Same solution scoring and       │
                               │ ranking as swiftc. No heuristic shortcut   │
                               │ that can change the answer.                │
                               └───────────────────────────────────────────┘
```

- **Stage 1.** Covers: references to non-overloaded declarations; member access on concrete types with one candidate; literals with a concrete contextual type; calls whose overload set collapses to one candidate under *admissible pruning*.
  - **Admissible pruning.** A pruning rule is admissible only if it can never remove a candidate that could appear in the best-ranked solution. For example, if `y: Int` and the expected type is `Int`, the viable overloads of `+` in `y + 1` collapse to `(Int, Int) -> Int`.
  - **Proof obligation.** Each pruning rule is documented together with its admissibility argument, and is tested differentially against `swiftc` ([09](09-roadmap.md)).
  - **Coverage.** The share of expressions that Stage 1 resolves is a *hypothesis to measure* ([14](14-measurement-methodology.md)), not a design guarantee.
- **Stage 2.** A constraint solver that implements Swift's typing rules:
  - implicit conversions (value-to-optional, function conversions, `CGFloat`↔`Double`, collection upcasts);
  - literal defaulting through `ExpressibleBy*Literal` default types;
  - multi-statement closure inference (SE-0326);
  - result builders (transformed before solving);
  - parameter packs;
  - opaque result types;
  - typed throws (`throws(E)`);
  - implicit member chains;
  - key-path literals.

  Solutions are compared with `swiftc`'s documented scoring rules, the solution score components. Partitioning into connected components is semantics-preserving because independent components cannot affect each other's scores.
  - **No answer-changing shortcuts.** There is **no** "fall back to the contextual type" shortcut. If a component's search grows large, the solver keeps searching, up to a work limit. At that limit it emits a "too complex" diagnostic, as `swiftc` does. Whether that limit needs to match `swiftc`'s is an open question (§6).

#### 4.3.3 Generic signatures and conformances

- **Requirement reasoning.** Generic signatures (conformance, superclass, layout, and same-type requirements, plus associated types) are minimized and queried with a term-rewriting **requirement machine**. The design follows the publicly documented approach in *Compiling Swift Generics*.
- **Conformance table.** Conformances are stored in a `ConformanceTable`: sorted `(nominal TypeId, ProtocolId)` keys, each pointing to a conformance record that holds conditional requirements, a witness list, and the source (declared, inherited from a superclass, synthesized, or retroactive).
  - Lookup is a binary search followed by a check of the conditional requirements against the requirement machine. That check is not O(1) in general.
- **Synthesized conformances.** `Equatable`, `Hashable`, `Comparable` (for enums), `Codable`, `RawRepresentable`, `CaseIterable`, and the `Sendable` inference rules (§4.4) are synthesized here.
- How generic code is *executed* (monomorphization in Tier 0, metadata passing in Tier 1) is out of scope here and covered in [11](11-generics-and-runtime-metadata.md).

#### 4.3.4 Other checked features

Macro declarations and uses: role attributes, introduced-name specifiers, `#externalMacro` targets, and the argument types of macro uses, which are type-checked like a call before expansion ([16](16-macros.md)). Access control; availability; property wrappers; `@inlinable`/`@usableFromInline` restrictions; `@frozen`; enum exhaustiveness (the space engine); `defer`; `throws` and `rethrows` checking; protocol extensions and their default implementations; class inheritance, overrides, and `final`; and initializer rules (designated/convenience, `required`, failable).

#### 4.3.5 Required feature profile (VectraOS)

VectraOS, the first-party user, builds with the **Swift 6.4** compiler, and its Tier 0 code is held to stricter settings: every target is built with `-enable-experimental-feature Embedded`, `-enable-experimental-feature Lifetimes`, `-strict-memory-safety`, `-Werror StrictMemorySafety`, `-Werror EmbeddedRestrictions`, `-Wwarning PerformanceHints`, `-enforce-exclusivity=unchecked`, `-Osize` and whole-module compilation. Everything below is required. It is checked with the same D5 parity rule as the rest of the language. Counts are use sites in VectraOS's 171 Swift files at the time it became the first-party consumer; rows with no use yet are required by components VectraOS's roadmap lifts later, and say which.

| Feature | VectraOS use | Swift-Stack requirement | Owner |
|---|---|---|---|
| `@c` / `@c(name)` (C-compatible functions), and `@c @implementation` | 10 today, all `@c @implementation`: Swift bodies for functions that `kernel.h` and `loader.h` declare, called from assembly and C. A Swift-implemented libc (`@c(getenv)`, `@c(exit)`) arrives with the userland in roadmap V2. | Check that the signature is C-representable, and for `@implementation` that it matches the imported C declaration. Emit an unmangled C symbol with the C calling convention. Callable from C through the shared TypePool. | here; symbols in [11](11-generics-and-runtime-metadata.md) §7 |
| `@_extern(c, "sym")` (`Extern` feature) | None yet; libc entry points on hosted builds (V2) | Declare an external C function by Swift signature, without a header | here; [11](11-generics-and-runtime-metadata.md) §7 |
| `@_silgen_name` | None yet | As for the stdlib ([12](12-standard-library-strategy.md) §5.2) | [12](12-standard-library-strategy.md) |
| Strict memory safety (SE-0458): `unsafe` expressions, `@unsafe`, `@safe`, `-strict-memory-safety` | ~2,100 `unsafe` expressions, ~40 `@unsafe` and ~60 `@safe`; all code built with `-Werror StrictMemorySafety` | Classify every declaration and expression as safe or unsafe, following `swiftc`'s rules, and diagnose under the `StrictMemorySafety` diagnostic group. Warnings are promotable to errors by group ([15](15-driver-and-diagnostics.md) §4.5). | here |
| Lifetime dependence (`Lifetimes` feature): `~Escapable`, `@_lifetime(...)` | Feature enabled on every target; ~100 uses of `Span`/`MutableSpan`/`RawSpan`/`MutableRawSpan`, no `@_lifetime` annotations of its own yet | Parse and check annotations here. Dependence enforcement is a mandatory AIR pass ([03](03-intermediate-representation.md) §4.3). | here + [03](03-intermediate-representation.md) |
| Value generics (SE-0452): `InlineArray<let count: Int, Element>` | ~270 uses of `InlineArray` | Integer generic parameters in the TypePool, generic signatures, specialization and mangling | here + [11](11-generics-and-runtime-metadata.md) |
| Typed throws (`throws(E)`) | ~900 uses (VectraOS principle 17: errors are values) | As in §4.3 | here |
| Noncopyable types (`~Copyable`) | ~75 uses | As in §4.5 | here |
| `Synchronization` module: `Atomic<T>` | ~70 imports, ~120 `Atomic<Int>`/`<UInt64>`/`<Bool>`/… in the kernel (no `Mutex` on the kernel's targets) | `Atomic` builtins lowering to AIR atomics with the requested orderings | [12](12-standard-library-strategy.md) |
| `_Volatile` module: `VolatileMappedRegister` | 13 imports, ~80 uses in the kernel's MMIO drivers (UART, IOMMUs, interrupt controllers) | Volatile load and store builtins lowering to AIR volatile memory operations ([03](03-intermediate-representation.md) §4.2) | [12](12-standard-library-strategy.md) |
| `@_noAllocation`, `-no-allocations` | None yet; `@AudioRenderer` ([16](16-macros.md)) puts it on real-time callbacks once VectraOS lifts its SDK (V6), and VectraOS's performance contracts name it | Performance-annotation checking, per function or for a whole module | [03](03-intermediate-representation.md) §4.3–4.4 |
| `-enforce-exclusivity=unchecked` | Every Embedded target | Omit dynamic exclusivity checks. Static exclusivity diagnostics still apply. | [03](03-intermediate-representation.md) §4.4 |

New features that VectraOS adopts are added to this table as they appear. The table is kept current by the `ss-census` tool ([09](09-roadmap.md)). In CI it counts feature, attribute and flag uses over a pinned VectraOS tree, and ranks the unsupported ones by use count, which in turn sets implementation order. The [09](09-roadmap.md) differential corpus is the source tree itself, so additions are detected by the build failing.

### 4.4 Swift 6 concurrency checking

Concurrency checking is part of the type system. It is therefore in scope for G1.

- **Actor isolation.** Isolation is inferred and checked for declarations and closures:
  - `actor` types, global actors (`@MainActor`), `nonisolated` (including `nonisolated(unsafe)`), `isolated` parameters, and `#isolation`;
  - inheritance of isolation through protocol conformance and overrides;
  - the isolation of default arguments and stored property initializers.
- **`Sendable` checking.**
  - Structural inference for non-public structs and enums.
  - Explicit conformance checking: stored properties of a class, which must be `final` with immutable `Sendable` properties.
  - `@unchecked Sendable`.
  - `@Sendable` and `sending` function types and parameters (SE-0430).
  - Sendability checking at isolation boundaries (crossing calls, captures).
- **Region-based isolation** (SE-0414). This analysis is flow-sensitive, so it runs as an AIR mandatory diagnostic pass over the control-flow graph ([03](03-intermediate-representation.md)). Sem supplies the isolation facts it consumes.
- **Language modes.** Swift 6 mode makes violations errors. Swift 5 mode emits them as warnings according to the same rules that `swiftc` uses.

The runtime side (executors, task allocation, the VectraOS port backend) is in [08](08-runtime-and-stdlib.md).

### 4.5 Ownership: type-level rules

Sem handles the declarative side of ownership:

- `~Copyable` and `~Escapable` suppression, plus inference of conditional copyability (`extension Box: Copyable where T: Copyable`);
- `consuming`, `borrowing`, and `inout` parameter conventions;
- the `consume`, `copy`, and `discard self` operators;
- `deinit` on noncopyable types;
- lifetime-dependence annotations, which the upstream stdlib uses for `Span` and friends ([12](12-standard-library-strategy.md)).

Checking that a consumed value is not used again, inserting `deinit` calls, and enforcing exclusivity are flow-sensitive. They run in AIR ([03](03-intermediate-representation.md) §4.3) and are not described here.

### 4.6 C ↔ Swift interop (no ClangImporter)

C headers are parsed by Swift-Stack's own C frontend into the shared `TypePool`. C declarations keep their **C types**. When Swift code refers to an imported C declaration, Sem produces its **Swift view** through the import map. The mapping is computed lazily, cached in `importMap: Column<TypeId>` indexed by C `TypeId`, and is deterministic.

| C type | Imported Swift type |
|---|---|
| `int`, `unsigned`, `short`, … | `CInt` (= `Int32`), `CUnsignedInt`, `CShort`, … (stdlib typealiases) |
| `char` | `CChar`: `Int8` or `UInt8` depending on the target's `char` signedness (for example, `UInt8` on Linux/AArch64) |
| `long`, `unsigned long` | `CLong` / `CUnsignedLong` (= `Int`/`UInt` on LP64) |
| `T *` (`_Nonnull`) | `UnsafeMutablePointer<T′>` (`UnsafePointer<T′>` if `T` is `const`) |
| `T *` (`_Nullable`) | `UnsafeMutablePointer<T′>?` |
| `T *` (unannotated) | `UnsafeMutablePointer<T′>!` (implicitly unwrapped, matching `swiftc`) |
| `void *` / `const void *` | `UnsafeMutableRawPointer` / `UnsafeRawPointer` (Optional by nullability, as above) |
| `struct S` | imported struct with **identical** C layout; bit-fields and anonymous members exposed as computed properties |
| `union U` | imported struct with overlapping computed properties |
| `enum E` | struct with `rawValue` by default; a Swift `enum` when `enum_extensibility(closed/open)` is present |
| function pointer | `@convention(c)` function type, Optional by nullability |
| `va_list` | `CVaListPointer`. Variadic C functions are not directly callable from Swift (matching `swiftc`) |

- **Typedef names.** Typedef names are preserved as Swift typealiases, for example `size_t` → `Int` through `typealias size_t = UInt`. This follows `swiftc`'s rules for `size_t` and for the standard integer typedefs.
- **C macros.** An object-like macro whose replacement is a single literal, or a parenthesized constant expression over literals, casts to imported types, and other importable macros, is imported as a Swift `let` constant whose type follows `swiftc`'s rules. Function-like macros are not imported.
- **Inline C functions.** C `static inline` functions are type-checked as C and lowered to AIR on demand. The optimizer can then inline them into Swift callers ([03](03-intermediate-representation.md)).
- **Imported names.** `swift_name`, `swift_private`, and `NS_SWIFT_NAME`-style attributes are honored for renaming.
- **C module boundaries.** How Swift code names a C module (`import Glibc`, VectraOS's `import CKernel`) and maps it to headers is defined by the module-map mechanism in [13](13-modules-and-incremental-builds.md).

## 5. Alternatives considered

- **A single global constraint system with no fast path,** as in `swiftc`. It is semantically simplest, but slow on common code. The staged design keeps the same semantics with lower average cost, provided admissibility is enforced.
- **A heuristic early commit** ("fall back to the contextual type"). Rejected: it changes which programs are accepted, and that violates D5.
- **Mapping C `int` and Swift `Int32` to the same `TypeId`.** Rejected: C and Swift have different type rules (implicit conversions, distinct `long`/`long long`), and a single ID cannot carry both.
- **Qualifiers as separate interned types.** Workable, but it multiplies pool entries. Qualifier bits on the handle are cheaper, and C qualifiers never apply to Swift types.
- **Reusing Clang through ClangImporter.** Excluded by the clean-room principle ([00](00-overview-and-principles.md)).

## 6. Open questions

1. **The solver work limit.** Must the "too complex" threshold match `swiftc`'s, or is accepting expressions that `swiftc` rejects as too complex a permitted divergence under D5? This needs a decision from the D5 owner.
2. **Statement expressions.** Are GNU statement expressions (`({ … })`) needed in the host-header profile? Some glibc macros use them, but only when user code expands those macros.
3. **Swift 5 language mode.** Is Swift 5 mode (concurrency diagnostics as warnings) in scope for v1, or is Swift 6 mode the only mode?
4. **Upstream `swiftc` behavior.** Is there a tractable way to track changes in upstream `swiftc` ranking behavior across releases? This affects how the D5 differential suite is versioned ([09](09-roadmap.md)).
