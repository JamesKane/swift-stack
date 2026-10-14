# 06. Data-Oriented Native Linker Architecture

## 1. Overview & The "Modern Linker Redundancy" Problem

In traditional C and Swift toolchains, the linker is one of the most frustrating, error-prone, and bottlenecked components. As analyzed by Jonathan Blow and Sean Barrett (in *Redundancies in Modern Linkers*), traditional linkers do enormous amounts of redundant, useless work while failing to provide basic safety:

1. **The Header & DWARF Duplication Tax:**
   In the classical C/C++ compilation model, every single translation unit that includes a header file generates duplicate debug information and struct definitions for every type in that header. The linker is then burdened with deduplicating millions of identical DIE records. This process is slow, memory-intensive, and prone to subtle bugs.
2. **Redundant Address Assignment vs Modern Loaders:**
   A large part of a traditional linker's original historic purpose was to statically fix addresses at link time so the OS loader wouldn't have to. With modern Address Space Layout Randomization (ASLR), modern OS loaders relocate code at startup anyway, causing work to be performed twice unless the toolchain is co-designed with the system loader.
3. **Flawed "First-Come, First-Served" Symbol Resolution:**
   Standard linkers place all global symbols into a flat global bucket. If multiple translation units or libraries define the same symbol, the first one encountered silently claims the slot. This leads to accidental symbol collisions, silent hijacking of functions, and phantom bugs that evade both compilers and linkers.
4. **Zero Type Safety at Link Time:**
   Compilers enforce strict type safety across arguments and return values, but the moment code transitions to the linker, that type safety completely vanishes. The linker sees only untyped strings. C++ uses complex name mangling as an awkward, brittle workaround; plain C has no link-time type verification at all, resulting in silent ABI mismatches when headers and implementations fall out of sync.
5. **The Disk Serialization Waste:**
   Compilers spend millions of cycles formatting and writing relocatable object files (`.o`) to disk, only for the linker process to immediately read those exact same bytes back off disk, re-parse the ELF/Mach-O headers, and reconstruct identical symbol tables.

Swift-Stack replaces this legacy architecture with an **in-process, data-oriented native linker** (`swift-ld` / `todh-ld`). It resolves symbols with **typed, module-scoped descriptors**, emits **single-instance debug information**, and operates directly on **in-memory section buffers**.

```
Backend In-Memory Relocatable Sections
           │
           ▼  (Zero-Copy In-Memory Direct Handoff)
Phase 1: Typed, Module-Scoped Symbol Resolution
  - Lock-free concurrent symbol table (Hopscotch / Radix hash)
  - Explicit (ModuleId, SymbolName, TypeSignatureHash) verification
  - Zero silent symbol hijacking
           │
           ▼
Phase 2: Section Allocation & Address Layout
  - Co-designed with Todhchai loader: Base 0x1000000, 4 KiB Page Alignment
  - Segments: RX (Text), R (Rodata/Debug), RW (Data/BSS), TLS (PT_TLS)
           │
           ▼
Phase 3: Concurrent Relocation Processing
  - Memory-mapped output executable
  - Slices of .text (64 KiB chunks) processed by worker threads concurrently
  - In-place binary patching: (S + A - P) / (S + A)
           │
           ▼
Phase 4: Synthetic Sections & Single-Emission Debug Info
  - .eh_frame_hdr (Binary search index)
  - .note.gnu.build-id (Fast BLAKE3 checksum)
  - Native Compact Debug Index (.todh_debug) - Emitted ONCE per module!
           │
           ▼
Final Static / Dynamic Executable Binary
```

---

## 2. Typed, Module-Scoped Symbol Binding

To permanently eliminate the silent aliasing flaws of legacy linkers, Swift-Stack implements **explicitly scoped, type-checked symbol binding**:

```swift
public struct SymbolDescriptor: Hashable {
    public var moduleId: ModuleId           // 4 bytes: Identifies defining library/module
    public var name: AtomId                 // 4 bytes: Interned symbol name
    public var typeSignatureHash: UInt64    // 8 bytes: Hash of parameter & return types
    public var flags: SymbolFlags           // 2 bytes: isExported, isWeak, isTrivial
}
```

### Eliminating Silent Aliasing & Mismatches

1. **Module Scoping:**
   References can specify the target library (e.g. `libtodhchai::Loop.openWindow`). The linker guarantees that the symbol resolves exclusively against that module, preventing an application or third-party library from accidentally overriding an internal system API.
2. **Link-Time Type Verification:**
   Every symbol import and export carries a 64-bit `typeSignatureHash` derived from its canonical `TypeId` representation in the `TypePool`.
   - If an imported C function is declared as `int open(const char*, int)` in one file but implemented as `long open(const char*, unsigned int)` in another, the linker immediately halts with an explicit **Link-Time Type Mismatch Error**, specifying both the caller's expectation and the provider's actual definition.
   - This eliminates the silent memory corruption and ABI bugs that have plagued C for decades.
3. **No Name Mangling Tax for Type Safety:**
   Because types are verified via 64-bit signature hashes, the compiler does not need to inflate symbol names with hundreds of bytes of mangled type strings. Symbol names remain clean, short, and readable in debug traces.

---

## 3. Single-Emission Debug Information (No DWARF Merging Tax)

In Swift-Stack, **type definitions and debug information are never duplicated across translation units**:
- In C23, types declared in shared header files are registered in the module's shared `TypePool`.
- The compiler emits debug information **once per module** directly into the `.todh_debug` section (or canonical `.debug_info`).
- The linker is completely freed from the burden of parsing, decompressing, and deduplicating millions of identical DIE trees. Debug info generation becomes a simple, linear append operation that completes in under 5 milliseconds.

---

## 4. Zero-Copy In-Memory Pipeline

When compiling a multi-file Swift module or C library:
1. **No Intermediate Disk Files:** The backend keeps relocatable sections in memory buffers (`~Copyable` arenas).
2. **Direct Buffer Handoff:** The linker accepts these memory slices directly without disk writes, serialization, or deserialization.
3. **Foreign Object Support:** When linking external C/assembly libraries, the linker memory-maps foreign `.o` and `.a` archive files directly into virtual memory.

---

## 5. The Four Concurrent Linking Phases

### Phase 1: Parallel Symbol Resolution
- **Concurrent Hash Table:** Symbols are interned into a fixed-size, concurrent hash table using open addressing with Robin Hood or Hopscotch collision resolution.
- **Lock-Free Deduplication:** Worker threads resolve undefined symbols concurrently using atomic CAS operations on symbol table slots.
- **Strict Strong vs Weak Semantics:** Global strong symbols override weak symbols deterministically without thread stalls. Duplicate definitions of strong symbols trigger instant diagnostic messages pointing directly to the source locations.

### Phase 2: Section Layout & Memory Sizing
- Section sizes and alignments from all input objects are aggregated using parallel prefix sums (scan).
- **Target OS Layouts:**
  - **Todhchai OS:** Static `ET_EXEC` mapped at base `0x1000000`, 4 KiB page alignment:
    ```
    Virtual Address Range           Segment Type   Flags   Alignment
    0x1000000 - 0x1000000 + text    PT_LOAD        R-X     4096 (4 KiB)
    ...       - ...         rodata  PT_LOAD        R--     4096 (4 KiB)
    ...       - ...         data    PT_LOAD        RW-     4096 (4 KiB)
    ...       - ...         tls     PT_TLS         R--     8 / 16 bytes
    ```
    Stack allocation: Enforces Todhchai's default 256 KiB stack allocation with non-executable stack flags (`PT_GNU_STACK` with `RW-` rights).
  - **FreeBSD Host Target:** Standard FreeBSD ELF64 (`ELFOSABI_FREEBSD` in `EI_OSABI`), emits `.note.tag` (FreeBSD ABI version), dynamic interpreter `PT_INTERP` pointing to `/libexec/ld-elf.so.1`, or static image base at standard FreeBSD layout (`0x200000` or PIE).
  - **Linux Host Target:** Standard System V / GNU ELF64 with dynamic interpreter `/lib64/ld-linux-x86-64.so.2` or static execution.
  - **macOS Host Target:** Mach-O 64-bit (`MH_EXECUTE`), emitting `LC_SEGMENT_64` (`__TEXT`, `__DATA`, `__LINKEDIT`), `LC_LOAD_DYLINKER`, and code signature slices.

### Phase 3: Concurrent Relocation Processing
Relocating machine code bytes is parallelized across CPU cores with zero lock contention:
1. **Memory-Mapped Output:** The target executable is allocated or memory-mapped to its final size.
2. **Chunk Partitioning:** Output sections (e.g. `.text`) are divided into 64 KiB work chunks.
3. **Worker Processing:** Each thread claims a chunk from a work-stealing queue and applies relocations in-place:
   - **x86-64 Relocations:**
     - `R_X86_64_PC32` / `R_X86_64_PLT32`: `S + A - P`
     - `R_X86_64_64`: `S + A`
   - **AArch64 Relocations:**
     - `R_AARCH64_ADR_PREL_PG_HI21`: Page-relative high 21-bit displacement
     - `R_AARCH64_ADD_ABS_LO12_NC`: Low 12-bit immediate
     - `R_AARCH64_CALL26` / `R_AARCH64_JUMP26`: 26-bit branch displacement
   - **RISC-V Relocations:**
     - `R_RISCV_CALL` / `R_RISCV_CALL_PLT`: `AUIPC` + `JALR` pair
     - `R_RISCV_PCREL_HI20` / `R_RISCV_PCREL_LO12_I`

### Phase 4: Synthetic Sections & Fast Debug Info

#### Exception Unwind Table (`.eh_frame_hdr`)
- Extracts FDE (Frame Description Entry) records from `.eh_frame`.
- Sorts FDE starting addresses in parallel.
- Emits a compact, binary-searchable `.eh_frame_hdr` table, allowing Todhchai's zero-cost exception and stack unwinder (`libunwind`) to locate exception handlers in $O(\log N)$ time without traversing linked lists.

#### Direct Debug Emission: `.todh_debug` vs DWARF 5
1. **Native Todhchai Format (`.todh_debug`):**
   - Emits a single, unified flat index directly into the output binary:
     - Table of Files: Contiguous string table of source paths.
     - Line Program Table: Run-length-encoded `(Address, FileId, Line, Column)` tuples.
     - Function & Global Variable Index: Flat array of `(SymbolId, Address, Size, TypeId)`.
   - Result: Emitted in $< 5$ milliseconds with zero deduplication overhead. Debuggers open the executable and inspect variables instantly without parsing multi-megabyte DWARF trees.
2. **Standard DWARF 5 Compatibility (POSIX Host Mode):**
   - When targeting Linux or macOS with GDB/LLDB, emits standard `.debug_info`, `.debug_line`, and `.debug_str` sections, utilizing multi-threaded string interning.
