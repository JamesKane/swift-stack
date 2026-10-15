# Milestone M2 — Encoders, Object Model, and Assemblers

Per [09-roadmap.md](../09-roadmap.md) (§M2) and [05-assembler.md](../05-assembler.md), Milestone M2 delivers the shared instruction encoding and disassembly tables (`Encode/`), the relocatable object model and ELF64 `ET_REL` reader/writer (`Object/`), and the multi-architecture assembler pipeline (`Asm/`) supporting x86-64 (AT&T syntax), AArch64, and RV64 (RVA23 profile).

---

## 1. Deliverables Completed

### 1.1 Table-Driven Instruction Encoders & Disassemblers (`Sources/SwiftStack/Encode/`)

All three target architectures use a single static instruction descriptor table shared between encoder and disassembler. Each descriptor is round-tripped (`encode -> disassemble -> re-encode`) from one sample, and every sample is checked against `llvm-mc` (§2):

- **x86-64 (`X86Codec.swift`)**:
  - `X86InstructionTable`, `X86TableEncoder`, and `X86TableDisassembler`.
  - Covers baseline x86-64 GPR, system/privileged (`syscall`, `sysretq`, `swapgs`, `lgdt`, `lgdtl`, `lidt`, `ltr`, `str`, `invlpg`, `wrmsr`, `rdmsr`, `rdtsc`, `rdtscp`, `cpuid`, `wbinvd`, `fxsave64`, `fxrstor64`, `xsave64`, `xrstor64`, `xsaveopt64`, `xgetbv`, `xsetbv`, `rdpkru`, `wrpkru`, `clac`, `stac`, `monitor`, `mwait`, `%crN`/`%drN`/segment moves, port I/O), ABM/CRC32 (`lzcnt`, `tzcnt`, `popcnt`, `crc32b/w/l/q`), `endbr64`/`endbr32`, and the full `x86-64-v3` level of [17](../17-simd-and-vectorization.md) §2:
    - SSE through SSE4.2 (legacy encoding) and AVX/AVX2 (VEX.128 and VEX.256): moves (aligned/unaligned, scalar, `movd`/`movq`, half-register, non-temporal, `movmsk*`, `maskmov*`/`vpmaskmov*`), FP and integer arithmetic/logic, horizontal ops, compares (`cmpps $imm` plus all 32 `vcmp<pred>` pseudo-op spellings, `(u)comis*`, `pcmpeq*`/`pcmpgt*`, `pcmp[ei]str[im]`), shuffles/unpacks/packs/aligns, blends (immediate and variable), shifts (by `xmm`, by immediate, AVX2 per-element), conversions (`cvt*`, including the `x`/`y` memory spellings), rounding, dot products, insert/extract, broadcasts, `vperm*`/`vpermil*`, 128-bit lane insert/extract/permute, `ptest`/`vtestp*`, and AVX2 gathers (VSIB).
    - BMI1/BMI2 (`andn`, `bextr`, `blsi`, `blsmsk`, `blsr`, `bzhi`, `mulx`, `pdep`, `pext`, `rorx`, `sarx`, `shlx`, `shrx`), FMA3 (`vfmadd`/`vfmsub`/`vfnmadd`/`vfnmsub` 132/213/231 `ps`/`pd`/`ss`/`sd`, `vfmaddsub`/`vfmsubadd`), F16C, MOVBE, ADX, AES-NI and `pclmulqdq` (legacy and VEX.128), SHA, `movnti`, prefetch/`clflushopt`/`clwb`, `(v)ldmxcsr`/`(v)stmxcsr`.
    - VEX 2-byte vs 3-byte selection matches LLVM MC, including swapping the sources of commutable map-0F instructions to reach the 2-byte form (05 §4.11, difference 4).
    - **Not covered:** MMX forms, x87, AVX-512/EVEX, VAES/VPCLMULQDQ (256-bit), and AMD-only extensions (SSE4a, XOP, FMA4, TBM).
  - Supports `.code64`, `.code32`, and `.code16` real/protected-mode boot transition encodings (including `ljmpl`/`ljmpw` far jumps and 16-bit absolute addressing).
  - `X86InstructionTable.verifyRoundTrip()` round-trips every descriptor plus special addressing modes (`%rsp` SIB `0x24`, `%rbp` `mod=1 disp8=0`, scaled index without base, `%fs`/`%gs` segment overrides, `%rip`-relative, mandatory REX low-byte registers, high-byte registers, `lock`/`rep` prefixes, and 3-byte VEX extended registers).

- **AArch64 (`AArch64Codec.swift`)**:
  - `AArch64InstructionTable`, `AArch64TableEncoder`, and `AArch64TableDisassembler`.
  - Covers A64 integer, branches, loads/stores (unsigned offset, pre-index, post-index, unscaled `ldur`/`stur`, pairs `ldp`/`stp`, exclusives `ldxr`/`stxr`/`ldaxr`/`stlxr`), system/barriers (`msr`/`mrs` including `S3_<op1>_<Cn>_<Cm>_<op2>` and architectural sysregs, `svc`, `hvc`, `smc`, `eret`, `wfi`, `wfe`, `sev`, `sevl`, `isb`, `dsb`, `dmb`, `dc`, `ic`, `tlbi`, `at`, `clrex`), scalar FP, Advanced SIMD (NEON `.16b`/`.8b`/`.4s`/`.2d`), and SVE (`z0`–`z31`, `p0`–`p15`, `ffr`, `mul vl` vector-length-scaled addressing, `rdvl`).
  - `AArch64InstructionTable.verifyRoundTrip()` round-trips every descriptor template.
  - **Not yet covered:** LSE atomics, much of scalar FP (`fmadd`, `fabs`, `fsqrt`, `frint*`, …) and most Advanced SIMD.

- **RV64 / RVA23 (`RV64Codec.swift`)**:
  - `RV64InstructionTable`, `RV64TableEncoder`, and `RV64TableDisassembler`.
  - Covers RV64I, M, A (`lr.w/d`, `sc.w/d`, `amoswap`, `amoadd`, `amoxor`, `amoand`, `amoor`, `amomin`, `amomax`), F, D, Zicsr (`csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci` plus aliases), privileged (`ecall`, `ebreak`, `mret`, `sret`, `wfi`, `sfence.vma`), Zba (`add.uw`, `sh1add`, `sh2add`, `sh3add`, `sh1add.uw`, `sh2add.uw`, `sh3add.uw`, `slli.uw`), Zbb (`andn`, `orn`, `xnor`, `clz`, `clzw`, `ctz`, `ctzw`, `cpop`, `cpopw`, `max`, `maxu`, `min`, `minu`, `sext.b`, `sext.h`, `zext.h`, `rol`, `rolw`, `ror`, `rori`, `roriw`, `rorw`, `orc.b`, `rev8`), Zbs (`bclr`, `bclri`, `bext`, `bexti`, `binv`, `binvi`, `bset`, `bseti`), Zicbom (`cbo.clean`, `cbo.flush`, `cbo.inval`), Zicboz (`cbo.zero`), Zicond (`czero.eqz`, `czero.nez`), C (16-bit compressed quadrant 0/1/2 encodings), and V (RVV 1.0 `vsetvli`, `vsetivli`, `vsetvl`, vector loads/stores, vector ALU/mask ops).
  - `RV64InstructionTable.verifyRoundTrip()` round-trips every descriptor template (both 32-bit and 16-bit compressed encodings).
  - **Not yet covered (RVA23 mandatory):** Zicbop, Zihintpause, Zihintntl, Zawrs, Zimop/Zcmop, Zvbb, Zvfhmin, Zfhmin converts, most of V (compares, reductions, slides, FMA, strided/indexed/segment memory).

### 1.2 Relocatable Object Model & ELF64 Reader/Writer (`Sources/SwiftStack/Object/`)

- **`RelocatableObject.swift`**:
  - `~Copyable` Structure-of-Arrays (`SectionColumn`, `SymbolColumn`, `RelocationColumn`) produced by the assembler (`Asm`). The M0.5 code generator now encodes every instruction through `X86TableEncoder` (`Codegen/X86CodeEmitter.swift`; the hand-rolled `Encode/X86Encoder` is gone) but still links through `Linker/StaticELFWriter`; moving it onto `RelocatableObject` is M3 work.
  - Closed `ObjectArch` (`x86_64`, `aarch64`, `riscv64`) and `ObjectFormat` (`elf64`) enums.
- **`ELFObjectIO.swift`**:
  - `ELFObjectWriter`: Deterministic (`D6`) ELF64 `ET_REL` serializer with canonical section ordering, local-before-global `SHT_SYMTAB` partitioning (`sh_info` = first global index), per-code-section `.rela<sec>` tables, and architecture `e_flags` (`EF_RISCV_RVC | EF_RISCV_FLOAT_ABI_DOUBLE` on RV64).
  - `ELFObjectReader`: Full ELF64 `ET_REL` parser reconstructing `RelocatableObject` sections, symbols, and `.rela` relocations for round-trip verification and upcoming M3 linker input. Input is untrusted: every offset, size, index, `sh_link`/`sh_info` and string reference is validated with overflow-checked arithmetic, and malformed input throws an `ELFReadError` instead of trapping.

### 1.3 Multi-Architecture Assemblers & `.S` Preprocessing (`Sources/SwiftStack/Asm/`)

- **`CPreprocessor.swift` (`assemblerMode: true`)**:
  - Preserves newlines after `#include`, `#define`, and `#if`/`#ifdef` directives so line-oriented assembly statements and line numbers remain intact.
  - Preserves `#` immediate prefixes on AArch64 (`#0x10`) inside macro bodies rather than treating them as C stringification operators when not followed by a macro parameter name.
- **`Assembler.swift`**:
  - Shared directive engine (`.section`, `.text`, `.data`, `.rodata`, `.bss`, `.pushsection`, `.popsection`, `.globl`/`.global`, `.weak`, `.local`, `.hidden`, `.type`, `.size`, `.equ`/`.set`, `.byte`, `.short`/`.hword`/`.2byte`, `.word`/`.long`/`.4byte`, `.quad`/`.dword`/`.8byte`, `.asciz`/`.string`, `.ascii`, `.space`/`.skip`/`.zero`, `.align`/`.balign`/`.p2align`, `.cfi_*`, `.option`, `.arch`, `.code16`/`.code32`/`.code64`).
  - Macro & repetition preprocessor (`.macro`/`.endm` with `\@` unique invocation counters, default/`:req`/`:vararg` parameters and `\()`, `.rept`/`.endr`, `.irp`/`.endr`, `.if`/`.ifdef`/`.ifndef`/`.ifeq`/`.ifne`/`.else`/`.elseif`/`.endif`) and directional numeric local labels (`1:` with `1b` / `1f` resolution).
  - Multi-pass branch relaxation engine with architecture-specific `NOP` alignment padding (multi-byte `NOP`s on x86-64, `0xD503201F` on AArch64, `0x00000013` / `0x0001` on RV64).
- **Architecture Frontends**:
  - `X86Assembler.swift` (`X86Asm`): AT&T syntax, `%seg:disp(base, index, scale)` parsing, `@PLT` / `@GOTPCREL` / `@TPOFF` modifiers, `.code16`/`.code32`/`.code64` state switching, and x86-64 `JMP`/`Jcc` `rel8` <-> `rel32` relaxation.
  - `AArch64Assembler.swift` (`A64Asm`): A64 register/NEON/SVE syntax, `:pg_hi21:` / `:lo12:` / `:got:` / `:got_lo12:` relocation modifiers, `adr`/`adrp`, `mov` wide/inverted/bitmask immediate synthesis, and `R_AARCH64_*` fixup emission.
  - `RV64Assembler.swift` (`RVAsm`): RV64I/M/A/F/D/C/V + RVA23 syntax, `.option rvc`/`norvc`/`push`/`pop`, `%pcrel_hi`/`%pcrel_lo`/`%hi`/`%lo` modifiers, pseudo-instructions (`la`, `lla`, `li` full 64-bit synthesis, `call`, `tail`, `j`, `jr`, `ret`, `mv`, `not`, `neg`, `negw`, `sext.w`, `seqz`, `snez`, `sltz`, `sgtz`, `beqz`, `bnez`, `blez`, `bgez`, `bltz`, `bgtz`, `bgt`, `ble`, `bgtu`, `bleu`, `csrr`, `csrw`, `csrs`, `csrc`, `csrwi`, `csrsi`, `csrci`, `rdcycle`, `rdtime`, `rdinstret`), and RVC opportunism (`EB8`).

---

## 2. Exit Criteria Verification

Per [09-roadmap.md](../09-roadmap.md) (§M2) and [05-assembler.md](../05-assembler.md) §4.11:

1. **Assembly matches GNU `as` (modulo documented choices).** `M2DifferentialTests.swift`:
   - Each file is assembled by Swift-Stack and by the oracles. Both objects are parsed by an independent test-only ELF reader, and the comparison covers every allocatable section (bytes, size, flags, alignment), every relocation, and every non-temporary symbol.
   - **Corpora:** the Todhchai floor entry stubs (3), all 21 Croi `kernel/arch/{amd64,arm64,rv64}/*.S` files, and the in-repo regression corpus `Tests/Differential/asm/<arch>/`.
   - **Oracles:** `clang -c` for all three architectures, and GNU `as` (via `gcc -c`) for x86-64. No GNU cross-assembler for AArch64/RV64 is installed on the reference machine.
   - **GNU `as` differences:** the x86-64 corpus differences are the three section-level ones documented in 05 §4.11 (alignment, NOP padding, `disp32` for a late-resolved label difference). Each is exempted only for the affected section, and the clang comparison still covers it exactly.
   - A missing corpus or oracle skips the test rather than passing it.
2. **Encoder/disassembler round trip.** `verifyRoundTrip()` round-trips one sample per descriptor. For x86-64 the round trip is exhaustive over the instruction table: `M2X86ExhaustiveTests.swift` (05 §4.11) generates every operand form of each of the 1,583 descriptors (about 285,000 instructions: every register of each slot's class, all low/extended register combinations, every ModR/M/SIB special case, boundary immediates). Each must round-trip, match `llvm-mc` byte for byte from both its text and our disassembly, assemble identically through `Asm/`, and match GNU `as` apart from the documented differences. The test also asserts that every descriptor is selected at least once. AArch64 and RV64 are still checked from one sample per descriptor. `M2EncoderOracleTests.swift` checks every sample against `llvm-mc`, which catches encoder/disassembler pairs that agree on a wrong encoding (it found the 16-bit `tzcnt`/`lzcnt`/`popcnt` prefix bug).
3. **Behavior without an oracle.** `M2AssemblerRegressionTests.swift` covers out-of-range AArch64/RV64 branch relaxation (clang reports these as errors instead of relaxing), rejected encodings being diagnosed rather than dropped, `ldr Xt, #imm`, rendered diagnostic locations (`file:line:col` through `.include`, macros, `.rept` and `.S` preprocessing), and an ELF reader fuzz test (every truncation plus 12,000 seeded mutations of valid objects must throw, never crash). It also pins GNU `as` output for CFI, `.equ` label differences, expression precedence and macro arguments, so these hold where no oracle is installed.

### Defects fixed after the initial M2 report
- **`.long sym - .`:** produced an absolute relocation. It now uses `R_X86_64_PC32`/`PC64`, `R_AARCH64_PREL32`/`PREL64`, or an `R_RISCV_ADD`/`SUB` pair.
- **`.size sym, . - sym`:** produced 0.
- **`.set` symbols:** were not emitted as `SHN_ABS`.
- **AArch64/RV64 branches out of range:** were silently truncated. They are now relaxed to an inverted branch over `b`/`jal`, as §4.5 specifies, and diagnosed if out of range even then.
- **AArch64 encoder rejections:** an instruction the encoder rejected was silently dropped. The encoder now range-checks PC-relative fields.
- **`.S` target macros:** AArch64/RV64 `.S` files also saw `__x86_64__`.
- **RISC-V external `j`:** a compressed jump to an external symbol was laid out at 2 bytes but emitted at 4.
- **`.eh_frame`:** CFA instructions had no `DW_CFA_advance_loc*`, so every rule applied from the function start. Records now match GNU `as` byte for byte (advance_loc/1/2/4, shared CIEs, multiple FDEs, padding), and more `.cfi_*` directives are supported (05 §4.4).
- **`.equ`/`.set` of a label difference:** did not resolve to a constant when it named labels, especially forward ones. It now resolves after layout, in immediates, data and `.size`.
- **Expression precedence:** followed C. It now follows GNU `as` (05 §4.4), including -1 for true comparisons and binary `!`.
- **Macros:** `:vararg` parameters, `\()` concatenation and GNU argument splitting were missing or wrong; unbounded recursion overflowed the stack.
- **Diagnostic locations:** assembler errors reported a bare line number, with no file, and the wrong line after `.include`, macro expansion and `.S` preprocessing. They now carry `file:line:col`, with notes at macro uses.
- **ELF reader:** truncated or corrupted objects (bad offsets, sizes, `sh_link`/`sh_info`, string offsets, symbol/relocation indices) could trap.
- **RVC:** `addi sp, sp, -16` used `c.addi16sp`; GNU `as` and LLVM MC use `c.addi` when the immediate fits.
- **Diagnostic rendering** trapped on an empty `DiagnosticBag`.
