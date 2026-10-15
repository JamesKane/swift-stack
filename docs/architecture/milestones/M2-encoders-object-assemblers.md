# Milestone M2 — Encoders, Object Model, and Assemblers

Per [09-roadmap.md](../09-roadmap.md) (§M2) and [05-assembler.md](../05-assembler.md), Milestone M2 delivers the shared instruction encoding and disassembly tables (`Encode/`), the relocatable object model and ELF64 `ET_REL` reader/writer (`Object/`), and the multi-architecture assembler pipeline (`Asm/`) supporting x86-64 (AT&T syntax), AArch64, and RV64 (RVA23 profile).

---

## 1. Deliverables Completed

### 1.1 Table-Driven Instruction Encoders & Disassemblers (`Sources/SwiftStack/Encode/`)

All three target architectures use a single static instruction descriptor table shared between encoder and disassembler, verified by exhaustive table round-trip (`encode -> disassemble -> re-encode`):

- **x86-64 (`X86Codec.swift`)**:
  - `X86InstructionTable`, `X86TableEncoder`, and `X86TableDisassembler`.
  - Covers baseline x86-64 GPR, system/privileged (`syscall`, `sysretq`, `swapgs`, `lgdt`, `lgdtl`, `lidt`, `ltr`, `str`, `invlpg`, `wrmsr`, `rdmsr`, `rdtsc`, `rdtscp`, `cpuid`, `wbinvd`, `fxsave64`, `fxrstor64`, `xsave64`, `xrstor64`, `xsaveopt64`, `xgetbv`, `xsetbv`, `rdpkru`, `wrpkru`, `clac`, `stac`, `monitor`, `mwait`, `%crN`/`%drN`/segment moves, port I/O), BMI1/BMI2/ABM/CRC32 (`lzcnt`, `tzcnt`, `popcnt`, `andn`, `bextr`, `bzhi`, `pdep`, `pext`, `rorx`, `sarx`, `shlx`, `shrx`, `crc32b/w/l/q`), SSE/SSE2/SSSE3/SSE4.1/SSE4.2, and 2-byte (`0xC5`) / 3-byte (`0xC4`) VEX (AVX/AVX2/FMA) instructions.
  - Supports `.code64`, `.code32`, and `.code16` real/protected-mode boot transition encodings (including `ljmpl`/`ljmpw` far jumps and 16-bit absolute addressing).
  - `X86InstructionTable.verifyRoundTrip()` verifies 589 descriptor forms plus special addressing modes (`%rsp` SIB `0x24`, `%rbp` `mod=1 disp8=0`, scaled index without base, `%fs`/`%gs` segment overrides, `%rip`-relative, mandatory REX low-byte registers, high-byte registers, `lock`/`rep` prefixes, and 3-byte VEX extended registers).

- **AArch64 (`AArch64Codec.swift`)**:
  - `AArch64InstructionTable`, `AArch64TableEncoder`, and `AArch64TableDisassembler`.
  - Covers A64 integer, branches, loads/stores (unsigned offset, pre-index, post-index, unscaled `ldur`/`stur`, pairs `ldp`/`stp`, exclusives `ldxr`/`stxr`/`ldaxr`/`stlxr`), LSE atomics (`ldadd`, `ldclr`, `ldset`, `swp`, `cas`), system/barriers (`msr`/`mrs` including `S3_<op1>_<Cn>_<Cm>_<op2>` and architectural sysregs, `svc`, `hvc`, `smc`, `eret`, `wfi`, `wfe`, `sev`, `sevl`, `isb`, `dsb`, `dmb`, `dc`, `ic`, `tlbi`, `at`, `clrex`), scalar FP, Advanced SIMD (NEON `.16b`/`.8b`/`.4s`/`.2d`), and SVE (`z0`–`z31`, `p0`–`p15`, `ffr`, `mul vl` vector-length-scaled addressing, `rdvl`).
  - `AArch64InstructionTable.verifyRoundTrip()` verifies all 206 descriptor templates.

- **RV64 / RVA23 (`RV64Codec.swift`)**:
  - `RV64InstructionTable`, `RV64TableEncoder`, and `RV64TableDisassembler`.
  - Covers RV64I, M, A (`lr.w/d`, `sc.w/d`, `amoswap`, `amoadd`, `amoxor`, `amoand`, `amoor`, `amomin`, `amomax`), F, D, Zicsr (`csrrw`, `csrrs`, `csrrc`, `csrrwi`, `csrrsi`, `csrrci` plus aliases), privileged (`ecall`, `ebreak`, `mret`, `sret`, `wfi`, `sfence.vma`), Zba (`add.uw`, `sh1add`, `sh2add`, `sh3add`, `sh1add.uw`, `sh2add.uw`, `sh3add.uw`, `slli.uw`), Zbb (`andn`, `orn`, `xnor`, `clz`, `clzw`, `ctz`, `ctzw`, `cpop`, `cpopw`, `max`, `maxu`, `min`, `minu`, `sext.b`, `sext.h`, `zext.h`, `rol`, `rolw`, `ror`, `rori`, `roriw`, `rorw`, `orc.b`, `rev8`), Zbs (`bclr`, `bclri`, `bext`, `bexti`, `binv`, `binvi`, `bset`, `bseti`), Zicbom (`cbo.clean`, `cbo.flush`, `cbo.inval`), Zicboz (`cbo.zero`), Zicond (`czero.eqz`, `czero.nez`), C (16-bit compressed quadrant 0/1/2 encodings), and V (RVV 1.0 `vsetvli`, `vsetivli`, `vsetvl`, vector loads/stores, vector ALU/mask ops).
  - `RV64InstructionTable.verifyRoundTrip()` verifies all 269 descriptor templates (both 32-bit and 16-bit compressed encodings).

### 1.2 Relocatable Object Model & ELF64 Reader/Writer (`Sources/SwiftStack/Object/`)

- **`RelocatableObject.swift`**:
  - `~Copyable` Structure-of-Arrays (`SectionColumn`, `SymbolColumn`, `RelocationColumn`) shared between the native code generator (`Codegen`) and the assembler (`Asm`).
  - Closed `ObjectArch` (`x86_64`, `aarch64`, `riscv64`) and `ObjectFormat` (`elf64`) enums.
- **`ELFObjectIO.swift`**:
  - `ELFObjectWriter`: Deterministic (`D6`) ELF64 `ET_REL` serializer with canonical section ordering, local-before-global `SHT_SYMTAB` partitioning (`sh_info` = first global index), per-code-section `.rela<sec>` tables, architecture `e_flags` (`EF_RISCV_RVC | EF_RISCV_FLOAT_ABI_DOUBLE` on RV64), and `.note.GNU-stack`.
  - `ELFObjectReader`: Full ELF64 `ET_REL` parser reconstructing `RelocatableObject` sections, symbols, and `.rela` relocations for round-trip verification and upcoming M3 linker input.

### 1.3 Multi-Architecture Assemblers & `.S` Preprocessing (`Sources/SwiftStack/Asm/`)

- **`CPreprocessor.swift` (`assemblerMode: true`)**:
  - Preserves newlines after `#include`, `#define`, and `#if`/`#ifdef` directives so line-oriented assembly statements and line numbers remain intact.
  - Preserves `#` immediate prefixes on AArch64 (`#0x10`) inside macro bodies rather than treating them as C stringification operators when not followed by a macro parameter name.
- **`Assembler.swift`**:
  - Shared directive engine (`.section`, `.text`, `.data`, `.rodata`, `.bss`, `.pushsection`, `.popsection`, `.globl`/`.global`, `.weak`, `.local`, `.hidden`, `.type`, `.size`, `.equ`/`.set`, `.byte`, `.short`/`.hword`/`.2byte`, `.word`/`.long`/`.4byte`, `.quad`/`.dword`/`.8byte`, `.asciz`/`.string`, `.ascii`, `.space`/`.skip`/`.zero`, `.align`/`.balign`/`.p2align`, `.cfi_*`, `.option`, `.arch`, `.code16`/`.code32`/`.code64`).
  - Macro & repetition preprocessor (`.macro`/`.endm` with `\@` unique invocation counters and default arguments, `.rept`/`.endr`, `.irp`/`.endr`, `.if`/`.ifdef`/`.ifndef`/`.ifeq`/`.ifne`/`.else`/`.elseif`/`.endif`) and directional numeric local labels (`1:` with `1b` / `1f` resolution).
  - Multi-pass branch relaxation engine with architecture-specific `NOP` alignment padding (multi-byte `NOP`s on x86-64, `0xD503201F` on AArch64, `0x00000013` / `0x0001` on RV64).
- **Architecture Frontends**:
  - `X86Assembler.swift` (`X86Asm`): AT&T syntax, `%seg:disp(base, index, scale)` parsing, `@PLT` / `@GOTPCREL` / `@TPOFF` modifiers, `.code16`/`.code32`/`.code64` state switching, and x86-64 `JMP`/`Jcc` `rel8` <-> `rel32` relaxation.
  - `AArch64Assembler.swift` (`A64Asm`): A64 register/NEON/SVE syntax, `:pg_hi21:` / `:lo12:` / `:got:` / `:got_lo12:` relocation modifiers, `adr`/`adrp`, `mov` wide/inverted/bitmask immediate synthesis, and `R_AARCH64_*` fixup emission.
  - `RV64Assembler.swift` (`RVAsm`): RV64I/M/A/F/D/C/V + RVA23 syntax, `.option rvc`/`norvc`/`push`/`pop`, `%pcrel_hi`/`%pcrel_lo`/`%hi`/`%lo` modifiers, pseudo-instructions (`la`, `lla`, `li` full 64-bit synthesis, `call`, `tail`, `j`, `jr`, `ret`, `mv`, `not`, `neg`, `negw`, `sext.w`, `seqz`, `snez`, `sltz`, `sgtz`, `beqz`, `bnez`, `blez`, `bgez`, `bltz`, `bgtz`, `bgt`, `ble`, `bgtu`, `bleu`, `csrr`, `csrw`, `csrs`, `csrc`, `csrwi`, `csrsi`, `csrci`, `rdcycle`, `rdtime`, `rdinstret`), and RVC opportunism (`EB8`).

---

## 2. Exit Criteria Verification

All exit criteria from [09-roadmap.md](../09-roadmap.md) (§M2) are verified in `Tests/SwiftStackTests/SwiftStackTests.swift` (`M2EncodersObjectAssemblersTests`):

1. **Exhaustive Encoder/Disassembler Table Round-Trip**:
   - `testX86InstructionTableRoundTrip()` — 589 descriptors + special addressing modes: **PASSED**
   - `testAArch64InstructionTableRoundTrip()` — 206 descriptors: **PASSED**
   - `testRV64InstructionTableRoundTrip()` — 269 descriptors (32-bit + RVC 16-bit): **PASSED**
2. **ELF64 `ET_REL` Read/Write & D6 Determinism**:
   - `testELFRelocatableObjectRoundTrip()` — verifies bit-identical serialization and deserialization across `x86_64`, `aarch64`, and `riscv64`: **PASSED**
3. **Differential Assembly Against Clang (`-c`)**:
   - `testTodhchaiDifferentialAssembly()` — assembles Todhchai floor entry stubs (`system/sys/floor/entry/{amd64,arm64,rv64}.S`) and verifies **100% byte-for-byte identical section contents** against `clang -c`: **PASSED**
   - `testCroiDifferentialAssembly()` — assembles all 21 Croi kernel architecture assembly files (`kernel/arch/{amd64,arm64,rv64}/{cpu,exceptions,smp,start,thread,usercopy,usertest}.S`) and verifies **100% byte-for-byte identical section contents** across every executable and data section against `clang -c`: **PASSED**
