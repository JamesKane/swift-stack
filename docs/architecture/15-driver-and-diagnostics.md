# 15. Driver, Build Integration, and Diagnostics

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [01](01-frontend.md), [02](02-semantic-analysis.md), [10](10-semantic-ir-and-name-resolution.md), [13](13-modules-and-incremental-builds.md), [14](14-measurement-methodology.md), [16](16-macros.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

The driver is the single `swift-stack` executable. It parses command-line options and selects a target. It builds an in-process job graph over the compiler, assembler and linker stages, and runs that graph on a work-stealing thread pool. It owns the diagnostic engine shared by every stage.

Compiling, assembling and linking all happen in one address space, with objects handed over in memory. The only subprocesses are Swift macro plugins, which run out of process by design (§4.4, [16](16-macros.md)).

## 2. Goals

- One executable, several personalities: compiler, C compiler (`cc`-compatible subset), assembler, linker.
- Cross-compilation by triple from day one.
- Deterministic output independent of job count (D6).
- Diagnostics that are precise, stable, machine-readable, and testable.
- Integration with SwiftPM and conventional Makefile/CMake builds without requiring them.

## 3. Non-goals

- Full flag compatibility with `swiftc` or `clang`. Only a documented subset is accepted under compatibility personalities.
- A language server in v1. The SemIR and module formats are designed not to preclude one.

## 4. Design

### 4.1 Personalities

The executable selects its personality from `argv[0]` or from the first subcommand:

| Invocation | Personality | Accepted options |
|---|---|---|
| `swift-stack build …` | Native | Full Swift-Stack option set |
| `swift-stack cc …` / `ss-cc` | C compiler | Subset of `cc`: `-c -o -I -D -U -std=c23 -O0/-O1/-O2 -g -target`, `-M*` dependency output |
| `swift-stack as …` / `ss-as` | Assembler | Subset of GNU `as` options |
| `swift-stack ld …` / `ss-ld` | Linker | Subset of `ld.lld` options sufficient for SwiftPM and common Makefiles |
| `swift-stack swiftc …` | Swift compatibility | Subset of `swiftc` options used by SwiftPM and by Todhchai's CMake build, including `-load-plugin-executable <path>#<module>`, `-plugin-path`, `-parse-as-library`, `-wmo`, `-Osize`, `-no-allocations`, `-strict-memory-safety`, `-enforce-exclusivity=unchecked`, `-enable-experimental-feature {Embedded, Lifetimes, Extern, Volatile}`, and `-Werror <group>` / `-Wwarning <group>` for diagnostic groups. Feature names and diagnostic-group names match `swiftc`'s spelling, so that existing builds work unchanged ([02](02-semantic-analysis.md) §4.3.5). Todhchai's backend flag `-Xllvm -disable-loop-idiom-all` is accepted and mapped to `-disable-loop-idioms` ([17](17-simd-and-vectorization.md) §5.5). Unsupported options are a hard error, never silently ignored. |

Native mode takes a whole build description (modules, sources, dependencies) and produces final artifacts in one process. The compatibility personalities exist so that existing build systems can drive Swift-Stack one step at a time, using on-disk objects and module files ([13](13-modules-and-incremental-builds.md)).

### 4.2 Target selection

`--target <triple>` selects the following, from a static target table:

- the instruction encoder ([04](04-backend.md));
- ABI rules, object and executable format ([06](06-linker.md));
- runtime tier and default sysroot ([08](08-runtime-and-stdlib.md));
- the ISA baseline, and any opt-in features given with `-target-feature` ([17](17-simd-and-vectorization.md) §5.4).

The table is data, not code. Adding a new OS on an existing architecture is a table entry plus a linker layout. The host triple is the default. Todhchai triples (`x86_64-unknown-todhchai`, `aarch64-unknown-todhchai`, `riscv64-unknown-todhchai`) are first-class.

### 4.3 Job graph and scheduling

The driver turns the build description into a directed acyclic graph of jobs at the granularity described in [00](00-overview-and-principles.md) §8: files, declarations, functions, call-graph SCCs, input sections.

- **Thread pool:** work-stealing with per-worker deques. Workers are pinned only when running benchmarks.
- **Barriers:** phases that must finish before canonical renumbering (D6) are explicit graph nodes.
- **Memory ownership:** each job runs with a scratch arena borrowed from the worker and reset when the job completes ([00](00-overview-and-principles.md) Principle 2).
- **Cancellation:** after the first fatal error, the scheduler drains in-flight jobs and doesn't start new ones in dependent subgraphs. Independent subgraphs continue, so that all diagnostics are reported (bounded by `--error-limit`).

### 4.4 Macro plugin host

The driver owns the pool of Swift macro plugin processes ([16](16-macros.md) §5.5):

- Plugins are started lazily, with at most `min(jobs, 4)` processes per plugin.
- Requests are dispatched from compiler workers, and their results are attached to the requesting expansion site (D6).
- The host handles crashes, timeouts and malformed replies by emitting diagnostics and restarting the plugin.
- Plugins are sandboxed by default (`--plugin-sandbox=off` to debug).
- Expansion results go through the artifact cache ([13](13-modules-and-incremental-builds.md)).
- `--verify-macro-determinism` expands each site twice in separate processes and compares the results.

### 4.5 Diagnostics

#### Representation

Each worker owns a thread-local `DiagnosticBag`: a set of `Column`s ([00](00-overview-and-principles.md) Principle 2) with these fields:

| Column | Type | Meaning |
|---|---|---|
| `ids` | `DiagId` (u16) | Diagnostic kind from a static table (severity, message template, category) |
| `locs` | `GlobalLocation` (`UnitId` + `SourceLocation`, 8 bytes) | Primary location. `SourceLocation` is per compilation unit and expansion-aware for C macros and Swift macro expansions ([01](01-frontend.md), [10](10-semantic-ir-and-name-resolution.md), [16](16-macros.md)) |
| `argsOffset` / `argsCount` | u32 / u16 | Slice into a flat argument column (types, names, integers) |
| `notesOffset` / `notesCount` | u32 / u16 | Attached notes (secondary locations) |
| `fixItsOffset` / `fixItsCount` | u32 / u16 | Replacement ranges and text |

Message text is never formatted on the hot path. Rendering happens once, at the end.

#### Ordering and determinism

Bags are merged and sorted by (unit order, `SourceLocation`, `DiagId`, argument values) before rendering. Output is therefore identical for any `--jobs` value (D6).

#### Error recovery contract

- The parser recovers syntactically ([01](01-frontend.md) §Error recovery).
- Semantic analysis uses an `error` type that suppresses follow-on diagnostics ([10](10-semantic-ir-and-name-resolution.md)).
- A stage MUST NOT emit a diagnostic whose only cause is an earlier error.

#### Output formats

- **Human-readable:** colored, with source excerpt and caret.
- **`--diagnostics-format=json`:** one object per line, stable schema.
- **`--diagnostics-format=sarif`:** later.

#### Diagnostic identifiers

Every `DiagId` has a stable textual name, e.g. `sema.overload.ambiguous`. It also belongs to at most one **diagnostic group** using `swiftc`'s group names (e.g. `StrictMemorySafety`, SE-0443), so that `-Werror StrictMemorySafety` and `-Wwarning <group>` behave as they do with `swiftc`. Tests match on names, not message text. Warnings can be controlled by name or category (`-W<name>`, `-Wno-<name>`, `-Werror=<name>`).

#### Parity with `swiftc`

D5 requires the same accepted programs, not the same messages. Differential tests compare accept/reject decisions and diagnostic *locations*, not wording.

### 4.6 Build-system integration

- **SwiftPM:** via the `swiftc` compatibility personality and a toolset file pointing SwiftPM at `swift-stack`. Native mode is preferred for whole-project builds where SwiftPM is not required.
- **Make/CMake:** `ss-cc`, `ss-as` and `ss-ld` behave like a conventional cross toolchain. `-MD`/`-MF` dependency files are supported for C.
- **Caching:** the content-addressed artifact cache ([13](13-modules-and-incremental-builds.md)) is driver-managed and shared across personalities.

### 4.7 Observability

- **`--time-phases`:** per-phase wall time, bytes, lines and item counts, in the formats required by [14](14-measurement-methodology.md).
- **`--stats`:** table sizes (tokens, nodes, types, instructions), arena high-water marks, peak RSS.
- **`--dump=<stage>`:** textual dumps of TokenBuffer, ParseTree, SemIR, AIR (before or after a named pass), LIR, and the object model. These are deterministic and used by FileCheck-style golden tests.
- **`--dump=macro-expansions`:** every macro expansion with its site, role and discriminator ([16](16-macros.md)).
- **`--verify-each`:** runs IR verifiers after every pass (debug builds of the compiler enable this by default).

## 5. Alternatives considered

- **Separate executables per stage with on-disk handoff** (the traditional model). Rejected as the default because it reintroduces the serialization cost the in-memory pipeline removes. It is still supported through the personalities, for build-system compatibility.
- **Format diagnostics eagerly.** Rejected: string formatting on worker threads costs time and makes ordering harder.

## 6. Open questions

1. Which SwiftPM version and `swiftc` flag subset is the compatibility target?
2. Should native mode read `Package.swift` directly? That would require evaluating Swift manifests, which in turn requires Tier 1 and Foundation.
3. Is a persistent compiler daemon (warm caches across builds) in scope after v1?
