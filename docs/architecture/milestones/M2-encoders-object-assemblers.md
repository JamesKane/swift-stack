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
  - `A64InstructionTable` (412 descriptors, up from 232), `A64Encoder`, and `A64Disassembler`. Descriptors whose width is a variable field (`size`, `ftype`, `Q`) list the scalar widths or vector arrangements they accept; the encoder rejects anything else.
  - Integer: add/sub (immediate, shifted, extended), logical (immediate, shifted), move wide, `adr`/`adrp`, bitfield, `extr`, 1/2/3-source data processing, `smulh`/`umulh`, conditional select and compare, branches.
  - Loads/stores: unsigned offset, pre/post-index, unscaled, unprivileged, register offset with every legal extend/shift, literal, `ldp`/`stp`, exclusives (`ldxr`/`stxr`/`ldaxr`/`stlxr`/`ldar`/`stlr` with `b`/`h` forms, `ldxp`/`stxp`), and the SIMD/FP (`b`/`h`/`s`/`d`/`q`) forms of all of these.
  - LSE atomics: `ldadd`/`ldclr`/`ldeor`/`ldset`/`ldsmax`/`ldsmin`/`ldumax`/`ldumin`/`swp` and `cas` with `a`/`al`/`l` ordering and `b`/`h` sizes, `casp`, and the `st<op>` aliases.
  - Scalar FP (half, single, double): `fmov` (register, general, immediate), `fabs`, `fneg`, `fsqrt`, `frint[npmzaxi]`, `fcvt` between all precisions, `fcvt[npmza][su]`, `scvtf`/`ucvtf` (integer and fixed-point), `fcvtzs`/`fcvtzu` fixed-point, `fadd`/`fsub`/`fmul`/`fdiv`/`fnmul`, `fmax`/`fmin`/`fmaxnm`/`fminnm`, `fmadd`/`fmsub`/`fnmadd`/`fnmsub`, `fcmp`/`fcmpe` (register and `#0.0`), `fccmp`/`fccmpe`, `fcsel`.
  - Advanced SIMD subset (full NEON is M5): three-same integer/bitwise/FP arithmetic and compares, permutes, two-register misc, compare with zero, across-lanes reductions, `xtn`, shifts by immediate (including `sshll`/`ushll`/`shrn` and the `sxtl`/`uxtl` aliases), `dup`/`ins`/`umov`/`smov` (with their `mov` aliases), `movi`/`mvni`/`orr`/`bic`/`fmov` (immediate), `ld1`-`ld4`/`st1`-`st4` (multiple structures, with post-index), `ld1r`, single-lane `ld1`/`st1`, `tbl`/`tbx`, `ext`.
  - System: `msr`/`mrs` (all system registers Todhchai and Croi named at the time, which VectraOS carries with croi's arm64 code, plus generic `s<op0>_<op1>_c<n>_c<m>_<op2>`), `msr` PSTATE (`spsel`, `daifset`, `daifclr`, `pan`), all 16 `dmb`/`dsb`/`isb`/`clrex` options (`ssbb`/`pssbb`), `hint` with its PAC/BTI/`csdb`/`dgh` aliases, `dc`/`ic`/`tlbi`/`at` (base-architecture and EL2 operations), exception generation, `udf`. SVE subset: `ldr`/`str` of `z`/`p` registers, `addvl`/`addpl`, `rdvl`, `rdffr`/`wrffr`.
  - The disassembler prints what `llvm-mc --disassemble` prints, including its preferred aliases (`mov`, `cmp`, `tst`, `neg`, `lsl`/`lsr`/`asr`, `ubfx`/`sbfiz`/`bfi`, `cset`/`cinc`, `mul`, `stadd`, `mvn`, `sxtl`, ...). The assembler accepts both these aliases and the architectural mnemonics.
  - Not in the table yet: `adc`/`sbc`, `ccmn`, widening multiplies (`smaddl`/`umaddl`/`smull`/`umull`), scalar `cls`, CRC32, `ldpsw`, `ldnp`/`stnp`, `prfm`, acquire-RCpc loads (`ldapr`), generic `sys`/`sysl`, `ldr`/`str` pointer-authentication loads, and the rest of NEON (widening/narrowing arithmetic, by-element forms, scalar SIMD, crypto).
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

1. **Assembly matches LLVM MC, the reference assembler; differences from GNU `as` are documented.** `M2DifferentialTests.swift`:
   - Each file is assembled by Swift-Stack and by the oracles. Both objects are parsed by an independent test-only ELF reader, and the comparison covers every allocatable section (bytes, size, flags, alignment), every relocation, and every non-temporary symbol.
   - **Corpora:** the Todhchai floor entry stubs (3), all 21 Croi `kernel/arch/{amd64,arm64,rv64}/*.S` files, and the in-repo regression corpus `Tests/Differential/asm/<arch>/`. *(As measured at the time. Todhchai and croi have since been retired, and the corpus is now VectraOS's 26 `.S` files; see "Corpus moved to VectraOS" below.)*
   - **Oracles:** `clang -c` for all three architectures, compared exactly (LLVM MC is the reference, 05 §4.11), and GNU `as` (via `gcc -c`) for x86-64. No GNU cross-assembler for AArch64/RV64 is installed on the reference machine.
   - **GNU `as` differences:** the corpus differences are the ones documented in 05 §4.11: alignment, NOP padding and `disp32` for a late-resolved label difference (x86-64 encoding); `.eh_frame` FDE order and CIE sharing (`cfi_cie_order.s`, whose `.eh_frame` is exempted); and macro argument splitting (`macro_args.s`, which GNU `as` rejects, so it is compared with clang only). Each is exempted only for the affected section or file, and the clang comparison still covers it exactly.
   - A missing corpus or oracle skips the test rather than passing it.
2. **Encoder/disassembler round trip.** `verifyRoundTrip()` round-trips one sample per descriptor. For x86-64 the round trip is exhaustive over the instruction table: `M2X86ExhaustiveTests.swift` (05 §4.11) generates every operand form of each of the 1,583 descriptors (about 285,000 instructions: every register of each slot's class, all low/extended register combinations, every ModR/M/SIB special case, boundary immediates). Each must round-trip, match `llvm-mc` byte for byte from both its text and our disassembly, assemble identically through `Asm/`, and match GNU `as` apart from the documented differences. The test also asserts that every descriptor is selected at least once. For AArch64, `M2AArch64ExhaustiveTests.swift` does the same for all 412 descriptors (about 176,000 instructions: every width and arrangement a descriptor accepts, every register slot swept over all 32 encodings, every addressing mode and extend, all conditions, all bitmask immediates, all `immr:imms` pairs, all FP8 immediates). Each must round-trip to the same descriptor, assemble through `llvm-mc` from our disassembly to exactly our bytes, disassemble through `llvm-mc` to exactly our text, and assemble identically through `Asm/`. Forms LLVM rejects as unpredictable (writeback base equal to a transfer register, `ldp` with Rt == Rt2, an exclusive store whose status register is also a source) are not generated. RV64 is still checked from one sample per descriptor. `M2EncoderOracleTests.swift` checks every sample against `llvm-mc`, which catches encoder/disassembler pairs that agree on a wrong encoding (it found the 16-bit `tzcnt`/`lzcnt`/`popcnt` prefix bug).
3. **Behavior without an oracle.** `M2AssemblerRegressionTests.swift` covers out-of-range AArch64/RV64 branch relaxation (clang reports these as errors instead of relaxing), rejected encodings being diagnosed rather than dropped, `ldr Xt, #imm`, rendered diagnostic locations (`file:line:col` through `.include`, macros, `.rept` and `.S` preprocessing), and an ELF reader fuzz test (every truncation plus 12,000 seeded mutations of valid objects must throw, never crash). It also pins LLVM MC output for CFI (including FDE grouping by CIE), `.equ` label differences, expression precedence and macro and `.irp` arguments, and LLVM MC's macro and CFI diagnostics, so these hold where no oracle is installed.

### Defects fixed after the initial M2 report
- **`.long sym - .`:** produced an absolute relocation. It now uses `R_X86_64_PC32`/`PC64`, `R_AARCH64_PREL32`/`PREL64`, or an `R_RISCV_ADD`/`SUB` pair.
- **`.size sym, . - sym`:** produced 0.
- **`.set` symbols:** were not emitted as `SHN_ABS`.
- **AArch64/RV64 branches out of range:** were silently truncated. They are now relaxed to an inverted branch over `b`/`jal`, as §4.5 specifies, and diagnosed if out of range even then.
- **AArch64 encoder rejections:** an instruction the encoder rejected was silently dropped. The encoder now range-checks PC-relative fields.
- **`.S` target macros:** AArch64/RV64 `.S` files also saw `__x86_64__`.
- **RISC-V external `j`:** a compressed jump to an external symbol was laid out at 2 bytes but emitted at 4.
- **`.eh_frame`:** CFA instructions had no `DW_CFA_advance_loc*`, so every rule applied from the function start. Records now match LLVM MC byte for byte (advance_loc/1/2/4, FDEs grouped by CIE key with one CIE per group, padding), and more `.cfi_*` directives are supported (05 §4.4, §4.9).
- **`.equ`/`.set` of a label difference:** did not resolve to a constant when it named labels, especially forward ones. It now resolves after layout, in immediates, data and `.size`.
- **Expression precedence:** followed C. It now follows LLVM MC's ELF precedence, which GNU `as` shares (05 §4.4), including -1 for true comparisons and binary `!`.
- **Macros:** `:vararg` parameters, `\()` concatenation and argument splitting were missing or wrong; unbounded recursion overflowed the stack.
- **GNU-preferring choices:** `.eh_frame` kept FDEs in source order and macro arguments were split as GNU `as` splits them. Both now match LLVM MC (05 §4.11, differences 8–11), as do `.irp`/`.irpc` value lists, quoted macro arguments (no escape processing), the 20-level nesting limit, and LLVM MC's macro and CFI diagnostics, which were previously accepted silently. `\@` counted from 1 instead of 0. A `.set` of a fixed label difference in another section was not folded at once, so a later reassignment changed earlier uses.
- **Diagnostic locations:** assembler errors reported a bare line number, with no file, and the wrong line after `.include`, macro expansion and `.S` preprocessing. They now carry `file:line:col`, with notes at macro uses.
- **ELF reader:** truncated or corrupted objects (bad offsets, sizes, `sh_link`/`sh_info`, string offsets, symbol/relocation indices) could trap.
- **RVC:** `addi sp, sp, -16` used `c.addi16sp`; GNU `as` and LLVM MC use `c.addi` when the immediate fits.
- **Diagnostic rendering** trapped on an empty `DiagnosticBag`.

### Corpus moved to VectraOS

The Todhchai and croi corpora above were retired with those projects. VectraOS, which carries croi's kernel and is now the first-party consumer ([00](../00-overview-and-principles.md) §7), replaced them. `M2DifferentialTests.swift` assembles all 26 of its `.S` files for their architectures with the definitions, include paths and ISA flags of its CMake build (`SWIFTSTACK_VECTRAOS_ROOT`, default `~/Projects/OS/VectraOS-swift`): 30 objects, 10 per architecture, all matching `clang -c` exactly, and the 10 x86-64 objects also matching GNU `as` with the documented allowances. VectraOS builds its RV64 kernel for `rv64imac_zicsr_zifencei`, PIE, with clang's default linker relaxation, which the croi corpus had been assembled without. Defects this exposed, each now fixed with a regression test:

- **`A - B` with `B` in the current section and `A` undefined** (`.long <entry point> - vdso_header` in the vDSO header) was an error on x86-64 and AArch64. It is now a PC-relative relocation against `A` with `P - B` in the addend, as in LLVM MC.
- **RISC-V linker relaxation** was not implemented (`.option relax` behaved as `norelax`). The assembler now emits `R_RISCV_RELAX` after relaxable relocations, worst-case NOP padding with `R_RISCV_ALIGN` for code alignment, and keeps branches and label differences that span either as relocations, matching LLVM MC ([05](../05-assembler.md) §4.8).
- **RISC-V target options:** the assembler assumed RVA23 and non-PIC. `RVAsmOptions(march:pic:relax:)` now takes them from the target as clang's driver does; without Zbs, `li` of a single high bit no longer uses `bseti`, and with `-fPIE`, `la` goes through the GOT.
- **RISC-V stores with `%lo`/`%tprel_lo`** used the I-type relocation (`R_RISCV_LO12_I`) instead of the S-type one.
- **RISC-V NOP padding** put the `c.nop` after the 4-byte `nop`s; LLVM MC puts it first.
