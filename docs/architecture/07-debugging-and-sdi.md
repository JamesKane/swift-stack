# 07. Debugging: SDI Format, Unwinding, and Inspection

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [04](04-backend.md), [06](06-linker.md), [08](08-runtime-and-stdlib.md), [11](11-generics-and-runtime-metadata.md), [13](13-modules-and-incremental-builds.md), [14](14-measurement-methodology.md) |

## 1. Summary

Swift-Stack defines **SDI (Swift-Stack Debug Info)**, a memory-mappable debug-information format inspired by the RAD Debugger's RDI format (Ryan Fleury, Epic Games Tools). SDI is a set of flat, sorted tables with 32-bit indices and an explicitly specified little-endian layout. Readers `mmap` it and use it without a parse step.

- The compiler emits one **SDI fragment per module**. The linker merges fragments into the image's `.ss_debug` section ([06](06-linker.md) §5.7).
- Unwinding on Todhchai uses **Compact Unwind Descriptors (CUD)**, which avoid bytecode interpretation for common frames and escape to an explicit rule record for everything else.
- For host debuggers (GDB, LLDB), the same internal records can be emitted as DWARF 5.
- This repository provides the format, a reader library, a symbolizer, and an unwinder. A full interactive debugger is a consumer built on top of these (§5.8).

## 2. Motivation

- **DWARF.** Location expressions and CFI are bytecode programs that are interpreted per query. DWARF type information is duplicated per translation unit and has to be deduplicated at link time.
- **PDB.** Its multi-stream container is expensive to open for very large programs.
- **Expression evaluation.** LLDB evaluates many expressions by compiling them with an embedded Clang or Swift compiler, which is slow for simple member accesses.

RDI showed that a debugger can open a large program quickly if the debug information is stored as pre-sorted flat tables that need no deserialization. SDI applies that approach, using the fact that Swift-Stack's compiler already stores types, scopes, and symbols in flat tables.

## 3. Goals

- MUST be readable by `mmap` plus bounds-checked, explicit-offset accessors, with no deserialization pass.
- MUST be specified normatively by a C23 header (`include/sdi/sdi.h`). Swift structs are *not* the file format, because Swift does not guarantee struct layout; Swift readers use explicit-offset accessors generated from the header.
- MUST describe optimized code correctly: variables whose location changes by PC range, values split across registers, values that are optimized out, and inlined calls.
- MUST support separate compilation: per-module fragments that a linker merges without access to the compiler's in-memory `TypePool`.
- MUST give the Swift-specific information needed to display generic, resilient, existential, and async values (§5.7).
- SHOULD meet the latency targets in §7.

## 4. Non-goals

- Evaluating expressions that require calling target code (function calls, computed properties, `description`). See §5.9.
- Full LLDB Swift-language support on host targets. LLDB's Swift support depends on swiftc module and metadata formats, which Swift-Stack does not produce (D1). Host debugging is C-level (§5.10).
- C++ debugging (C++ is a project non-goal).

## 5. Design

### 5.1 Encoding rules

- **Byte order and alignment.** All integers are little-endian. Every table starts at an offset aligned to 8. Each record type has the fixed size and alignment given in the header, and records contain no implicit padding: every byte is either a named field or `reserved` (zero).
- **Index conventions.** Index 0 in every table is a reserved null record, so 0 means "none".
- **Strings.** Strings are offsets into the string pool: UTF-8, NUL-terminated, and deduplicated.
- **Addresses.** In a linked image, address fields are virtual addresses. In a fragment (`SDI_FLAG_FRAGMENT`), an address field encodes `(section_index << 48) | section_offset`, and the linker rebases it.
- **Registers.** Register numbers use the DWARF register numbering of each architecture, so that existing tables and tools can be reused.
- **Versioning.** The header carries a major and minor version. Readers MUST reject an unknown major version and MUST ignore unknown tables (by directory kind) and set flag bits that they do not understand.

### 5.2 Header and directory

```c
// include/sdi/sdi.h (normative excerpt)
#define SDI_MAGIC 0x31494453u            /* "SDI1" */

typedef struct sdi_header {              /* size 48, align 8 */
    uint32_t magic;                      /*  0 */
    uint16_t version_major;              /*  4 */
    uint16_t version_minor;              /*  6 */
    uint64_t total_size;                 /*  8 */
    uint64_t dir_offset;                 /* 16 */
    uint32_t dir_count;                  /* 24 */
    uint32_t flags;                      /* 28: bit0 FRAGMENT, bit1 HAS_DWARF_COMPANION */
    uint64_t generation_id;              /* 32: hot-reload generation (§5.11) */
    uint64_t build_id_prefix;            /* 40: first 8 bytes of the image build-id */
} sdi_header;

typedef struct sdi_dir_entry {           /* size 24, align 8 */
    uint32_t kind;                       /*  0: SDI_TABLE_* */
    uint32_t record_size;                /*  4: lets readers skip newer, larger records */
    uint64_t offset;                     /*  8 */
    uint64_t count;                      /* 16 */
} sdi_dir_entry;
```

The tables are: string pool, source files, line rows, types, members, type lists, procedures, scopes, scope ranges, locals, locations, location pieces, globals, inline sites, address map, and (in fragments only) type content hashes.

**Macro expansions.** Every Swift macro expansion buffer ([16](16-macros.md) §5.8) is a row in the source-files table, flagged `SDI_FILE_GENERATED`. Its path is `<macro:Module.Type>/<discriminator>.swift`, its text is stored in the string pool, and it has a parent link to the expansion site's file and line. Line rows for generated code point into these virtual files, so a debugger can show and step through code such as the IPC server stubs that `@IPCLibrary` generates. When DWARF is emitted, the same text goes into DWARF 5 embedded-source (`DW_LNCT_LLVM_source`-style) entries, subject to host debugger support (to be verified).

### 5.3 Core records

```c
typedef struct sdi_procedure {           /* size 40, align 8 */
    uint64_t vaddr_start;                /*  0 */
    uint64_t vaddr_end;                  /*  8: exclusive */
    uint32_t name;                       /* 16: string (mangled `_SS…` for Swift) */
    uint32_t display_name;               /* 20: string (demangled) */
    uint32_t type;                       /* 24: sdi_type index (signature) */
    uint32_t root_scope;                 /* 28 */
    uint32_t file;                       /* 32 */
    uint16_t flags;                      /* 36: STATIC, ASYNC, TIER0, ARTIFICIAL */
    uint16_t reserved;                   /* 38 */
} sdi_procedure;                         /* line: in the line table */

typedef struct sdi_scope {               /* size 24, align 4 */
    uint32_t parent;                     /*  0: 0 at a procedure root */
    uint32_t first_range;                /*  4: into the scope-range table */
    uint32_t range_count;                /*  8: optimized code may split a scope */
    uint32_t first_local;                /* 12 */
    uint32_t local_count;                /* 16 */
    uint32_t inline_site;                /* 20: non-zero if this scope is an inlined call */
} sdi_scope;

typedef struct sdi_range {               /* size 16, align 8 */
    uint64_t start, end;                 /* end is exclusive */
} sdi_range;

typedef struct sdi_line_row {            /* size 24, align 8 */
    uint64_t vaddr;                      /*  0 */
    uint32_t file;                       /*  8 */
    uint32_t line;                       /* 12 */
    uint16_t column;                     /* 16 */
    uint16_t flags;                      /* 18: IS_STMT, PROLOGUE_END, EPILOGUE_BEGIN, END_SEQUENCE */
    uint32_t reserved;                   /* 20 */
} sdi_line_row;

typedef struct sdi_type {                /* size 32, align 8 */
    uint8_t  kind;                       /*  0: int, float, pointer, struct, enum, class, tuple, func, array, existential, generic_param, ... */
    uint8_t  flags;                      /*  1: TRIVIAL, NONCOPYABLE, RESILIENT, SIGNED */
    uint16_t align;                      /*  2 */
    uint32_t size;                       /*  4: 0xFFFFFFFF = layout known only at run time (§5.7) */
    uint32_t name;                       /*  8 */
    uint32_t payload;                    /* 12: first member / element type / type list */
    uint32_t payload_count;              /* 16 */
    uint32_t metadata_symbol;            /* 20: string: runtime metadata accessor symbol, or 0 */
    uint64_t content_hash;               /* 24: structural hash; used for cross-module merging */
} sdi_type;

typedef struct sdi_member {              /* size 16, align 4 */
    uint32_t name;                       /*  0 */
    uint32_t type;                       /*  4 */
    uint32_t byte_offset;                /*  8: 0xFFFFFFFF = resilient; look up the offset at run time */
    uint16_t bit_offset;                 /* 12: C bit-fields */
    uint16_t bit_size;                   /* 14: 0 = not a bit-field */
} sdi_member;

typedef struct sdi_inline_site {         /* size 24, align 4 */
    uint32_t callee_name;                /*  0: string */
    uint32_t callee_type;                /*  4 */
    uint32_t call_file;                  /*  8 */
    uint32_t call_line;                  /* 12 */
    uint16_t call_column;                /* 16 */
    uint16_t flags;                      /* 18 */
    uint32_t parent_site;                /* 20: enclosing inline site, or 0 */
} sdi_inline_site;
```

The **address map** is a sorted array of `(vaddr_start, vaddr_end, procedure)` used to resolve a PC to a procedure. The innermost scope is then found by descending scope ranges. Each inlined scope produces one virtual frame in backtraces, using `call_file`/`call_line` as the caller's position.

### 5.4 Locations for optimized code

A local refers to a list of location entries. Each entry is valid over a PC range, which allows a variable to move between a register, a stack slot, and "optimized out" over its lifetime.

```c
typedef struct sdi_local {               /* size 20, align 4 */
    uint32_t name;                       /*  0 */
    uint32_t type;                       /*  4 */
    uint32_t first_location;             /*  8 */
    uint32_t location_count;             /* 12 */
    uint16_t flags;                      /* 16: PARAMETER, ARTIFICIAL, SELF, TYPE_METADATA */
    uint16_t reserved;                   /* 18 */
} sdi_local;

typedef struct sdi_location {            /* size 32, align 8 */
    uint64_t pc_start;                   /*  0: pc_start == pc_end == 0 → entire enclosing scope */
    uint64_t pc_end;                     /*  8 */
    uint8_t  kind;                       /* 16: see the table below */
    uint8_t  reg;                        /* 17: DWARF register number */
    uint16_t piece_count;                /* 18: COMPOSITE only */
    int32_t  offset;                     /* 20 */
    uint64_t payload;                    /* 24: address, constant, or first piece index */
} sdi_location;

typedef struct sdi_piece {               /* size 16, align 4 */
    uint32_t byte_offset;                /*  0: within the variable */
    uint32_t byte_size;                  /*  4 */
    uint32_t location;                   /*  8: a non-composite sdi_location */
    uint32_t reserved;                   /* 12 */
} sdi_piece;
```

| `kind` | Meaning |
|---|---|
| 0 `REGISTER` | value is in `reg` |
| 1 `FRAME_OFFSET` | value is at `frame_base + offset` (frame base = FP) |
| 2 `REGISTER_INDIRECT` | value is at `[reg + offset]` |
| 3 `ABSOLUTE` | value is at address `payload` |
| 4 `CONSTANT` | value is the constant `payload` (small integers) |
| 5 `COMPOSITE` | value is assembled from `piece_count` pieces starting at `payload` |
| 6 `ASYNC_CONTEXT` | value is at `[async_context + offset]` (§5.7) |
| 7 `OPTIMIZED_OUT` | value is unavailable in this range |

The common unoptimized case (one stack slot for the whole scope) is a single entry with `pc_start == pc_end == 0` and `kind = FRAME_OFFSET`. This is the compact form of the general model.

Location tables are kept deliberately non-programmable. If the backend cannot describe a value with these kinds, it emits `OPTIMIZED_OUT` for that range rather than an expression program.

### 5.5 Compact Unwind Descriptors (CUD)

Frame pointers are kept by default on all targets ([04](04-backend.md)). A CUD table is a sorted array of `(function_start: u32 image offset, descriptor: u32)` pairs. The top two bits select a mode:

| Mode | Bits | Meaning |
|---|---|---|
| `00` FP standard | `[29:24]` prologue length in bytes (0–63); `[23:0]` callee-saved mask | Frame record `(saved FP, return address)` at FP. Callee-saved registers are stored at fixed slots below FP in canonical order. CFA = FP + 16. Frame size is not needed, so frame size is unbounded. |
| `01` frameless | `[29:24]` prologue length; `[23:10]` stack size in 16-byte units (≤ 256 KiB); `[9:0]` callee-saved mask (first 10) | Leaf or FP-omitted function with a canonical prologue. |
| `10` escape | `[29:0]` index into the extended-rule table | Anything else: large frameless frames, unusual prologues, hand-written assembly, functions with several frame shapes. |
| `11` terminal | — | Bottom of stack (for example `_start`, thread entry). |

The 24-bit mask covers the callee-saved sets of all three targets: x86-64 `rbx, r12–r15`; AArch64 `x19–x28, d8–d15`; RISC-V `s1–s11, fs0–fs11` (23 bits).

**Extended rules** are explicit per-PC-range rows: a CFA rule (register + offset) plus a save rule per register (same value, at CFA+offset, in register). They are a table of rows rather than bytecode, so lookup is a binary search.

**Asynchronous precision.** Sampling profilers, signal handlers, and debuggers stop at arbitrary instructions, including inside prologues and epilogues. CUD handles this as follows:

- **Prologues.** The prologue-length field says how many bytes the frame takes to be established. The code generator MUST emit only canonical prologue shapes for modes `00`/`01`, so the unwinder can compute the partial state at any offset inside the prologue.
- **Epilogues.** Epilogue start offsets are listed in a sorted side table (`ss_unwind_epilogues`: `(function_offset: u32, kind: u8)`). Within a listed epilogue, the unwinder applies the canonical reverse state.
- **Escape.** A function whose prologue or epilogue is not canonical MUST use mode `10`.

**Relation to `.eh_frame`.** On Todhchai, CUD is the canonical format. Foreign objects provide only `.eh_frame` FDEs, which the linker indexes with `.eh_frame_hdr` ([06](06-linker.md) §5.6). The unwinder consults CUD first and falls back to FDEs. Host targets emit `.eh_frame` because the system tools expect it. Swift error propagation does not unwind.

### 5.6 Per-module fragments and linking

The backend writes one fragment per module. Fragments are stored in the module's object (`.ss_debug`) and alongside the module artifact ([13](13-modules-and-incremental-builds.md)).

- Within a module, types are already unique because the compiler's `TypePool` is canonical. Each type carries a structural `content_hash`.
- Addresses in a fragment are section-relative (§5.1).
- The linker merges fragments ([06](06-linker.md) §5.7): it concatenates tables, rebases indices, deduplicates types across modules by `content_hash` (for example, types from a C header used by several modules), rebases addresses, and sorts the address map and line rows.

The linker needs no compiler data structures, so separately compiled modules, cached modules, and libraries built earlier are handled identically to in-process compilation. Foreign C objects carry DWARF, not SDI. Converting their DWARF to SDI at link time is optional and off by default (§9).

### 5.7 Swift-specific information

- **Generic values.** In unspecialized Tier 1 code ([11](11-generics-and-runtime-metadata.md)), a value of type `T` has no static layout. The procedure emits an artificial `TYPE_METADATA` local for each generic parameter, holding the location of its metadata pointer. The debugger reads size, alignment, and field layout from the target's runtime metadata and value-witness table, whose layout is specified in [11](11-generics-and-runtime-metadata.md).
- **Resilient types.** These are marked with `size = 0xFFFFFFFF` and/or member `byte_offset = 0xFFFFFFFF`; the layout is obtained through `metadata_symbol` at run time.
- **Existentials.** These use `kind = existential` with the container layout from [11](11-generics-and-runtime-metadata.md): inline buffer, metadata pointer, and witness tables.
- **Async functions.** Their locals live in a heap-allocated async context, so locations use `ASYNC_CONTEXT`. The context register is `r14` on x86-64 and `x22` on AArch64 (the RISC-V assignment is defined in [04](04-backend.md)). The debugger builds a *logical* backtrace by following the parent-context chain, whose layout is defined in [08](08-runtime-and-stdlib.md) and [11](11-generics-and-runtime-metadata.md), in addition to the physical stack.
- **Tier 0.** All types are specialized, so all sizes are static and no runtime metadata is required.

### 5.8 Consumers: reader, symbolizer, unwinder, debugger

SDI is only useful if something reads it. This repository provides the following, and the roadmap includes them ([09](09-roadmap.md)):

1. **`SDIReader`.** A C23 and Swift library with explicit-offset, bounds-checked accessors, plus a validator (`ssdb-dump --verify`) that checks sortedness, index bounds, and record sizes. It also serves as the format's conformance test.
2. **Symbolizer.** `ssdb-symbolize <image> <addr...>` resolves addresses to procedure, inline frames, file, and line. Used by crash reports and runtime backtraces.
3. **Unwinder library.** Shared by the runtime's backtrace support ([08](08-runtime-and-stdlib.md)) and the debugger; supports CUD, extended rules, and the FDE fallback.
4. **Debugger (`ssdb`).** An interactive debugger for Todhchai that uses 1–3 together with OS debugging services. It is a separate milestone and may live in the Todhchai tree.

### 5.9 Expression evaluation

The evaluator works directly on SDI and target memory and never runs target code. Supported:

- identifiers (locals in scope at the PC, and globals)
- member access `.` and `->`
- dereference `*`, and `pointee` on Swift unsafe pointers
- subscripts `[n]` on C arrays, pointers, tuples, and fixed-size/`InlineArray` storage
- casts to SDI types, address-of, and integer/float arithmetic and comparisons

Out of scope: function calls, computed properties, subscripts implemented as functions (for example `Array.subscript`), and `description`. Data formatters for standard-library types (`Array`, `String`, `Dictionary`) MAY read their storage layouts directly. Those layouts are versioned with the stdlib ([12](12-standard-library-strategy.md)).

Example: evaluating `person.address.zipCode` for stored properties of fixed-layout types:

1. Find `person` in the locals of the innermost scope at the PC, and choose the location entry whose range covers the PC.
2. Compute the base address (for example `FP + offset`).
3. Look up member `address` in the type of `person`, then member `zipCode` in the type of `address`, and add their `byte_offset`s.
4. Read `size` bytes of `zipCode`'s type from target memory.

### 5.10 DWARF for host debuggers

`--debug-format=dwarf` (or `both`) emits DWARF 5 from the same internal records: `.debug_info`, `.debug_abbrev`, `.debug_line`, `.debug_str`/`.debug_line_str`, `.debug_rnglists`, `.debug_loclists`, and `.debug_addr`. SDI location kinds map one-to-one to simple DWARF location expressions. Swift types are described as DWARF structures, enumerations, and pointers with their Swift names, so GDB and LLDB provide C-level inspection of Swift code. Swift-aware LLDB features (expression evaluation in Swift, reflection-based formatting) are not expected to work (D1).

### 5.11 Hot reload (Todhchai OS principle 17)

Todhchai OS principle 17 makes debugging and hot reload OS services. SDI supports this as follows:

- Each code-module build has a `generation_id` in its SDI header.
- When Todhchai swaps a `CodeModule`, the debugger is notified on its event port. It maps the new generation's SDI and unmaps the old one when no frames of the old code remain live.
- Breakpoints are stored as `(procedure display name, file, line)` and re-bound against the new generation. Breakpoints in unchanged procedures resolve to the same source positions; breakpoints in changed procedures are re-resolved, and the user is told if one cannot be bound.

Hot reload needs relocatable code modules, which v1 does not link ([06](06-linker.md) §10, question 5).

## 6. Alternatives considered

- **DWARF only.** Rejected for Todhchai because of the query cost of interpreted location and CFI programs and the link-time cost of deduplication. Kept as a host output (§5.10).
- **Swift structs as the on-disk format.** Rejected: Swift layout is not a stable format, and readers in other languages need a normative definition.
- **Location expressions as bytecode (like DWARF).** Rejected in favor of a closed set of kinds plus `OPTIMIZED_OUT`. This costs some coverage of optimized code in exchange for simple and fast readers.
- **Apple-style compact unwind alone.** Rejected: it is not precise at arbitrary instructions and depends on DWARF for fallbacks. CUD adds prologue and epilogue information and a table-based escape mode.
- **Emitting SDI in the linker from the compiler's in-memory `TypePool`.** Rejected: it only works for single-process whole-program builds.

## 7. Performance targets

These are hypotheses to be measured per [14](14-measurement-methodology.md).

| Metric | Target |
|---|---|
| PC → procedure + line lookup | < 100 ns median on a warm mapping |
| Open a 100K-LOC program's SDI (mmap + header validation) | < 1 ms |
| Unwind 100 frames (CUD mode `00`) | < 2 µs |
| Simple member-access expression | < 10 µs, excluding target-memory read latency |
| Fragment merge in the linker | see [06](06-linker.md) §11 |

## 8. Open questions

1. Should line rows be delta-compressed (with a sorted block index) in v1, or kept as raw 24-byte rows until size is measured?
2. Should SDI optionally live in a separate file (`.sdi`) next to stripped release images, keyed by build-id?
3. Should DWARF in foreign C objects be converted to SDI at link time so that whole-program symbolication works on Todhchai, and at what cost?
4. What is the RISC-V register for the async context, and does it change the CUD canonical prologue shapes? (Depends on [04](04-backend.md).)
5. What is the policy for data formatters when stdlib storage layouts change, and how are their versions recorded in SDI?
