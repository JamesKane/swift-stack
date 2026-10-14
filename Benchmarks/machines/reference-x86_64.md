# Reference Machine: x86-64 (Zen 5)

Per `docs/architecture/14-measurement-methodology.md` §8.

## Hardware Specifications

| Property | Value |
|---|---|
| **Architecture** | x86_64 (AMD64) |
| **CPU Model** | AMD Ryzen 7 9700X 8-Core Processor |
| **Microarchitecture** | Zen 5 |
| **Cores / Threads** | 8 physical cores / 16 threads |
| **Base / Max Frequency** | 3.8 GHz nominal / 5.58 GHz max boost |
| **Reference Cycle Clock** | ~3.8 GHz (RDTSC constant rate) |
| **L1d Cache** | 8 × 48 KiB (384 KiB total) |
| **L1i Cache** | 8 × 32 KiB (256 KiB total) |
| **L2 Cache** | 8 × 1 MiB (8 MiB total) |
| **L3 Cache** | 32 MiB unified |
| **System Memory** | 48 GiB RAM |
| **NUMA Nodes** | 1 |

## Software & Toolchain

| Component | Version |
|---|---|
| **OS** | Fedora Linux 44 (KDE Plasma Desktop Edition) |
| **Kernel** | Linux 7.2.9-201.fc44.x86_64 #1 SMP PREEMPT_DYNAMIC |
| **Host Swift** | Swift version 6.3.1 (`swift-6.3.1-RELEASE`) |
| **Host Clang** | Clang 21.0.0 (swiftlang/llvm-project `11673e6660b2d0a5f9f99b1c7b773f4c2f6df1b0`) |
| **Host Linker** | LLD 21.0.0 (swiftlang/llvm-project `11673e6660b2d0a5f9f99b1c7b773f4c2f6df1b0`) |
| **Profiling Tools** | `perf` version 7.2.10-200.fc44.x86_64 |

## CPU Instruction Set & Vector Features

- AVX-512 (F, DQ, IFMA, CD, BW, VL, BF16, VBMI, VBMI2, VNNI, BITALG, VPOPCNTDQ, VP2INTERSECT)
- AVX2, FMA, BMI1, BMI2, POPCNT, AES-NI, SHA-NI
- Constant TSC, Non-stop TSC, RDTSCP
