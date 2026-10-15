# 11. Generics, Runtime Metadata, Symbol Mangling & Swift Calling Convention

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [02](02-semantic-analysis.md), [03](03-intermediate-representation.md), [04](04-backend.md), [06](06-linker.md), [07](07-debugging-and-sdi.md), [08](08-runtime-and-stdlib.md), [10](10-semantic-ir-and-name-resolution.md), [12](12-standard-library-strategy.md), [13](13-modules-and-incremental-builds.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

Generics are the hardest part of implementing Swift, so this chapter specifies how Swift-Stack implements them at its two runtime tiers (D3):

- **Tier 0 (Embedded)** specializes every generic use at compile time. No runtime type metadata is created for value types.
- **Tier 1 (Full)** compiles generic code once, in an unspecialized form that receives **type metadata** and **witness tables** as hidden arguments. Specialization ([03](03-intermediate-representation.md)) is an optimization layered on top.

The chapter also defines the metadata layout, value and protocol witness tables, the existential and enum layouts, dynamic casts, the `_SS` symbol mangling, and the Swift calling convention used by Swift-Stack.

Per **D1**, none of this is binary-compatible with Apple's Swift ABI. Swift-Stack binaries cannot link against `swiftc`-built Swift libraries, and the reverse is also true. C ABI compatibility is unaffected. §9 lists what Apple-ABI compatibility would require later.

## 2. Goals

- Full Swift generic semantics in Tier 1: unspecialized generic functions and types, conditional conformances, associated types, existentials, `as?`/`is`/`as!`, class inheritance, and metatypes.
- In Tier 0, rejection of unspecializable code with a clear diagnostic, and no other runtime cost.
- A single layout algorithm for every type, so that Tier 0 and Tier 1 agree on the layout of any type they share, and layout depends only on the type and the target.
- Static, read-only metadata wherever possible: no registration at process start, and 32-bit relative pointers in descriptors so that `.rodata` needs no dynamic relocations.
- Deterministic mangled names (D6) that identify overloads by their full signature and can be demangled for diagnostics and debuggers ([07](07-debugging-and-sdi.md)).

## 3. Non-goals

- Apple Swift ABI compatibility in v1 (D1): its mangling, metadata layout, runtime entry points, and object header.
- **Library evolution / resilience.** Every module is compiled with full layout knowledge of the types it imports, as `swiftc` does without `-enable-library-evolution`. The only values of unknown size are values of unspecialized generic parameter types.
- Objective-C interop: no ObjC `isa`, no bridging, no `@objc` dispatch.
- Reflection (`Mirror`, field-name lookup at runtime) in Tier 0. In Tier 1 it is deferred, although descriptors keep field names so it can be added later.

## 4. Tier 0: full monomorphization

Tier 0 follows the published Embedded Swift model.

1. **Specialization is total.** Every call to a generic function is specialized for concrete type arguments. This requires access to the bodies of imported generic functions, which are serialized as AIR in module interfaces ([13](13-modules-and-incremental-builds.md)). Specializations are emitted as *link-once* symbols, deduplicated by mangled name ([06](06-linker.md)).
2. **Value types have no metadata.** Structs, enums, and tuples have no runtime metadata or value witness tables; all copies and destroys are inlined.
3. **Classes get minimal metadata.** Each class has a superclass pointer, a destroy function, and a vtable, emitted statically. This is enough for virtual dispatch and class downcasts.
4. **Unsupported in Tier 0:**
   - existentials of non-class-bound protocols (`any P` where `P` is not `AnyObject`-constrained)
   - `any Any`
   - untyped `throws` (it requires `any Error`; typed throws is supported)
   - key paths
   - reflection
   - dynamic casts to protocol types

   Class-bound existentials MAY be supported, since they need only a class reference and statically emitted witness tables.
5. **Diagnostics.** If a generic use cannot be specialized, compilation stops with an error that shows the instantiation chain that led to it. Typical causes are polymorphic recursion (`f<T>` calls `f<Array<T>>`) and a `public` generic entry point with no concrete caller in the image. Instantiation depth is capped (default 256, configurable) so that polymorphic recursion terminates.

## 5. Tier 1: metadata and witness tables

All three targets are 64-bit, so a word is 8 bytes. Runtime-instantiated metadata uses absolute pointers; static descriptors in `.rodata` use 32-bit self-relative offsets (`RelPtr`).

### 5.1 Type metadata

Every type metadata record starts with this header:

```
offset 0   kind:  UInt32       // struct, enum, optional, tuple, function, class,
                               // existential, metatype, foreign (C) struct, ...
offset 4   flags: UInt32       // isComplete, hasGenericArgs, isCopyable, ...
offset 8   vwt:   *ValueWitnessTable
offset 16  descriptor: *NominalTypeDescriptor   // null for structural types
offset 24  kind-specific payload
```

- **Nominal value types (struct, enum).** The payload holds the generic argument metadata pointers in canonical generic-signature order, then the witness tables for each conformance requirement in canonical requirement order, then (for structs whose layout depends on generic arguments) a field-offset vector.
- **Tuples.** The payload is the element count, then (metadata, offset) for each element.
- **Function types.** The payload holds the parameter and result metadata plus convention and effect flags (`async`, `throws`, thin/thick).
- **Non-generic types** have fully initialized metadata emitted statically. Nothing is registered at process start.

**Nominal type descriptors** live in `.rodata` and hold:

- the name
- a `RelPtr` to the parent context
- the generic signature (parameter count and requirement list)
- the field descriptor (field names and field-type references)
- for generic types, a `RelPtr` to the metadata accessor function

### 5.2 Value witness tables

A value witness table (VWT) describes how to handle values of a type without knowing the type statically.

```
struct ValueWitnessTable {           // 8-byte aligned; stride 88
    initializeWithCopy   : fn(dest, src, M)     // null if ~Copyable
    assignWithCopy       : fn(dest, src, M)     // null if ~Copyable
    initializeWithTake   : fn(dest, src, M)     // move
    assignWithTake       : fn(dest, src, M)
    destroy              : fn(obj, M)           // runs deinit for ~Copyable / classes
    getEnumTagSinglePayload   : fn(obj, emptyCases, M) -> UInt32
    storeEnumTagSinglePayload : fn(obj, tag, emptyCases, M)
    size                 : UInt64
    stride               : UInt64
    flags                : UInt32  // alignMask, isPOD, isBitwiseTakable,
                                   // isInlineStorage (fits existential buffer), isCopyable
    extraInhabitantCount : UInt32
}
```

There are shared VWTs for POD types of each common size, so that most types point at one of a small number of tables.

**`~Copyable` generics.** In code over `T: ~Copyable`, the type checker guarantees that copy witnesses are never called. For non-copyable types the copy slots are null and `isCopyable` is clear; if a null copy slot is reached anyway, the runtime traps. `destroy` runs the type's `deinit`. `~Escapable` follows upstream stabilization (open question 4).

### 5.3 Protocol witness tables

```
word 0       RelPtr-backed *ProtocolConformanceDescriptor
words 1..k   inherited (base) protocol witness tables, in declaration order
words k+1..  requirements in protocol declaration order:
               - method / property accessor / initializer: function pointer
               - associated type: metadata accessor fn(conformingMetadata) -> *Metadata
               - associated conformance: accessor returning a witness table
```

- **Unconditional conformances** of non-generic types have static witness tables.
- **Conditional conformances,** and conformances of generic types whose associated types depend on arguments (for example `Array: Equatable where Element: Equatable`), are **instantiated** at runtime from a pattern and cached. The pattern takes the conditional-requirement witness tables as instantiation arguments.

### 5.4 Calling unspecialized generic code

For `func f<T: P & Q, U>(_ x: T, _ y: U) -> T`, the arguments are passed in this order:

1. Formal parameters, lowered by the Swift calling convention (§8). Values of type `T` and `U` are address-only and passed indirectly; the result `T` is returned through an indirect result pointer.
2. Generic metadata: `T`, `U`, in canonical generic-signature order.
3. Witness tables: `T: P`, `T: Q`, in canonical requirement order (protocols ordered by mangled name).
4. Context registers (§8): `self` in the self register for methods, or the closure context in the same register for thick closures; the async context; the error register.

Methods of generic types do not take separate metadata arguments for the type's own generic parameters; they read them from the `self` metadata (passed as the `Self` metadata argument).

**Unknown-size locals** in unspecialized code are allocated on the stack with a dynamic `alloca` sized from `vwt.size`. In `async` functions they are allocated from the task allocator instead ([08](08-runtime-and-stdlib.md)). They are copied, moved, and destroyed only through VWT calls. Associated types are reached through the witness table's associated-type accessors.

### 5.5 Metadata instantiation and caching

Generic type metadata is created on demand through `ss_getGenericMetadata(descriptor, args)`.

- **The cache** is one concurrent hash table per descriptor, keyed by the argument tuple. Reads are lock-free; inserts use compare-and-swap. If two threads race to build the same entry, one result wins and the other is discarded. Metadata is never freed; it lives in a process-lifetime arena.
- **Completion states.** Each entry is either `layoutComplete` (size, alignment, and VWT are known) or `complete` (field types and conformances are resolved). This lets recursive generic types such as `struct Node<T> { var next: Box<Node<T>>? }` be instantiated without deadlock: a thread that needs only the layout of an entry still being built waits for `layoutComplete`, and dependency cycles are detected and diagnosed.
- **Witness table instantiation** for conditional conformances uses the same cache structure, keyed by (conformance descriptor, conforming metadata).

### 5.6 Existentials

| Kind | Representation | Size |
|---|---|---|
| `any P` (opaque) | 3-word inline buffer + metadata + 1 witness table per protocol | 5 words for a single protocol |
| `any Any` | 3-word buffer + metadata | 4 words |
| `any P` where `P: AnyObject` | object reference + witness tables | 2 words for a single protocol |
| `AnyObject` | object reference | 1 word |
| `any Error` | single pointer to a refcounted box (metadata + witness table + value) | 1 word (fits the error register) |
| `any P.Type` | metadata + witness tables | 2 words for a single protocol |

**Inline vs boxed storage.** A value is stored inline when `vwt.flags.isInlineStorage` is set: `size ≤ 24`, `align ≤ 8`, and the type is bitwise-takable. Otherwise the value lives in a refcounted heap box and the buffer holds the box pointer. Copying an existential that holds a box shares the box. Opening an existential for mutation (`inout` on an opened existential) first checks that the box is uniquely referenced, and copies it if it is not (copy-on-write).

**Non-copyable existentials** (`any P & ~Copyable`) use the same layout; their boxes are never shared.

### 5.7 Class metadata and objects

```
Class metadata = common header (§5.1, kind = class)
  + superclass metadata pointer
  + instance size (UInt32), instance alignment mask (UInt16), flags
  + ivar destroyer (fn)
  + field-offset vector (only for generic classes with dependent layout)
  + vtable: one function pointer per overridable member, in declaration order;
    a subclass copies its parent's vtable and replaces overridden slots
```

- **Object header.** 16 bytes: a metadata (`isa`) pointer, then a 64-bit refcount word that holds the inline strong and unowned counts, with a side table for weak references ([08](08-runtime-and-stdlib.md)).
- **Dispatch.** Without resilience, vtable slot indices are fixed at compile time. `final` members, members of `final` classes, and calls whose receiver type is known are dispatched directly.
- **Generic class metadata** is instantiated at runtime (§5.5). Field offsets are computed from the argument VWTs when the layout depends on them.

### 5.8 Enum layout

Layout is computed by one algorithm, used both by the compiler (when payload types are known) and by the runtime (when instantiating generic enums, which consults the payload VWTs):

1. **No payloads.** Zero cases is uninhabited (size 0). One case has size 0. Otherwise the tag is the smallest of `UInt8`, `UInt16`, or `UInt32` that can hold the case count.
2. **Single payload** (including `Optional`). The empty cases are encoded in the payload's **extra inhabitants**: bit patterns that are never valid for the payload, such as null and low addresses for references, or values 2–255 for `Bool`. If there are more empty cases than inhabitants, tag bytes are appended after the payload.
3. **Multiple payloads.** If the payloads share spare bits that can hold the case index, the tag goes there; otherwise tag bytes are appended. The spare-bit mask for pointers is **declared per target**, conservatively: on AArch64 the top byte is not used, because of TBI; on x86-64 and RV64 only the bits above the configured user address-space width are used.
4. **`indirect` cases** store a pointer to a refcounted box.
5. **C enums** imported from C23 are plain integers of their underlying type.

### 5.9 Dynamic casts

`ss_dynamicCast(dest, src, srcMetadata, destMetadata, flags) -> Bool` implements `as?`, `as!`, and `is`. Supported cases:

- **Class to class:** walk the superclass chain.
- **To a protocol or existential:** look up the conformance; on success, wrap the value in the existential representation.
- **Opening a source existential,** then retrying with the dynamic type.
- **Optional:** wrapping and unwrapping, including nested Optionals.
- **Tuples:** element-wise, when the labels match.
- **Functions:** identical function types only.
- **Collections** (`[Any] as? [Int]`): delegated to stdlib entry points that the runtime calls ([12](12-standard-library-strategy.md)).

**Conformance lookup.** The compiler emits one conformance record per conformance into a section named `ss_conformances` on ELF and `__TEXT,__ss_conform` on Mach-O. The ELF name deliberately has no leading dot: `__start_`/`__stop_` symbols are only synthesized for sections whose names are valid C identifiers. At runtime the records are scanned once per (metadata, protocol) pair; results, including negative results, are cached in a lock-free hash table. A generic nominal type matches by its descriptor, and any conditional conformance is then instantiated (§5.3).

### 5.10 Key paths (deferred)

Key paths are deferred to after the first Tier 1 milestone. Design sketch:

- A key path is a refcounted object holding a list of components: stored-property offset, computed property (getter/setter plus captured arguments), optional chaining, and tuple element.
- It is instantiated from a static pattern in `.rodata`, with generic arguments filled in at runtime.
- The open question is whether FoundationEssentials (D2) requires key paths before Tier 1 is complete ([12](12-standard-library-strategy.md)).

## 6. Specialization in Tier 1

Specialization is the main optimization for generic code ([03 §4.4](03-intermediate-representation.md)).

- **When.** Generic functions are specialized when the type arguments are concrete at a call site and their bodies are available. Bodies are available for the current module and for `@inlinable` or `@usableFromInline` declarations from imported modules, serialized per [13](13-modules-and-incremental-builds.md).
- **`@_specialize`.** Explicit `@_specialize(where ...)` attributes in the stdlib cause the listed specializations to be emitted eagerly.
- **Entry points.** The unspecialized entry point remains for public generic declarations, and for any function that is called from unspecialized code or captured as a value.
- **Identity.** A specialization's mangled name is its identity (§7), which makes deduplication deterministic (D6).

## 7. Symbol naming: `_SS` mangling

Swift symbols need distinct, deterministic names: overloads differ by argument labels and types; there are generic specializations, closures, local types, and extension members. Swift-Stack uses its own grammar. It is shorter than Apple's and intentionally different from it (D1).

```
symbol       ::= "_SS" entity specialization?
entity       ::= context decl
context      ::= module ( nominal | extension )*
module       ::= ident
nominal      ::= ident nominal-kind                 // S struct, C class, E enum, P protocol
extension    ::= "X" module generic-sig?            // extension declared in module, with constraints
decl         ::= kind name signature? discriminator?
kind         ::= "F" func | "v" var | "g" getter | "s" setter | "m" modify
               | "i" init | "d" deinit | "u" subscript | "c" closure
               | "M" type metadata | "N" nominal descriptor | "W" witness table
               | "V" value witness table | "A" metadata accessor
name         ::= ident labels?
labels       ::= "l" ( ident | "_" )* "_"            // argument labels, "_" = unlabeled
signature    ::= generic-sig? "T" type* effects "_" type
effects      ::= ( "a" async | "t" throws | "y" type typed-throws )*
generic-sig  ::= "G" decimal requirement* "_"      // param count, then requirements
requirement  ::= "c" param type                     // conformance / superclass
               | "e" type type                      // same-type
               | "n" param                          // ~Copyable relaxation
discriminator ::= "L" decimal                       // local decl / closure index, source order
specialization ::= "Sp" type* "_"                    // concrete substitutions, in signature order
ident        ::= decimal chars                      // length-prefixed, UTF-8, punycode if non-ASCII
type         ::= std-type | nominal-ref | tuple | function | "Q" decimal (back-ref) | ...
std-type     ::= "Ki" Int | "Ku" UInt | "Kb" Bool | "Kd" Double | "Kf" Float
               | "Ks" String | "Ka" Array | "Ko" Optional | "Kk" Dictionary | ...
```

An illustrative example (the encoding may change while the format is in Draft):

```
func Geometry.Point.distance(to other: Point) -> Double      // in module Geometry
_SS8Geometry5PointS F8distancel2to_ T Q0 _ Kd
   (spaces added for readability; Q0 back-references the first nominal, Point)
```

**Rules:**

- Closures and local declarations are numbered in source order within their parent, so names do not depend on traversal order or threads (D6).
- Back-references (`Q n`) make repeated types compact.
- A demangler (`ss-demangle`, shared with the debugger and diagnostics) MUST round-trip every name the compiler produces. This is enforced by a test that demangles and re-mangles every symbol in the corpora.
- C symbols are never mangled.
- **Swift declarations with C names** are emitted under a plain C symbol, with the C calling convention, and are never `_SS`-mangled:
  - `@c` uses the Swift base name; `@c(name)` uses `name`;
  - `@_extern(c, "name")` declares an external C function by its Swift signature;
  - `@_silgen_name("name")` uses `name`, under the mapping table in [12](12-standard-library-strategy.md) §5.

  VectraOS's kernel and loader implement C-declared entry points this way (`@c @implementation`), and a Swift-implemented libc (`@c(getenv)`, `@c(exit)`, …) relies on it ([02](02-semantic-analysis.md) §4.3.5). For `.ss_symtypes` (§7.1), these symbols get a hash of their C-level signature, so a Swift `@c` definition and a C declaration of the same function are checked against each other.
- **Value generics** (SE-0452, e.g. `InlineArray<let count: Int, Element>`). Integer generic arguments are mangled as signed decimal literals in the generic-argument list. Specializations for different counts are distinct symbols. In Tier 1, integer generic parameters are passed as `Int` arguments alongside type metadata, and metadata for such types is cached per (descriptor, integer arguments).

### 7.1 Relationship to `.ss_symtypes`

The mangled name already encodes a Swift declaration's signature, so a Swift caller and callee that disagree on parameter *types* fail to link as an undefined symbol, not as a silent mismatch. The `.ss_symtypes` side section adds two checks that mangling cannot provide. Its on-disk format is owned by [06](06-linker.md); its meaning is defined here.

- **Signature hash.** Exported C symbols have no mangling, so the 64-bit hash of the canonical C function type is their only link-time type check.
- **Layout fingerprint.** A 64-bit hash over the recursive layout of every nominal type that appears in the signature: field types, offsets, size, and alignment. This catches a stale module compiled against an older definition of `struct Foo`, which mangles identically.

Both hashes are the first 64 bits of BLAKE3 over a canonical byte encoding of the type, so they are deterministic and independent of the host. When a symbol is undefined, the linker also looks for definitions with the same demangled base name and reports them as probable signature mismatches.

## 8. Swift calling convention (swiftcc)

Swift functions use swiftcc register assignments so that existing knowledge and tooling around swiftcc carry over. This does not make Swift-Stack ABI-compatible with Apple (§9).

| Role | x86-64 | AArch64 | RV64 |
|---|---|---|---|
| Integer / pointer arguments | RDI, RSI, RDX, RCX, R8, R9 | X0–X7 | a0–a7 |
| FP arguments | XMM0–XMM7 | V0–V7 | fa0–fa7 |
| Integer results (direct) | RAX, RDX, RCX, R8 | X0–X3 | a0–a3 *(proposed)* |
| FP results (direct) | XMM0–XMM3 | V0–V3 | fa0–fa3 *(proposed)* |
| Vector (`SIMDn`, `Builtin.Vec*`) args/results ≤ 16 bytes | XMM0–XMM7 | V0–V7 | v8–v15 (RVV, part of the RVA23 baseline) *(proposed)* |
| `self` / closure context (`swiftself`) | R13 | X20 | *to be confirmed* |
| Error (`swifterror`) | R12 | X21 | *to be confirmed* |
| Async context (`swiftasync`) | R14 | X22 | *to be confirmed* |
| Indirect result pointer | follows C convention (open question 3) | X8 | follows C convention |

The x86-64 and AArch64 context registers match LLVM's swiftcc. The RV64 assignments MUST be confirmed against LLVM's `RISCVCallingConv` swiftcc handling before the RV64 backend is frozen; until then they are open question 2. Swift-Stack-to-Swift-Stack calls on RV64 work whatever the choice, but changing it later breaks binary compatibility between Swift-Stack versions.

**Rules:**

- **Aggregate expansion.** A loadable struct, tuple, or enum argument or result is scalarized when its expansion fits within 4 integer and 4 FP registers; otherwise it is passed or returned indirectly. Address-only values (unknown size, or non-bitwise-takable) are always indirect.
- **Errors.**
  - **Untyped `throws`.** The callee sets the error register to a non-null `any Error` box when it throws, and the caller tests the register after the call. The register MUST be zeroed by the caller before the call.
  - **Typed throws of a concrete type.** The error value is written to an indirect error-result buffer passed as a hidden argument, and the error register holds a non-null sentinel to signal that a throw happened.
- **Async functions** receive their async context in the async register, and suspend and resume as described in [03 §4.2](03-intermediate-representation.md) and [08](08-runtime-and-stdlib.md).
- **Callee-saved registers** are those of the platform C ABI, plus the context registers when the callee does not use them. **Hidden generic arguments** follow the formal arguments (§5.4) in the remaining argument registers, and then on the stack.
- **C functions** (`@convention(c)`, imported C declarations) use the platform C ABI exactly, as specified in [04](04-backend.md).

## 9. What Apple-ABI compatibility would require (post-v1)

1. Apple's mangling grammar (`$s` prefix), including its substitution and word-compression rules, in place of `_SS`.
2. Apple's metadata and descriptor layouts: VWT at offset −1, context-descriptor hierarchy, relative-pointer conventions, and metadata completion protocol.
3. Apple's runtime entry points and object header (`swift_retain`, `swift_allocObject`, and so on) with their exact calling conventions.
4. Library evolution: resilient types, resilient witness tables, and dispatch thunks.
5. Consuming `.swiftmodule` / `.swiftinterface` files instead of, or in addition to, Swift-Stack interfaces ([13](13-modules-and-incremental-builds.md)).
6. Objective-C interop on Darwin.

The scope of this list is why D1 excludes compatibility from v1.

## 10. Alternatives considered

- **Monomorphize everything in Tier 1 too.** Rejected. Separate compilation of public generics, existentials, and `as?` to protocols all require runtime metadata. Code size also grows without bound for heavily generic stdlib code.
- **Dictionary passing without a VWT** (passing size and copy functions individually). Rejected. A single VWT pointer per type parameter keeps calling sequences short and lets metadata and VWTs be shared.
- **Reusing Apple's layouts now** for future compatibility. Rejected for v1. It locks in a much larger and less documented ABI before Swift-Stack has a working Tier 1; the delta is tracked in §9.
- **Plain hashes instead of a mangling scheme.** Rejected. Names must be readable in backtraces and demanglable by the debugger, and hashes alone cannot do that.

## 11. Open questions

1. Is the per-target spare-bit mask for VectraOS pointers stable? It depends on VectraOS's address-space layout (user mappings in the lower half; the kernel in the upper half, at a random base).
2. What are the RV64 `swiftself`/`swifterror`/`swiftasync` registers? They must be confirmed against LLVM `RISCVCallingConv` (also [04](04-backend.md) §6, question 1).
3. On x86-64, should the indirect result pointer be a hidden first argument (RDI, as in C) or a dedicated register (as on AArch64 with X8)?
4. ~~Should `~Escapable` / lifetime dependencies be in v1?~~ Resolved: yes, in both tiers. VectraOS builds every target with the `Lifetimes` feature and uses `Span` and `MutableSpan` throughout its Tier 0 code ([02](02-semantic-analysis.md) §4.3.5). `~Escapable` values need no runtime metadata beyond that of their `Escapable` counterparts.
5. Does FoundationEssentials need key paths before Tier 1 is complete (§5.10)?
6. Is it worth keeping field names in descriptors for future reflection, given the size cost on VectraOS images?
7. Should metadata-completion cycles be diagnosed at compile time where possible, rather than only detected at runtime?
