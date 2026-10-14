# 05. Native Assembler Architecture (AMD64, ARM64, RV64 & Extensible Target Framework)

## 1. Overview & Purpose

In operating system development and systems programming (such as [Todhchai OS](file:///home/jkane/Projects/OS/todhchai)), compilers alone are insufficient. Systems code requires standalone assembly files (`.s` and `.S`) for:
- Low-level process entry stubs (`system/sys/floor/start.S`).
- Microkernel traps, interrupt gates, and thread context switching routines.
- Hardware-specific register configuration (page tables, control registers, timer setup).
- Hand-optimized vector and SWAR kernels (cryptography, codecs, and memory primitives).

Traditional toolchains force developers to install and coordinate external assemblers (GNU `as`, `nasm`, or Clang's integrated assembler), introducing toolchain fragmentation and slow sub-process invocation.

Swift-Stack incorporates **built-in, data-oriented native assemblers** for **AMD64**, **ARM64**, and **RV64**, while providing an extensible target architecture for future platforms.

```
Assembly Source (*.s, *.S)
            │
            ▼  (SourceManager with 64-byte sentinel zero-padding)
     Assembly Lexer  (SWAR scanning of mnemonics, registers, labels, directives)
            │
            ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      PLUGGABLE ASSEMBLER TARGET                        │
├────────────────────┬────────────────────┬──────────────────────────────┤
│ AMD64 (x86_64)     │ ARM64 (AArch64)    │ RV64 (RISC-V 64GC)           │
│ - Intel & AT&T     │ - Standard ARM UAL │ - Base 32-bit + 16-bit C ext │
│ - ModR/M, SIB, REX │ - 32-bit fixed     │ - Pseudoinstruction expansion│
│ - Branch relaxation│ - ADRP/ADD pairs   │ - li, la, call, tail, ret    │
└────────────────────┴────────────────────┴──────────────────────────────┘
            │
            ▼  (Zero-Copy In-Memory Direct Output)
Relocatable Sections (.text, .rela.text, .symtab, .eh_frame)
            │
            ▼  (Direct handoff to in-process Linker)
      Native Linker
```

---

## 2. Extensible Architecture Framework

The assembler is decoupled from machine-specific encoding via a high-performance, data-oriented target protocol:

```swift
public protocol AssemblerTarget: Sendable {
    /// Human-readable architecture identifier (e.g. "x86_64", "aarch64", "riscv64")
    static var targetName: String { get }

    /// Assembles an assembly token stream directly into in-memory relocatable sections.
    static func assemble(
        source: SourceManager.Buffer,
        tokens: TokenBuffer,
        output: inout RelocatableSection
    ) throws
}
```

### Planned Extensibility
While AMD64, ARM64, and RV64 are the base requirements, the framework provides clean abstraction hooks for future target backends (such as WebAssembly text format `wat` or future ISA extensions) without altering the frontend parser or linker pipeline.

---

## 3. Base Target: AMD64 (x86-64 / x86-64-v2)

### 1. Grammar & Syntax Support
- Supports both **AT&T Syntax** (standard for OS kernel stubs, `%rax, (%rdi)`) and **Intel Syntax** (`[rdi], rax`).
- Full directive parser:
  - Data definitions: `.byte`, `.short`, `.long`, `.quad`, `.ascii`, `.asciz`, `.space`, `.fill`.
  - Symbol linkage: `.globl`, `.local`, `.weak`, `.hidden`, `.type`, `.size`.
  - Alignment: `.align`, `.p2align`.
  - Sections: `.section .text`, `.section .rodata`, `.bss`.
  - Dwarf unwinding: `.cfi_startproc`, `.cfi_endproc`, `.cfi_def_cfa_offset`, `.cfi_offset`.
  - Numeric local labels (`1:`, `1b` [backwards], `1f` [forwards]).

### 2. Instruction Encoding Engine
- REX prefixes (`0x40 - 0x4F`) for 64-bit operand sizes and extended registers (`R8-R15`).
- VEX/EVEX prefix generation for AVX and AVX-512 SIMD vector instructions.
- ModR/M and SIB byte calculation with automatic displacement sizing (0, 8-bit, or 32-bit).
- Two-Pass Branch Relaxation:
  - First pass emits 8-bit short branch instructions (`JMP`, `Jcc`).
  - If target displacement exceeds $[-128, 127]$, automatically relaxes to 32-bit near branches in a single linear pass.

---

## 4. Base Target: ARM64 (AArch64)

### 1. Grammar & Syntax Support
- Standard ARM Unified Assembler Language (UAL).
- Register names:
  - 64-bit scalar: `x0`–`x30`, `sp`, `xzr` (zero register).
  - 32-bit scalar: `w0`–`w30`, `wzr`.
  - SIMD/Vector: `v0`–`v31`, `q0`–`q31`, `d0`–`d31`, `s0`–`s31`, `b0`–`b31`.
  - System registers: `TPIDR_EL0`, `DAIF`, `NZCV`, `VBAR_EL1`.

### 2. Instruction Encoding Engine
- Strict fixed 32-bit instruction word generation:
  - Branch instructions: `B`, `BL`, `CBZ`, `CBNZ`, `TBZ`, `TBNZ`, `B.cond`.
  - Load/Store pairs: `LDP`, `STP` with pre-index `[sp, #-16]!` and post-index `[sp], #16` addressing.
  - PC-relative addressing: Generates `ADRP` and `ADD` instruction pairs with associated relocations (`R_AARCH64_ADR_PREL_PG_HI21` and `R_AARCH64_ADD_ABS_LO12_NC`).
  - Bitfield instructions: `UBFM`, `SBFM`, `EXTR`, `BFM`.

---

## 5. Base Target: RV64 (RISC-V 64GC)

### 1. Grammar & Syntax Support
- Standard RISC-V assembly grammar and ABI register aliases:
  - Integer: `zero`, `ra`, `sp`, `gp`, `tp`, `t0`–`t6`, `s0`–`s11`, `a0`–`a7`.
  - Floating Point: `ft0`–`ft11`, `fs0`–`fs11`, `fa0`–`fa7`.
  - Control & Status Registers (CSRs): `mstatus`, `sstatus`, `satp`, `sie`, `sip`, `stvec`, `sepc`, `scause`.

### 2. Pseudoinstruction Expansion
In RISC-V, assembly code heavily relies on pseudoinstructions that expand into sequences of hardware instructions. The RV64 assembler natively synthesizes:
- `li rd, imm` (Load Immediate): Automatically selects the shortest instruction sequence (1 to 6 instructions using `addi`, `lui`, `slli`, `add`) to materialize any 64-bit constant.
- `la rd, symbol` (Load Address): Expands to `auipc rd, %pcrel_hi(symbol)` and `addi rd, rd, %pcrel_lo(symbol)`.
- `call symbol` / `tail symbol`: Expands to `auipc` + `jalr`.
- `ret`: Expands to `jalr zero, 0(ra)`.
- `nop`: Expands to `addi zero, zero, 0` (or `c.nop`).
- `mv rd, rs`: Expands to `addi rd, rs, 0`.

### 3. Compressed Instructions (C Extension)
- Emits 16-bit compressed instructions (`c.li`, `c.mv`, `c.add`, `c.ld`, `c.sd`, `c.addi4spn`, `c.addi16sp`) whenever operands and registers conform to the compressed instruction subset, cutting binary footprint by 25–35%.

---

## 6. Zero-Disk In-Memory Integration

Traditional tools invoke an external assembler via `execvp("as", ...)` writing to a temporary file on disk.

Swift-Stack's assemblers:
1. Parse the assembly file in memory using the fast SWAR lexer.
2. Emit machine code bytes directly into memory-backed `RelocatableSection` buffers.
3. Hand the resulting section buffers directly to the internal Linker (`swift-ld`).
4. Total execution time for typical OS kernel assembly files (e.g. `start.S` or `context_switch.S`): **under 1 millisecond**.
