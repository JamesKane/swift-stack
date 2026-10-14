# 14. Measurement Methodology and Performance Budgets

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [09](09-roadmap.md), [13](13-modules-and-incremental-builds.md), [15](15-driver-and-diagnostics.md), [16](16-macros.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

Every performance number in this document set is either a **target** (something we intend to reach) or a **hypothesis** (something we believe about other systems). Neither counts as a measured fact until it has been measured.

This chapter defines:

- the metrics and how each is measured;
- the corpora and reference machines;
- how baselines for `swiftc`, Clang and lld are established;
- how continuous integration (CI) gates on regressions.

It follows the Todhchai principle "slower is a claim to measure, not assume". The same applies to "faster".

## 2. Goals

- Every budget in the README and in the chapters links back to a metric defined here.
- Baseline numbers for comparison toolchains are measured on the project's reference machines, not quoted from elsewhere.
- CI regression gates are low-noise enough that a failing gate means something.

## 3. Non-goals

- Cross-vendor benchmarking claims for publication.
- Measuring toolchain configurations the project does not target (e.g. Windows).

## 4. Budgets

All values are **targets**. The "Baseline" column records the comparison toolchain to be measured; until it has been measured it says *TBM* (to be measured). Earlier drafts quoted figures such as "`swiftc`: ~40 MB/s lexing". Those were unsourced and have been removed.

| ID | Metric | Target | Per item at 3.5 GHz | Baseline | Status |
|---|---|---|---|---|---|
| B1 | Lexing throughput, single core | ≥ 600 MB/s | ≈ 5.8 cycles/byte | `swiftc -dump-parse` lex phase, Clang `-E`: TBM | Unmeasured |
| B2 | Parsing throughput (lex + parse), single core | ≥ 300 MB/s | ≈ 11.7 cycles/byte | `swiftc -parse`, Clang `-fsyntax-only` (C, headers pre-expanded): TBM | Unmeasured |
| B3 | End-to-end debug build, single core | ≥ 100,000 lines/s | ≈ 35,000 cycles/line | `swiftc -Onone` + lld; `clang -O0` + lld: TBM | Unmeasured |
| B4 | End-to-end optimized build, single core | ≥ 20,000 lines/s | ≈ 175,000 cycles/line | `swiftc -O`; `clang -O2`: TBM | Unmeasured |
| B5 | Link time, Todhchai system-service image | < 50 ms | ≈ 175 M cycles per link | `ld.lld` with equivalent inputs: TBM | Unmeasured |
| B6 | SDI emission, 100K-line program | < 5 ms | ≈ 175 cycles/line | `ld.lld` DWARF 5 handling: TBM | Unmeasured |
| B7 | Stack unwind, 100 frames, frame-pointer path | < 2 µs | ≈ 70 cycles/frame | libunwind with `.eh_frame`: TBM | Unmeasured |
| B8 | Peak RSS, 100K-line build | < 256 MB | ≈ 2.6 KB/line | `swiftc` + LLVM: TBM | Unmeasured |
| B9 | Runtime performance, optimized | 80–90% of `clang -O2` (C) / `swiftc -O` (Swift) (geomean per category, §7) | — | `swiftc -O`, `clang -O2` | Hypothesis |
| B10 | Incremental rebuild after body-only edit, 100K-line module | < 200 ms | ≈ 700 M cycles per rebuild | `swiftc` incremental: TBM | Unmeasured |
| B11 | Assembling a typical OS stub (`start.S`, context switch) | < 1 ms | ≈ 3.5 M cycles per file | GNU `as`, Clang integrated assembler: TBM | Unmeasured |
| B12 | Macro expansion overhead: plugin start-up, per-expansion round-trip, and cache-hit cost, on the Todhchai `@IPCLibrary` corpus | Per-expansion host overhead (excluding plugin compute) < 0.5 ms; cache hit < 20 µs | ≈ 1.75 M cycles per expansion; ≈ 70,000 cycles per cache hit | `swiftc` with the same plugins: TBM | Unmeasured |
| B13 | Compile-time cost of `-vectorize` (optional loop vectorizer, [17](17-simd-and-vectorization.md)) | ≤ 5% added to optimized build time on `swift-real` and `c-real`; its benefit is reported per B9 category | — | LLVM loop vectorizer share of `clang -O2` time: TBM | Unmeasured |
| B14 | Clean build of Swift-Stack itself (D10), ~100K lines, reference machine, current host `swiftc` | ≤ 20 s debug; ≤ 60 s release (WMO) | ≈ 700,000 cycles/line (debug) | Tracked over time; no external baseline | Unmeasured |

The "per item" column converts each target into a cycle budget, assuming a **3.5 GHz reference clock** (an assumption to be replaced by the reference machines' measured sustained clock). It states the cost of one unit of work, which is easier to reason about against the hardware than a rate.

Chapters MAY define finer-grained internal budgets (e.g. AIR instructions optimized per second). They MUST use the same measurement rules and SHOULD state them in cycles per item as well.

**Speed of light.** Each throughput target is compared with what the hardware can do, not only with other compilers:

- **Memory bandwidth is not the limit.** A single core streams sequential memory at roughly 10–20 GB/s, which is well under 0.5 cycles per byte. B1 (≈ 5.8 cycles/byte) and B2 (≈ 11.7 cycles/byte) are therefore far from memory-bound: lexing and parsing are **compute-bound**, limited by instructions and branches per byte.
- **The lexer's realistic ceiling.** A SWAR or SIMD lexer that classifies bytes in bulk and branches once per token, not once per byte, plausibly needs 1–2 cycles per byte. That suggests B1 could be raised several-fold.
- **Targets are revised from data.** They are raised once the M0 repetition-tester measurements (§8) show where the real limit is. They are not lowered without a recorded reason.
- **These figures are estimates** to be confirmed on the reference machines, not measurements.

## 5. Metric definitions

**Lines.** Non-blank, non-comment physical source lines of the corpus files given on the command line, counted by the corpus tool (`Benchmarks/count-lines`). Lines from headers and imported modules are reported separately and not counted in lines/s.

**Throughput (MB/s).** Source bytes processed divided by wall time of that phase alone. Input is already in memory: file I/O is excluded and measured separately as B0 "I/O + mapping". Phase boundaries are instrumented with the compiler's own `--time-phases` output ([15](15-driver-and-diagnostics.md)). For baselines, the closest available stage-limiting flag is used. The comparison is documented as approximate wherever stages don't line up exactly.

**End-to-end build time.** Wall time from process start to the final executable written, warm file cache, on the corpus. Single-core numbers use `--jobs 1`. Multi-core numbers are reported as a speed-up curve (1, 2, 4, 8, all cores), never as a single "× cores" multiplication.

**Link time.** Wall time of the link phase only:

- **In-process:** objects already in memory (Swift-Stack native).
- **Standalone:** reading `.o`/`.a` from disk. This is the like-for-like comparison with lld.

Both are reported.

**Peak RSS.** `getrusage(RUSAGE_SELF).ru_maxrss` (Linux, FreeBSD), or `task_info` on macOS, at process exit.

**Unwind latency.** Mean time to produce return addresses for a synthetic 100-frame stack, measured in-process, after warm-up, over ≥ 10,000 iterations. Symbolication is excluded.

**Runtime performance.** See §7.

## 6. Corpora

| Corpus | Contents | Used for |
|---|---|---|
| `swift-synth` | Generated Swift with controlled mix: declarations, generic code, closures, operator-heavy expressions | B1–B4, B8, type-checker stress |
| `swift-real` | Swift-Stack's own sources (once self-hosting-capable), selected open-source Swift packages pinned by commit | B1–B4, B8, B10 |
| `c-real` | SQLite amalgamation, Lua, a pinned c-testsuite snapshot | B1–B4 (C), differential tests |
| `todhchai` | Pinned snapshot of Todhchai OS sources, assembly stubs, and macro plugins | B5, B6, B9 (portable-SIMD codec kernels), B11, B12, end-to-end |
| `runtime-swift` | A subset of the upstream Swift benchmark suite (input per D2) plus project micro-benchmarks | B9 |
| `runtime-c` | CoreMark, selected Embench programs, SQLite speed test | B9 |

Corpora are pinned by content hash. Changing a corpus resets the regression history for the metrics that use it.

## 7. Runtime performance (B9)

- **Categories, reported separately:**
  - Swift scalar compute
  - Swift collections / ARC-heavy
  - Swift generics-heavy
  - Swift string processing
  - Swift portable SIMD (`SIMDn` kernels, e.g. Todhchai codecs; also run on RV64 RVA23 under QEMU, and on `rv64gc` to measure the scalar fallback)
  - C integer
  - C floating-point / numeric (reported with and without `-vectorize`)
- **Aggregation:** geometric mean of per-benchmark speed ratios within each category. There is no single overall number, because an overall mean hides category regressions (vectorizable C kernels are expected to be the outlier, see [00](00-overview-and-principles.md) Principle 4).
- **Comparison flags:** Swift-Stack's optimized mode vs `swiftc -O` (not `-Ounchecked`) and `clang -O2`, same target CPU baseline on both sides ([17](17-simd-and-vectorization.md) §5.4): x86-64 Ivy Bridge-class (`-march=ivybridge` for Clang; the equivalent target CPU for `swiftc`), `armv8-a`, and RVA23 (`-march=rva23u64`).
- **Floating-point policy:** no fast-math on either side. FMA contraction is disabled on both sides for differential correctness runs. Performance runs record the contraction setting used.

## 8. Measurement protocol

- **Reference machines.** At least one x86-64 and one AArch64 machine, specs recorded in `Benchmarks/machines/` ([09](09-roadmap.md) §4.2). RV64 is measured opportunistically and not gated.
- **Environment:**
  - frequency scaling fixed (performance governor; turbo disabled where possible);
  - benchmark process pinned to isolated cores;
  - no other workload.
- **Repetition:**
  - wall-time metrics: ≥ 10 runs after 2 warm-up runs, reported as median and median absolute deviation (MAD);
  - runtime benchmarks: each benchmark run until its 95% confidence interval is within ±1%, or 30 runs, whichever comes first.
- **Baselines** are re-measured whenever the comparison toolchain version changes. Versions are recorded alongside results.
- **Built-in profiler (primary attribution tool).** Every phase and hot routine is wrapped in a timed block that reads the cycle counter: `rdtsc` on x86-64, `cntvct_el0` on AArch64, `rdtime` on RV64 ([15](15-driver-and-diagnostics.md) §4.7).
  - Blocks are always compiled in and cost one predictable branch when off.
  - `--profile=<file>` writes per-lane timelines as Chrome trace JSON.
  - It runs identically on Linux, FreeBSD, macOS and Todhchai. That makes it the one tool available everywhere, including on croi, where `perf` and Cachegrind don't exist.
  - Counter frequencies are calibrated at startup and recorded in the output. `cntvct_el0` and `rdtime` tick at a fixed timer rate rather than the core clock, so their results are reported in nanoseconds and converted to cycles using the measured core clock.
- **Repetition tester.** `Benchmarks/` contains a harness for kernels (the lexer inner loop, instruction encoding, relocation application, legalization tables). It runs a kernel repeatedly on fixed input until the best time stops improving, and reports:
  - best and mean cycles per byte or per item;
  - effective bandwidth;
  - the ratio to the speed-of-light estimate (§4).

  This is how budgets get grounded in the hardware.
- **External tools (secondary).** `perf`, Cachegrind and hardware counters are used for deeper analysis (cache misses, branch mispredictions) and for retired-instruction gating where available. No measurement in this chapter depends on them alone.

## 9. Continuous integration gates

Wall-clock time on shared CI machines is too noisy to gate on small percentages. CI therefore gates on deterministic proxies and only watches wall time.

| Signal | Tool | Gate |
|---|---|---|
| Retired instructions per phase on fixed corpora | `perf stat -e instructions` (Linux) or Cachegrind | Fail if > 2% increase vs. the main-branch rolling median |
| Cycles per phase, from the built-in profiler (used where hardware instruction counts are unavailable, e.g. Todhchai, some CI virtual machines) | `--profile`, median of 5 runs | Fail if > 5% increase (cycles are noisier than retired instructions, hence the wider threshold) |
| Self-build time (B14) | Nightly on reference machines | Alert on a sustained shift > 10% |
| Peak RSS on fixed corpora | `ru_maxrss` | Fail if > 2% increase |
| Output size (text, data, SDI) | Driver statistics | Fail if > 1% increase without an accompanying note |
| Wall time on reference machines | Nightly, not per commit | Alert when a sustained shift > 5% is detected by a change-point test |
| Determinism (D6) | Build corpus with `--jobs 1`, `--jobs 2` and `--jobs N`; compare all outputs (objects, executables, SDI, module files, diagnostics) bytewise | Fail on any difference |

Intentional regressions are allowed with a commit trailer (`Perf-Regression: <reason>`), which resets the baseline for that metric.

## 10. Alternatives considered

- **Gate on wall time per commit.** Rejected: noise on shared hardware exceeds the 2% threshold.
- **Single aggregate runtime score.** Rejected: hides the category-specific risks in Principle 4.
- **Rely only on external profilers.** Rejected: they don't exist on Todhchai, differ between hosts, and see the compiler from outside. The built-in profiler sees phases and lanes as the compiler defines them, everywhere.

## 11. Open questions

1. Which open-source Swift packages make up `swift-real` before self-hosting is possible?
2. Do we need a Todhchai-native benchmark harness (running on croi), or are host measurements sufficient until M6?
3. Is B4 (optimized lines/s) the right second throughput target, or should it be expressed as "optimized build ≤ N× debug build"?
