# 05. Native Assemblers: x86-64, AArch64, RV64

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [01](01-frontend.md), [04](04-backend.md), [06](06-linker.md), [07](07-debugging-and-sdi.md), [14](14-measurement-methodology.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

Systems code needs hand-written assembly: process entry stubs (`system/sys/floor/start.S`), trap and interrupt entry, context switching, control-register setup, and hand-tuned memory and crypto kernels. Swift-Stack includes built-in assemblers for x86-64, AArch64 and RV64, so building Todhchai needs no external `as`.

The assembler:

- runs `.S` files through the C23 preprocessor ([01](01-frontend.md)) in assembler mode;
- parses a GNU-`as`-compatible directive and macro language;
- encodes instructions with the **same `Encode` tables the compiler backend uses** ([04](04-backend.md));
- relaxes branches to a fixpoint; and
- produces an `Object.RelocatableObject` ([06](06-linker.md)), handed to the linker in memory or written to disk with `-c`.

## 2. Goals

- Assemble Todhchai's existing assembly sources without modifying them. This needs GNU `as` dialect compatibility for the directives and syntax those files actually use.
- Have exactly one encoding source of truth (`Encode`), shared with codegen and the disassembler.
- Produce deterministic output (D6): the same input and flags give identical bytes.
- Produce `.eh_frame` from CFI directives, and produce or verify CUD records ([07](07-debugging-and-sdi.md)) from the same information.
- Report errors with precise source locations, including locations inside macro expansions.

## 3. Non-goals

- Intel syntax for x86 (planned after AT&T; see §4.6).
- EVEX encodings (AVX-512) and SVE, until there is a concrete user. VEX (AVX, in the x86-64 baseline; AVX2, opt-in) and all RVA23 extensions (including RVV 1.0, Zba/Zbb/Zbs, Zicond, Zfa, Zcb) are supported, because the backend uses them and they come from the shared `Encode` tables ([04](04-backend.md) §4.9, [17](17-simd-and-vectorization.md)). That keeps hand-written kernels possible on every architecture.
- MASM, NASM, or armasm dialects.
- RISC-V linker relaxation (`R_RISCV_RELAX`/`R_RISCV_ALIGN` emission). The v1 policy is in [04 §4.12](04-backend.md).
- Target-specific features of GNU `as` that Todhchai sources do not use. Each directive is added when a corpus file needs it.

## 4. Design

### 4.1 Pipeline

```
*.S                          *.s
 │                            │
 ▼ C23 preprocessor ("assembler-with-cpp" mode, 01)
 │                            │
 └────────────┬───────────────┘
              ▼  Assembly lexer (shared Lex primitives; per-arch comment and separator rules)
         Statement stream: label | directive | instruction
              ▼  Macro and conditional expansion (.macro/.rept/.irp/.if...)
              ▼  Per-architecture instruction parsing (AssemblerArch switch) → Encode
         Fragments per section: fixed bytes | relaxable branch | alignment | fill | data expression
              ▼  Layout + branch relaxation to a fixpoint (§4.5)
              ▼  Fixup resolution: local → patched bytes; external or section-relative → relocations
              ▼  CFI → .eh_frame FDEs; CUD synthesis or verification (§4.9)
Object.RelocatableObject ──► Linker (06) in memory, or ELF/Mach-O .o via -c
```

### 4.2 Component structure

All of these are folders in the single `SwiftStack` module (D10), not separate Swift modules:

| Component | Role |
|---|---|
| `Asm/` | Statement parser, directives, macro engine, expression evaluator, layout and relaxation, CFI processing, per-architecture instruction parsers |
| `Encode/` | Instruction tables, encoders, disassemblers (shared with `Codegen/`; [04 §4.9](04-backend.md)) |
| `Object/` | `RelocatableObject` model and ELF/Mach-O writers (canonical in [06](06-linker.md)) |
| `Lex/` | SWAR scanning primitives and the C23 preprocessor |

**Layering rule:** code in `Asm/` uses `Source/`, `Lex/`, `Encode/` and `Object/`, and MUST NOT reference `Codegen/`. With one module, the compiler can't enforce this, so a CI check on cross-folder symbol references does ([09](09-roadmap.md)).

### 4.3 Architecture dispatch: a closed enum

The generic layer owns everything shared across targets: lexing, directives, macros, expressions, sections, symbols, layout, relaxation and CFI. An architecture supplies only three things: instruction parsing, relaxation rules and relocation mapping. They are selected by an exhaustive `switch` over a closed enum, not by a protocol:

```swift
public enum AssemblerArch: UInt8, BitwiseCopyable {
    case x86_64, aarch64, riscv64
}

extension AssemblerArch {
    /// Parses one instruction statement and appends one fragment: fixed bytes,
    /// or a relaxable fragment with its short-form encoding.
    @inline(__always)
    func parseInstruction(_ s: AsmStatement, _ tokens: borrowing TokenBuffer,
                          into section: inout FragmentBuilder,
                          diagnostics: inout DiagnosticBag) {
        switch self {
        case .x86_64:  X86Asm.parseInstruction(s, tokens, into: &section, diagnostics: &diagnostics)
        case .aarch64: A64Asm.parseInstruction(s, tokens, into: &section, diagnostics: &diagnostics)
        case .riscv64: RVAsm.parseInstruction(s, tokens, into: &section, diagnostics: &diagnostics)
        }
    }

    /// Encoding size of a relaxable fragment at a given displacement.
    /// Monotonic: a fragment never shrinks.
    func relaxedSize(of f: RelaxableFragment, displacement: Int64) -> UInt8 {
        switch self {
        case .x86_64:  X86Asm.relaxedSize(of: f, displacement: displacement)
        case .aarch64: A64Asm.relaxedSize(of: f, displacement: displacement)
        case .riscv64: RVAsm.relaxedSize(of: f, displacement: displacement)
        }
    }

    // relocationKind(for:format:) and lexicalRules follow the same pattern.
}
```

`X86Asm`, `A64Asm` and `RVAsm` are caseless enums holding static functions. Why a closed enum instead of a protocol:

- **No dynamic dispatch.** The architecture is fixed for a whole assembly, so the `switch` is perfectly predicted. Each per-architecture function is a direct call that can be inlined. A protocol would invite existential or generic dispatch on every statement, and an unspecialized generic would be one optimization flag away ([00](00-overview-and-principles.md) Principle 8).
- **Exhaustiveness.** Adding an architecture means adding an enum case and `Encode` tables. The compiler then reports every `switch` that must handle it, so a missing piece can't slip through.
- **The extension point is stated honestly.** The supported set is closed and changes only by editing these files. The directive, macro, layout and object layers don't change when an architecture is added.

### 4.4 Common language (all targets)

The assembler implements the subset of the GNU assembler language used by the Todhchai corpus, with LLVM MC's semantics wherever LLVM MC and GNU `as` differ (§4.11). The list grows only when a corpus file needs a new directive.

| Category | Directives / features |
|---|---|
| Sections | `.text`, `.data`, `.bss`, `.section name, "flags", @type`, `.pushsection`/`.popsection`, `.previous` |
| Data | `.byte`, `.short`/`.2byte`, `.long`/`.4byte`, `.quad`/`.8byte`, `.ascii`, `.asciz`/`.string`, `.zero`, `.space`, `.fill` |
| Symbols | `.globl`/`.global`, `.local`, `.weak`, `.hidden`, `.type sym, @function/@object`, `.size`, `.set`/`.equ`, `=` |
| Alignment | `.align` (target-specific meaning: bytes on x86, power of two on ARM and RISC-V, as in LLVM MC and GNU `as`), `.balign`, `.p2align` |
| Macros | `.macro name args` / `.endm`, default, `:req` and `:vararg` parameters, positional and `name=value` arguments, `\arg` substitution, `\()` separator, `\@` counter, `.exitm`, `.purgem` |
| Repetition | `.rept n` / `.endr`, `.irp sym, values` / `.endr`, `.irpc` |
| Conditionals | `.if expr`, `.ifeq`/`.ifne`/`.ifge`/`.ifgt`/`.ifle`/`.iflt`, `.ifdef`/`.ifndef`, `.ifc`/`.ifnc`, `.ifeqs`/`.ifnes`, `.ifb`/`.ifnb`, `.else`, `.elseif`, `.endif` |
| Inclusion | `.include "file"`, `.incbin "file"[, skip[, count]]` (shares the `BinaryAssetPool` with `#embed`) |
| Labels | Named labels; numeric local labels `1:` with `1b` (nearest backward) and `1f` (nearest forward) |
| CFI | `.cfi_startproc`/`.cfi_endproc`, `.cfi_def_cfa`, `.cfi_def_cfa_offset`, `.cfi_def_cfa_register`, `.cfi_offset`, `.cfi_rel_offset`, `.cfi_restore`, `.cfi_undefined`, `.cfi_remember_state`/`.cfi_restore_state`, `.cfi_adjust_cfa_offset`, `.cfi_signal_frame`, `.cfi_val_offset`, `.cfi_same_value`, `.cfi_register`, `.cfi_return_column`, `.cfi_escape`, `.cfi_window_save`/`.cfi_negate_ra_state`, `.cfi_sections`; `.cfi_personality`/`.cfi_lsda` only with encoding `0xff` (omit) |
| Misc | `.file`, `.loc` (line info), `.ident` (ignored), `.option` (RISC-V; §4.8) |

**`.S` preprocessing.** `.S` files go through the C23 preprocessor ([01](01-frontend.md)) in *assembler-with-cpp* mode:

- Lines starting with `#` that are not preprocessing directives pass through unchanged, because they are assembler comments on x86 and RISC-V.
- Unbalanced `'` and `"` characters do not cause errors.
- Token pasting and stringizing behave as in C.

The preprocessor output carries GNU line markers (`# <line> "<file>"`) and keeps each line's original column, and the assembler honours them (and `#line`). Every statement therefore keeps a `file:line:col` location, through `#include`d headers, `.include`, `.rept`/`.irp` and macro expansion; an error inside a macro body also gets a note at each enclosing macro use. Macro, `.rept` and `.irp` expansion is bounded at 20 nested levels, as in LLVM MC (`macros cannot be nested more than 20 levels deep`).

**Macros** follow LLVM MC's `AsmParser`:

- **Argument splitting.** A comma ends an argument, and so does a blank, unless the token after the blank is an operator (`+ - ~ ! * / | ^ & == != < <= << <> > >= >> && || = .`; not `%`). An operator joins the tokens on both sides, and blanks after it are ignored. So `m 4 5` passes `4` and `5`, but `m 4 -5` and `m 1 + 2` each pass one argument. Only parentheses group: `m (1 2)` is one argument, `m [x0, #8]` is two.
- **Substitution.** The substituted text is the argument's tokens without the blanks that separated them (`4-5`, `1+2`); blanks inside parentheses are kept. A string argument is substituted without its quotes and without escape processing. A `:vararg` parameter receives the rest of the line verbatim, quotes included. `\@` counts macro instantiations from 0.
- **Binding.** An empty argument takes the parameter's default. Keyword arguments (`name=value`) may follow positional ones, but a positional argument may not follow a keyword one.
- **`.irp` and `.irpc`.** `.irp` values are split like macro arguments (`.irp r, 1 2` iterates twice; `.irp r,` iterates zero times). `.irpc` takes exactly one token and iterates over its characters. Both require a comma after the parameter name.
- **Errors.** Malformed headers and calls get LLVM MC's diagnostics: an unknown qualifier, a duplicate parameter, `:vararg` not last, a macro defined twice, `.purgem` of an undefined macro, too many arguments (`Wrong number of arguments` for a macro without parameters), a positional argument after a keyword one, an unknown keyword, unbalanced parentheses, and `=` right after an argument token (`m 1=2`). A default for a `:req` parameter is a warning. A call with an argument error is not expanded.

**Expressions.** Integer expressions use the GNU-style operator precedence that LLVM MC uses for ELF targets (`getGNUBinOpPrecedence`; GNU `as` agrees), which is not C's. From tightest to loosest: unary `- ~ ! +`; `* / % << >>`; `| & ^ !` (binary `!` is or-not); `+ -`; comparisons `== != <> < > <= >=` (true is -1); `&&`; `||`. Operators of one level associate left to right, `>>` is a logical shift, and arithmetic wraps at 64 bits. Expressions also support symbol arithmetic and `.` (current location). `.equ`/`.set`/`=` may name a label difference, including forward references; it resolves to an absolute constant after layout, usable in immediates, data, `.size` and other `.equ`s. A difference of labels in one run of fixed-size fragments is folded at once, in any section, so a later reassignment does not change earlier uses. Each value is one of: an absolute constant; a section-relative value (`sym + c`); a difference of symbols in the same section, resolved after layout; or an external symbol plus addend, which becomes a relocation.

### 4.5 Layout and relaxation

Each section is a sequence of fragments:

| Fragment | Size |
|---|---|
| Fixed bytes | Known at parse time |
| Relaxable instruction | Short or long form, decided by layout |
| Alignment | Depends on the fragment's address |
| Fill / space | Known, or determined by an absolute expression |
| Data expression | Fixed width; value resolved after layout or turned into a relocation |

**Relaxation algorithm:**

1. Start every relaxable fragment in its short form.
2. Assign addresses in one forward pass, computing alignment padding from current addresses.
3. For every relaxable fragment whose target is in the same section, compute the displacement. If it is out of range for the current form, grow the fragment to the next form.
4. If any fragment grew, go back to step 2.

Fragments **never shrink**, even if another fragment's growth reduces some padding. Each fragment has finitely many forms, so the loop terminates after at most (fragments × forms) iterations; in practice it takes two or three. A single linear pass is not enough, because growing one branch can push others out of range.

Branches to symbols that are undefined, external, or in another section are encoded in their long form immediately and get a relocation. They never take part in relaxation.

### 4.6 x86-64

- **Syntax:** AT&T syntax (`movq %rax, (%rdi)`) is implemented first. *Assumption to verify before M1:* Todhchai's existing x86-64 `.S` files use GNU AT&T syntax. Intel syntax (`.intel_syntax noprefix`) is a later item, added when a corpus file needs it.
- **Operands:** registers (`%rax`… `%r15`, sub-registers, `%xmm0`–`%xmm15`, `%ymm0`–`%ymm15`, segment and control registers), immediates (`$expr`), memory operands `disp(base, index, scale)` including RIP-relative `sym(%rip)`, and operand-size suffixes (`b/w/l/q`), inferred from registers when omitted.
- **Encoding:** through `Encode` tables (legacy prefixes, REX, two- and three-byte VEX, ModR/M, SIB, maps `0F`/`0F38`/`0F3A`). Both legacy SSE and VEX (`v`-prefixed) mnemonics are accepted; AVX is in the baseline and AVX2 is accepted when enabled ([17](17-simd-and-vectorization.md) §5.4). The displacement size (none, 8-bit, or 32-bit) is chosen at encode time when the value is known; symbolic displacements are always 32-bit with a relocation.
- **Relaxable:** `JMP` and `Jcc` (rel8 → rel32).
- **Relocations:**
  - ELF: `R_X86_64_PC32`, `R_X86_64_PLT32`, `R_X86_64_GOTPCREL(X)`, `R_X86_64_64`, `R_X86_64_32S`, TLS (`R_X86_64_TPOFF32`, `R_X86_64_GOTTPOFF`).
  - Mach-O: `X86_64_RELOC_*` equivalents.
- **Privileged instructions** needed by kernel and stub code: `syscall`/`sysret`, `iretq`, `swapgs`, `lgdt`/`lidt`, `mov %crN`, `rdmsr`/`wrmsr`, `xsave`/`xrstor`, `cpuid`, `rdtsc`, `pause`, `hlt`, `invlpg`.

### 4.7 AArch64

- **Syntax:** GNU AArch64 syntax (the A64 forms of Arm's unified assembler language).
- **Registers:**
  - general: `x0`–`x30`, `w0`–`w30`, `sp`, `wsp`, `xzr`, `wzr`;
  - SIMD and FP: `v0`–`v31` with arrangement specifiers (`v0.4s`), `q`/`d`/`s`/`h`/`b` views;
  - system registers by name or by `S<op0>_<op1>_<Cn>_<Cm>_<op2>`: `TPIDR_EL0`, `DAIF`, `NZCV`, `VBAR_EL1`, `TTBR0_EL1`, `SCTLR_EL1`, `ESR_EL1`, `ELR_EL1`, `SPSR_EL1`.
- **Encoding (fixed 32-bit words):**
  - branches: `B`, `BL`, `B.cond`, `CBZ`/`CBNZ`, `TBZ`/`TBNZ`, `BR`, `BLR`, `RET`;
  - loads and stores, including `LDP`/`STP` with pre-index (`[sp, #-16]!`) and post-index (`[sp], #16`) addressing;
  - bitfield instructions (`UBFM`, `SBFM`, `BFM`, `EXTR` and their aliases);
  - logical immediates (bitmask encoding);
  - `MOVZ`/`MOVK`/`MOVN`, the `mov` alias, and `MSR`/`MRS`;
  - barriers (`DMB`, `DSB`, `ISB`), `ERET`, `SVC`/`HVC`/`SMC`;
  - Advanced SIMD (NEON) instructions with arrangement specifiers.
- **Relaxable:**
  - `B.cond`/`CBZ`/`CBNZ` (±1 MiB) and `TBZ`/`TBNZ` (±32 KiB) relax to an inverted branch over `B`;
  - `ldr xN, =imm` literal loads use a literal pool flushed at `.ltorg` or at the end of the section.
- **Symbol modifiers:**
  - ELF: `:lo12:`, `:got:`, `:got_lo12:`, `:tprel_hi12:`, `:tprel_lo12_nc:`;
  - Mach-O: `sym@PAGE`, `sym@PAGEOFF`, `sym@GOTPAGE`, `sym@GOTPAGEOFF`.
- **Relocations:**
  - ELF: `R_AARCH64_ADR_PREL_PG_HI21`, `R_AARCH64_ADD_ABS_LO12_NC`, `R_AARCH64_LDST{8,16,32,64,128}_ABS_LO12_NC`, `R_AARCH64_CALL26`, `R_AARCH64_JUMP26`, `R_AARCH64_CONDBR19`, `R_AARCH64_TSTBR14`, `R_AARCH64_ADR_GOT_PAGE`, `R_AARCH64_LD64_GOT_LO12_NC`, `R_AARCH64_ABS64`, `R_AARCH64_PREL32`, and the TLS LE relocations.
  - Mach-O: the `ARM64_RELOC_*` equivalents.

### 4.8 RV64 (RVA23)

- **Registers:** ABI and numeric names: `zero`, `ra`, `sp`, `gp`, `tp`, `t0`–`t6`, `s0`/`fp`–`s11`, `a0`–`a7`, `x0`–`x31`; `ft0`–`ft11`, `fs0`–`fs11`, `fa0`–`fa7`, `f0`–`f31`; vector registers `v0`–`v31`. CSRs by name (`mstatus`, `sstatus`, `satp`, `sie`, `sip`, `stvec`, `sepc`, `scause`, `stval`, `sscratch`, `time`, `cycle`) or by number.
- **Pseudoinstructions:**
  - `li rd, imm`: materializes any 64-bit constant in **up to 8 instructions** (`lui`/`addi(w)` followed by `slli`/`addi` pairs). It searches for shorter forms using trailing-zero shifts and sign-extended 32-bit values, and uses compressed forms (`c.li`, `c.lui`, `c.slli`, `c.addi`) where possible.
  - `la rd, sym`: `auipc` + `addi` with `%pcrel_hi`/`%pcrel_lo` when the symbol is local. In PIC mode for preemptible symbols, it becomes `auipc` + `ld` through the GOT (`%got_pcrel_hi`).
  - `lla`; `call sym` / `tail sym` (`auipc` + `jalr`, `R_RISCV_CALL_PLT`); `ret`; `nop` (`c.nop` when C is enabled); `mv`, `not`, `neg`, `seqz`, `snez`, `beqz`, `bnez`, `bgt`, `ble`, `j`, `jr`, `csrr`, `csrw`, `csrs`, `csrc`, `fence`, `fmv`.
- **Extensions:** every RVA23 mandatory extension, including RVV 1.0 (`vsetvli`/`vsetivli`, vector loads, stores and arithmetic with `vtype` operands), Zba/Zbb/Zbs, Zicond, Zfa and Zcb ([17](17-simd-and-vectorization.md) §5.4).
- **Compressed instructions:** when `.option rvc` is in effect (the default; C and Zcb are part of RVA23), each instruction is emitted in its 16-bit C form if registers and immediates fit (`c.li`, `c.mv`, `c.add`, `c.addi`, `c.addi16sp`, `c.addi4spn`, `c.ld`, `c.sd`, `c.ldsp`, `c.sdsp`, `c.j`, `c.beqz`, `c.bnez`, `c.jr`, `c.jalr`). `.option norvc` disables this. `.option push`/`.option pop` are supported.
- **Relaxation (v1):** `.option relax` is accepted, but the assembler behaves as `norelax` per [04 §4.12](04-backend.md):
  - it never emits `R_RISCV_RELAX` or `R_RISCV_ALIGN`;
  - alignment padding is exact;
  - `%pcrel_lo` refers to the label of its paired `auipc`, as in GNU `as`.
- **Relaxable branches (assembler-local):** `c.beqz`/`c.bnez` → `beq`/`bne` → inverted branch over `jal`; `c.j` → `jal`.
- **Relocations (ELF only; there is no RISC-V Mach-O):** `R_RISCV_PCREL_HI20`, `R_RISCV_PCREL_LO12_I/S`, `R_RISCV_HI20`, `R_RISCV_LO12_I/S`, `R_RISCV_CALL_PLT`, `R_RISCV_JAL`, `R_RISCV_BRANCH`, `R_RISCV_RVC_JUMP`, `R_RISCV_RVC_BRANCH`, `R_RISCV_GOT_HI20`, `R_RISCV_64`, `R_RISCV_32`, and TLS LE (`R_RISCV_TPREL_HI20`/`LO12_I`/`LO12_S`/`ADD`).

### 4.9 CFI, `.eh_frame`, and CUD

CFI directives in hand-written assembly serve two purposes, reconciling the unwind policy in [04 §4.11](04-backend.md) and [07](07-debugging-and-sdi.md):

1. **`.eh_frame` generation.** Each `.cfi_startproc`…`.cfi_endproc` region produces one FDE. Each CFA instruction follows a `DW_CFA_advance_loc`, `advance_loc1`, `advance_loc2` or `advance_loc4` from the previous one's address, chosen after layout so relaxed branches are accounted for. The layout is LLVM MC's: FDEs are stable-sorted by CIE key (`.cfi_signal_frame`, then `.cfi_startproc simple`, then the return column, where an explicit `.cfi_return_column` sorts before the default and gets its own CIE even when it names the default register), and each CIE is emitted once, just before its group. Records are padded with `DW_CFA_nop` to 4 bytes, the last FDE to 8. The bytes and `pc_begin` relocations match LLVM MC on all three targets. A CFI directive outside a `.cfi_startproc`…`.cfi_endproc` region, or a `.cfi_startproc` inside one, is an error. This is the canonical unwind info on Linux and FreeBSD, and the fallback on Todhchai and macOS.
2. **CUD synthesis.** The assembler interprets each region's CFI program symbolically. If the final state at every instruction past the prologue matches a CUD-describable layout (frame pointer established, fixed frame size, callee-saved registers at fixed offsets), it emits a CUD record and, on Todhchai, drops the FDE. Otherwise the function is marked *CUD-inexpressible* and keeps its FDE. A note-level diagnostic lists such functions.

Functions with no CFI region (common in entry stubs and context switches) get no unwind info. Unwinders stop at them.

- `_start` and similar entry points SHOULD mark the end of the stack explicitly with `.cfi_undefined` on the return-address register, following existing practice in glibc and FreeBSD. CUD records this as a terminal frame.
- Context-switch routines that change stacks SHOULD carry `.cfi_signal_frame`, or no CFI at all, so unwinders do not walk across stacks.

### 4.10 Integration

- **In-process (default):** the assembler's `RelocatableObject` goes to the linker with the compiler's objects. No temporary files are written.
- **Through the main driver only.** Assembly sources are passed to `swift-stack` like any other input. A standalone, GNU-`as`-option-compatible `as` personality is **deferred** until a concrete external build needs it ([15](15-driver-and-diagnostics.md)).
- **`-c`:** `Object`'s ELF or Mach-O writer serializes a standard relocatable `.o` that GNU `ld`, `lld` and Apple `ld` can consume. This keeps Swift-Stack assembly usable in external builds and lets host linkers act as differential oracles.
- **Line info:** `.loc`/`.file` directives, or automatic line rows when `-g` is given without them, produce line-table rows for SDI ([07](07-debugging-and-sdi.md)) and DWARF `.debug_line` on hosts.
- **Throughput target:** typical stub and context-switch files (a few hundred lines) assemble in **under 1 ms**. This is a target, measured per [14](14-measurement-methodology.md).

### 4.11 Verification

- **Reference assembler: LLVM MC.** Swift-Stack replaces LLVM in the stack, so LLVM MC (`llvm-mc`, and the integrated assembler of `clang -c`) is the reference. Wherever GNU `as` and LLVM MC disagree, Swift-Stack matches LLVM MC exactly; the GNU `as` behavior is documented below, not matched.
- **Round trip:** every `Encode` table entry is assembled from text, disassembled, and compared with the original statement.
- **Differential:** each corpus file is assembled with Swift-Stack, with `clang -c` for all three architectures, and with host GNU `as` for x86-64. The `clang -c` comparison is exact. The GNU `as` comparison exempts only the documented differences below, each for the affected section or file only. The section bytes, symbol tables and relocations are compared (after normalizing for documented differences such as RISC-V relaxation).
  - Both objects are parsed by an independent test-only ELF reader. Relocations against local symbols are normalized to `section + offset`, since GNU `as` and LLVM MC choose differently between a section symbol and a local label; temporary `.L*` labels and `$x`/`$d` mapping symbols are excluded.
  - Every allocatable section is compared: bytes, size, flags, alignment. So are all relocations (type, offset, target, addend) and all non-temporary symbols (binding, type, visibility, section, value, size).
- **Documented differences from GNU `as` (x86-64 encoding).** Swift-Stack matches LLVM MC, and the `clang -c` comparison checks these sections exactly:
  1. `.text` alignment is 4 (GNU: 1).
  2. Multi-byte NOP padding uses a single 6-byte `nopw` where GNU emits `nop` + 5-byte `nopl`.
  3. A memory displacement given by a label difference that is unknown when the instruction is parsed (`lea T_OFF(sym)(%rsi)` with `T_OFF(x) = x - base`) is encoded as `disp32`. GNU `as` later relaxes it to `disp8`, which changes the containing section's size.
  4. Commutable VEX instructions (the map-0F binary operations LLVM MC marks commutable, such as `vaddps`, `vpcmpeqb` and `vcmpeqps`) swap their two sources when that moves an extended register out of ModRM.rm and so allows the 2-byte VEX prefix: `vaddps %xmm8, %xmm1, %xmm2` is `c5 b8 58 d1` (GNU: `c4 c1 70 58 d0`).
  5. Register-register `xchg` puts the first AT&T operand in ModRM.rm: `xchg %ecx, %ebx` is `87 d9` (GNU: `87 cb`).
  6. `mov` between a segment register and a 64-bit GPR (`movq %ds, %rax`, `movq %rax, %ds`) and `str %r64` keep REX.W (GNU drops it, since the operation is the same).
  7. An explicit segment override equal to the default segment (`%ds:(%rax)`) is emitted (`3e`); GNU `as` drops it.
- **Documented differences from GNU `as` (all targets).** Swift-Stack matches LLVM MC (§4.4, §4.9). The in-repo corpus covers 8 and 9 (`cfi_cie_order.s` and `macro_args.s` for each architecture), and the `clang -c` comparison checks them exactly. `M2AssemblerRegressionTests` pins the LLVM MC output and diagnostics for all four:
  8. `.eh_frame` FDEs are grouped by CIE key, so FDEs with different CIEs leave source order, and an explicit `.cfi_return_column` gets its own CIE. GNU `as` keeps FDEs in source order and shares CIEs by content. The GNU comparison skips `.eh_frame` for `cfi_cie_order.s` only.
  9. A blank before an operator does not end a macro argument: `m 4 -5` passes `4-5`. GNU `as` passes `4` and `-5` (also `m 7 +8` passes `7` and `+8`), and rejects `m 5 - 6` and `m 24 *2` for a two-parameter macro with "too many positional arguments". `macro_args.s` is therefore compared with clang only.
  10. `.irp r,` iterates zero times (GNU: once, with an empty value). `.irp` without a comma after the parameter and `.irpc` with more than one token (`.irpc c, ab cd`) are errors; GNU `as` accepts both.
  11. Macro, `.rept` and `.irp` nesting is limited to 20 levels (GNU `as`: 100 macro levels).
- **Exhaustive x86-64 sweep** (`M2X86ExhaustiveTests`): every descriptor in the x86 table is instantiated in every operand form its format allows. Each register slot is swept over its whole class, all low/extended combinations of the register slots are tried (REX.R/X/B, VEX.R/X/B/vvvv, 2- vs 3-byte VEX), memory operands cover every ModR/M and SIB special case (`%rsp`/`%rbp`/`%r12`/`%r13` bases, no base, RIP-relative, disp8/disp32 boundaries, every index and scale, segment overrides, 32-bit addressing), and immediates cover their boundary values. Every instance must round-trip encode → disassemble → re-encode to identical bytes. Its text and its disassembly must assemble to exactly those bytes with `llvm-mc` and with Swift-Stack's own assembler, and with GNU `as` too, apart from differences 4–7 above. A form the encoder rejects must be rejected by `llvm-mc` as well, and every descriptor must be selected at least once, so a new table entry cannot escape the sweep.
- **Exhaustive AArch64 sweep** (`M2AArch64ExhaustiveTests`): every descriptor in the A64 table is instantiated in every width and vector arrangement it accepts, with each register slot swept over all 32 encodings (so register 31 is tried as both SP and ZR where each is legal), every addressing mode, extend and shift, all conditions, and immediates covering their boundaries plus every bitmask immediate, every bitfield `immr:imms` pair and every FP8 value. Every instance must round-trip encode → disassemble → re-encode to the same descriptor and word. Its disassembly must assemble to exactly that word with `llvm-mc` and with Swift-Stack's own assembler, and `llvm-mc --disassemble` must print exactly the same text, preferred aliases included. Forms LLVM rejects as unpredictable are not generated. Every descriptor must round-trip at least once.
- **Encoder oracle:** every `Encode` table sample is also checked against `llvm-mc`. `llvm-mc` assembles the disassembler's text, and the bytes must match or decode to the same instruction. This catches encoder/disassembler pairs that agree on a wrong encoding, which a self round trip cannot.
- **Corpus:** Todhchai `system/sys/floor/start.S`, context-switch and trap sources for all three architectures, plus synthetic tests for every directive in §4.4. Regressions live in `Tests/Differential/asm/<arch>/`.

## 5. Alternatives considered

- **Separate encoders for the assembler and codegen:** this was the original design implied by doc 04, which described encoders twice. Rejected: two encoders drift apart, and every bug has to be fixed twice.
- **Driving the backend's LIR from the assembler (assembly → LIR → encoder):** LIR is SSA- and virtual-register-oriented and does not model directives or exact user-chosen encodings. The assembler instead talks to `Encode` directly.
- **Single-pass "optimistic" relaxation:** incorrect, as shown in §4.5. Rejected in favor of the fixpoint.
- **Requiring Intel syntax or a new assembly dialect:** would force rewriting existing Todhchai sources and break compatibility with GNU-syntax references.

## 6. Open questions

1. **Corpus syntax audit:** confirm that all Todhchai x86-64 `.S` files use AT&T syntax, and list exactly which directives the corpus uses, to fix the v1 directive set.
2. **Custom unwind directive:** should Swift-Stack add one (e.g. `.ss_unwind none|terminal`) for cases CFI expresses badly, or rely only on standard CFI?
3. ~~Foreign RISC-V objects with `R_RISCV_ALIGN`?~~ Resolved in [06](06-linker.md) §5.5: the linker deletes excess padding NOPs only, and rejects the object with a diagnostic if that is not possible.
4. **Mach-O assembler dialect differences** (Apple `as` uses `sym@PAGE`, different section directives such as `.section __TEXT,__text`, and `.subsections_via_symbols`): how much is needed for macOS host builds?
5. **Inline assembly (D7):** the C frontend's basic `asm("...")` statements should be parsed and encoded by this assembler. Extended asm with operand constraints needs an interface with register allocation ([04](04-backend.md)), and its v1 scope is not yet decided.
