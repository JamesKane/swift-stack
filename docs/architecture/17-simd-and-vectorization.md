# 17. SIMD and Vectorization

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md) (D9), [03](03-intermediate-representation.md), [04](04-backend.md), [12](12-standard-library-strategy.md), [14](14-measurement-methodology.md) |

## 1. Summary

Writing vector code by hand for x86-64, AArch64 and RV64 separately is tedious and error-prone. Swift-Stack addresses this in three layers, each built on the one below. Only the first two are required for v1 (D9).

| Layer | What the programmer writes | What the compiler does | Status |
|---|---|---|---|
| **A. Portable SIMD** | Swift `SIMDn<T>` types; C `vector_size` / `ext_vector_type` types | Lowers each operation to native vector instructions on every target, or to correct scalar code where the target has no vector unit | **Required** (v1) |
| **B. Loop idioms** | Ordinary loops that fill, copy or compare memory | Rewrites them to calls to tuned `memset`/`memcpy`/`memmove`/`memcmp` | **Required** (v1, cheap) |
| **C. Auto-vectorization** | Ordinary scalar loops | Vectorizes countable inner loops when it is legal and profitable | **Optional.** Designed into the IR now; delivered on its own track after M5 |

Writing code once as Layer A gives experts multi-architecture SIMD without per-architecture code. Layer C is a convenience on top of that, not a requirement of the spec.

## 2. First-party evidence (Todhchai)

Todhchai already writes its hot codec kernels with Swift's portable SIMD types: inflate, Adler-32, JPEG IDCT and output, color conversion, and PNG row filters. The common types are `SIMD8<UInt8>`, `SIMD16<UInt8>`, `SIMD8<Int16>` and `SIMD8<Int32>`, using reductions such as `wrappedSum()` and unaligned loads.

Those kernels are guarded by `#if arch(x86_64) || arch(arm64)` or `#if !arch(riscv64)`. RV64GC has no vector unit, so the portable code would be scalarized there, and the authors keep a separate scalar path instead. Two consequences follow:

1. Layer A must produce good code on x86-64 and AArch64. An earlier draft of [04](04-backend.md) excluded SIMD instruction selection, which would have scalarized these kernels everywhere.
2. On RV64, the baseline is the **RVA23** profile, which includes RVV 1.0 (§5.4). Layer A therefore always has a vector unit on RV64, and the architecture guards can be removed.

Todhchai uses no C intrinsics headers and no hand-written vector assembly today.

## 3. Goals

- Swift `SIMDn<T>` operations lower to native vector instructions at each target's ISA baseline (§5.4):
  - x86-64: SSE4.2 and AVX (VEX), the 2013 Mac Pro-class floor; AVX2 opt-in;
  - AArch64: Advanced SIMD/NEON;
  - RV64: RVV 1.0 (RVA23).

  Scalar fallback exists only for explicitly requested sub-baseline targets.
- Code quality for Layer A at `-O` within the [14](14-measurement-methodology.md) B9 "Swift SIMD" category target relative to `swiftc -O`.
- **Usable at `-Onone`.** SIMD operations are inlined and lowered to vector instructions even in debug builds, because codec developers debug these kernels.
- Loop idiom recognition at `-O` (Layer B).
- An IR and backend design in which Layer C needs no new vector machinery: the vectorizer emits the same AIR vector operations that Layer A uses.

## 4. Non-goals

- **C intrinsics headers** (`<immintrin.h>`, `<arm_neon.h>`, `<riscv_vector.h>`) in v1. They contain thousands of target builtins. Todhchai doesn't use them. Hand-written assembly remains available ([05](05-assembler.md)).
- **SVE/SVE2 and AVX-512** code generation in v1.
- **x86-64 CPUs older than the 2013 Mac Pro-class floor** (§5.4), and RV64 below RVA23 as a release target.
- **Auto-vectorization as a v1 exit criterion** (D9).
- **Outer-loop vectorization, and vectorization that relies on polyhedral analysis.**

## 5. Design

### 5.1 AIR vector types and operations

- **Types.** The `TypePool` ([02](02-semantic-analysis.md)) has builtin vector types `Vec<N × E>`, with `E` ∈ {i1, i8, i16, i32, i64, f32, f64} and `N` a power of two from 2 to 64. These are the targets of the upstream stdlib's `Builtin.Vec*` types ([12](12-standard-library-strategy.md)). C `vector_size` / `ext_vector_type` types map to the same entries. `Vec<N × i1>` is the mask type produced by comparisons.
- **Operations** (AIR opcodes):
  - lane-wise integer and floating-point arithmetic, including wrapping and saturating forms;
  - bitwise operations and shifts (by scalar and by vector);
  - comparisons producing masks, and `select` (blend by mask);
  - conversions (truncate, extend, int↔float);
  - reductions (`add`, `mul`, `min`, `max`, `and`, `or`, `xor`);
  - `insert`/`extract` of a lane, and splat;
  - `shuffle` with a constant lane-index vector (half extraction, interleaving, concatenation);
  - unaligned and aligned vector `load`/`store`;
  - masked load and store, used by Layer C and by RVV tails.
- **Specialization and inlining are required for SIMD.** Swift's `SIMDn<T>` is generic over `SIMDStorage` and reaches `Builtin` vector operations only through `@_transparent` and `@inlinable` code. The mandatory pipeline ([03](03-intermediate-representation.md) §4.3) therefore always inlines `@_transparent` SIMD operations and specializes them for concrete scalar types, at every optimization level. Without this, SIMD code at `-Onone` goes through generic witness calls and is many times slower.

### 5.2 Legalization (backend)

Each target has a **legalization table**, keyed by (operation, vector type). Each entry is one of:

| Action | Meaning | Example |
|---|---|---|
| `legal` | One native instruction or a short fixed sequence | `add Vec<16×i8>` → `PADDB` / `ADD v.16b` |
| `split` | The type is wider than a register; operate on halves | `Vec<16×i16>` on SSE/NEON → two 128-bit operations |
| `widen` | The type is narrower than a register; pad, operate, ignore extra lanes | `Vec<4×i8>` → low lanes of a 128-bit register |
| `expand` | A fixed multi-instruction recipe | x86 8-bit multiply via `PMULLW` + pack; `min` on `Vec<2×i64>` via compare and blend without SSE4.2 |
| `scalarize` | Per-lane scalar code | Operations with no vector form on the target (e.g. 64-bit integer multiply before AVX-512); any vector operation on a sub-baseline target such as `rv64gc` |

- **The table is data, beside the `Encode` instruction tables** ([04](04-backend.md)). Adding a target feature (AVX2, RVV) means adding entries, not code paths.
- **Legalization runs once, before instruction selection**, as an AIR→LIR lowering step. That keeps tiling unchanged: it sees only legal vector operations.
- **Reductions** lower to shuffle-and-add trees on SSE, to `ADDV`/`UADDLV` on AArch64, and to `vredsum` on RVV.

### 5.3 Registers, allocation and ABI

- **Register classes.** LIR adds a vector class per target: `XMM0–15`/`YMM0–15` on x86-64 (256-bit FP vectors from the AVX baseline; 256-bit integer vectors with AVX2); `V0–V31` on AArch64; `v0–v31` on RVV. The linear-scan allocator ([04](04-backend.md)) treats it as another class with its own callee-saved set:
  - x86-64 SysV: no callee-saved vector registers;
  - AAPCS64: the low 64 bits of `V8–V15` are callee-saved;
  - RISC-V: no callee-saved vector registers.
- **Swift calling convention** (D1 lets Swift-Stack choose): `Vec` values up to 16 bytes are passed and returned in vector registers. Larger ones are split across up to four vector registers, then fall back to indirect passing. This is recorded in [11](11-generics-and-runtime-metadata.md) §8.
- **C calling convention:** vector types follow each psABI (`__m128`-class on SysV, short vectors in `V` registers on AAPCS64, the RISC-V vector calling convention when V is enabled).
- **RVV state.** RVV is vector-length-agnostic: `vsetvli` sets the element width and active length.
  - Fixed-width `SIMDn` operations use `vsetivli` with the constant lane count. They rely on `VLEN ≥ 128`, which the RVA23 baseline guarantees, so any `SIMDn` of 128 bits or less fits in one vector register with LMUL=1.
  - The backend tracks the current `vtype`/`vl` per block and removes redundant `vsetvli` instructions (a forward dataflow pass).

### 5.4 ISA baselines and target features

These baselines are deliberate floors. Code generated without extra flags MAY use every feature in its baseline.

**x86-64: the 2013 Mac Pro-class floor (Ivy Bridge-EP).**

- **Features:** `x86-64-v2` (SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT, CMPXCHG16B, LAHF/SAHF), plus AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, XSAVE/XSAVEOPT and FSGSBASE. This is equivalent to the Ivy Bridge feature set.
  - AMD parts qualify if they implement the same list. Zen and later do. Earlier AMD families must be checked feature by feature.
- **Excluded from the floor:** AVX2, FMA, BMI1/BMI2, LZCNT and MOVBE (Haswell and later; together these make `x86-64-v3`), and AVX-512.
- **Consequences for SIMD:**
  - All vector code is **VEX-encoded**. That gives non-destructive three-operand forms, and it avoids SSE/AVX transition penalties. `vzeroupper` is emitted before calls and returns whenever upper YMM state may be dirty.
  - **Floating-point** vectors are legal up to **256 bits** (`SIMD8<Float>`, `SIMD4<Double>` in one YMM register).
  - **Integer** vectors are legal up to **128 bits**, because AVX1 has no 256-bit integer operations. `SIMD16<UInt16>` and `SIMD8<Int32>` are split into two XMM operations.
  - No FMA, so `a*b+c` stays two rounded operations. This also keeps differential testing simple ([14](14-measurement-methodology.md) §7).
- **Scalar uses:** F16C gives hardware `Float16` ↔ `Float` conversion. RDRAND is available to the runtime's entropy source. FSGSBASE is used by codegen only where the OS enables it (Todhchai TLS, [08](08-runtime-and-stdlib.md)), never on hosts by default.
- **Opt-in:** `-target-feature +avx2` (with FMA and BMI as separate features), which adds 256-bit integer vectors.

**AArch64:** `armv8-a` with Advanced SIMD (NEON), which is mandatory. Later features (e.g. `+dotprod`, `+i8mm`, SVE) are opt-in. SVE is a non-goal for v1.

**RV64: the RVA23 profile (RVA23U64).**

- **Mandatory extensions relevant to codegen** (the full list is per the RVA23 profile specification; to be verified against its ratified text):
  - **RVV 1.0** with `VLEN ≥ 128`;
  - **Zba/Zbb/Zbs** (address generation, basic bit manipulation, single-bit ops);
  - **Zicond** (conditional zero, used for branchless selects);
  - **Zfa** (extra FP instructions);
  - **Zfhmin** (half-precision conversions);
  - **Zcb** (extra compressed instructions);
  - vector bit manipulation (**Zvbb**);
  - cache-block management (**Zicbom/Zicboz**).
- **Effect on codegen:**
  - instruction selection uses `sh1add/sh2add/sh3add`, `andn`/`orn`, `rev8`, `clz/ctz/cpop`, `min/max` and `czero.eqz/nez` ([04](04-backend.md));
  - all `SIMDn` code uses RVV;
  - the RISC-V attributes section records the profile ([06](06-linker.md)).
- **Sub-baseline target:** `-march=rv64gc` is available for older Linux boards. Every vector operation is then scalarized. It is not the default, and it is not a release target.

**Per-function features and multiversioning.** `@_target(...)`-style per-function feature selection with load-time dispatch would let one binary ship both AVX and AVX2 paths. It remains an open question (§7). Until it is resolved, wider features are chosen per build.

`#if targetFeature(...)` would let source opt into wider paths. It is not standard Swift (D5), so it is an open question.

### 5.5 Layer B: loop idiom recognition

Layer B runs at `-O` after LICM ([03](03-intermediate-representation.md) §4.4). It recognizes:

- a countable loop storing a loop-invariant byte pattern to consecutive addresses → `memset`;
- a loop copying `src[i]` to `dst[i]`, unit stride and same element size → `memcpy` when non-overlap is proven, otherwise `memmove`;
- byte-compare loops with an early exit → `memcmp` / `bcmp` (later).

The runtime's `memset`/`memcpy`/`memmove` ([08](08-runtime-and-stdlib.md)) are hand-vectorized per architecture once, by the runtime authors. Every user loop the pass recognizes benefits from that work.

**Self-recursion guard.** Todhchai implements its libc in Swift (`@c(memcpy)` and friends). The pass MUST NOT rewrite a loop into a call to the function it is inside, matched by C symbol name (`memset`, `memcpy`, `memmove`, `memcmp`, `bcmp`, and their `__*_chk` variants). `-disable-loop-idioms` turns the pass off for a whole module; Todhchai's libc build currently passes `-Xllvm -disable-loop-idiom-all` to `swiftc` for this reason, and that flag is mapped to it ([15](15-driver-and-diagnostics.md)).

### 5.6 Layer C: auto-vectorization (optional track)

Layer C is a loop vectorizer over AIR, enabled with `-vectorize`. It will become the default at `-O` only when it meets its compile-time budget (B13 in [14](14-measurement-methodology.md)) and shows a benefit on the B9 categories.

**Scope:**

- Innermost, countable loops with a single latch and a computable trip count.
- Unit-stride loads and stores. Constant-stride and gather access is out of scope at first.
- Reductions (`+`, `*`, `min`, `max`, bitwise) and simple induction variables.
- If-conversion of simple diamonds into `select`/masked stores.
- Vector width from a per-target cost table (the same table family as §5.2), with interleave factor 1 or 2.
- **Remainder handling:** a scalar epilogue on x86-64 and AArch64; on RVV, strip-mining with `vsetvli`, so no epilogue is needed.

**Legality:**

- Dependence analysis for affine subscripts of the form `a*i + b` over a single induction variable. Anything else is treated as a dependence.
- **Aliasing:** basic alias analysis ([03](03-intermediate-representation.md) §4.6), plus language facts:
  - C `restrict`;
  - Swift exclusivity: `inout` parameters and distinct accessed `Array`/`UnsafeBufferPointer` storage don't alias writes made through other accesses during the access;
  - otherwise, **runtime overlap checks** on the loop's address ranges, with the original scalar loop as fallback.
- **Swift bounds checks** must have been hoisted or eliminated first ([03](03-intermediate-representation.md) bounds-check elimination). A loop that still contains per-iteration bounds checks is not vectorized.
- **Swift overflow checks.** Checked arithmetic (`+`, `*`) traps on overflow, and the trap is observable relative to the loop's stores. Layer C vectorizes:
  - wrapping arithmetic (`&+`, `&*`), as Todhchai's kernels already use;
  - checked arithmetic when range analysis proves no overflow;
  - checked **reductions** with no stores in the loop, using vector overflow detection. On overflow, the loop re-executes in scalar mode from the start of the vector iteration, so the trap occurs at the same iteration with the same state.

  Otherwise the loop stays scalar.
- **Floating-point reductions** are vectorized only when reassociation is allowed. Swift and C don't allow it by default, so FP reductions need an explicit opt-in (`-ffp-reassociate`, or `Relaxed` operations in Swift's `Numerics`-style APIs). FP element-wise loops without reductions are vectorized normally.

**Remarks.** `-Rvectorize` reports every inner loop as vectorized (width, interleave, runtime checks) or not vectorized (with the specific reason). Experts can then adjust code, or fall back to Layer A, without guessing.

**SLP vectorization** (packing independent scalar operations in straight-line code) is a later addition. It reuses the same legalization and cost tables.

### 5.7 C vector extensions

The host-header profile (D7, [02](02-semantic-analysis.md)) includes GCC `__attribute__((vector_size(N)))` and Clang `ext_vector_type(N)`. They give C code the same portable-SIMD path as Layer A, and they are needed to parse macOS `<simd/simd.h>`. Supported operations: element-wise operators, subscripting, comparisons, `__builtin_shufflevector`, `__builtin_convertvector`, and the reduction builtins listed in the profile.

## 6. Verification

- **Differential tests** of every `SIMDn` operation × element type × target against `swiftc`-built results, at each baseline (x86-64 Ivy Bridge-class, AArch64 `armv8-a`, RV64 RVA23 under QEMU), plus the opt-in features (AVX2) and the `rv64gc` scalar fallback.
- **Legalization-table coverage:** every (operation, type) pair has an entry on every target, checked by CI.
- **Layer C:**
  - output equivalence on Csmith/YARPGen loops with vectorization on and off;
  - a corpus of loops that must vectorize, with expected remarks;
  - a corpus that must not vectorize (aliasing, overflow traps).
- **Todhchai codecs** with the architecture guards removed: same output on all three architectures, and performance per B9.

## 7. Open questions

1. ~~Todhchai RV64 baseline?~~ Resolved: RVA23 (§5.4). Todhchai's `#if !arch(riscv64)` codec guards can be removed once Swift-Stack, or `swiftc` with an RVA23 target, builds them.
2. **Function multiversioning** (SSE and AVX2 paths in one binary, chosen at load time): worth it in v1, or is a per-target build enough for Todhchai?
3. **`#if targetFeature(...)`:** should Swift-Stack offer it as an extension, given D5?
4. Should Layer C eventually be the default at `-O`? This is decided by B13 and B9 measurements, not in advance.
5. Is a subset of `<arm_neon.h>`/`<immintrin.h>` worth providing for porting existing C code bases, even though Todhchai doesn't need it?
