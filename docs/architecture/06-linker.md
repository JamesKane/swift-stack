# 06. Data-Oriented Native Linker

| | |
|---|---|
| **Status** | Draft |
| **Depends on** | [00](00-overview-and-principles.md), [02](02-semantic-analysis.md), [04](04-backend.md), [05](05-assembler.md), [07](07-debugging-and-sdi.md), [08](08-runtime-and-stdlib.md), [09](09-roadmap.md), [11](11-generics-and-runtime-metadata.md), [13](13-modules-and-incremental-builds.md), [14](14-measurement-methodology.md), [15](15-driver-and-diagnostics.md) |

## 1. Summary

The Swift-Stack linker runs in-process with the compiler, driven by the main `swift-stack` driver. A standalone `ld`-compatible personality (`ss-ld`) is deferred until a concrete external build needs one ([15](15-driver-and-diagnostics.md)). It consumes relocatable objects in a shared in-memory **object model** (the `Object` module, defined canonically in this chapter), whether they were produced by Codegen, by the native assemblers, or read from foreign ELF / Mach-O `.o` and `.a` files. It produces static ELF executables for VectraOS and static or dynamic executables for the POSIX host targets.

Relative to a conventional linker it adds three things, without changing ordinary ELF/Mach-O symbol semantics:

1. **Link-time type checking** of symbol references, using type-signature hashes carried in a side section (`.ss_symtypes`).
2. **Debug-info merging without DIE deduplication**, by consuming per-module SDI fragments (see [07](07-debugging-and-sdi.md)).
3. **Deterministic parallel linking**: output is bitwise identical regardless of thread count (D6).

## 2. Motivation

The design is motivated by linker redundancies discussed by Jonathan Blow and others in the Handmade community (streams and talks; citation to be added), and by the observed costs of conventional toolchains:

- **Debug-info duplication.** In the classical C model every translation unit that includes a header emits debug records for the header's types, and the linker (or a post-link tool) spends significant time deduplicating them. Swift-Stack emits type debug information once per module and merges modules by content hash (§5.7, [07](07-debugging-and-sdi.md)).
- **First-come symbol resolution.** Archive member selection and weak/strong rules let an unrelated definition satisfy a reference silently. Swift-Stack keeps standard semantics (so foreign code links as expected) but adds optional provider-module constraints and type checks (§5.3).
- **No type information at link time.** In plain C, a declaration and a definition can disagree on a signature without any diagnostic. `.ss_symtypes` lets the linker report such mismatches when both sides were compiled by Swift-Stack.
- **Disk round-trips.** Writing `.o` files only to have the linker re-parse them is unnecessary when compiler and linker share a process. In-process handoff (§6) removes this; on-disk objects remain supported for separate compilation and caching ([13](13-modules-and-incremental-builds.md)).

A note on loaders: the original document claimed that ASLR makes link-time address assignment redundant. That overstates it. Position-independent executables use PC-relative code, so text is not patched at load time; the loader applies mostly `R_*_RELATIVE` and GOT/`JUMP_SLOT` relocations to data. Link-time layout remains necessary. What *can* be co-designed with the VectraOS loaders is the set of load-time relocations: zero for static `ET_EXEC`, and only `R_*_RELATIVE` for static PIEs, which is all VectraOS's loaders accept.

## 3. Goals

- MUST link objects from Codegen, the native assemblers, and foreign ELF objects/archives (Mach-O on macOS) with standard symbol semantics.
- MUST produce identical output bytes for identical inputs and flags, independent of thread count and scheduling (D6).
- MUST support the targets in §8 in the staged order given there.
- MUST verify `.ss_symtypes` type hashes when both the reference and the definition carry them.
- SHOULD meet the link-time targets in §9 (hypotheses, measured per [14](14-measurement-methodology.md)).

## 4. Non-goals

- PE/COFF and Windows (project non-goal, [00](00-overview-and-principles.md)).
- Producing shared libraries in v1 (dynamic *executables* linking against system shared libraries are in scope for host targets).
- Linker scripts beyond a small fixed set of built-in layouts.
- LTO. Cross-module optimization happens in the compiler using inlinable bodies from module interfaces ([13](13-modules-and-incremental-builds.md)).
- Binary compatibility with swiftc-produced Swift objects (D1).

## 5. Design

### 5.1 The `Object` model (canonical)

`Object` is the shared relocatable-object model used by Codegen ([04](04-backend.md)), the assemblers ([05](05-assembler.md)), the foreign-object readers, and the linker. All tables are `Column<T>` storage (D8, [00](00-overview-and-principles.md)); there are no per-symbol or per-relocation heap objects.

```swift
public struct RelocatableObject: ~Copyable {
    public var origin: ObjectOrigin             // compiled, assembled, foreignELF, foreignMachO
    public var moduleId: ModuleId               // Swift-Stack module, or .foreign
    public var inputPriority: UInt32            // command-line order; used for deterministic tie-breaks

    // Sections
    public var sectionNames: Column<AtomId>
    public var sectionKinds: Column<SectionKind>    // text, rodata, data, bss, tdata, tbss, eh_frame, ss_symtypes, ss_debug, ...
    public var sectionAligns: Column<UInt8>         // log2 alignment
    public var sectionBytes: Column<ByteRange>      // range into `bytes`; bss/tbss have size only
    public var bytes: Column<UInt8>

    // Symbols
    public var symbolNames: Column<AtomId>          // mangled `_SS…` for Swift, plain for C/asm
    public var symbolSections: Column<SectionIndex> // or .undefined / .absolute / .common
    public var symbolValues: Column<UInt64>
    public var symbolSizes: Column<UInt64>
    public var symbolBindings: Column<SymbolBinding> // local, global, weak
    public var symbolVisibility: Column<SymbolVisibility>
    public var symbolTypes: Column<SymbolTypeRecord> // optional; from .ss_symtypes (§5.3)

    // Relocations, grouped by section (CSR layout). Stored as whole rows (AoS): every
    // relocation is applied by reading all four fields together ([18](18-data-catalog.md) §5.4).
    public var relocSectionStart: Column<UInt32>    // per section, offset into `relocs`
    public var relocs: Column<Relocation>           // 24-byte rows, see below

    // Unwind and debug
    public var unwind: Column<UnwindRecord>         // CUD records (07 §5.5); FDEs stay in an eh_frame section
    public var debugFragment: SDIFragmentRef?       // per-module SDI fragment (07 §5.6)
}
```

```swift
@frozen public struct Relocation {      // stride 24 (layout hypothesis, 18)
    public var offset: UInt64            // within the section
    public var addend: Int64
    public var symbol: SymbolIndex       // UInt32; 0 = nil row (00 Principle 7)
    public var kind: RelocKind           // UInt16, target-neutral, mapped from ELF/Mach-O types
    public var flags: UInt16
}
```

Rules:

- `RelocKind` is a target-neutral enumeration with a 1:1 mapping to each object format's relocation types, so that foreign objects round-trip without loss.
- Codegen and the assemblers produce `RelocatableObject` values directly. The ELF and Mach-O readers `mmap` the input and fill the same columns; section bytes may alias the mapping (zero-copy).
- An `ObjectWriter` can serialize a `RelocatableObject` to a standard ELF `.o` (or Mach-O on macOS). This is used for caching ([13](13-modules-and-incremental-builds.md)), for `-c` builds, and for interoperation with external tools.

### 5.2 Symbol resolution

Symbol semantics follow ELF (and Mach-O on macOS) so that foreign code behaves as it does under `ld.lld`:

- Strong vs. weak definitions, common symbols, and lazy archive-member extraction follow the standard rules.
- Duplicate strong definitions are an error. The diagnostic names both input objects and, when available, both source locations (from SDI fragments).
- Archive member extraction is iterated to a fixed point in a deterministic order (input priority, then member index).

**Parallel, deterministic resolution.** Symbols are inserted into a concurrent open-addressing table keyed by interned name. Each slot stores the candidate definition with the *lowest* `(rank, inputPriority, symbolIndex)` tuple, where `rank` orders strong < weak < common < lazy. Updates use a CAS loop that only replaces a candidate with a strictly smaller tuple. The final result depends only on the input set, not on which thread arrives first (D6).

### 5.3 Typed symbol checks: `.ss_symtypes`

Symbol names are ordinary. Swift symbols use Swift-Stack's mangling (prefix `_SS`, defined in [11](11-generics-and-runtime-metadata.md)), which already encodes the module and distinguishes overloads. C and assembly symbols use their plain names. Type checking is layered on top through a side section:

```c
// Normative layout; little-endian; section alignment 8.
typedef struct ss_symtype {
    uint32_t symbol_index;    // offset 0: index into the object's symbol table
    uint8_t  kind;            // offset 4: 0 = function, 1 = object (data), 2 = TLS object
    uint8_t  language;        // offset 5: 0 = C, 1 = Swift, 2 = asm-declared
    uint16_t flags;           // offset 6: bit 0 = definition, bit 1 = has provider module
    uint64_t signature_hash;  // offset 8: canonical type-signature hash (BLAKE3-64)
    uint32_t provider_module; // offset 16: interned module name (string table offset), or 0
    uint32_t reserved;        // offset 20
} ss_symtype;                 // size 24
```

**Hash derivation.** The hash is computed over a *canonical structural encoding* of the declared type. It is never computed from a `TypeId`, because `TypeId`s are compilation-local.

- **Swift:** the hash covers the lowered function signature (parameter and result types, ownership conventions, `throws`/`async`). The mangled name already separates overloads; the hash catches stale interface/implementation pairs.
- **C:** the hash covers the function or object type after removing top-level parameter qualifiers and expanding typedefs. Struct and union types follow the C23 cross-translation-unit compatibility rules (C23 §6.2.7): a complete tagged type is encoded by its tag plus its member names and member types in order (recursively, with cycles broken by tag reference). An incomplete type is encoded by kind and tag only. Two types that the standard calls compatible MUST hash equal; a hash difference MAY still be a false negative for compatible-but-differently-spelled types, which is why the diagnostic is configurable.
- `long` and `long long` remain distinct in the encoding even when they have the same size ([02](02-semantic-analysis.md)).

**Check policy.**

- A check runs only when *both* the referencing object and the defining object carry a record for the symbol.
- A mismatch is an error by default (`--ss-type-mismatch=error|warn|ignore`). The diagnostic prints both decoded signatures, which are recoverable from the SDI fragments.
- Foreign objects without `.ss_symtypes` link normally. `--ss-warn-untyped` optionally reports references satisfied by untyped definitions.

**Provider-module constraint.** A reference MAY carry a `provider_module`. In that case the linker accepts only a definition from that module and reports an error otherwise, which prevents an unrelated library from satisfying a system-API reference. This is an optional namespace qualifier on top of ELF semantics, not a replacement for them; references without it resolve normally.

### 5.4 Layout

1. Input sections are grouped into output sections by kind and name, in a fixed order (text, rodata, eh_frame/eh_frame_hdr, data, tdata, tbss, bss, non-allocated). Within an output section, input order is `(inputPriority, sectionIndex)`, which is deterministic.
2. Section sizes and offsets are computed with a parallel prefix sum. Alignment padding is part of the scan.
3. Synthetic sections (GOT, PLT, `.eh_frame_hdr`, build-id note, `.ss_debug`) are sized after scanning relocations, which determines GOT/PLT entries, and are placed at fixed positions in the order above.

### 5.5 Relocation processing

Relocations are applied in parallel, **partitioned by input section** as in mold and lld, not by fixed-size chunks of the output. Each input section's relocations are contiguous in the `Object` model (CSR layout) and patch only that section's bytes, so workers never write to shared bytes. Large input sections MAY be split by relocation index range. Scheduling follows D11: input sections are pre-sorted by `(inputPriority, index)`, and lanes claim the next one through an atomic cursor. Each lane writes only to that section's precomputed output range, so the result is independent of which lane took which section.

Relocation coverage required in v1:

| Class | x86-64 | AArch64 | RISC-V 64 |
|---|---|---|---|
| Absolute | `R_X86_64_64`, `_32`, `_32S` | `R_AARCH64_ABS64`, `ABS32` | `R_RISCV_64`, `R_RISCV_32` |
| PC-relative / branch | `PC32`, `PLT32` | `CALL26`, `JUMP26`, `CONDBR19`, `TSTBR14`, `ADR_PREL_PG_HI21`, `ADD_ABS_LO12_NC`, `LDST{8,16,32,64,128}_ABS_LO12_NC` | `CALL`, `CALL_PLT`, `PCREL_HI20`, `PCREL_LO12_I/S`, `BRANCH`, `JAL`, `RVC_BRANCH`, `RVC_JUMP` |
| GOT | `GOTPCREL`, `GOTPCRELX`, `REX_GOTPCRELX` | `ADR_GOT_PAGE`, `LD64_GOT_LO12_NC` | `GOT_HI20` |
| TLS local-exec | `TPOFF32` | `TLSLE_ADD_TPREL_HI12`, `TLSLE_ADD_TPREL_LO12_NC` | `TPREL_HI20`, `TPREL_LO12_I/S`, `TPREL_ADD` |
| TLS initial-exec | `GOTTPOFF` | `TLSIE_ADR_GOTTPREL_PAGE21`, `TLSIE_LD64_GOTTPREL_LO12_NC` | `TLS_GOT_HI20` |
| Dynamic (output) | `RELATIVE`, `GLOB_DAT`, `JUMP_SLOT` | `RELATIVE`, `GLOB_DAT`, `JUMP_SLOT` | `RELATIVE`, `64`, `JUMP_SLOT` |

GOT-indirect references to symbols that resolve locally in static images SHOULD be relaxed to direct forms where the ABI permits it (for example `GOTPCRELX` to `lea`). General-dynamic and local-dynamic TLS are not needed in v1 because v1 produces no shared libraries. They are required if foreign objects use them; such objects are diagnosed until support is added.

**RISC-V specifics.**

- `R_RISCV_PCREL_LO12_I/S` refers to the *label of the paired `auipc`*, not to the target symbol. The linker MUST locate the `PCREL_HI20` relocation at that address in the same section and compute the low part from that pair's target. The lookup uses a per-section index sorted by offset.
- **RISC-V attributes.** Every input's `.riscv.attributes` section (`Tag_RISCV_arch` and related tags) is merged. Swift-Stack's own objects record the RVA23 profile ISA string. A foreign input whose ISA string needs an extension outside the output's target profile is a link error, unless `--allow-isa-superset` is given.
- **Relaxation policy (depends on [04](04-backend.md)):** v1 does not perform linker relaxation. Swift-Stack's code generator MUST NOT emit `R_RISCV_RELAX` or `R_RISCV_ALIGN`. Its assembler emits them, as LLVM MC does, for hand-written assembly assembled with relaxation on (clang's default, and how VectraOS builds; [05](05-assembler.md) §4.8), so the linker treats those objects like foreign ones. A foreign object containing `R_RISCV_RELAX` links correctly without relaxing, because the relaxation hint is optional. A foreign object containing `R_RISCV_ALIGN` requires NOP deletion to be correct. v1 handles it by deleting the excess padding NOPs only (the minimal form of relaxation), and rejects the object with a diagnostic if that is not possible.

### 5.6 Unwind information

- **VectraOS:** Compact Unwind Descriptors (CUD, [07](07-debugging-and-sdi.md) §5.5) are the canonical unwind format. The linker sorts CUD records by address into a binary-searchable table in `.ss_unwind`. Frame pointers are kept on all targets by default.
- **Linux and FreeBSD, and foreign objects on any ELF target:** `.eh_frame` sections are concatenated, CIEs are deduplicated, and `.eh_frame_hdr` is emitted (sorted FDE table, `PT_GNU_EH_FRAME`).
- **macOS:** `__LD,__compact_unwind` inputs are turned into `__TEXT,__unwind_info`, with `__eh_frame` as the fallback ([04](04-backend.md) §4.11).
- On VectraOS, functions that come only with FDEs (foreign C or assembly) are covered through `.eh_frame_hdr`, and the unwinder consults CUD first and FDEs second.
- Swift errors do not use unwinding (they use the `swifterror` register convention). Unwind tables exist for backtraces, debuggers, profilers, and foreign code.

### 5.7 Debug information

The linker does not deduplicate DIE trees. Each Swift-Stack module contributes one SDI fragment, produced at compile time and stored in the module artifact or in the object's `.ss_debug` section ([07](07-debugging-and-sdi.md) §5.6, [13](13-modules-and-incremental-builds.md)). The linker:

1. Concatenates the fragments' tables, rebasing table indices by prefix sums.
2. Merges type records by content hash. Records within a module are already unique, so cross-module duplicates (types from shared C headers) are dropped with a hash-table probe.
3. Rewrites section-relative addresses to final virtual addresses and sorts the address map.

For host debuggers, `--debug-format=dwarf` emits DWARF 5 instead of (or in addition to) SDI ([07](07-debugging-and-sdi.md) §5.10).

### 5.8 Deterministic output (D6)

- All ordering decisions use `(inputPriority, index)` tuples, never thread arrival order or hash-table iteration order.
- String tables and symbol tables are emitted in a sorted order: locals by input order, then globals by name.
- Timestamps are never embedded. The build-id is a BLAKE3 hash of the final image bytes with the build-id field zeroed, computed after layout and relocation.
- Parallel phases write to disjoint, precomputed output ranges.
- CI links with 1 and N threads and compares the outputs bytewise ([14](14-measurement-methodology.md)).

### 5.9 Link-once sections and Swift runtime sections

- **Link-once (COMDAT-like) sections.** Generic specializations ([11](11-generics-and-runtime-metadata.md)) and other compiler-synthesized definitions that several modules may emit are placed in link-once sections keyed by their `_SS` mangled name ([13](13-modules-and-incremental-builds.md)).
  - The linker keeps the copy from the input with the lowest `(inputPriority, index)` and discards the rest, together with their relocations, unwind records and SDI fragments.
  - On ELF this uses `SHT_GROUP`/`GRP_COMDAT`; on Mach-O, weak definitions with the same deterministic choice rule.
  - If two copies have different `.ss_symtypes` hashes or different sizes, the link fails with a diagnostic. Under D6 identical inputs produce identical bodies, so a mismatch indicates a stale artifact.
- **Runtime-discovered sections.** The Tier 1 runtime finds tables through linker-defined bounds rather than by registering them at startup ([08](08-runtime-and-stdlib.md)):
  - conformance records in `ss_conformances` (ELF) and `__TEXT,__ss_conform` (Mach-O), from [11](11-generics-and-runtime-metadata.md) §5;
  - nominal type descriptors for by-name lookup (e.g. `_typeByName`) in `ss_types`, using the same scheme. The name is reserved here; the record format is to be defined in [11](11-generics-and-runtime-metadata.md).

  For ELF, section names without a leading dot let the linker synthesize `__start_<name>`/`__stop_<name>`. For Mach-O, the runtime uses `getsectiondata` on the loaded image. These sections are concatenated in deterministic input order and MUST NOT be garbage-collected while any input references the bounds symbols.

## 6. In-memory pipeline

When the driver compiles and links in one invocation ([15](15-driver-and-diagnostics.md)), Codegen and the assemblers hand `RelocatableObject` values to the linker without serializing them. Foreign `.o`/`.a` inputs are `mmap`ed. The output file is created at its final size and memory-mapped; workers write into it directly. Separate-compilation builds write objects to the artifact cache ([13](13-modules-and-incremental-builds.md)) and read them back through the same `Object` reader.

## 7. Thread-local storage

Only the local-exec and initial-exec models are produced in v1. The linker computes thread-pointer offsets as follows:

- **x86-64 (variant II).** `%fs` points to the TCB, which follows the TLS block. A symbol's offset is `sym_offset_in_tls − align_up(tls_memsz, tls_align)`, which is negative. VectraOS user threads set `%fs` through the kernel (`object_set_property` `REGISTER_FS`; the kernel leaves `CR4.FSGSBASE` off), and save `TPIDR_EL0` and `tp` per thread on AArch64 and RV64; its user runtime has no ELF TLS image yet (planned with pthreads in its userland).
- **AArch64 (variant I).** `TPIDR_EL0` points to a 16-byte TCB, and the TLS block starts at `align_up(16, tls_align)`.
- **RISC-V (variant I).** `tp` (`x4`) points directly at the start of the TLS block (TCB size 0 as seen from TLS offsets).

`PT_TLS` is emitted with the `.tdata` image and the `.tbss` size.

## 8. Targets (staged order)

Targets are brought up in this order. Each stage is gated on the differential tests in [09](09-roadmap.md).

1. **VectraOS static ELF64**, as VectraOS's CMake build links it today with `ld.lld`:
   - User programs: `ET_EXEC` at `--image-base=0x1000000`, or a static PIE (`-static -pie --no-dynamic-linker -ztext`, linked at 0) that the loaders place at a random base, applying only `R_*_RELATIVE` relocations and then making `PT_GNU_RELRO` read-only. An `ET_EXEC` may carry a relocation-free dynamic section (`--export-dynamic`) as a symbol table for programs that will host loaded code.
   - 4 KiB pages (`-zmax-page-size=4096`), page-aligned separate `PT_LOAD` segments `R-X` (text), `R--` (rodata, eh_frame_hdr) and `RW-` (data, bss) (`-zseparate-loadable-segments`), `PT_GNU_STACK` (`RW-`, `-znoexecstack`) whose size is the main-thread stack (`-zstack-size`, 256 KiB by default), `--gc-sections` with `-ffunction-sections`/`-fdata-sections`, and a SHA-1 `--build-id`. `PT_TLS` and `PT_GNU_EH_FRAME` when present.
   - The kernel: a static PIE linked at `0xffffffff80000000` with its own linker script and `--orphan-handling=error`, placed at a random base by the UEFI loader (KASLR). The loader itself: a static PIE that `vx elf2efi` converts to PE32+.
   - VectraOS's loaders read the stack size from `PT_GNU_STACK`, which settles §11 question 2 for this target.
2. **Linux ELF64.**
   - Static: `ET_EXEC` or static-PIE.
   - Dynamic: `ET_DYN` (PIE) with `PT_INTERP` (`/lib64/ld-linux-x86-64.so.2`, `/lib/ld-linux-aarch64.so.1`, `/lib/ld-linux-riscv64-lp64d.so.1`), `PT_DYNAMIC`, `DT_NEEDED`, `DT_RELA`/`DT_JMPREL`, `RELATIVE`/`GLOB_DAT`/`JUMP_SLOT` relocations, `.dynsym`/`.dynstr`, `DT_GNU_HASH`, and a PLT/GOT.
3. **FreeBSD ELF64.** As for Linux, plus `ELFOSABI_FREEBSD`, the `.note.tag` ABI note, and the interpreter `/libexec/ld-elf.so.1`. Static images use the platform's default base address.
4. **macOS Mach-O 64.**
   - Dynamic executables only; macOS does not support static executables.
   - Required load commands: `MH_EXECUTE`, `LC_SEGMENT_64` (`__PAGEZERO`, `__TEXT`, `__DATA_CONST`, `__DATA`, `__LINKEDIT`), `LC_LOAD_DYLINKER` (`/usr/lib/dyld`), `LC_LOAD_DYLIB` (`/usr/lib/libSystem.B.dylib`), `LC_MAIN`, `LC_BUILD_VERSION`, `LC_DYLD_CHAINED_FIXUPS`, `LC_DYLD_EXPORTS_TRIE`, `LC_SYMTAB`/`LC_DYSYMTAB`, and `LC_UUID`.
   - An ad-hoc `LC_CODE_SIGNATURE` is mandatory on arm64 and is always emitted.
   - Requires a Mach-O object *reader* for foreign `.o`/`.a` inputs and, on the backend side, a Mach-O relocation mapping in `RelocKind`.
   - Linking against `libSystem` needs its exported-symbol list. This is read from the SDK `.tbd` text stubs, so no binary dylib is needed at link time.

## 9. Performance targets

These are hypotheses to be measured per [14](14-measurement-methodology.md); they are not claims.

| Metric | Target | Notes |
|---|---|---|
| Link a VectraOS system service (static, in-memory inputs) | < 50 ms | 8 cores; compare against `ld.lld` and `mold` on identical inputs |
| SDI merge for a 100K-LOC program | < 5 ms | fragments precomputed at compile time |
| 1-thread vs. N-thread output | bitwise identical | CI gate, not a performance target |

## 10. Alternatives considered

- **Replace ELF symbol semantics with module-scoped binding everywhere.** Rejected: it would break linking against foreign archives and system libraries. Module scoping is offered as an optional constraint (§5.3).
- **Unmangled Swift symbol names, with type hashes for overload disambiguation.** Rejected: object formats require unique symbol names, so overloads need distinct names (D1).
- **Fixed 64 KiB output chunks for relocation.** Rejected: a relocation's input section is the natural unit of work, and chunking by output address needs an extra mapping step and still touches every relocation.
- **Using `TypeId` directly as the link-time type identity.** Rejected: `TypeId`s are not stable across compilations.

## 11. Open questions

1. ~~ASLR on the primary target?~~ Resolved by VectraOS: its loaders already place static PIEs at random bases (and the kernel itself with KASLR), while `ET_EXEC` images still load where linked. The linker produces both, with a `RELATIVE`-only table for PIEs.
2. Where does the per-image stack size live: a note section, a loader default, or a program header? VectraOS uses `PT_GNU_STACK`'s size; the question remains for the hosts.
3. Should `--ss-type-mismatch` default to `warn` for C-only links until the hash canonicalization has been validated against a large C corpus?
4. Minimal RISC-V `R_RISCV_ALIGN` handling versus rejecting such objects: VectraOS's rv64 assembly, assembled as its build does (relaxation on), contains `R_RISCV_ALIGN` and `R_RISCV_RELAX` in every file with code alignment or relaxable instructions, so v1's NOP deletion is required, not optional. Which other relocations do its C objects carry?
5. Should shared-library output be in scope for v2 (needed for hot reload of code modules, [07](07-debugging-and-sdi.md) §5.11)? VectraOS has no dynamic linker yet; its decision comes first.
6. **Patchable code modules ahead of macOS.** Should relocatable, patchable code modules, which enable live code editing, move ahead of macOS Mach-O output in the roadmap ([09](09-roadmap.md))?
   - **What they are:** a code image a VectraOS loader could map, relocate and swap while the process runs. This is Handmade Hero-style hot reload and serves VectraOS principle 23 ("debugging and hot reload are OS services"). VectraOS has no such loader yet.
   - **Why now:** function-level incremental compilation ([13](13-modules-and-incremental-builds.md)) plus such modules would give edit-and-continue in seconds, which arguably matters more to day-to-day development than a fourth host format.
   - **Overlap with question 5:** shared-library output is the conventional route to the same capability.
