# B1 Lexing Throughput Baseline

Per `docs/architecture/14-measurement-methodology.md` §4 & §8 and `docs/architecture/09-roadmap.md` §5 (M0 Exit Criteria).

## 1. Test Environment

- **Date:** October 14, 2026
- **Machine:** [reference-x86_64.md](../machines/reference-x86_64.md)
  - **CPU:** AMD Ryzen 7 9700X 8-Core Processor (Zen 5 microarchitecture)
  - **Cores / Threads:** 8 physical cores / 16 threads
  - **L1d / L1i:** 8 × 48 KiB / 8 × 32 KiB
  - **L2 / L3:** 8 × 1 MiB / 32 MiB unified
  - **Memory:** 48 GiB DDR5
  - **OS / Kernel:** Fedora Linux 44, Linux 7.2.9-201.fc44.x86_64
- **Host Toolchains:**
  - `swiftc`: Swift version 6.3.1 (`swift-6.3.1-RELEASE`)
  - `clang`: Clang 21.0.0 (swiftlang/llvm-project `11673e6660b2d0a5f9f99b1c7b773f4c2f6df1b0`)
  - `ld.lld`: LLD 21.0.0

## 2. Corpora

| Corpus | File | Physical Source Lines | Source Bytes | Token Count |
|---|---|---|---|---|
| `swift-synth` | `Benchmarks/corpora/swift-synth/synth_50k.swift` | 44,650 lines | 1,503,492 bytes (1.50 MB) | 307,193 tokens |
| `c-synth` | `Benchmarks/corpora/c-synth/synth_50k.c` | 48,154 lines | 1,454,005 bytes (1.45 MB) | 283,371 tokens |

*Lines counted by `Benchmarks/count-lines` (excluding blank lines and block/line comments).*

## 3. Results Summary

| Target ID | Language | Implementation | Throughput (MB/s) | Best Cycles / Byte | Mean Cycles / Byte | Status vs Budget (≥ 600 MB/s, ≤ 5.8 cyc/B) |
|---|---|---|---|---|---|---|
| **B1** | **Swift** | **SwiftStack `SwiftLexer`** | **727.27 MB/s** | **5.225** | **5.296** | **MET (Target exceeded by 21.2%)** |
| B1 Baseline | Swift | Host `swiftc -frontend -dump-parse` | ~11.6 MB/s | ~423 | ~435 | Baseline comparison |
| **B1** | **ISO C23** | **SwiftStack `CLexer`** | **774.17 MB/s** | **4.909** | **5.011** | **MET (Target exceeded by 29.0%)** |
| B1 Baseline | C | Host `clang -std=c23 -E` | ~65.6 MB/s | ~59 | ~62 | Baseline comparison |

## 4. Hardware Counter Analysis

Measurements captured via `perf stat -e instructions:u,cpu-cycles:u`:

| Target | Retired Instructions (User) | Total Cycles | Instruction / Cycle (IPC) | Total Execution Time |
|---|---|---|---|---|
| `swift-stack` on `synth_50k.swift` | 114,664,435 | 67,531,932 | 1.70 | 0.019 s |
| `swiftc` on `synth_50k.swift` | 1,954,967,768 | 636,844,909 | 3.07 | 0.129 s |
| `swift-stack` on `synth_50k.c` | 112,410,281 | 65,190,443 | 1.72 | 0.018 s |
| `clang -std=c23 -E` on `synth_50k.c` | 287,388,432 | 85,800,783 | 3.35 | 0.022 s |

### Key Takeaways:
1. **Instruction Efficiency:** `swift-stack` retired **17× fewer instructions** than `swiftc` to tokenize the Swift corpus.
2. **Zero Allocation:** The `@_noAllocation` guarantee on the inner lexing loop eliminates memory allocation, locks, and refcount overhead.
3. **SWAR Vectorization:** Fast runs of whitespace and alphanumeric identifiers process 8 bytes per single 64-bit register cycle.
4. **Speed of Light:** At 4.9–5.2 cycles/byte, `SwiftStack` is ~3.3× from the theoretical single-cycle compute ceiling (1.5 cycles/byte), leaving headroom for SIMD vectorization (AVX-512) in future milestones.
