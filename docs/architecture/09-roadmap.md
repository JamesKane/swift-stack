# 09. Roadmap, Milestones, and Verification Strategy

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [02](02-semantic-analysis.md), [03](03-intermediate-representation.md), [11](11-generics-and-runtime-metadata.md), [12](12-standard-library-strategy.md), [13](13-modules-and-incremental-builds.md), [14](14-measurement-methodology.md), [15](15-driver-and-diagnostics.md), [16](16-macros.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

This chapter defines the module layout, the milestone sequence, and how correctness is verified. Three principles shape the sequence:

1. **C before Swift.** C exercises the whole backend (IR, register allocation, encoders, linker, debug info) with a far smaller frontend and no runtime. Bringing C up end-to-end first de-risks everything Swift depends on.
2. **Measure first.** Baselines, the benchmark harness and the built-in profiler ([14](14-measurement-methodology.md)) are milestone-0 deliverables, so every later claim has something to be measured against.
3. **A vertical slice before breadth.** M0.5 is a thin end-to-end path (a tiny C subset to a running Linux executable). Every data layout in [18](18-data-catalog.md) gets its first real measurement from it, before any layer is built out horizontally ("compression-oriented programming").

An earlier draft scheduled everything through self-hosting in 25 weeks. That schedule has been withdrawn. It did not account for the standard library, generics, runtime metadata, or module serialization ([11](11-generics-and-runtime-metadata.md), [12](12-standard-library-strategy.md), [13](13-modules-and-incremental-builds.md)). Milestones are now sized one at a time, using what was measured in the previous milestone. M4 (Tier 0 Swift) and M6 (Tier 1) are expected to be the largest by a wide margin.

## 2. Goals

- Every milestone ends in something that runs and is tested end-to-end.
- Each milestone has objective exit criteria.
- Target platforms come up in a fixed order: VectraOS static ELF → Linux → FreeBSD → macOS.

## 3. Non-goals

- Calendar commitments before M0 baselines exist.

## 4. Module graph and repository layout

### 4.1 Swift package modules (D10)

```
SwiftStack (one library module; folders, not modules)
  Source/ Lex/ Parse/ Sem/ AIR/ Opt/ LIR/ Codegen/
  Encode/   shared instruction tables, encoders, disassembler (Codegen, Asm)
  Object/   relocatable object model, ELF/Mach-O readers & writers (Codegen, Asm, Linker)
  Asm/ Linker/
Driver (executable) ─► SwiftStack
Runtime/Tier0, Runtime/Tier1 ─ built by Swift-Stack itself, not by SwiftPM
```

- **One module** so that `Column`, handle types and hot helpers are specialized and inlined everywhere without cross-module annotations (D10). Release builds use whole-module optimization.
- **Folder dependencies are still a rule:**
  - `Encode/` and `Object/` MUST NOT reference compiler folders, which keeps the assembler and linker usable on their own ([04](04-backend.md), [05](05-assembler.md), [06](06-linker.md));
  - `Asm/` MUST NOT reference `Codegen/`.

  A CI script checks folder-level imports by symbol prefix and file location.
- Standalone tools (`ss-as`, `ss-ld`, `ss-demangle`, `ssdb`), when they exist, are thin executable targets over `SwiftStack`.
- Test targets use `@testable import SwiftStack`.
- **Current state:** `Package.swift` still has separate `Source` and `Lex` targets. Merging them into `SwiftStack` is an M0 task.

### 4.2 Repository layout

```
swift-stack/
├── Package.swift
├── README.md
├── docs/architecture/            # This document set (00–18)
├── Sources/
│   ├── SwiftStack/               # One module (D10), organized by folder:
│   │   ├── Source/  Lex/  Parse/  Sem/  AIR/  Opt/  LIR/  Codegen/
│   │   └── Encode/  Object/  Asm/  Linker/  Profile/  Census/
│   ├── Driver/
│   └── Runtime/
│       ├── Tier0/                # Freestanding runtime (Swift + C23)
│       └── Tier1/                # Full runtime: refcounting, metadata, casts, concurrency
├── Tests/
│   ├── SwiftStackTests/          # Unit tests (@testable import), one folder per subsystem
│   ├── Golden/                   # --dump=<stage> golden files (FileCheck-style)
│   └── Differential/             # Harness for swiftc / clang / GNU as / lld oracles
├── Benchmarks/                   # Harnesses and machine descriptions (see 14)
└── External/                     # Pinned, fetched-not-committed inputs: upstream stdlib,
                                  # FoundationEssentials, corpora, third-party test suites
```

`External/` holds content-hash-pinned inputs fetched by a script. Third-party test suites with incompatible licenses (e.g. the GPL GCC torture tests) are fetched and run as data. They are never committed or linked.

## 5. Milestones

Each milestone lists its deliverables and its **exit criteria**. A milestone is done only when its exit criteria are met, and the D6 determinism check ([14](14-measurement-methodology.md) §9) passes for everything it produces.

### M0 — Foundation and measurement

- **Deliverables:**
  - restructure the package into the single `SwiftStack` module (D10);
  - `Column`/arena infrastructure with reserve-then-commit storage and nil row 0 ([00](00-overview-and-principles.md) Principles 2 and 7). The existing `TokenBuffer` (four separate `malloc`s, copy-on-grow) and `SourceManager` (a class with a `[String: FileId]` dictionary) are brought in line with this;
  - `SourceManager`;
  - Swift and C lexers, with inner loops marked `@_noAllocation` (Principle 8);
  - the built-in profiler and repetition tester ([14](14-measurement-methodology.md));
  - `ss-census`, a feature-census tool that counts Swift features, attributes and flags used in a source tree, ranks the unsupported ones by use count, and runs in CI over a pinned VectraOS snapshot. It keeps [02](02-semantic-analysis.md) §4.3.5 current and orders work in M4 and M6 by real use;
  - benchmark harness and reference-machine setup ([14](14-measurement-methodology.md));
  - baseline numbers for `swiftc`, Clang and lld on the corpora;
  - `--dump`, `--stats` and `--time-phases` plumbing ([15](15-driver-and-diagnostics.md)).
- **Exit:**
  - B1 measured for both languages, with the target met or the gap documented;
  - baselines recorded;
  - CI instruction-count gating live.

### M0.5 — Vertical slice

- **Deliverables:** the thinnest possible end-to-end path, written directly and without generality.
  - **C subset:** `int`/`long`/pointers, functions, locals, `if`/`while`/`return`, calls, string literals.
  - **Pipeline:** lexer → postorder parse tree → minimal type checking → AIR → naive instruction selection → simple linear scan → x86-64 encoding → static ELF linked in process → runs on Linux. It calls `write`/`exit` through a hand-written `_start`.
  - The built-in profiler is wired through every stage. `--stats` reports per-table sizes.
- **Exit:**
  - the slice compiles and runs a small program corpus (e.g. a few dozen c-testsuite programs in the subset);
  - cycles per byte (or per item) are measured for every stage;
  - each table in [18](18-data-catalog.md) touched by the slice has its layout hypothesis confirmed or revised, with the measurement recorded;
  - a recorded decision on which parts of the slice become the foundation and which are rewritten.

The slice is deliberately throwaway where needed. Its purpose is to replace guesses in chapters 01–04 with measurements before M1–M3 build each layer out.

### M1 — C23 frontend

- **Deliverables:**
  - C23 preprocessor, including `#embed` and the host-header profile (D7);
  - C parser into the postorder ParseTree;
  - C semantic analysis and SemIR ([02](02-semantic-analysis.md), [10](10-semantic-ir-and-name-resolution.md));
  - diagnostics engine.
- **Exit:**
  - SQLite, Lua and VectraOS C sources parse and type-check; VectraOS's 12 C files and each of its headers are checked for each of its three architectures, freestanding, with its build's include paths and definitions;
  - glibc and FreeBSD libc headers parse;
  - the c-testsuite accept/reject set matches Clang.

### M2 — Encoders, object model, assemblers

- **Deliverables:**
  - `Encode` for x86-64 (including VEX), then AArch64, then RV64 (RVA23 extensions), with a disassembler;
  - `Object` with ELF relocatable read/write;
  - AT&T-syntax x86-64 assembler, AArch64 and RV64 assemblers, `.S` preprocessing ([05](05-assembler.md)).
- **Exit:**
  - all 26 VectraOS assembly files, assembled for each architecture with its build's definitions, include paths and ISA flags (RV64 with linker relaxation), assemble byte-identically to LLVM MC (clang's integrated assembler), the reference assembler; differences from GNU `as` are documented, not matched ([05](05-assembler.md) §4.11);
  - encoder/disassembler round-trip is exhaustive over the instruction tables.

### M3 — C end-to-end at `-O0` (x86-64)

The phase plan is in [milestones/M3-plan.md](milestones/M3-plan.md). The M0.5 back end (AIR lowering from the parse tree, the allocator, the emitter and `StaticELFWriter`) is replaced, not extended.

- **Deliverables:**
  - a per-target data layout, and SemIR complete enough to lower from: implicit conversions, lvalues, control flow and static initializer values ([02](02-semantic-analysis.md), [10](10-semantic-ir-and-name-resolution.md));
  - C lowering to AIR ([03](03-intermediate-representation.md));
  - LIR, SSA linear-scan register allocation, x86-64 code generation with the full System V ABI, including `long double` (X87 class, so the encoder gains the x87 subset that code needs) ([04](04-backend.md));
  - `-c` and `-S` output, `.eh_frame`, and DWARF 5 `.debug_line` from the code generator and from the assembler's `.file`/`.loc` (`-g` line information for gdb and perf on Linux; variable information stays in SDI);
  - linker for VectraOS static ELF (`ET_EXEC` and static PIE) and Linux static/dynamic ELF, reading foreign `.o` and `.a` inputs ([06](06-linker.md));
  - CUD and minimal SDI plus an `ssdb` symbolizer ([07](07-debugging-and-sdi.md));
  - `--record`/`--replay` compile bundles ([15](15-driver-and-diagnostics.md)), so every M3 bug report and fuzzer find is one reproducible file.
- **Exit:**
  - c-testsuite and the GCC torture `execute` tests pass on Linux x86-64 via differential execution against Clang;
  - the SQLite amalgamation and its shell, built and linked by Swift-Stack, give the same results as Clang's build on a scripted SQL corpus (sqllogictest or equivalent). SQLite's TCL test suite (`testfixture`, dynamically linked against the host's libtcl) is a follow-on gate after M3, once dynamic linking has been proven;
  - a C program built by Swift-Stack, linked against VectraOS's user runtime, runs on VectraOS in QEMU. A Swift-Stack test builds VectraOS out of tree in its own build directory, substitutes the program, and boots it with VectraOS's `tools/qemu.sh`, without changing VectraOS sources;
  - `ssdb` symbolizes a crash backtrace.

### M4 — Tier 0 Swift

- **Deliverables:**
  - Swift parser;
  - name resolution and operator folding ([10](10-semantic-ir-and-name-resolution.md));
  - type checker with D5 parity on the Tier 0 subset;
  - Swift macros: the plugin host, all attached roles VectraOS's macros use (`member` with `names: arbitrary`, `peer`, `memberAttribute`, `extension`; [16](16-macros.md) §2), freestanding expression macros, and built-in macros ([16](16-macros.md)). Plugins are built by the host `swiftc`;
  - ownership and borrow checking in AIR, and `@_noAllocation`/`@_noLocks` checking ([03](03-intermediate-representation.md) §4.3);
  - the VectraOS feature profile ([02](02-semantic-analysis.md) §4.3.5):
    - `@c`/`@c(name)`, `@c @implementation` and `@_extern(c)`;
    - typed throws, `~Copyable`, `Synchronization`'s `Atomic`;
    - strict memory safety, with diagnostic groups;
    - `~Escapable`, `@_lifetime` and lifetime-dependence checking;
    - value generics (`InlineArray`), `Span`/`MutableSpan`;
    - `_Volatile`;
    - `-no-allocations`, `-Osize`;
  - full monomorphization ([11](11-generics-and-runtime-metadata.md));
  - Embedded stdlib compiled from upstream sources, pinned to Swift 6.4 ([12](12-standard-library-strategy.md));
  - Tier 0 runtime ([08](08-runtime-and-stdlib.md)).
- **Exit:**
  - VectraOS's Tier 0 images (the kernel, the UEFI loader, `userboot` and its Embedded Swift test programs) built by Swift-Stack pass VectraOS's boot tests (`vx test`, QEMU, all three architectures), as its `swiftc` builds do;
  - the type-checker accept/reject differential suite matches `swiftc` on the Tier 0 corpus;
  - every `@IPCLibrary` and `@AudioRenderer` expansion in VectraOS is textually identical to `swiftc`'s, using the same plugins. This waits for VectraOS to lift them (its roadmap V2 and V6);
  - a deliberately allocating `@AudioRenderer` `render` method is rejected, as with `swiftc`;
  - VectraOS's targets build with their exact CMake flag set (`-enable-experimental-feature Embedded`/`Lifetimes`, `-parse-as-library`, `-strict-memory-safety`, `-Werror StrictMemorySafety`, `-Werror EmbeddedRestrictions`, `-Wwarning PerformanceHints`, `-enforce-exclusivity=unchecked`, `-Xfrontend -function-sections`, `-Osize`, whole-module, and `-Xcc` arch flags), using Swift-Stack's `swiftc` personality ([15](15-driver-and-diagnostics.md));
  - a Swift-implemented libc (`@c(memcpy)` and friends, as VectraOS's userland will carry from V2) does not compile into self-calls ([17](17-simd-and-vectorization.md) §5.5).

### M5 — Optimizer and remaining backends

- **Deliverables:**
  - the core, interprocedural and Swift-specific optimization passes, including loop idiom recognition ([03](03-intermediate-representation.md));
  - AArch64 and RV64 code generation;
  - portable SIMD (D9): AIR vector operations, per-target legalization tables, vector register classes, VEX SSE4.2/AVX, NEON and RVV encodings at the D9 baselines ([17](17-simd-and-vectorization.md));
  - Linux AArch64 and RV64 targets.
- **Exit:**
  - B9 measured per category on x86-64 and AArch64 ([14](14-measurement-methodology.md) §7), including the portable-SIMD category;
  - `SIMDn` codec kernels (inflate, Adler-32, JPEG, PNG, color conversion) produce identical output on all three architectures, and also with their `arch` guards removed. VectraOS carries these from its roadmap V6; until then this criterion waits on [14](14-measurement-methodology.md) §11, open question 4;
  - the parity hypothesis confirmed, or the gap documented per category with a decision recorded in [00](00-overview-and-principles.md).

### M6 — Tier 1 Swift

- **Deliverables:**
  - runtime metadata, witness tables, existentials, dynamic casts ([11](11-generics-and-runtime-metadata.md));
  - Tier 1 runtime;
  - full upstream stdlib and FoundationEssentials, including the `FoundationMacros` plugin and the stdlib's own macro plugins ([12](12-standard-library-strategy.md) §8);
  - swift-testing (library as an input, `TestingMacros` plugin, runtime test discovery), so that VectraOS's host test suites build;
  - Swift-Stack able to build swift-syntax-based plugin executables itself;
  - `.ssmodule` files and incremental builds ([13](13-modules-and-incremental-builds.md));
  - FreeBSD target.
- **Exit:**
  - the upstream stdlib's executable tests pass;
  - VectraOS's swift-testing suites (the host tests of `vx`'s bench and image libraries) build and pass;
  - B10 measured;
  - separate compilation across modules works through `.ssmodule`.

### M7 — Concurrency and macOS

- **Deliverables:**
  - async lowering;
  - executor backends (VectraOS port, `kqueue`, `epoll`) ([08](08-runtime-and-stdlib.md));
  - Swift 6 strict-concurrency checking ([02](02-semantic-analysis.md));
  - the macOS target (Mach-O, chained fixups, ad-hoc signing).
- **Exit:**
  - concurrency differential tests pass on all hosts;
  - VectraOS's desktop components (Tracker, Deskbar, the terminal; its roadmap V6) build and run, or, if VectraOS has not reached V6, a Tier 1 async program runs on VectraOS with the port backend.

### M8 — Self-hosting

- **Deliverables:** Swift-Stack builds itself.
- **Exit:**
  - Stage 2 (built by the Swift-Stack-built compiler) and stage 3 are bitwise identical (D6);
  - the stage 2 compiler passes the full test suite.

### Optional track V — Auto-vectorization

This track is not on the critical path and has no milestone dependency after M5 (D9).

- **Deliverables:**
  - the loop vectorizer behind `-vectorize`, with dependence analysis, runtime alias checks, reductions, simple if-conversion and RVV strip-mining ([17](17-simd-and-vectorization.md) §5.6);
  - `-Rvectorize` remarks.
- **Exit:**
  - Csmith and YARPGen loop corpora give identical results with `-vectorize` on and off;
  - B13 compile-time cost is measured and the B9 benefit is reported per category;
  - a recorded decision on whether `-vectorize` becomes default at `-O`.

SLP vectorization is a later follow-on on the same track.

## 6. Verification strategy

### 6.1 Differential testing

```
Source ──┬──► oracle (swiftc / clang / GNU as / ld.lld) ──► artifact A ──► run ──► result A
         │                                                                          │ compare
         └──► swift-stack ───────────────────────────────► artifact B ──► run ──► result B
```

| Component | Oracle | What is compared |
|---|---|---|
| Swift type checker | `swiftc -typecheck` | Accept/reject, diagnostic locations (D5) |
| Swift macros | `swiftc` with the same plugin executables | Expanded source text per site; accept/reject of name lookup involving macro-introduced names ([16](16-macros.md) §5.9) |
| Swift execution | `swiftc` | stdout, exit code. Sources: the executable subset of the upstream Swift test suite (`test/Interpreter` and similar; most of `test/` checks compiler output and is not usable directly) plus project tests |
| C frontend and execution | Clang | Accept/reject; stdout and exit code for c-testsuite, GCC torture `execute` tests (fetched, GPL, run as data), SQLite tests |
| C random programs | Clang, GCC | Csmith and YARPGen generated programs: checksum output. Run continuously, not per commit. |
| Portable SIMD | `swiftc` | Per-operation results for every `SIMDn` operation and element type at each ISA baseline ([17](17-simd-and-vectorization.md) §6) |
| Assembler | `llvm-mc` / `clang -c` (reference); GNU `as` apart from documented differences ([05](05-assembler.md) §4.11) | Section bytes and relocations |
| Linker | `ld.lld` | Program behavior. `readelf`/`llvm-readobj` structural validation. Bytes are not compared, since layout legitimately differs. |
| Debug info | DWARF from Clang where applicable | Line tables and variable locations at sampled PCs |

Floating-point differences are triaged under the policy in [14](14-measurement-methodology.md) §7: FMA contraction is off for differential runs, so remaining differences are defects.

### 6.2 Internal verification

- **IR verifiers** for SemIR, AIR and LIR run after every pass in debug builds (`--verify-each`).
- **Golden tests** use the `--dump` output ([15](15-driver-and-diagnostics.md)).
- **Exhaustive tests** of the encoder/disassembler round-trip.

### 6.3 Robustness

- **Coverage-guided fuzzing** of the lexers, preprocessor, parsers, assembler parser, and the ELF/Mach-O object readers. The compiler MUST NOT crash or hang on any input.
- Fuzzing runs continuously. Crashes found by fuzzing are saved as `.ssrec` record bundles ([15](15-driver-and-diagnostics.md) §4.8), and each bundle becomes a regression test replayed in CI.

### 6.4 Performance gates

See [14](14-measurement-methodology.md) §9.

## 7. Open questions

1. Should the macOS target move earlier, since it's a common developer host? Swift-Stack can run on macOS (built by `swiftc`) long before it can *target* macOS.
2. ~~Is Linux the right first host target?~~ Yes for now: VectraOS is developed on Linux (its toolchain is a swiftly-installed Swift on Linux, with QEMU and edk2).
3. Which VectraOS components define the M4 corpus beyond the kernel, the loader and `userboot`, as its userland (roadmap V2) arrives? `ss-census` output can guide this.
4. Should relocatable, patchable code modules (live code editing, VectraOS principle 23) come before macOS Mach-O output in M7? Function-level incremental compilation ([13](13-modules-and-incremental-builds.md)) plus patchable modules would give edit-and-continue in seconds ([06](06-linker.md) open questions).
