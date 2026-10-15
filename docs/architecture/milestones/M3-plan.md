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

## 3. Decisions taken in scoping

- **SQLite is staged.** The M3 exit uses the amalgamation and its shell on a scripted SQL corpus. SQLite's TCL test suite (`testfixture`, dynamically linked against the host's libtcl) becomes a follow-on gate once dynamic linking is proven.
- **`long double` is supported.** The SysV X87 class and an x87 encoder subset are in M3, which reverses M2's exclusion of x87 for exactly that subset.
- **VectraOS is exercised from Swift-Stack's side**, with an out-of-tree build and no VectraOS source changes.
- **`-g` gives DWARF 5 `.debug_line`** from both the code generator and the assembler, so gdb and perf get file and line on Linux. Variable information stays in SDI, after M3.

## 4. Out of scope for M3

Optimization beyond `-O0` (M5), the AArch64 and RV64 back ends (M5), the RV64 linker and its relaxation (M5), `-march` enforcement on AArch64, FreeBSD and Mach-O output, shared-library output, general-dynamic TLS, DWARF variable information, and the interactive `ssdb` debugger.
