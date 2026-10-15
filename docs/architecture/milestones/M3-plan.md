# Milestone M3 Plan — C End-to-End at `-O0` (x86-64)

Per [09-roadmap.md](../09-roadmap.md) (§M3). Scoped 2026-10-15. This is a plan, not a report; the report replaces it when M3 closes.

## 1. Starting point

The C front end is M1-grade: C23 preprocessing, parsing and semantic analysis, SysV struct layout with bit-fields (`TypePool.completeStruct`), and the glibc, FreeBSD libc, SQLite, Lua and VectraOS header corpora. M2 supplies the `Encode` tables, `RelocatableObject`, the ELF reader and writer, and the assembler's `.eh_frame` builder (LLVM MC byte-identical).

The back end is still the M0.5 slice, and M3 replaces it rather than extending it ([M0.5](M0.5-vertical-slice.md) §6.2):

- **AIR** has 27 integer-only opcodes, and `AIRLowering` reads the parse tree plus sema's M0.5 compatibility maps, not SemIR. It has no globals, floats, structs, switch, `goto`, `for` or `break`.
- **SemIR** carries a type on every instruction, but sema does not emit the implicit-conversion or lvalue-to-rvalue instructions it defines. Statements have no control-flow structure, global initializers have no values, constant evaluation is integer-only, and sema assigns stack offsets itself.
- **Register allocation** uses first-use to last-use ranges with no CFG liveness, which is wrong across loops. Its pool is five callee-saved registers.
- **Emission** goes through `X86TableEncoder` (kept), but into a private buffer with two relocation kinds. Callees are hard-coded IDs (`write` 1, `exit` 2), and an unknown callee is a `fatalError`.
- **Linking** (`StaticELFWriter`) writes an `ET_EXEC` with a built-in `_start`/`write`/`exit`. It reads no objects, and an unresolved symbol silently binds to `write`.
- **Driver:** `-c` is parsed but ignored; there is no `-S`, no C-to-`.o` path and no `--record`/`--replay`.
- **Tests:** no c-testsuite program is compiled and executed today; only the 10 `c-subset` slice programs are.

## 2. Phases

The phases are worked in order, each as one or more serial agent tasks with its own gate. Phases 1–3 are the largest.

| # | Phase | Contents | Gate |
|---|---|---|---|
| 1 | Data layout and SemIR | A per-target `DataLayout` (x86-64 SysV first; `_BitInt` per the psABI, `long double` as the 80-bit x87 type, size 16). Sema emits implicit conversions, lvalue-to-rvalue, and structured control flow (`for`, `do`, `switch`, `goto`, labels, `break`/`continue`). A static-initializer evaluator produces data images with floats, address constants and relocations, aggregates, designated initializers and string initializers. Stack offsets move out of sema. | SemIR verifier on every corpus; `sizeof`/`_Alignof`/`offsetof` and initializer images match clang on generated probes |
| 2 | AIR | The AIR of [03](../03-intermediate-representation.md) §4.1, with the C operations: signed and unsigned integer arithmetic of every width, floats, conversions, globals and TLS, aggregates (`memcpy`/`memset`), `switch`, `goto`, varargs, VLAs and `alloca`, compound literals, bit-field access, `volatile` and atomics (as calls or `lock`-prefixed operations). Lowered from SemIR. At `-O0` named locals stay in stack slots; temporaries are SSA. Verifier (`--verify-each`). | Golden `--dump=air` tests; the verifier passes on all corpora |
| 3 | LIR, selection, allocation | LIR ([04](../04-backend.md) §4.3), greedy tiling with single-use folding (§4.4), and linear scan on SSA with lifetime holes, splitting and parallel-move resolution (§4.5). M5 builds on this, so it is built once, properly. Frame layout with frame pointers (§4.6). The full SysV ABI (§4.7.1): eightbyte classification, XMM arguments and returns, return through memory, varargs (`al`, `va_list`), and the X87 class. The encoder gains the x87 subset `long double` code needs (`fld`/`fstp`/`fild`/`fistp`, arithmetic, `fucomi`, `fxch`, `fldcw`/`fnstcw`, ...), with exhaustive llvm-mc sweep coverage. Switch lowering with jump tables (§4.8.1). | c-testsuite execution starts, linked by `ld.lld` until phase 5 |
| 4 | Object output | The code generator fills a `RelocatableObject`: `.text`/`.rodata`/`.data`/`.bss`/`.tdata`/`.tbss`, `-ffunction-sections`/`-fdata-sections`, `-fPIC`/`-fPIE` addressing, `.eh_frame` from the frame layout (sharing the assembler's CFI builder), and DWARF 5 `.debug_line` (also from the assembler's `.file`/`.loc`). Driver `-c` and `-S`. x86-64 `-march` feature sets, used by instruction selection and enforced by the assembler as clang enforces them. | Our `-S` output assembled by our assembler is byte-identical to our `-c`; `clang -c` of our `-S` agrees; D6 determinism |
| 5 | Linker | [06](../06-linker.md) stages 1–2 for x86-64: ET_REL and `.a` input, symbol resolution with weak/common/lazy archive rules, the x86-64 relocations of §5.5 including GOT relaxation and local-exec/initial-exec TLS, `.eh_frame_hdr`, build-id. Outputs: VectraOS `ET_EXEC` at `0x1000000` and static PIE (`RELATIVE` only), with the segment layout and `PT_GNU_STACK` size of §8; Linux static and dynamic PIE against glibc (`PT_INTERP`, PLT/GOT, `DT_GNU_HASH`). | `llvm-readobj` structural checks; programs behave as when linked by `ld.lld`; 1-thread vs. N-thread output identical |
| 6 | Differential execution | c-testsuite's 220 `single-exec` programs, the GCC torture `execute` tests (fetched, run as data), then the SQLite amalgamation and shell on a scripted SQL corpus, each against clang (stdout and exit code; FP policy of [14](../14-measurement-methodology.md) §7). | Exit criterion 1 |
| 7 | Debug and repro | CUD records ([07](../07-debugging-and-sdi.md) §5.5) from the frame layout, a minimal SDI fragment (procedures, line table), the `ssdb` symbolizer, and `--record`/`--replay` bundles ([15](../15-driver-and-diagnostics.md) §4.8). | Exit criterion 3; a replayed bundle reproduces its recorded output hashes |
| 8 | VectraOS | A C program built by Swift-Stack, linked with VectraOS's `libcroi-runtime.a` (clang-built at `-O2` with `-fstack-protector-strong`), loaded by its kernel and run under QEMU. A Swift-Stack test builds VectraOS out of tree in its own build directory, substitutes the program, and boots it with `tools/qemu.sh`. VectraOS sources are not changed. | Exit criterion 2 |

## 3. Progress

**Phase 1 is done** (2026-10-15). Its gate:
- **The SemIR verifier passes on every corpus.** That covers c-testsuite (220 files), SQLite, Lua and VectraOS (both architectures), with no verifier issues, no unmodeled instructions, and a data image for every static object.
- **Layout matches clang 22.** `sizeof`, `_Alignof` and `offsetof` agree on 100 generated probe files per target (x86-64, AArch64, RISC-V), which cover packed and aligned records, `#pragma pack`, bit-fields, `_BitInt`, `long double` and flexible array members.
- **Initializer images match `clang -c -O0`.** That holds on 300 generated files per target and for every global of the x86-64 corpora (268 files), relocations included.
- **Golden `--dump=sem-ir` tests** cover conversions, control flow, lvalues, static initializers and layout (`Tests/Golden/sem-ir`).

The probes found and fixed:
- `#pragma pack` (it had been ignored);
- `_Alignas` on a member (it applied to the record instead);
- the AAPCS64 alignment of unnamed bit-fields;
- `asm` labels (it had been ignored, so glibc's `stat64` redirect was lost);
- brace elision in the length of an array of unknown size;
- the spacing of `#` stringizing;
- `_Generic` association matching;
- static flexible array members;
- bit-field integer promotion;
- GNU case ranges.

Carried forward:
- **Phase 4:** LLVM gives an internal object of size 0 one byte, so that distinct objects have distinct addresses. The object writer should do the same.
- **Phase 6:** `_Complex` is not supported (`__STDC_NO_COMPLEX__`; 02 §4.2.6), so GCC torture tests that use it are out of the differential set.
- **Clang divergences, not defects:**
  - Clang 22 emits an initialized array of `_BitInt(N > 128)`, or a record holding one, with LLVM's larger allocation size: `_BitInt(300) a[6]` has `sizeof` 240 but a 280-byte symbol. The image probes keep these out.
  - The D7 profile predefines clang 19's `__clang_version__` and GCC 14's `__GNUC__`, so a string built from them differs from clang 22's (SQLite's compile options).

**Phase 2 is done** (2026-10-15). AIR is the design of [03](../03-intermediate-representation.md) §4.1, with the C types and operations of §4.1.1. `AIRLowering` lowers SemIR to it. The M0.5 AIR is kept as `SliceAIR*` until phase 3 replaces the code generator that reads it.

The gate:
- **The AIR verifier passes on every corpus,** with no construct left unlowered. The verifier checks structure, types, calls against their C types, `phi` edges, and SSA dominance. The corpora:

  | Corpus | Files | Functions | Instructions |
  |---|---|---|---|
  | c-testsuite | 220 | 424 | 9,312 |
  | SQLite | 1 | 2,604 | 270,937 |
  | Lua | 35 | 1,097 | 68,391 |
  | VectraOS (three architectures) | 36 | 678 | 68,641 |

  The constraint probes, the VectraOS headers and the glibc headers pass too. The one exception is a `_Complex` probe, listed as known.
- **Golden `--dump=air` tests** (`Tests/Golden/air`) cover:
  - integers of every width;
  - floats, `long double` included;
  - control flow;
  - aggregates and bit-fields;
  - globals and TLS;
  - varargs and VLAs;
  - atomics, volatile accesses, builtins and `asm`.

  Each dump was reviewed by hand.
- **Negative tests** check that the verifier reports each kind of defect.
- **`--dump=air` and `--verify-each`** run the new AIR in the driver.

The lowering found these front-end gaps, now fixed:
- **Builtin result types.** Every builtin had been typed `long (...)`, so a call's result was a `long` (`__builtin_inff`, `__atomic_load_n` on a pointer).
- **Inline `asm` operands.** They had been skipped by the parser. They are now parsed and modeled in SemIR (`SemAsm`), and file-scope `asm` is kept.
- **VLA parameters.** The length expressions of a variably modified parameter were dropped. They are now evaluated on entry.
- **Inline-only definitions.** `__GNUC_STDC_INLINE__` and `__NO_INLINE__` were not predefined, so glibc's inline wrappers were not `gnu_inline`. An inline-only definition is now not emitted.
- **Array alignment.** Clang aligns x86-64 array *variables* of 16 bytes or more to 16, static ones included, unless the variable has an alignment attribute. The phase 1 image probes compared bytes, not symbol alignment, so they missed this.
- **Flexible array members.** An object whose flexible array member is initialized is larger than its type.

As Clang does at `-O0`, the lowering emits an internal function or object only when something emitted refers to it. VectraOS drops from 1,047 functions to 678 this way, and no unused `static inline` function from a header brings in undefined references.

Carried forward to phase 3, which must lower all of these:
- integers of widths that are not powers of two: bit-field units spanning 3, 5, 6 or 7 bytes, and `_BitInt(N)`;
- `i128`, and wider integers through runtime calls (`__divei4`, ...);
- `f80` on the x87;
- aggregates passed and returned by address, which the ABI lowering turns into eightbytes;
- `va_arg`, which yields an address;
- `phi`s;
- `dyn_alloca` with `stack_save`/`stack_restore`;
- `clz`/`ctz`: the 2013 Mac Pro floor has no `LZCNT`/`TZCNT`, so `bsr`/`bsf` with the zero case left undefined;
- 16-byte atomics (`cmpxchg16b`);
- `asm` constraints and symbolic operand names.

Not modeled yet:
- `register` variables pinned to a register with `asm("reg")` (VectraOS's AArch64 `usertest`);
- `_Complex`;
- vector extensions;
- `__builtin_va_arg_pack`, which only appears in `gnu_inline` bodies, and those are never emitted.

## 4. Decisions taken in scoping

- **SQLite is staged.** The M3 exit uses the amalgamation and its shell on a scripted SQL corpus. SQLite's TCL test suite (`testfixture`, dynamically linked against the host's libtcl) becomes a follow-on gate once dynamic linking is proven.
- **`long double` is supported.** The SysV X87 class and an x87 encoder subset are in M3, which reverses M2's exclusion of x87 for exactly that subset.
- **VectraOS is exercised from Swift-Stack's side**, with an out-of-tree build and no VectraOS source changes.
- **`-g` gives DWARF 5 `.debug_line`** from both the code generator and the assembler, so gdb and perf get file and line on Linux. Variable information stays in SDI, after M3.

## 5. Out of scope for M3

Optimization beyond `-O0` (M5), the AArch64 and RV64 back ends (M5), the RV64 linker and its relaxation (M5), `-march` enforcement on AArch64, FreeBSD and Mach-O output, shared-library output, general-dynamic TLS, DWARF variable information, and the interactive `ssdb` debugger.
