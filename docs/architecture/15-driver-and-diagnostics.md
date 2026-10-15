# 15. Driver, Build Integration, and Diagnostics

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [01](01-frontend.md), [02](02-semantic-analysis.md), [10](10-semantic-ir-and-name-resolution.md), [13](13-modules-and-incremental-builds.md), [14](14-measurement-methodology.md), [16](16-macros.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

The driver is the single `swift-stack` executable. It parses command-line options and selects a target. It runs the compiler, assembler and linker stages as a fixed sequence of phases, each executed by all worker lanes in SPMD style with barriers between phases (D11). It owns the diagnostic engine shared by every stage, the built-in profiler, and compile recording and replay.

Compiling, assembling and linking all happen in one address space, with objects handed over in memory. The only subprocesses are Swift macro plugins, which run out of process by design (§4.4, [16](16-macros.md)).

## 2. Goals

- One executable with the personalities that real users need: native, `cc`, and `swiftc`. VectraOS's CMake build drives `swiftc` for Swift and `clang` for C and for `.S` assembly (`-target <triple> -c`), so the `cc` personality assembles `.S` inputs, and links go to `ld.lld` directly. Standalone assembler and linker personalities are deferred until a concrete user exists.
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
| `swift-stack as …` / `ss-as` | Assembler | *Deferred until a concrete user exists.* `.s`/`.S` inputs are accepted by the native and `cc` personalities. |
| `swift-stack ld …` / `ss-ld` | Linker | *Deferred until a concrete user exists.* Linking happens in the native and `cc`/`swiftc` personalities. |
| `swift-stack swiftc …` | Swift compatibility | Subset of `swiftc` options used by SwiftPM and by VectraOS's CMake build: `-target`, `-module-name`, `-parse-as-library`, `-wmo`, `-Osize`, `-strict-memory-safety`, `-enforce-exclusivity=unchecked`, `-enable-experimental-feature {Embedded, Lifetimes}`, `-Xfrontend -function-sections`, `-Xcc <clang flag>`, and `-Werror <group>` / `-Wwarning <group>` for diagnostic groups (`StrictMemorySafety`, `EmbeddedRestrictions`, `PerformanceHints`); also `-load-plugin-executable <path>#<module>`, `-plugin-path`, `-no-allocations` and the `Extern` and `Volatile` features, for the macros and libc VectraOS lifts later. Feature names and diagnostic-group names match `swiftc`'s spelling, so that existing builds work unchanged ([02](02-semantic-analysis.md) §4.3.5). The backend flag `-Xllvm -disable-loop-idiom-all`, which a Swift-implemented libc needs under `swiftc`, is accepted and mapped to `-disable-loop-idioms` ([17](17-simd-and-vectorization.md) §5.5). Unsupported options are a hard error, never silently ignored. |

Native mode takes a whole build description (modules, sources, dependencies) and produces final artifacts in one process. The compatibility personalities exist so that existing build systems can drive Swift-Stack one step at a time, using on-disk objects and module files ([13](13-modules-and-incremental-builds.md)).

### 4.2 Target selection

`--target <triple>` selects the following, from a static target table:

- the instruction encoder ([04](04-backend.md));
- ABI rules, object and executable format ([06](06-linker.md));
- runtime tier and default sysroot ([08](08-runtime-and-stdlib.md));
- the ISA baseline, and any opt-in features given with `-target-feature` ([17](17-simd-and-vectorization.md) §5.4).

The table is data, not code. Adding a new OS on an existing architecture is a table entry plus a linker layout. The host triple is the default. VectraOS's triples are first-class: the freestanding ones its build uses today (Swift `x86_64-unknown-none-elf`, `aarch64-none-none-elf`, `riscv64-none-none-eabi`; C and assembly `x86_64-unknown-none-elf`, `aarch64-unknown-none-elf`, `riscv64-unknown-none-elf`), with VectraOS's ISA flags (`-mgeneral-regs-only`, `-march=rv64imac_zicsr_zifencei -mabi=lp64`, …), and an OS-named triple once the `os(...)` spelling is decided ([12](12-standard-library-strategy.md) open question 1).

### 4.3 Phases and lanes

Parallelism follows D11 ([00](00-overview-and-principles.md)): SPMD lanes by default, after Fleury's "multi-core by default" practice. There is no general job graph or work-stealing deque in v1.

- **Lanes.** The driver starts `--jobs` worker threads once. Each phase is one function that every lane runs with `(laneIndex, laneCount)`. Lanes are pinned only when running benchmarks.
- **Regular phases** (lexing and parsing files, declaration collection, relocation of input sections) partition their input deterministically: items are sorted by stable key and split into `laneCount` contiguous ranges of roughly equal estimated cost (bytes, token count, instruction count).
- **Irregular phases** (per-function optimization and code generation, call-graph SCC levels, [03](03-intermediate-representation.md) §4.4) put their items in a pre-sorted work array. Lanes take the next item with a shared atomic cursor. Results are written to the slot of the item's index, so output order never depends on which lane ran what.
- **Barriers** separate phases, including the canonical-renumbering barriers (D6, [10](10-semantic-ir-and-name-resolution.md) §4.6). The phase sequence is visible in one driver function, not spread through a dependency graph.
- **Memory ownership:** each lane owns a scratch arena, reset per item or per phase ([00](00-overview-and-principles.md) Principle 2).
- **Cancellation:** after the first fatal error, lanes finish their current item and the driver stops at the next barrier. Phases whose inputs are unaffected still run, so that all diagnostics are reported (bounded by `--error-limit`).
- **Separate compilation** (several modules in one invocation, [13](13-modules-and-incremental-builds.md) §5.7) runs modules in dependency order. All lanes work on one module's phase at a time; independent modules at the same depth are batched into the same phase.

### 4.4 Macro plugin host

The driver owns the pool of Swift macro plugin processes ([16](16-macros.md) §5.5):

- Plugins are started lazily, with at most `min(jobs, 4)` processes per plugin.
- Requests are dispatched from compiler workers, and their results are attached to the requesting expansion site (D6).
- The host handles crashes, timeouts and malformed replies by emitting diagnostics and restarting the plugin.
- Plugins run unsandboxed in v1, as `swiftc` does on Linux. Per-OS sandboxing (`--plugin-sandbox`) is deferred and listed as an open question (§6).
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
- **SARIF output:** deferred until a concrete user exists.

#### Diagnostic identifiers

Every `DiagId` has a stable textual name, e.g. `sema.overload.ambiguous`. It also belongs to at most one **diagnostic group** using `swiftc`'s group names (e.g. `StrictMemorySafety`, SE-0443), so that `-Werror StrictMemorySafety` and `-Wwarning <group>` behave as they do with `swiftc`. Tests match on names, not message text. Warnings can be controlled by name or category (`-W<name>`, `-Wno-<name>`, `-Werror=<name>`).

#### Parity with `swiftc`

D5 requires the same accepted programs, not the same messages. Differential tests compare accept/reject decisions and diagnostic *locations*, not wording.

### 4.6 Build-system integration

- **SwiftPM:** via the `swiftc` compatibility personality and a toolset file pointing SwiftPM at `swift-stack`. Native mode is preferred for whole-project builds where SwiftPM is not required.
- **Make/CMake:** `ss-cc` (and `swift-stack swiftc` for Swift) behaves like a conventional cross toolchain, compiling, assembling `.s`/`.S` inputs and linking. `-MD`/`-MF` dependency files are supported for C.
- **Caching:** the content-addressed artifact cache ([13](13-modules-and-incremental-builds.md)) is driver-managed and shared across personalities.

### 4.7 Observability

- **`--time-phases`:** per-phase wall time, bytes, lines and item counts, in the formats required by [14](14-measurement-methodology.md).
- **`--stats`:** table sizes (tokens, nodes, types, instructions), arena high-water marks, peak RSS.
- **`--dump=<stage>`:** textual dumps of TokenBuffer, ParseTree, SemIR, AIR (before or after a named pass), LIR, and the object model. These are deterministic and used by FileCheck-style golden tests.
- **`--dump=macro-expansions`:** every macro expansion with its site, role and discriminator ([16](16-macros.md)).
- **`--verify-each`:** runs IR verifiers after every pass (debug builds of the compiler enable this by default).
- **`--profile=<file>`:** the built-in profiler. Timed blocks are always compiled in. They read the cycle counter (x86-64 `rdtsc`, AArch64 `cntvct_el0`, RV64 `rdtime`), and cost one predictable branch when profiling is off. The output is a per-lane timeline in Chrome trace JSON. It works on VectraOS, where `perf` and Cachegrind don't exist, and it supplies cycle counts to CI ([14](14-measurement-methodology.md) §8–9).

### 4.8 Record and replay

- **`--record=<bundle>.ssrec`** captures every input of a compilation into one file:
  - source and header contents, stored by content hash;
  - flags, target and pins;
  - macro-plugin responses;
  - the compiler build id.

  It reuses the content-addressed store format ([13](13-modules-and-incremental-builds.md) §5.6).
- **`--replay=<bundle>`** reproduces the compilation bit for bit, with no filesystem or plugin access (D6). A replay that differs from the recorded output hashes is itself a defect.
- **Uses:** bug reports are a single file, and crashes found by fuzzing or in the field become regression tests by checking in their bundle ([09](09-roadmap.md) §6.3).

## 5. Alternatives considered

- **Separate executables per stage with on-disk handoff** (the traditional model). Rejected as the default because it reintroduces the serialization cost the in-memory pipeline removes. It is still supported through the personalities, for build-system compatibility.
- **Format diagnostics eagerly.** Rejected: string formatting on worker threads costs time and makes ordering harder.
- **A general job graph on a work-stealing pool** (an earlier draft). Rejected for v1 (D11). It is more machinery, its scheduling order is nondeterministic, so D6 must be restored afterwards, and it hides the phase structure. Lanes with a shared cursor handle the irregular phases.

## 6. Open questions

1. Which SwiftPM version and `swiftc` flag subset is the compatibility target?
2. Should native mode read `Package.swift` directly? That would require evaluating Swift manifests, which in turn requires Tier 1 and Foundation.
3. Is a persistent compiler daemon (warm caches across builds) in scope after v1?
4. Per-OS plugin sandboxing (Capsicum, Landlock/seccomp, the macOS sandbox, VectraOS capabilities): when, and opt-in or default ([16](16-macros.md) §5.5)?
5. Is there a concrete user for the `as`/`ld` personalities or SARIF output?
