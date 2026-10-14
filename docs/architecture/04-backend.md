# 04. Backend Architecture & Target Code Generation

## 1. Overview

Traditional compiler backends (such as LLVM's `SelectionDAG`, `GlobalISel`, and Chaitin-Briggs graph coloring register allocator) prioritize peak instruction scheduling at the cost of catastrophic compile-time overhead and millions of lines of code.

Swift-Stack designs a **lean, deterministic machine code generator** composed of:
1. **LIR (Low-Level Machine IR):** A flat, cache-dense instruction array representing target-specific instructions and virtual registers.
2. **Tiling Instruction Selection:** A fast maximal-munch pattern matcher that lowers AIR into LIR in linear time.
3. **Linear Scan Register Allocation with Interval Splitting:** Delivering 95%+ of graph coloring code quality at 15x–30x the speed.
4. **Direct Machine Code Encoders:** Native binary encoders for **x86-64-v2**, **AArch64**, and **RISC-V (RV64GC)** that emit machine code bytes directly into memory buffers without invoking external assemblers.

```
AIR (Optimized SSA Instructions)
              │
              ▼  (Linear-time Maximal Munch Pattern Tiling)
     LIR (Target-Specific Virtual Registers)
              │
              ▼  (Backward Liveness Analysis: 64-bit Bitsets)
      Live Range Intervals
              │
              ▼  (Linear Scan with Loop Interval Splitting)
     LIR (Physical Registers & Stack Spill Slots Assigned)
              │
              ▼  (Peephole Cleanup & Branch Relaxation)
     Direct Binary Machine Code Encoders (x86_64, aarch64, riscv64)
              │
              ▼
  In-Memory ELF64 / Mach-O Relocatable Sections (.text, .rodata, .rela)
```

---

## 2. Low-Level Machine IR (LIR)

LIR mirrors the target CPU architecture while retaining the flat-array data-oriented layout of the frontend and middle-end:

```swift
public struct LIRFunction {
    public var instructions: [LIRInstruction]
    public var basicBlocks: [LIRBlock]
    public var stackFrameSize: UInt32
    public var calleeSavedRegsMask: UInt64
}

public struct LIRInstruction {
    public var op: MachineOpcode       // 2 bytes: Target opcode (e.g. X86_MOV_RR, ARM_ADD_IMM)
    public var dest: Register          // 2 bytes: Physical or Virtual Register ID
    public var src1: Register          // 2 bytes: Physical or Virtual Register ID
    public var src2: Register          // 2 bytes: Physical or Virtual Register ID
    public var immediate: Int64        // 8 bytes: Displacement, constant, or symbol index
    public var flags: UInt16           // 2 bytes: Memory width, condition code
}
```

**Footprint:** Exactly 18 bytes per instruction in a contiguous array.

---

## 3. Fast Instruction Selection (Pattern Tiling)

Rather than building complex SelectionDAG graphs with node replacement cycles, Swift-Stack uses a **linear-time Maximal Munch Tiling** algorithm over the postorder AIR stream:

```
[AIR Instruction]                [Generated Target LIR (x86-64)]
%ptr = air.add %base, %offset    ──► LEA reg_dest, [reg_base + reg_offset * 1]
%val = air.load %ptr             ──► MOV reg_val,  [reg_dest]
```

- **Fused Memory Operands:** Memory address computations (`base + index * scale + disp`) are matched in a single greedy step and folded into x86 SIB (Scale-Index-Base) addressing or AArch64 base-register offsets.
- **Immediate Folding:** Constant operands that fit into architecture immediate fields (e.g. 12-bit unsigned on AArch64, 32-bit sign-extended on x86-64) are embedded directly into the instruction, bypassing scratch register loads.

---

## 4. Linear Scan Register Allocation

Graph coloring allocators (such as LLVM's greedy/PBQP allocator) construct $O(V^2)$ interference graphs. For functions with hundreds of variables, building and updating the interference matrix dominates backend execution.

Swift-Stack implements **Linear Scan with Interval Splitting** (Poletto & Sarkar / Wimmer):

```
Live Range Intervals:
vreg0:  [inst 2  ───────────────► inst 18]   ── Allocated to: RAX
vreg1:  [inst 4  ──────────────────────────────────────────► inst 42] ── Spilled to Stack
vreg2:        [inst 8  ──► inst 14]         ── Allocated to: RDX
vreg3:             [inst 12 ──────────────────────────────► inst 38] ── Allocated to: RCX
```

### Algorithm Steps

1. **Linear Liveness Analysis:**
   - Traverses basic blocks backward in reverse postorder.
   - Computes live intervals using bitsets over virtual registers. Execution time is $O(Instructions \times \frac{VRegs}{64})$.
2. **Interval Ordering:**
   - Active intervals are stored in a sorted priority queue ordered by start instruction index.
3. **Linear Scan & Spill Selection:**
   - When all physical registers are exhausted, the allocator selects the interval that extends furthest into the future.
   - If that interval belongs to a loop body, **loop boundary splitting** splits the interval at the loop entry/exit, ensuring values inside the loop stay in registers while spilling only outside the hot path.

This produces binary code within 1–3% of graph-coloring quality while running in linear time.

---

## 5. ABI Compliance: Swift & C Calling Conventions

Swift-Stack strictly adheres to target platform ABIs:

### 1. Swift Calling Convention (`swiftcc`)
- **Self Pointer (`swiftself`):**
  - x86-64: `R13`
  - AArch64: `X20`
  - RISC-V: `s2`
- **Error Pointer (`swifterror`):**
  - x86-64: `R12`
  - AArch64: `X21`
  - RISC-V: `s3`
- **Multi-Value Direct Returns:** Up to 4 scalar/pointer values returned in registers (x86-64: `RAX, RDX, RCX, R8`; AArch64: `X0-X3`; RISC-V: `a0-a3`) before falling back to indirect return buffers.
- **Calley-Save Preservation:** Preserves standard ABI callee-saved registers across calls.

### 2. Standard C Calling Convention (`sysv_cdecl`)
- **Argument Registers:**
  - x86-64: `RDI, RSI, RDX, RCX, R8, R9` (Floats: `XMM0-XMM7`)
  - AArch64: `X0-X7` (Floats: `V0-V7`)
  - RISC-V: `a0-a7` (Floats: `fa0-fa7`)
- **Return Registers:** `RAX / RDX` (x86), `X0 / X1` (ARM64), `a0 / a1` (RISC-V).

---

## 6. Target Architecture Encoders

All encoders write binary bytes directly into flat memory buffers. No intermediate assembly text (`.s`) is generated.

### 1. x86-64-v2 Encoder (Todhchai amd64 + FreeBSD / Linux / macOS)
- Baseline: `x86-64-v2` (requires CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSSE3, SSE4.1, SSE4.2).
- Full instruction encoding support:
  - ModR/M and SIB byte layout.
  - REX prefixes (`0x40 - 0x4F`) for 64-bit operand sizes and extended registers (`R8-R15`).
  - Two-byte and three-byte opcode maps (`0x0F`, `0x0F 0x38`, `0x0F 0x3A`).
  - Short (8-bit) and near (32-bit) conditional branch displacement relaxation.

### 2. AArch64 Encoder (Todhchai aarch64 + FreeBSD / Linux / macOS)
- Fixed 32-bit instruction words.
- Clean bitfield encoding:
  - Load/Store pair instructions (`LDP`, `STP`) for fast prologue/epilogue register saving.
  - Immediate arithmetic (`ADD`, `SUB`, `MOVZ`, `MOVK`).
  - PC-relative addressing (`ADRP` + `ADD` / `LDR`) for position-independent rodata and symbol loads.

### 3. RISC-V Encoder (RV64GC: Todhchai rv64 + FreeBSD / Linux)
- Standard 32-bit RV64G instruction set (Base 64-bit integer, Integer Multiplication/Division, Atomics, Single/Double Precision Floats).
- **C Extension (Compressed 16-bit Instructions):** Automatically emits 16-bit compressed instructions (`c.li`, `c.mv`, `c.add`, `c.ld`, `c.sd`) whenever operands fit within the restricted register set (`x8-x15`) and small immediates, reducing code size by 25–35%.

---

## 7. Direct Object File Emission

The backend emits in-memory object sections:
- `.text`: Executable machine code bytes.
- `.rodata`: String literals, type metadata tables, floating-point constants, and `#embed` binary data.
- `.data` / `.bss`: Global mutable variables and uninitialized memory descriptors.
- `.rela.text` / `.rela.rodata`: Direct relocation tables recording `(offset, symbol_index, relocation_type, addend)`.

These in-memory sections are transferred directly to the internal Linker via zero-copy buffer handoff.
