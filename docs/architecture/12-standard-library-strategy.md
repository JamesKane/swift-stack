# 12. Standard Library Strategy

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [02](02-semantic-analysis.md), [08](08-runtime-and-stdlib.md), [10](10-semantic-ir-and-name-resolution.md), [11](11-generics-and-runtime-metadata.md), [13](13-modules-and-incremental-builds.md) |

---

## 1. Summary

Much of Swift is defined in its standard library, not in the compiler:

- `Int`, `Bool`, `Optional`, `Array`, and `String` are library types.
- Arithmetic and comparison operators are library functions.
- Literals are typed through library protocols such as `ExpressibleByIntegerLiteral`.

A Swift compiler is therefore incomplete without a stdlib that it can compile.

**Decision D2.** Swift-Stack compiles the upstream Swift standard library (`swiftlang/swift`, `stdlib/public/core`) and swift-foundation's `FoundationEssentials` from source, at a pinned release. Neither source tree is vendored into the compiler. Swift-Stack implements the compiler-known entities those sources rely on (§5) and its own runtime (§6, [08](08-runtime-and-stdlib.md)).

## 2. Goals

- Run unmodified upstream stdlib sources for the pinned release. Keep the patch queue small, documented, and upstreamable where possible (§10).
- Produce stdlib behaviour that matches swiftc's for the supported feature set (D5). This covers `String`, Unicode, hashing semantics, collection algorithms, and numeric formatting.
- Build a Tier 0 (Embedded) stdlib and a Tier 1 (full) stdlib from the same sources (§7).
- Keep the compiler free of upstream code: the stdlib is an *input* to the compiler, like a user's package.

## 3. Non-goals

- A clean-room reimplementation of the stdlib. Writing and maintaining one would cost person-years and still diverge from the language's de facto definition.
- Binary compatibility with Apple's `libswiftCore` (D1). The stdlib is compiled with Swift-Stack's ABI, mangling (`_SS`, [11](11-generics-and-runtime-metadata.md)), and metadata layout.
- Objective-C bridging (`_ObjectiveCBridgeable`, `NSString`-backed strings). These code paths are compiled out (§5.4).
- Full Foundation (`Foundation`, `FoundationInternationalization`, `FoundationNetworking`) in v1. Only `FoundationEssentials` is in scope.

---

## 4. Licensing and the Clean-Room Principle

### 4.1 Licence

The upstream stdlib and swift-foundation are licensed under Apache-2.0 with the Runtime Library Exception. To be verified for each pinned release, including swift-foundation's exact licence file. Using them as compiled inputs is permitted. Swift-Stack MUST:

- Keep the sources in a separate pinned checkout (a git submodule or a fetched archive with a recorded hash) under `External/` ([09](09-roadmap.md) §4.2). They must never be copied into `Sources/`.
- Preserve upstream licence and NOTICE files in the checkout and in any distributed stdlib binaries.
- Keep Swift-Stack's own patches (§10) in a separate patch directory, applied at sync time.

### 4.2 How this fits Principle 3

Principle 3 ([00](00-overview-and-principles.md)) is restated more precisely:

- **Clean-room scope:** the compiler, assembler, linker, debugger, and runtime are written from specifications. No LLVM, Clang, swift-syntax, lld, upstream Swift compiler code, or upstream C++ runtime code is copied or linked.
- **Library inputs:** the stdlib and FoundationEssentials are Swift-language libraries. The language's own definition depends on them. Compiling them is the same activity as compiling any user package. Their source is not a reference for implementing the compiler.

The upstream *compiler* remains off-limits as an implementation reference. Its observable behaviour is used only as a differential oracle ([09](09-roadmap.md)). Where the stdlib requires a compiler-known entity (§5), its required behaviour is derived from:

1. Swift Evolution proposals and the language reference.
2. How the stdlib source uses the entity.
3. Observed swiftc behaviour on test programs.

---

## 5. Compiler-Known Entities

The upstream stdlib is not ordinary Swift. It relies on compiler features that user code generally cannot or should not use. Swift-Stack MUST implement each entity in this section, scoped to what the pinned sources actually use. An automated audit lists every use: it runs over the Embedded subset as the first task of milestone M4, and over the full stdlib and FoundationEssentials as the first task of M6 ([09](09-roadmap.md)). The inventory below is the expected shape and is to be verified by that audit.

### 5.1 The `Builtin` module

`Builtin` is a compiler-synthesized module, imported by the stdlib with `-parse-stdlib` semantics. Swift-Stack synthesizes it in Sem ([10](10-semantic-ir-and-name-resolution.md)).

| Category | Examples | Lowering |
|---|---|---|
| Types | `Builtin.Int1`…`Int64`, `Int128`, `Builtin.Word`, `FPIEEE32/64/80`, `RawPointer`, `NativeObject`, `BridgeObject`, `Vec*`, `Executor`, `Job` | Primitive `TypeId`s in the TypePool ([02](02-semantic-analysis.md)). These are the *only* hard-coded primitive types; `Swift.Int` is an ordinary struct wrapping `Builtin.Int64`/`Word`. `Builtin.Vec*` map to the AIR vector types behind `SIMDn<T>` ([17](17-simd-and-vectorization.md) §5.1). |
| Arithmetic | `add_Int64`, `sadd_with_overflow_Int64`, `cmp_slt_Int64`, `fadd_FPIEEE64`, `trunc*`, `zext*`, `sext*` | 1:1 AIR opcodes ([03](03-intermediate-representation.md)) |
| Memory | `load`, `take`, `assign`, `initialize`, `destroy`, `copyMemory`, `allocRaw`, `deallocRaw`, `gep*`, `bindMemory` | AIR memory ops / runtime calls |
| Refcounting & ownership | `retain`, `release`, `isUnique`, `unsafeGuaranteed`, `castReference` | AIR ARC ops |
| Atomics | `atomicload_*`, `atomicstore_*`, `atomicrmw_*`, `cmpxchg_*`, `fence_*` | AIR atomic ops with ordering operand |
| Control | `unreachable`, `condfail_message`, `int_trap`, `assumeTrue`, `expect` | AIR terminators / hints |
| Generics & metadata | `sizeof`, `strideof`, `alignof`, `isPOD`, `isBitwiseTakable`, `getTypeName` (to be verified) | Constants after specialization; value-witness queries otherwise ([11](11-generics-and-runtime-metadata.md)) |
| Concurrency | task creation, `getCurrentAsyncTask`, continuation builtins, `buildDefaultActorExecutorRef` | Calls into the task runtime ([08](08-runtime-and-stdlib.md)) |

### 5.2 Attributes

| Attribute | Required behaviour |
|---|---|
| `@_transparent` | The function MUST be inlined at every call site, before diagnostics that depend on the inlined body (for example overflow of constants). It is also treated as `@inlinable`. |
| `@inlinable`, `@usableFromInline` | The function body is serialized into the module interface ([13](13-modules-and-incremental-builds.md)) and is available for inlining and specialization in client modules. `@usableFromInline` internal declarations get public symbols. |
| `@_alwaysEmitIntoClient` | The body is emitted into each client and never exported as a symbol from the defining module. |
| `@frozen` | The layout is fixed and visible to clients. With D1 and whole-stdlib compilation, every stdlib type is effectively non-resilient in v1. The attribute is recorded but not needed for correctness (see open question 2). |
| `@_semantics("...")` | Opaque string tags read by the optimizer (for example `array.get_count`, `optimize.sil.specialize.generic.never`). Swift-Stack MUST accept every tag. It MAY act on a documented subset ([03](03-intermediate-representation.md)), and unknown tags are ignored. |
| `@_effects(readonly / readnone / releasenone …)` | Trusted effect annotations feeding ARC optimization and GVN. Swift-Stack MUST accept them and SHOULD use `readonly` and `readnone`. |
| `@_silgen_name("sym")` | Binds a declaration to a fixed symbol name, used for runtime entry points and C shims. Swift-Stack maps each name through a table to its `_SS` runtime symbol or C symbol ([11](11-generics-and-runtime-metadata.md)). A name missing from the table is a compile error, never a silent fallback. |
| `@_specialize`, `@_optimize`, `@_nonoverride`, `@_borrowed`, `@_disfavoredOverload`, `@_implements`, `@_spi` … | Each is classified during the audit as *semantic* (must implement: `@_disfavoredOverload` affects overload ranking, D5; `@_implements` affects witness matching) or *advisory* (accepted, MAY be ignored). |

### 5.3 Compiler-known protocols and types

The compiler must locate these stdlib declarations by name after loading the `Swift` module, and use them in type checking and lowering:

- **Literals:**
  - `ExpressibleByIntegerLiteral`, `…FloatLiteral`, `…BooleanLiteral`, `…StringLiteral`, `…ExtendedGraphemeClusterLiteral`, `…UnicodeScalarLiteral`, `…ArrayLiteral`, `…DictionaryLiteral`, `…NilLiteral`, `…StringInterpolation`
  - The `_ExpressibleByBuiltin*Literal` protocols
  - The default literal types (`IntegerLiteralType`, etc.)
- **Optional:** `Optional`, including the special conversion rules for `nil`, optional promotion, and `?`/`!` chaining.
- **Core protocols:**
  - `Equatable`, `Hashable`, `Comparable`, `RawRepresentable`, `CaseIterable`, `Codable` (synthesized conformances)
  - `Sequence`/`IteratorProtocol` (`for`-`in`)
  - `Error` (throwing)
  - `Sendable`, `Copyable`, `Escapable`, `BitwiseCopyable`
  - `Actor`, `AsyncSequence`, `AsyncIteratorProtocol`
- **Collection conversions:** `Array`, `Dictionary`, `Set` (literal and upcast conversions), `String` (interpolation lowering).
- **Unsafe pointers:** `UnsafePointer` and friends, for C import ([02](02-semantic-analysis.md)) and for inout-to-pointer conversion.

`_ObjectiveCBridgeable` and the other Objective-C bridging protocols are excluded. Code guarded by `#if _runtime(_ObjC)` compiles out because Swift-Stack reports `_runtime(_Native)`.

### 5.4 Conditional compilation

Swift-Stack MUST define the platform conditions the stdlib tests:

- `os(...)` with a new value `Todhchai` (to be decided with upstream naming conventions in mind), `arch(...)`, `_endian(...)`, `_pointerBitWidth(...)`, `_runtime(_Native)`
- `canImport(...)`
- `hasFeature(...)` for each upstream feature flag the sources test
- `$Feature` checks
- `compiler(>=...)`: Swift-Stack reports the pinned upstream language version

### 5.5 C shims

The stdlib imports C declarations from `SwiftShims` (`stdlib/public/SwiftShims`). These headers are parsed by Swift-Stack's C frontend (D7) and imported through the normal C interop path ([02](02-semantic-analysis.md)). The headers are C-compatible; any C++-only constructs are to be verified during the audit.

### 5.6 gyb-generated sources

Some stdlib files are generated from `.gyb` templates by a Python tool in the upstream repository. These files:

- Are expanded **at sync time** using the gyb tool from the same pinned upstream tag. The expanded `.swift` files are recorded with their hashes.
- Make gyb a build-time tool for producing stdlib inputs. It is not a compiler dependency, and Python is not needed to build the compiler or user code.

---

## 6. Runtime Entry Points

The stdlib calls the runtime through `@_silgen_name` declarations and through calls the compiler emits implicitly. Every such entry point maps to a symbol in Swift-Stack's runtime ([08](08-runtime-and-stdlib.md)). Main families (names follow upstream spelling for traceability; emitted symbols use the `_SS` scheme):

| Family | Representative upstream entry points |
|---|---|
| Allocation | `swift_allocObject`, `swift_deallocObject`, `swift_slowAlloc`, `swift_slowDealloc`, `swift_allocBox` |
| Refcounting | `swift_retain`, `swift_release`, `swift_retain_n`, `swift_bridgeObjectRetain/Release`, `swift_isUniquelyReferenced_nonNull_native`, `swift_weak*`, `swift_unownedRetain*` |
| Metadata | `swift_getGenericMetadata`, `swift_getTupleTypeMetadata*`, `swift_getFunctionTypeMetadata*`, `swift_getExistentialTypeMetadata`, `swift_getTypeName` |
| Conformances & casts | `swift_conformsToProtocol`, `swift_dynamicCast*`, `swift_getWitnessTable` |
| Existentials & errors | `swift_allocError`, `swift_deallocError`, `swift_errorRetain/Release`, `swift_willThrow` |
| Exclusivity | `swift_beginAccess`, `swift_endAccess` |
| Once / globals | `swift_once` |
| Failure | `swift_reportError`, `_swift_stdlib_reportFatalError*` |
| Stdlib stubs | `_swift_stdlib_*` helpers: hashing seed, float parsing and printing, Unicode property lookup, `random` |
| Concurrency | `swift_task_create`, `swift_task_switch`, `swift_task_enqueue*`, `swift_continuation_*`, `swift_taskGroup_*`, `swift_task_localValue*`, `swift_defaultActor_*` |
| Unicode data | Upstream keeps generated Unicode tables as C data headers consumed by C++ accessor stubs (to be verified). Swift-Stack parses the data headers with its C frontend and reimplements the thin accessors in C23. |

Upstream's `stdlib/public/stubs` and `stdlib/public/runtime` are C++, and are not compiled (no C++ frontend; C++ is a non-goal). Every function they provide that the core sources reach is reimplemented in [08](08-runtime-and-stdlib.md). The audit produces the authoritative list. A link failure caused by a missing runtime symbol is treated as a tracked defect.

---

## 7. Tier 0 and Tier 1 Builds

Both tiers are built from the same pinned sources:

| | Tier 0 (Embedded) | Tier 1 (Full) |
|---|---|---|
| Configuration | The upstream Embedded Swift configuration of `stdlib/public/core`: the same file set and feature conditions the upstream Embedded stdlib build uses (to be verified per release). | The full `core` file set. |
| Generics | Fully specialized. Unspecialized generic code is not emitted ([11](11-generics-and-runtime-metadata.md)). | Metadata-passing plus specialization. |
| Distribution | Shipped as a module interface with `@inlinable` bodies only. Clients specialize what they use; there is no prebuilt binary beyond non-generic leaf functions. | A prebuilt static library plus module interface. |
| Unavailable APIs | Upstream `@_unavailableInEmbedded` (or its successor) is honoured. Uses produce a diagnostic. | — |

### 7.1 Stdlib modules and types Todhchai depends on

These are compiled from the same pinned sources. They are listed because each one pulls in compiler features ([02](02-semantic-analysis.md) §4.3.5):

- **`Span`, `MutableSpan`, `RawSpan`, `MutableRawSpan`** need `~Escapable`, lifetime dependence, and the lifetime-checking pass ([03](03-intermediate-representation.md) §4.3).
- **`InlineArray`** needs value generics. Its storage uses a fixed-size `Builtin` array type (expected `Builtin.FixedArray`, to be verified by the audit).
- **`_Volatile`** (`VolatileMappedRegister`) is a separate upstream module, built when the `Volatile` feature is enabled. Its `Builtin` volatile load and store map to AIR volatile accesses ([03](03-intermediate-representation.md) §4.2).
- **`SIMDn<T>`** needs `Builtin.Vec*` and mandatory inlining ([17](17-simd-and-vectorization.md) §5.1).

## 8. FoundationEssentials and Macros (D4)

FoundationEssentials provides `Data`, `Date`, `UUID`, `URL`, `JSONEncoder`/`JSONDecoder`, `AttributedString`, `Predicate`, `FormatStyle` scaffolding, and more. Its dependencies are **to be audited** for the pinned release. Expected items:

- **Swift macros.** Swift macros like `#Predicate` and `#Expression` are declared in FoundationEssentials and implemented in a separate `FoundationMacros` compiler plugin built on swift-syntax. Whether FoundationEssentials *itself* uses macros internally (rather than only declaring them) is to be verified.
- **Custom availability macros.** These are passed as `-define-availability` compiler options, not macro plugins. Swift-Stack MUST support that option.
- **Package dependencies.** Expected to include swift-collections (for `AttributedString` internals, to be verified) and the C shim target `_FoundationCShims`.

**Decision.** Macros are supported through executable compiler plugins (D4, [16](16-macros.md)). No natively reimplemented allowlist is needed.

1. **FoundationEssentials macros.** `FoundationMacros` is built as a plugin executable from the pinned swift-foundation sources, by the host `swiftc` until Swift-Stack can build it (M6). `#Predicate` and `#Expression` then work like any user macro.
2. **Stdlib macros.** Macros declared by the upstream stdlib (expected: `@DebugDescription`, `@TaskLocal`, and others; to be verified by the audit) are treated the same way. Their implementations in the upstream Swift repository's macro sources are compiled into a plugin as inputs.
3. **The audit (§5)** also records which macros the pinned sources *use* internally. Their plugins are then required to build the stdlib or FoundationEssentials at all, not only by clients.

Package dependencies such as swift-collections are compiled from pinned sources under the same policy as §4.

---

## 9. Testing

- **Upstream stdlib tests.** Upstream's `test/stdlib` and `validation-test/stdlib` contain both executable tests (`StdlibUnittest`-based) and FileCheck-style compiler-output tests. Only the executable tests are used. They are compiled by Swift-Stack, run, and their pass/fail is compared against the same tests built with swiftc at the pinned tag. `StdlibUnittest` itself is compiled as an input under §4.
- **FoundationEssentials and Todhchai tests.** These suites use swift-testing. Its library is compiled from pinned sources as an input. Its `TestingMacros` plugin is built as an executable plugin ([16](16-macros.md)). Runtime test discovery requires Tier 1 metadata or section support (open question 4).
- **Differential behaviour.** `String` normalization, grapheme breaking, `Hasher` (with a fixed seed), float printing, and sorting stability are checked against swiftc output on generated inputs.
- **Audit gate.** CI fails if the pinned sources use a `Builtin`, attribute, `@_semantics` tag, or `@_silgen_name` that is not in the classification tables (§5). Upgrading the pin therefore surfaces new requirements explicitly.

## 10. Version Pinning and Patch Policy

- Track **one** upstream Swift 6.x release tag for the stdlib, and a matching swift-foundation tag. The initial pin is **Swift 6.4**, the compiler and swift-syntax (`604.x`) release that Todhchai builds against. The pin moves when Todhchai moves. Both are recorded in a single pin file with commit hashes.
- Move the pin deliberately, at most once per upstream minor release. Each move is a separate change with the audit diff attached.
- **Patch queue.** If the pinned sources depend on a feature Swift-Stack does not yet support, the preferred order is:
  1. Implement the feature.
  2. Exclude the affected file or API in the build configuration, with a diagnostic for users.
  3. Patch the source.

  Every patch lives in `External/patches/`, records its reason and the upstream file and line, and is reviewed for removal at each pin move. The queue SHOULD stay under roughly 20 patches; exceeding that is a signal to re-plan.
- Patches MUST NOT change observable stdlib semantics. If a patch would, the API is excluded instead.

## 11. Alternatives considered

- **Clean-room stdlib.** Rejected (§3). Too large, and it would define a dialect.
- **Link Apple's prebuilt `libswiftCore`.** Rejected by D1: incompatible ABI and metadata, and no Todhchai build.
- **Vendor the stdlib into the repository.** Rejected. It blurs the clean-room boundary and complicates licence hygiene. A pinned external checkout keeps the boundary visible.
- **Natively reimplement the macros the stdlib and Foundation need (allowlist).** Rejected once macros became a goal (D4). Running the real plugins is less work and can't diverge from upstream behavior.

## 12. Open questions

1. Final `os(...)` spelling for Todhchai and whether to propose it upstream.
2. Should Tier 1 stdlib clients be able to rely on non-frozen stdlib layouts (whole-world compilation), or should Swift-Stack implement library evolution (resilience) for the stdlib from the start?
3. Does FoundationEssentials internally require any macro expansion, and does it hard-depend on swift-collections? (Audit item.)
4. How does swift-testing discover tests at runtime (a section-based record or conformance scanning) on Linux and Todhchai, and which runtime support does that require ([16](16-macros.md) open question 4)?
5. Pin cadence: follow every Swift 6.x minor, or only even minors?
