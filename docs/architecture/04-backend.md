# 04. Backend: Machine IR, Instruction Selection, Register Allocation, and Encoding

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [03](03-intermediate-representation.md), [06](06-linker.md), [07](07-debugging-and-sdi.md), [05](05-assembler.md), [11](11-generics-and-runtime-metadata.md), [14](14-measurement-methodology.md), [17](17-simd-and-vectorization.md) |

## 1. Summary

The backend lowers optimized AIR ([03](03-intermediate-representation.md)) to machine code for x86-64 (2013 Mac Pro-class floor: `x86-64-v2` + AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, FSGSBASE), AArch64 (`armv8-a`), and RV64 (the RVA23 profile) ([17](17-simd-and-vectorization.md) §5.4), and produces an in-memory `Object.RelocatableObject` that the linker ([06](06-linker.md)) consumes directly. It consists of:

1. **LIR** — a target-specific, flat, column-oriented machine IR over 32-bit virtual registers.
2. **Instruction selection** — linear-time greedy tiling of each basic block's SSA DAG.
3. **Register allocation** — linear scan on SSA form with lifetime holes and interval splitting (Wimmer & Franz, 2010).
4. **Frame lowering, calling conventions, branch relaxation and switch lowering.**
5. **Encoding** — via the shared `Encode` module, which the assembler ([05](05-assembler.md)) also uses.

## 2. Goals

- Produce correct code that conforms to each target's C ABI (D1): System V x86-64, AAPCS64 (including the Apple arm64 variant), and RISC-V LP64D.
- Compile in time linear (or near-linear) in function size, with no quadratic interference-graph construction.
- Emit object code deterministically (D6): output bytes MUST NOT depend on thread count or scheduling order.
- Keep frame pointers by default so that Compact Unwind Descriptors ([07](07-debugging-and-sdi.md)) describe nearly all functions.
- Share one instruction-description source of truth between the compiler, assembler, and disassembler.

## 3. Non-goals

- Auto-vectorization as a requirement. It is an optional AIR-level track (D9, [17](17-simd-and-vectorization.md) §5.6); the backend needs nothing extra for it beyond vector support (§4.4.1).
- Global instruction scheduling, software pipelining, PGO-driven layout.
- AVX-512 and SVE code generation. AVX (VEX) is in the x86-64 baseline; AVX2, FMA and BMI1/BMI2 are opt-in ([17](17-simd-and-vectorization.md) §5.4).
- 32-bit targets, Windows x64 ABI, PE/COFF.
- Binary compatibility with `swiftc`-compiled Swift code (D1). Only the C ABI is a compatibility boundary.

## 4. Design

### 4.1 Pipeline

```
AIR function (optimized SSA, per function)
        │
        ▼  Instruction selection: greedy tiling per block, single-use folding only
LIR (target opcodes, 32-bit virtual registers, SSA)
        │
        ▼  Block linearization (RPO, loop blocks contiguous) + instruction numbering
        ▼  Liveness (backward dataflow, live-in bitsets) → intervals with lifetime holes
        ▼  Linear scan on SSA: fixed intervals, hints, splitting, spilling
        ▼  Resolution: phi elimination + split-edge moves (parallel-move sequentialization)
LIR (physical registers, spill slots)
        │
        ▼  Frame layout, prologue/epilogue, peephole cleanup
        ▼  Encoding via `Encode` + branch relaxation to a fixpoint
Function fragment: bytes, relocations, CUD record, CFI, line rows, variable locations
        │
        ▼  Deterministic module assembly (function order = FunctionId order)
Object.RelocatableObject (ELF64 or Mach-O section model) ──► Linker (06) or object file (-c)
```

### 4.2 Module layout

| Module | Contents | Depends on |
|---|---|---|
| `LIR` | LIR data structures, liveness, interval construction | `AIR` |
| `Encode` | Per-architecture instruction tables, encoders, disassemblers | — |
| `Object` | `RelocatableObject`: sections, symbols, relocations (canonical in [06](06-linker.md)) | — |
| `Codegen` | Instruction selection, register allocation, frame lowering, ABI lowering, emission | `AIR`, `LIR`, `Encode`, `Object` |

`Asm` depends on `Encode` and `Object`, not on `Codegen`. `Linker` depends on `Object`, not on `Codegen`.

### 4.3 LIR representation

LIR is stored as columns (D8), not as an array of structs. A Swift struct of `{UInt16, UInt16, UInt16, UInt16, Int64, UInt16}` has a size of 18 but a **stride of 24** because of `Int64` alignment. Columns avoid that padding. Passes also touch different subsets of fields: liveness and register allocation read only opcodes and operands, while the encoder reads everything. Columns keep each pass's working set small.

```swift
public struct LIRFunction: ~Copyable {
    // Per instruction (indexed by LIRInstId):
    public var opcodes:   Column<UInt16>   // 2 B  target opcode (X86_ADD_RR, A64_ADD_IMM, RV_ADDI, ...)
    public var dst:       Column<Operand>  // 4 B  register operand or .none
    public var src1:      Column<Operand>  // 4 B
    public var src2:      Column<Operand>  // 4 B
    public var imm:       Column<Int64>    // 8 B  immediate / displacement / SymbolId (per flags)
    public var flags:     Column<UInt16>   // 2 B  width, condition code, addressing mode, scale
    public var extra:     Column<UInt32>   // 4 B  offset into `extraOperands` (calls, parallel moves), or 0
    public var extraOperands: Column<Operand>

    // Per block (indexed by LIRBlockId), CSR-encoded edges:
    public var blockFirstInst: Column<UInt32>
    public var blockInstCount: Column<UInt32>
    public var succOffsets:    Column<UInt32>
    public var succs:          Column<UInt32>
    public var predOffsets:    Column<UInt32>
    public var preds:          Column<UInt32>

    public var stackFrameSize: UInt32
    public var calleeSavedMask: UInt64
}

/// A register operand. Bit 31 set = physical register (low 8 bits index the
/// target register file); clear = virtual register number (up to 2^31 - 1).
public struct Operand: BitwiseCopyable, Hashable {
    public var raw: UInt32
}
```

- **Footprint:** 28 bytes of column data per instruction, with no padding, plus overflow operands for calls and parallel moves. This is honest accounting, not a minimum. Moving `imm` to a side table indexed only by instructions that need it is an open question (§6).
- **Virtual registers are 32-bit.** A 16-bit register field would cap a function at 65,536 values. Large generated C functions and fully inlined Swift code can exceed that.
- **Memory operands** use `src1` as base, `src2` as index, scale and mode in `flags`, and displacement or symbol in `imm`. Symbol references set a flag so that `imm` is read as a `SymbolId` and the emitter records a relocation.

### 4.4 Instruction selection

Selection tiles each basic block's SSA expression DAG greedily (maximal munch), largest pattern first. Tables of patterns per target are data, defined alongside `Encode`.

**Single-use folding rule.** An AIR value MAY be absorbed into a larger tile (address arithmetic into an x86 SIB operand, a load into an ALU memory operand, a compare into a branch) only if:

1. it has exactly one use (a use-count column is computed before selection);
2. it is defined in the same basic block as its user; and
3. for loads, no instruction with memory side effects lies between the load and its user.

A value with several uses is materialized once into a virtual register and every user reads that register. Without this rule, greedy tiling over a DAG duplicates computation, and duplicating a load changes semantics if memory changes in between.

```
[AIR]                               [LIR, x86-64]
%p = air.add %base, %off            ; %p single-use → folded
%v = air.load %p                    MOV  v1, [vBase + vOff*1]
%w = air.add %v, 1                  ; %v used twice → materialized
%x = air.mul %v, %w                 LEA  v2, [v1 + 1]
                                    IMUL v3, v1, v2   ; two-address form, see §4.5.4
```

**Immediate folding:** a constant becomes an immediate operand only when it fits the encoding: x86-64 sign-extended imm8/imm32; AArch64 12-bit unsigned (optionally shifted by 12) for arithmetic, and the bitmask-immediate encoding for logical ops; RV64 12-bit signed. Otherwise it is materialized (x86 `MOV r64, imm64`; AArch64 `MOVZ`/`MOVK`; RV64 the `li` expansion from [05](05-assembler.md)).

### 4.4.1 Vector operations

AIR vector types and operations ([17](17-simd-and-vectorization.md) §5.1) are first-class in the backend, because Swift `SIMDn<T>` code and C vector-extension code depend on them (D9).

- **Legalization** runs before tiling. A per-target, data-driven table maps each (operation, vector type) pair to `legal`, `split`, `widen`, `expand` or `scalarize` ([17](17-simd-and-vectorization.md) §5.2). Tiling only ever sees legal vector operations.
- **Vector tiles** fold loads into memory operands where the encoding allows it. All x86-64 vector code is VEX-encoded (AVX baseline), and VEX memory operands do not require alignment, so unaligned single-use loads fold too. Splats of constants fold into constant-pool loads.
- **Register class.** LIR has a vector register class per target: `XMM0–15`/`YMM0–15` (AVX baseline: 256-bit FP vectors; 256-bit integer vectors only with AVX2), AArch64 `V0–V31`, RVV `v0–v31`. On x86-64 and AArch64 it shares physical registers with the scalar FP class, so aliasing is modeled; RVV registers are separate.
  - Callee-saved sets follow the C ABI: none on SysV x86-64 or RISC-V; the low 64 bits of `V8–V15` on AAPCS64.
- **RVV state.** A forward pass tracks `vtype`/`vl` per block and removes redundant `vsetvli`/`vsetivli` instructions.
- **Below baseline.** On a sub-baseline target (`-march=rv64gc`, not a release target), every vector operation is scalarized during legalization. The code is correct, though slower.
- **`vzeroupper`** is inserted before calls and returns when upper YMM state may be dirty, to avoid AVX/SSE transition penalties with foreign SSE-encoded code.

### 4.5 Register allocation: linear scan on SSA

The allocator follows Wimmer & Franz, *Linear Scan Register Allocation on SSA Form* (CGO 2010), which in turn builds on Wimmer & Mössenböck (2005). The broader claim, that linear scan gets close to graph-coloring code quality at a fraction of the cost, is a **hypothesis** to measure against LLVM's greedy allocator ([14](14-measurement-methodology.md)). It is not a stated fact.

#### 4.5.1 Linearization and numbering

- Blocks are ordered in reverse postorder, with each loop's blocks kept contiguous so that intervals inside a loop do not cover unrelated code.
- Instructions are numbered with even positions. Odd positions are left free for moves the allocator inserts later.

#### 4.5.2 Liveness and intervals

- Liveness is a backward dataflow over blocks using per-block `liveIn` bitsets (columns of 64-bit words). Loop headers extend live ranges of values live at the header across the whole loop, so a single pass over the linear order suffices. Cost is O(instructions × vregs / 64) in the worst case.
- Each virtual register gets an **interval**: a sorted list of ranges `[from, to)` with **lifetime holes** between them, plus a sorted list of **use positions**, each marked register-required or register-optional (an x86 memory operand can take a spilled value).
- Interval storage is column-based: ranges and use positions live in flat columns, and each interval holds offsets into them.

#### 4.5.3 The scan

The allocator keeps four sets:

| Set | Contents | Ordering |
|---|---|---|
| `unhandled` | Intervals not yet reached | Sorted by start position, computed once with a sort; no priority queue is needed |
| `active` | Intervals that cover the current position and hold a register | Checked by end position |
| `inactive` | Intervals started earlier that are currently in a lifetime hole | Checked by next range start |
| `handled` | Finished intervals | — |

For each interval taken from `unhandled` in start order:

1. Move intervals between `active`, `inactive` and `handled` according to the current position.
2. **`tryAllocateFreeRegister`:** compute `freeUntilPos` for each allowed physical register from `active`, `inactive` and fixed intervals. Pick the register free the longest, preferring a **hint** register (a phi operand, a move source, or an ABI register). If that register is free only for part of the interval, split the interval at the best position before that point.
3. **`allocateBlockedRegister`:** otherwise compute `nextUsePos` for each register. If the current interval's first use is later than every other interval's next use, spill the current interval up to its first register-required use. Otherwise evict the register whose next use is furthest away: split and spill the intervals that hold it.
4. **Split position choice:** prefer block boundaries, and among those, loop boundaries. A split moves to the start of the outermost loop the interval does not need to be in a register for, so spill and reload code lands outside loops where possible.

#### 4.5.4 Constraints

- **Fixed intervals:** each physical register has a fixed interval covering positions where the ABI or the ISA requires it:
  - **Calls:** every caller-saved register gets a one-position range at each call, so values live across a call are split into callee-saved registers or spilled.
  - **x86 `DIV`/`IDIV`:** inputs and outputs in `RAX`/`RDX`.
  - **x86 variable shifts:** the count operand must be in `CL`.
  - Argument and return registers at call sites and at function entry and exit.
- **Two-address forms (x86):** most x86 ALU instructions overwrite their first source. Instruction selection emits `dst = op src1, src2` and gives `dst` a hint for `src1`'s register. If `src1` is still live after the instruction, the allocator inserts `MOV dst, src1` first.
- **Reserved registers:** stack pointer, frame pointer (§4.6), AArch64 `X18` on Apple and Todhchai targets (§4.7.2), RISC-V `gp` and `tp`, and any register a Swift CC role pins for the function (§4.7.4).

#### 4.5.5 Resolution and SSA destruction

- Phis are not lowered before allocation. After allocation, each control-flow edge `pred → succ` gets the moves needed to bring every phi operand and every split interval into the location `succ` expects.
- Critical edges are split before allocation so every edge has a place for its moves.
- The moves on one edge form a **parallel move**. It is sequentialized by emitting moves whose destination is not read by another pending move, and breaking any remaining cycle with a scratch register (on x86-64, `XCHG` for general-purpose register cycles), or a stack slot if no register is free.
- Spill slots are assigned after allocation. Intervals whose spilled ranges do not overlap share slots.

### 4.6 Frame layout and frame-pointer policy

- **Frame pointers MUST be kept by default on all targets** (`RBP`, `X29`, `s0`/`fp`), with the standard frame record (saved FP and return address adjacent at the FP). This lets CUD ([07](07-debugging-and-sdi.md)) unwind most frames with one load each, and lets external profilers walk stacks. A later flag MAY allow leaf functions to omit the frame; CUD describes such frames with its frameless mode ([07](07-debugging-and-sdi.md) §5.5).
- **Stack alignment:** 16 bytes at every call boundary on all three architectures.
- **Red zone:** v1 does not use a red zone on any target. Tier 0 and kernel-adjacent code on Todhchai cannot rely on one. Using SysV's 128-byte red zone for hosted Linux and FreeBSD leaf functions is a later optimization.
- **Layout (growing down):** return address → saved FP → callee-saved register area → spill slots → locals and allocas → outgoing argument area. On AArch64, `STP`/`LDP` pairs save and restore registers. On RV64, the C extension's `c.sdsp`/`c.ldsp` are used when encodable.

### 4.7 Calling conventions

#### 4.7.1 C ABI: System V x86-64

- **Integer and pointer arguments:** `RDI, RSI, RDX, RCX, R8, R9`. **FP arguments:** `XMM0`–`XMM7`. **Returns:** `RAX`/`RDX`, `XMM0`/`XMM1`.
- **Aggregates:** each eightbyte is classified as INTEGER, SSE, X87/X87UP, or MEMORY, and the two classes are merged by the psABI rules.
  - Aggregates larger than 16 bytes, or with unaligned fields, are MEMORY: passed by copy on the stack, and returned through a hidden pointer in `RDI` that is also returned in `RAX`.
  - If an aggregate needs more registers of a class than remain, the whole aggregate goes to memory.
- **Varargs:** `AL` carries an upper bound on the number of vector registers used. `va_list` is the psABI structure with a register save area.
- **`long double`** is the 80-bit x87 format (X87 class).
- **Callee-saved:** `RBX, RBP, R12–R15`.

#### 4.7.2 C ABI: AAPCS64 and the Apple arm64 variant

- **Integer arguments:** `X0`–`X7`. **FP and vector arguments:** `V0`–`V7`. **Indirect result register:** `X8`.
- **Homogeneous aggregates:** an HFA or HVA (1–4 members of the same FP or short-vector type) goes in consecutive `V` registers.
- **Other composites:** those of 16 bytes or less go in up to two `X` registers, with 16-byte-aligned composites starting at an even register. Larger composites are copied by the caller and passed **by pointer**.
- **Callee-saved:** `X19`–`X28`, `X29` (FP), `X30` (LR, saved in the frame record), and the low 64 bits of `V8`–`V15`.
- **`long double`** is IEEE binary128 on Linux and FreeBSD (implemented with soft-float library calls).

**Apple arm64 differences** that MUST be implemented:

- Variadic arguments are always passed **on the stack**, in 8-byte slots, never in registers.
- Non-variadic stack arguments are packed to their natural alignment rather than 8-byte slots.
- The caller sign- or zero-extends `char` and `short` arguments to 32 bits.
- `X18` is a reserved platform register and MUST NOT be allocated.
- `long double` is the same as `double`.

`X18` is also reserved on Todhchai AArch64 (pending confirmation, §6). It is allocatable only on Linux and FreeBSD.

#### 4.7.3 C ABI: RISC-V LP64D

- **Integer arguments:** `a0`–`a7`. **FP arguments:** `fa0`–`fa7`. **Returns:** `a0`/`a1`, `fa0`/`fa1`.
- **Struct flattening:**
  - A struct that flattens to one FP field, two FP fields, or one FP and one integer field is passed in FP and integer registers if enough are free.
  - Other aggregates of 2×XLEN or less go in integer registers. If only one register remains, the second half goes on the stack.
  - Aggregates larger than 2×XLEN are passed by reference.
- **Varargs:** passed in integer registers, including FP values. Arguments with 2×XLEN alignment start at an even register.
- **Callee-saved:** `s0`–`s11`, `fs0`–`fs11`.
- **`long double`** is binary128 (soft-float library calls).

#### 4.7.4 Swift calling convention (summary)

The full Swift calling convention and the type-lowering rules that decide which values are passed directly are owned by [11](11-generics-and-runtime-metadata.md). Per D1, Swift-Stack adopts `swiftcc` register assignments but does not promise binary compatibility with `swiftc`-built code.

| Role | x86-64 | AArch64 | RV64 |
|---|---|---|---|
| `swiftself` (context / self) | `R13` | `X20` | open question (§6) |
| `swifterror` | `R12` | `X21` | open question (§6) |
| `swiftasync` (async context) | `R14` | `X22` | open question (§6) |
| Direct return registers (up to 4) | `RAX, RDX, RCX, R8` / `XMM0–XMM3` | `X0–X3` / `V0–V3` | `a0–a3` / `fa0–fa3` (proposed) |
| Vector (`SIMDn`) arguments/results ≤ 16 bytes | `XMM0–XMM7` | `V0–V7` | `v8–v15` (RVV; proposed) |
| Callee-saved | as C ABI | as C ABI | as C ABI |

- `swifterror` is treated specially: the callee may write it and the caller reads it after the call, even though the register is callee-saved in the C ABI.
- These roles are modeled as fixed intervals at function entry and at call sites (§4.5.4).

### 4.8 Control-flow lowering

#### 4.8.1 Switch lowering

- **Dense switches** (at least 4 cases and density of at least 40% over the value range; to be tuned per [14](14-measurement-methodology.md)) become a bounds check followed by a **jump table** in `.rodata`.
- Table entries are **32-bit offsets relative to the table base**. This keeps the table position-independent and free of dynamic relocations on PIE hosts.
- Sparse switches become a balanced binary tree of compares. Clusters of dense cases inside a sparse switch get their own sub-tables.

#### 4.8.2 Branch relaxation

Branch ranges differ by architecture. Every branch starts in its short form, and relaxation repeats to a fixpoint. Sizes only grow (a relaxed branch never shrinks back), so the loop terminates after at most one growth per branch.

| Target | Short form and range | Long form |
|---|---|---|
| x86-64 | `Jcc`/`JMP` rel8 (±128 B) | rel32 |
| AArch64 | `TBZ`/`TBNZ` ±32 KiB; `B.cond`/`CBZ` ±1 MiB | Inverted condition over an unconditional `B` (±128 MiB) |
| RV64 | `c.beqz`/`c.bnez` ±256 B; `B`-type ±4 KiB | Inverted branch over `JAL` (±1 MiB), then `AUIPC`+`JALR` |

Branches to symbols outside the function always use the long form plus a relocation. The linker owns range extension (thunks or veneers) for calls that exceed ±128 MiB on AArch64 ([06](06-linker.md)).

### 4.9 Encoders: the shared `Encode` module

- One table-driven instruction description per architecture: mnemonic, operand classes, encoding template, and relocation kinds for symbolic operands. It is written clean-room from the Intel SDM, the Arm ARM, and the RISC-V unprivileged and privileged specifications.
- The **same tables** drive three things:
  1. the backend encoder (LIR opcode → bytes);
  2. the assembler ([05](05-assembler.md)) (mnemonic and operands → bytes); and
  3. a **disassembler** (bytes → mnemonic and operands).
- **Round-trip testing:** every table entry is encoded, disassembled and compared. Host `objdump` and `llvm-objdump` act as differential oracles for disassembly, consistent with Principle 3's use of host tools only for testing.
- Per-target notes:
  - **x86-64:** the baseline is `x86-64-v2` (CMPXCHG16B, LAHF/SAHF, POPCNT, SSE3, SSSE3, SSE4.1, SSE4.2) plus AVX, F16C, AES-NI, PCLMULQDQ, RDRAND, XSAVE/XSAVEOPT and FSGSBASE (the 2013 Mac Pro / Ivy Bridge-class floor). Encoding covers legacy prefixes, REX, two- and three-byte VEX, ModR/M, SIB, and opcode maps `0F`, `0F 38` and `0F 3A`. RIP-relative addressing is used for all global and rodata references.
  - **AArch64:** fixed 32-bit words; bitmask-immediate encoder; `ADRP` + `ADD`/`LDR` with `:lo12:` page offsets.
  - **Vector encodings:** VEX-encoded SSE4.2/AVX (baseline; legacy SSE encodings are kept for the assembler and disassembler) and AVX2 (opt-in) on x86-64; Advanced SIMD on AArch64; RVV 1.0 on RV64 (baseline). The assembler shares these tables, which also serves hand-written kernels ([05](05-assembler.md)).
  - **RV64 (RVA23):** RV64IMAFDC + Zicsr + Zifencei, the RVA23 mandatory extensions used by codegen (Zba, Zbb, Zbs, Zicond, Zfa, Zfhmin, Zcb, V, Zvbb), and the rest of the profile for the assembler and disassembler. Instruction selection uses the bit-manipulation and `czero` forms. A compressed form is chosen whenever registers (`x8`–`x15` for most forms) and immediates fit. Code-size reduction from C is a measured outcome, not a stated percentage.

### 4.10 Object emission and determinism

- Each function compiles independently into a **fragment**: code bytes, relocations, a CUD record, CFI (on host targets), line-table rows, and variable location ranges.
- Fragments are concatenated in **`FunctionId` order**, never completion order, then aligned and placed into `Object.RelocatableObject` sections. This is required by D6.
- Section naming follows the target format through the `Object` abstraction:
  - ELF: `.text`, `.rodata`, `.data`, `.bss`, `.tdata`/`.tbss`, plus `.rela.*` relocation tables.
  - Mach-O: `__TEXT,__text`, `__TEXT,__const`, `__DATA,__data`, and so on, with Mach-O relocation entries. Mach-O relocatable output is required for macOS hosts.
- **In-process builds** hand the `RelocatableObject` to the linker without serializing it. With `-c`, a format writer in `Object` serializes it to an ELF or Mach-O `.o` that is byte-identical across runs.
- `#embed` data and constant pools are placed into `.rodata` (or its Mach-O equivalent) by the same path.

### 4.11 Unwind and debug outputs

| Target | Canonical unwind info | Also emitted |
|---|---|---|
| Todhchai (all architectures) | **CUD** records, sorted by the linker into `.ss_unwind` ([06](06-linker.md) §5.6), with a copy in SDI (`.ss_debug`, [07](07-debugging-and-sdi.md)) | `.eh_frame` only for functions CUD cannot describe (e.g. hand-written assembly with non-standard frames) |
| Linux, FreeBSD | **`.eh_frame`** (system unwinders, gdb, perf need it), plus `.eh_frame_hdr` built by the linker | CUD in SDI for Swift-Stack tools |
| macOS | **Apple compact unwind** (`__LD,__compact_unwind` input → linker-built `__TEXT,__unwind_info`) with `__eh_frame` fallback | CUD in SDI |

- Because frame pointers are kept (§4.6), each function's CUD record is computed directly from the final frame layout. CFI on host targets is generated from the same layout, so the two cannot disagree.
- The CUD encoding (modes, the 24-bit callee-saved mask, the escape table) is owned by [07](07-debugging-and-sdi.md) §5.5. The code generator MUST emit only the canonical prologue and epilogue shapes that CUD modes `00`/`01` assume, record epilogue offsets for the `ss_unwind_epilogues` table, and fall back to the escape mode for any other frame shape.
- **Debug outputs:** line-table rows map code offsets to `SourceLocation`. Variable locations are emitted as **ranges keyed by PC** (register or frame slot per live range), taken from the allocator's final intervals. This is how [07](07-debugging-and-sdi.md) represents optimized code.

### 4.12 RISC-V relaxation policy (v1)

- The backend picks final encodings itself, including compressed forms, and does **not** emit `R_RISCV_RELAX` or `R_RISCV_ALIGN`.
- `call` sequences are emitted as `AUIPC`+`JALR` with `R_RISCV_CALL_PLT`. Alignment padding is exact, so no linker-side deletion is needed.
- The cost is a few bytes per far call compared with a relaxing toolchain. The benefit is that layout is final at emission time, which keeps the linker simple and deterministic.
- Foreign RISC-V objects (from GCC or Clang) may contain `R_RISCV_ALIGN`. The linker MUST at least handle that relocation correctly ([06](06-linker.md)).

## 5. Alternatives considered

- **Graph-coloring allocation (Chaitin–Briggs, or LLVM's greedy allocator):** better code in high-pressure regions, but interference graphs are superlinear to build and update. Rejected for v1. The quality gap is to be measured, not assumed ([14](14-measurement-methodology.md)).
- **SelectionDAG or GlobalISel-style selection:** more global matching, at much higher cost and complexity. Greedy tiling with the single-use rule covers the high-value patterns: addressing modes, compare-and-branch, and immediates.
- **Array-of-structs LIR:** simpler to write, but wastes 6 bytes per instruction on padding (stride 24) and pulls cold fields into allocator passes.
- **Emitting assembly text and running the assembler on it:** avoided. The shared `Encode` tables give the same consistency guarantee without a text round trip.
- **RISC-V linker relaxation in v1:** gives smaller code, but layout would depend on the linker, and the linker would need a delete-bytes relaxation engine. Deferred.

## 6. Open questions

1. **RV64 Swift CC registers:** which registers serve `swiftself`, `swifterror` and `swiftasync` on RV64? Candidates are callee-saved `s` registers. To be confirmed against current upstream LLVM conventions and then fixed in [11](11-generics-and-runtime-metadata.md).
2. **Todhchai AArch64 `X18`:** is `X18` reserved by croi or Todhchai (for example for a shadow call stack)? The default assumption is reserved.
3. **`_BitInt(N)` ABI:** follow each psABI's `_BitInt` rules (x86-64 has them; AArch64 and RISC-V rules are newer). Confirm per target before implementing N > 64 parameter passing.
4. **Immediate side table:** should `imm` move to a sparse side column? This depends on the measured fraction of LIR instructions that carry immediates.
5. **Switch density threshold and minimum case count:** to be tuned on the [14](14-measurement-methodology.md) corpus.
6. **AVX2/FMA/BMI opt-in:** when is it worth enabling these by default for specific builds? This is tied to the multiversioning question in [17](17-simd-and-vectorization.md) §8. FMA contraction affects the differential-testing floating-point policy in [09](09-roadmap.md).
7. **Leaf frame-pointer omission:** is it worth having? Measure code size and speed against the unwinding cost.
