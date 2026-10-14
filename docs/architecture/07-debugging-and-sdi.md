# 07. First-Class Debugging Architecture: RDI-Inspired Format, Live Inspection & Zero-Cost Unwinding

## 1. Context & The Debugging Crisis

In modern systems programming, debugging has become an agonizingly slow and resource-intensive experience:
- **DWARF's Turing-Complete Complexity:** Traditional ELF DWARF debug information relies on complex bytecode state machines (such as DWARF expression bytecode and Call Frame Information / CFI machines). Debuggers (GDB, LLDB) must interpret bytecodes on every stack frame and step, resulting in high latency.
- **PDB's Multi-Gigabyte Bloat:** Microsoft's PDB format requires parsing hierarchical multi-stream files that frequently exceed 2–4 GB for large game engines or OS kernels, causing debuggers to freeze for 10–60 seconds on startup.
- **The LLDB JIT Tax:** Evaluating a simple expression like `p my_struct.x` in LLDB often spins up an entire Clang or Swift compiler instance to JIT-compile a dynamic expression wrapper, stalling the user for seconds.

Following the pioneering architectural work of the **RAD Debugger** (Ryan Fleury, RAD Game Tools / Epic Games) and the **RAD Debug Info (RDI)** format, Swift-Stack treats debugging as a **first-class, zero-latency system service** (aligning with [Todhchai OS Principle 17](file:///home/jkane/Projects/OS/todhchai/docs/principles.md)).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      THE SWIFT-STACK DEBUG PIPELINE                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  Compiler Front & Middle-End (TypePool, SymbolTable, AIR)                   │
│    - All types, scopes, and variables already stored in flat 32-bit arrays  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                      │                                      │
│                                      ▼                                      │
│  In-Process Native Linker (RAD Linker Architecture)                         │
│    - Directly dumps SDI (.todh_debug) in a single linear pass (< 5 ms)      │
│    - Zero DWARF merging or post-link conversion passes                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                      │                                      │
│                                      ▼                                      │
│  Output Executable Binary with Memory-Mappable SDI Section (.todh_debug)    │
│    - Zero-Parse Startup: Debugger mmap's SDI directly                       │
│    - O(log N) Binary Search for Address -> Line / Symbol in nanoseconds     │
│    - Compact Unwind Descriptors: Microsecond stack traces                   │
│    - Direct Memory Expression Evaluator (No Clang/Swiftc JIT spinning)      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Swift-Stack Debug Info (SDI): Format Architecture

Swift-Stack defines **SDI (Swift-Stack Debug Info)**, a native, memory-mappable debug format inspired by RDI. 

### Core Design Rules of SDI

1. **Memory-Mapped Direct Access (`mmap`):** An SDI file or `.todh_debug` ELF section requires **zero deserialization**. The debugger memory-maps the section and casts pointers directly to table headers.
2. **Flat Arrays & 32-Bit Handles:** All references between types, scopes, procedures, and source locations use strongly-typed 32-bit indices (`SDI_TypeIndex`, `SDI_ScopeIndex`, `SDI_FileIndex`). No pointers exist on disk.
3. **Pre-Sorted Lookup Tables:** All address ranges (functions, lexical scopes, line table segments) are sorted by virtual address at link time. Resolving an instruction pointer (`RIP`/`PC`) to a procedure, line, or variable is a simple $O(\log N)$ binary search taking less than **50 nanoseconds**.

---

## 3. Structural Layout of an SDI Section

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              SDI Header                                 │
│  Magic: 'SDI1' (0x31494453)  |  Version: 1  |  Directory Offset/Count   │
├─────────────────────────────────────────────────────────────────────────┤
│                          Section Directory                              │
│  [Table Kind: u32, Byte Offset: u32, Element Count: u32, Element Size]  │
├──────────────────┬──────────────────┬──────────────────┬────────────────┤
│ 1. String Pool   │ 2. Source Files  │ 3. Line Tables   │ 4. Type Pool   │
├──────────────────┼──────────────────┼──────────────────┼────────────────┤
│ 5. Member Table  │ 6. Procedures    │ 7. Lexical Scopes│ 8. Locals      │
├──────────────────┼──────────────────┼──────────────────┼────────────────┤
│ 9. Globals       │ 10. Address Map  │ 11. Compact CUD  │ 12. Inline Site│
└──────────────────┴──────────────────┴──────────────────┴────────────────┘
```

### 1. Master Header (`SDI_Header`)
```swift
public struct SDI_Header {
    public var magic: UInt32           // 0x31494453 ("SDI1")
    public var version: UInt32         // Format version (1)
    public var totalSize: UInt64       // Total byte size of debug payload
    public var sectionTableOffset: UInt32
    public var sectionTableCount: UInt32
}
```

### 2. Procedures & Functions (`SDI_Procedure`)
Represents compiled functions, methods, and closures:
```swift
public struct SDI_Procedure {
    public var nameStringIndex: UInt32 // Offset into string pool
    public var vaddrStart: UInt64      // Starting virtual address
    public var vaddrEnd: UInt64        // Ending virtual address
    public var typeIndex: UInt32       // Index into SDI_Type (signature)
    public var rootScopeIndex: UInt32  // Index into SDI_Scope
    public var fileIndex: UInt32       // Definition source file
    public var line: UInt32            // Definition line number
    public var flags: UInt16           // isStatic, isInline, isAsync, isTier0
}
```

### 3. Lexical Scopes & Local Variables (`SDI_Scope` & `SDI_Local`)
Lexical scopes are nested hierarchical intervals:
```swift
public struct SDI_Scope {
    public var parentScopeIndex: UInt32 // 0 if root of procedure
    public var vaddrStart: UInt64       // Scope code range
    public var vaddrEnd: UInt64
    public var firstLocalIndex: UInt32  // Offset into SDI_Local table
    public var localCount: UInt32       // Number of variables in this scope
}

public struct SDI_Local {
    public var nameStringIndex: UInt32  // Variable name
    public var typeIndex: UInt32        // Index into SDI_Type
    public var locationKind: UInt8      // 0: Register, 1: FramePointerOffset, 2: Address
    public var registerId: UInt8        // Register ID (if in register)
    public var frameOffset: Int32       // Stack offset relative to RBP/X29/s0
}
```

### 4. Direct Type System Representation (`SDI_Type`)
Because Swift-Stack's compiler already uses a flat `TypePool`, emitting SDI types requires **almost zero translation**:
```swift
public struct SDI_Type {
    public var kind: UInt8              // Struct, Enum, Class, Tuple, Func, Pointer, Int...
    public var flags: UInt8             // isTrivial, isNonCopyable (~Copyable), isGeneric
    public var sizeInBytes: UInt32      // Byte size
    public var alignmentInBytes: UInt16 // Alignment
    public var nameStringIndex: UInt32  // Typename string
    public var payloadIndex: UInt32     // Points to SDI_Member or sub-type list
}

public struct SDI_Member {
    public var nameStringIndex: UInt32  // Field name
    public var typeIndex: UInt32        // Field TypeId
    public var byteOffset: UInt32       // Byte offset inside struct
}
```

---

## 4. The RAD Linker Model: Direct Linker Emission

Traditional toolchains suffer from a disjointed two-step debug generation workflow:
1. Compiler writes DWARF/PDB into individual object files.
2. Linker reads and de-duplicates them, or an external conversion tool (`radbin`) converts PDB to RDI after linking.

**Swift-Stack eliminates this entirely:**
- The in-process native Linker (`swift-ld` / `todh-ld`) receives the compiler's flat `TypePool` and `SymbolTable` directly in memory.
- During Phase 4 of linking, the linker performs a **direct linear memory write** of the pre-indexed SDI tables into the `.todh_debug` ELF section.
- **Emission Speed:** Emitting complete, rich debug information for a 100,000-line application takes **under 5 milliseconds**, adding virtually zero overhead to the link step!

---

## 5. Zero-Bytecode Stack Unwinding: Compact Unwind Descriptors (CUD)

DWARF CFI (Call Frame Information) uses complex bytecode instructions (`DW_CFA_advance_loc`, `DW_CFA_def_cfa_offset`, `DW_CFA_offset`) to describe register saves for every instruction boundary. Interpreting CFI bytecode on every stack frame is computationally heavy.

Swift-Stack implements **Compact Unwind Descriptors (CUD)**:
- Fixed-size 32-bit records describing standard stack layouts.
- **Descriptor Encoding:**
  - Bit 31: `uses_frame_pointer` (1 if standard frame pointer chain `RBP`/`X29`/`s0` is maintained).
  - Bits 30–20: `stack_frame_size` (size in 16-byte units).
  - Bits 19–0: `callee_saved_mask` (bitmask of which ABI callee-saved registers are pushed to the stack).
- **Microsecond Unwinding:**
  - For 98% of functions maintaining frame pointers, unwinding a stack frame is a single memory load: `next_fp = *(uintptr_t*)fp; return_addr = *(uintptr_t*)(fp + 8);`.
  - For leaf or frame-pointer-omitted functions, the CUD record provides the exact stack size without running an interpreter.
  - Stack traces for 100 deep frames complete in **under 2 microseconds**!

---

## 6. Fast In-Memory Expression Evaluation

Traditional debuggers stall when evaluating watch expressions because they spin up full compiler instances.

In Swift-Stack, debuggers evaluate expressions using an **in-memory lightweight evaluator**:
1. When the user evaluates `person.address.zipCode`:
   - Debugger resolves `person` via a binary search in `SDI_Local` at the current `PC`.
   - Locates its base memory address from the frame pointer offset.
   - Inspects `SDI_Type` for `person`, finding `address` at byte offset `16`.
   - Inspects `SDI_Type` for `address`, finding `zipCode` at byte offset `8`.
   - Directly reads 4 bytes from target process memory at `(base + 16 + 8)`.
2. **Instant Response:** Expression evaluation finishes in **microseconds**, displaying values in the UI at 120 FPS during live mouse-over inspection.

---

## 7. OS Integration & Live Hot Reload (Todhchai Principle 17)

[Todhchai OS Principle 17](file:///home/jkane/Projects/OS/todhchai/docs/principles.md) mandates that *debugging and hot reload are OS services*.
- **Unlocked Modules:** Loaded executable modules are never file-locked by the OS kernel.
- **Generation-Indexed SDI:** Every recompiled module appends a new generation counter (`generationId`) to its `.todh_debug` section.
- **Live State Swap:**
  - When Todhchai swaps an executable module (`CodeModule`), the debugger receives an IPC event on `td_executor_port`.
  - The debugger unmaps the old SDI section and maps the new generation buffer in $O(1)$ time.
  - Breakpoints on unchanged functions remain valid; updated functions immediately display their new source lines and local variables with zero debugger restart.
