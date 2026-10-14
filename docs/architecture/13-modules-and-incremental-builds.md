# 13. Modules, Separate Compilation, and Incremental Builds

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [02](02-semantic-analysis.md), [03](03-intermediate-representation.md), [06](06-linker.md), [07](07-debugging-and-sdi.md), [08](08-runtime-and-stdlib.md), [10](10-semantic-ir-and-name-resolution.md), [11](11-generics-and-runtime-metadata.md), [14](14-measurement-methodology.md), [15](15-driver-and-diagnostics.md), [16](16-macros.md) |

## 1. Summary

A Swift-Stack module compiles to three artifacts:

1. A **module interface** (`.ssmodule`): a versioned, deterministic, memory-mappable file that holds the module's exported declarations (SemIR), the slice of its `TypePool` they reference, its conformance table, and the bodies importers may inline or specialize.
2. **Objects**, in the [06](06-linker.md) `Object` model, serialized as ELF or Mach-O when written to disk. They carry `.ss_symtypes` and an `.ss_debug` SDI fragment.
3. **Dependency records**, used by incremental builds.

The driver ([15](15-driver-and-diagnostics.md)) orders modules by their dependency DAG and runs each phase across all worker lanes (D11). Rebuild decisions use fine-grained, per-declaration interface hashes, so a change to a function body does not invalidate the modules or files that depend on it. All artifacts are stored in a content-addressed cache, which is safe because outputs are deterministic (D6).

## 2. Goals

- MUST support separate compilation of Swift modules and C libraries, including linking against modules built in earlier invocations.
- MUST make module interfaces loadable by `mmap` with lazy, per-declaration access. Importing a large module MUST NOT require deserializing all of it.
- MUST produce bitwise-identical module files and objects for identical inputs and flags (D6). Module files MUST NOT contain timestamps or absolute paths.
- MUST rebuild the minimal set of work after an edit. In particular, a change to a function body MUST NOT recompile dependents unless the body is part of the interface (for example `@inlinable` functions, or generic bodies in Tier 0).
- SHOULD make the incremental-build scenarios in §6 measurable and meet their targets ([14](14-measurement-methodology.md)).

## 3. Non-goals

- **A stable module format across compiler versions in v1.** Module files are build artifacts keyed by the compiler's build id; they are not a distribution format.
- **Compatibility with swiftc `.swiftmodule` or `.swiftinterface` files (D1).**
- **Binary library evolution (resilience) as a distribution mechanism in v1.** Resilient type layout is still supported where the language requires it ([11](11-generics-and-runtime-metadata.md)).
- **Clang modules and module maps.** C headers are handled as described in §5.4.

## 4. Artifacts and identity

### 4.1 Declaration keys

Each exported declaration is identified by a stable **declaration key**: its `_SS`-mangled name ([11](11-generics-and-runtime-metadata.md)) for Swift, and `c:` plus its linkage name or tag for C. Keys, not compilation-local IDs, link interfaces to their importers. `TypeId`, `DeclId`, and `AtomId` values are local to one compilation (they are reassigned canonically after parallel phases, [10](10-semantic-ir-and-name-resolution.md)). Inside a module file they are file-local indices.

### 4.2 Hashes

For every exported declaration the compiler computes two hashes (BLAKE3, 128-bit), both of which are stored in the module file:

- **Interface hash.** Covers everything an importer can observe:
  - the signature, generic signature, and attributes
  - access level and conformances
  - for non-resilient structs and enums, the stored layout (stored property types and order, enum cases), because importers depend on layout
  - for `@inlinable` or `@usableFromInline` declarations, and for generic functions in Tier 0, the serialized body
- **Body hash.** Covers the implementation only.

The module's **interface fingerprint** is the hash of all its exported declarations' keys and interface hashes, in key order.

## 5. Design

### 5.1 `.ssmodule` format

The file uses the same conventions as SDI ([07](07-debugging-and-sdi.md) §5.1): little-endian; a header and table directory; 8-byte-aligned tables of fixed-size records; a string pool; index 0 means "none". The normative layout is a C23 header (`include/ssmodule/ssmodule.h`). Tables are serialized `Column<T>` images (D8), so loading a table is a pointer-and-count view into the mapping, not a copy.

| Table | Contents |
|---|---|
| Header | magic `SSM1`, format major/minor, compiler build id, target triple, language mode, tier (0/1), interface fingerprint, flags |
| Imports | imported modules, each with the interface fingerprint it was compiled against |
| Declaration index | on-disk hash table: (parent context key, name) → declaration records, used for lazy name lookup |
| Declarations | SemIR declaration records ([10](10-semantic-ir-and-name-resolution.md)) with key, kind, access, generic signature, type, and interface/body hashes |
| Types | the module's `TypePool` slice in file-local indices; types from other modules are stored as `(import index, type key)` references |
| Conformances | sorted `(type key, protocol key) → witness table record`, including conditional requirements |
| Operators | operator and precedence-group declarations, needed for sequence folding in importers ([10](10-semantic-ir-and-name-resolution.md)) |
| Inlinable bodies | serialized AIR ([03](03-intermediate-representation.md)) after mandatory lowering, for `@inlinable`/`@usableFromInline`, Tier 0 generic bodies, and C `static inline` functions |
| Symbol types | `(declaration key → ss_symtype signature hash)` for every exported symbol (§5.3) |
| C macros | importable object-like macros (constants) for Swift clients of C modules |
| Source map | relative source paths (after prefix mapping) and per-file content hashes, for diagnostics and incremental checks |

**Import.** An importer `mmap`s the file, validates the header, and resolves names lazily through the declaration index. When a declaration is first used, its types are *re-interned* into the importer's `TypePool`, and a per-import remap table (file-local index → `TypeId`) caches the result. Types of declarations the importer never touches are never interned.

**Determinism.**

- Every table is sorted by key.
- The declaration index uses a fixed hash function and a fixed bucket layout.
- Paths are recorded relative to the project root or after `-ffile-prefix-map`-style remapping.
- Nothing depends on thread scheduling.

Declarations introduced by Swift macro expansions are serialized as ordinary declarations, along with their expansion buffers' text, so that diagnostics and debug info can still refer to them. A client of a module never needs the plugins that module used ([16](16-macros.md) §5.7).

### 5.2 Separate compilation of Swift modules

The driver compiles a module in three steps:

1. **Declaration phase.** Parse and type-check declarations ([02](02-semantic-analysis.md), [10](10-semantic-ir-and-name-resolution.md)), then emit `.ssmodule`. Dependents can start once this is done (*pipelining*): they need the interface, not the upstream objects.
2. **Body phase.** Type-check and lower function bodies, optimize, generate code, and produce objects and the SDI fragment.
3. **Link.** The executable is linked once all objects are available ([06](06-linker.md)).

In Tier 0, generic code is monomorphized in the module that uses it, from the generic bodies in the interface ([11](11-generics-and-runtime-metadata.md)). Specializations get deterministic, mangled names and are emitted as COMDAT-like link-once sections, so that identical specializations from different modules are deduplicated by the linker ([06](06-linker.md) §5.9).

### 5.3 Link-time type hashes and SDI fragments

- A **definition**'s `.ss_symtypes` record ([06](06-linker.md) §5.3) is computed from the definition being compiled.
- A **reference** to an imported symbol takes its hash from the symbol-types table of the `.ssmodule` that the importer compiled against.

If the provider's implementation later changes its signature without the importer being rebuilt, the two hashes differ and the linker reports the stale pair. This is the main practical value of link-time type checking for Swift code, since mangled names already cover overloads.

SDI fragments ([07](07-debugging-and-sdi.md) §5.6) are produced in the body phase and stored in the object's `.ss_debug` section. The linker merges them without access to any compiler state, so cached and freshly built modules are treated identically.

### 5.4 C libraries

A C library is compiled per translation unit to objects (with `.ss_symtypes` and SDI fragments) as usual.

For **Swift clients**, the C headers a module exposes are compiled into a C-kind `.ssmodule`. It contains declarations, types, `static inline` bodies as AIR, and importable macros, and it is computed for one *configuration*: target, include paths, predefined and command-line macros, and the D7 dialect profile. This gives Swift importers the benefit of a precompiled header without Clang modules.

For **C clients**, headers are parsed textually as C requires. A header-parse cache (§5.6) avoids re-lexing and re-parsing unchanged headers.

### 5.5 Dependency tracking

The compiler records, for each source file:

- **Provides.** The declaration keys, with their interface hashes, that the file defines.
- **Depends.** Lookups performed while type-checking the file:
  - top-level name lookups `(module, name)`, *including lookups that failed*, so that adding a new overload or shadowing declaration correctly invalidates the file
  - member lookups `(type key, member name)`
  - conformance queries `(type key, protocol key)`
  - operator lookups
  - the interface hashes of every external declaration that was actually used
- **Inputs.** For C translation units:
  - the resolved include graph, with each file's path and content hash
  - *negative* include results (searched paths that did not exist, and `__has_include` answers)
  - `#embed` resources and their hashes
  - a digest of the initial macro state (predefined + command line)
- **Swift macro expansions** ([16](16-macros.md) §5.7). Each expansion depends on its request payload (the syntax text of the use site and its context, with paths normalized) and on the content hash of the plugin executable. Editing the attached declaration re-expands that site only. Replacing a plugin binary invalidates all of its expansions. Expansion results are cached values (§5.6).

A file must be rebuilt when its content hash changed, or when any recorded dependency resolves differently or has a different interface hash. For C, the include graph and negative entries are re-validated with `stat` and content hashing, and any change triggers a reparse of the translation unit.

Function-level caching: within a file that must be rebuilt, the code for each function is cached under the hash of its optimized AIR, the target and flags, and the interface hashes of the inlined callees. Unchanged functions reuse their machine code and SDI records.

### 5.6 Content-addressed artifact cache

- **Keys.** `BLAKE3(compiler build id, target, flags that affect output, input content hashes, dependency interface hashes)`.
- **Values.** Module interfaces, macro expansion results, per-file SemIR summaries, per-function code and SDI records, objects, header-parse results, and dependency records.
- **Location.** A per-user cache (for example `$XDG_CACHE_HOME/swift-stack`) plus an optional per-project cache. Eviction is least-recently-used with a size cap.
- **Integrity.** Each value records its key and a content hash and is verified when read; a corrupt entry is discarded and rebuilt.
- **Sharing.** Because of D6 and path remapping, cache entries may be shared between machines with the same compiler build. A remote cache is deferred until a concrete user exists (§8, question 5).

### 5.7 Driver build graph

The driver ([15](15-driver-and-diagnostics.md) §4.3) orders work by the module dependency DAG. It does not build a general job graph. Each step is a phase run by all lanes (D11): per-module declaration phase, per-file (or per-function-batch) body phase, per-TU C compilation, assembly, and link. Independent modules at the same depth share a phase. The driver:

1. Loads the previous dependency records and computes the invalid set (§5.5) before scheduling anything.
2. Runs the phases with module pipelining (§5.2): a dependent module's declaration phase can join the same lane phase as its upstream module's body phase.
3. Compares the interface fingerprint after each declaration phase. If the fingerprint did not change, no downstream module is invalidated, even though the module's bodies are recompiled.
4. Writes new dependency records atomically when the build finishes.

A *null build* (nothing changed) MUST check only content hashes and `stat` results and do no compiler work.

### 5.8 Record bundles

A record bundle (`.ssrec`, [15](15-driver-and-diagnostics.md) §4.8) is a single file in the same content-addressed store format as §5.6. It holds:

- every input blob a compilation read, keyed by content hash;
- the command line, target and pins;
- the macro-plugin responses ([16](16-macros.md) §5.7);
- the compiler build id;
- the expected output hashes.

Replay mounts the bundle as the only file system and plugin source. Because inputs are already content-addressed and outputs are deterministic (D6), recording adds no new identity scheme, just a way to export a closed subset of the store.

## 6. Incremental-build targets

The old claim of "near-instant incremental builds" is replaced by scenarios that can be measured. They run on the 100K-LOC reference corpus defined in [14](14-measurement-methodology.md) (8 cores, warm OS file cache). All values are hypotheses until measured.

| Scenario | Target (edit → linked executable) |
|---|---|
| Null build | < 50 ms |
| Body-only edit in one Swift function (non-inlinable) | < 200 ms ([14](14-measurement-methodology.md) B10) |
| Body-only edit in an `@inlinable` function used by 10 files | < 500 ms |
| Add a public declaration to a mid-graph module | < 1 s |
| Touch a widely included C header (comment-only change) | < 1 s; may become a null build, see §8 question 1 |
| Cold build with an empty cache | the throughput targets in [14](14-measurement-methodology.md) |

Each scenario is also a correctness test: the incremental output MUST be bitwise identical to a clean build of the same sources (D6). CI checks this on scripted edit sequences.

## 7. Alternatives considered

- **Textual interfaces (like `.swiftinterface`).** Rejected for v1: they must be re-parsed and re-type-checked on every import. A binary, `mmap`able interface is cheaper to load, and v1 does not need cross-version stability.
- **Whole-module recompilation on any change.** Rejected: simple, but it makes edit latency proportional to module size.
- **File-level dependencies only (like `make`).** Rejected for Swift: a body-only edit would invalidate every importer. File-level tracking is still used for C, where the language model is textual.
- **Clang-style module maps for C headers.** Rejected: they add a configuration language. Per-configuration C-kind `.ssmodule` files give Swift importers most of the benefit.

## 8. Open questions

1. Should an edit that only touches a header's comments or whitespace still invalidate its dependents? This depends on whether header caching keys on a token-stream hash or on raw bytes. Hashing tokens is more precise but costs a lex.
2. What granularity should the body phase use: per file, or per function batch? Per-function batches balance work better but complicate dependency records.
3. Should inlinable bodies be serialized as AIR before or after optimization? Before is more stable across optimizer changes; after is faster for importers.
4. How should header caching handle macro state? It could be keyed by the full incoming macro-state digest, or only by the macros the header actually tests (more cache hits, more bookkeeping).
5. *Deferred:* a remote or shared cache protocol, and the trust model it would need (signed entries, a build-id allow-list). Revisit when a concrete user exists.
6. When Tier 1 library evolution is added, does the interface hash split into separate "layout" and "API" hashes?
