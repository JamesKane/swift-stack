import Foundation
import Testing
@testable import SwiftStack

// Regressions for M2 assembler defects. Some behavior has no clang/GNU oracle (clang reports out-of-range
// AArch64 branches and RISC-V `jal` as errors, whereas 05-assembler.md §4.5 requires relaxing them; diagnostics and
// malformed-ELF handling are ours alone). The rest pin LLVM MC output (`llvm-mc`/`clang -c`, the reference
// assembler; 05-assembler.md §4.11), so they hold even where no oracle is installed;
// `Tests/Differential/asm/` compares the same features live.

@Suite("M2 — Assembler regressions")
struct M2AssemblerRegressionTests {

    /// Section contents, symbols (`section`, value) and relocations of an assembled object, plus rendered diagnostics.
    struct Assembled {
        var sections: [String: [UInt8]] = [:]
        var symbols: [String: (section: String, value: UInt64, size: UInt64)] = [:]
        var relocs: [String: [(offset: UInt64, symbol: String, addend: Int64)]] = [:]
        var errors = 0
        var rendered = ""
    }

    private static func assembleObject(_ src: String, _ arch: AssemblerArch, fileName: String = "t.s") -> Assembled {
        var diags = DiagnosticBag()
        let sm = SourceManager()
        let obj = Assembler.assemble(source: src, arch: arch, fileName: fileName, sourceManager: sm, diagnostics: &diags)
        return describe(obj, diags: diags, sourceManager: sm)
    }

    private static func describe(_ obj: borrowing RelocatableObject, diags: borrowing DiagnosticBag, sourceManager: SourceManager) -> Assembled {
        var out = Assembled()
        func sectionName(_ s: SectionIndex) -> String {
            s == .absolute ? "*ABS*" : (s == .undefined ? "*UND*" : obj.sectionName(s))
        }
        if obj.sectionCount > 0 {
            for i: UInt32 in 1...obj.sectionCount {
                let sec = SectionIndex(i)
                out.sections[obj.sectionName(sec)] = obj.sectionData(sec)
                out.relocs[obj.sectionName(sec)] = obj.relocs(for: sec).map { r in
                    (r.offset, r.symbol.isValid ? obj.symbolName(r.symbol) : "", r.addend)
                }
            }
        }
        if obj.symbolCount > 0 {
            for i: UInt32 in 1...obj.symbolCount {
                let sym = SymbolIndex(i)
                out.symbols[obj.symbolName(sym)] = (sectionName(obj.symbolSections[sym]), obj.symbolValues[sym], obj.symbolSizes[sym])
            }
        }
        out.errors = diags.errorCount
        out.rendered = DiagnosticRenderer.render(diagnostics: diags, sourceManager: sourceManager)
        return out
    }

    private static func assemble(_ src: String, _ arch: AssemblerArch) -> (text: [UInt8], errors: Int, symbols: [String: UInt64]) {
        var diags = DiagnosticBag()
        let obj = Assembler.assemble(source: src, arch: arch, diagnostics: &diags)
        let text = obj.findSection(name: ".text").map { obj.sectionData($0) } ?? []
        var symbols: [String: UInt64] = [:]
        if obj.symbolCount > 0 {
            for i: UInt32 in 1...obj.symbolCount {
                symbols[obj.symbolName(SymbolIndex(i))] = obj.symbolValues[SymbolIndex(i)]
            }
        }
        return (text, diags.errorCount, symbols)
    }

    private static func words(_ bytes: [UInt8], count: Int) -> [UInt32] {
        (0..<count).map { i in (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[i * 4 + $1]) << (8 * UInt32($1)) } }
    }

    @Test("AArch64 tbz/cbz/b.cond out of range relax to an inverted branch over B")
    func a64Relaxation() {
        let (text, errors, _) = Self.assemble("""
            tbz x0, #1, far
            cbz x1, far2
            b.eq far2
            .space 40000
        far: nop
            .space 1100000
        far2: nop
        """, .aarch64)
        #expect(errors == 0)
        // tbnz w0,#1,+8 ; b far | cbnz x1,+8 ; b far2 | b.ne +8 ; b far2   (decoded with llvm-objdump)
        #expect(Self.words(text, count: 6) == [0x3708_0040, 0x1400_2715, 0xB500_0041, 0x1404_594C, 0x5400_0041, 0x1404_594A])
    }

    @Test("RISC-V branches relax compressed -> 32-bit -> inverted branch over jal; jal out of range is an error")
    func rvRelaxation() {
        let (text, errors, _) = Self.assemble("""
            beqz a0, far
            beq a1, a2, far
            j near
        near: nop
            .space 5000
        far: nop
        """, .riscv64)
        #expect(errors == 0)
        // c.bnez a0,+6 ; j far | bne a1,a2,+8 ; j far | c.j near (llvm-mc 22: a compressible branch inverts to `c.bnez`)
        #expect(Array(text[0..<2]) == [0x19, 0xE1])
        #expect(Self.words(Array(text[2...]), count: 3) == [0x3980_106F, 0x00C5_9463, 0x3900_106F])
        #expect(Array(text[14..<16]) == [0x09, 0xA0])

        let (_, rangeErrors, _) = Self.assemble("j far\n.space 1100000\nfar: nop\n", .riscv64)
        #expect(rangeErrors == 1)
    }

    @Test("RISC-V jump to an external symbol is laid out at its 4-byte relocated size")
    func rvExternalJumpLayout() throws {
        let (text, errors, symbols) = Self.assemble("j ext\nnop\nlbl: nop\n.globl lbl\n", .riscv64)
        #expect(errors == 0)
        #expect(text.count == 8)
        #expect(symbols["lbl"] == 6)
    }

    @Test("Instructions the encoder rejects are diagnosed, never silently dropped")
    func rejectedInstructionsAreDiagnosed() {
        #expect(Self.assemble("ldp x0, x1, [sp, #255]\n", .aarch64).errors == 1)
        #expect(Self.assemble("cbz x0, #3\n", .aarch64).errors == 1)
    }

    @Test("AArch64 `ldr Xt, #imm` uses the PC-relative literal form")
    func a64LdrLiteralImmediate() {
        let (text, errors, _) = Self.assemble("ldr x0, #64\nldr w3, #-8\n", .aarch64)
        #expect(errors == 0)
        #expect(Self.words(text, count: 2) == [0x5800_0200, 0x18FF_FFC3])
    }

    @Test("x86-64 16-bit tzcnt/lzcnt/popcnt keep the 0x66 operand-size prefix")
    func x86BitCount16() {
        #expect(Self.assemble("tzcnt %cx, %dx\n", .x86_64).text == [0x66, 0xF3, 0x0F, 0xBC, 0xD1])
        #expect(Self.assemble("popcnt %cx, %dx\n", .x86_64).text == [0x66, 0xF3, 0x0F, 0xB8, 0xD1])
        #expect(Self.assemble("tzcnt %ecx, %edx\n", .x86_64).text == [0xF3, 0x0F, 0xBC, 0xD1])
    }

    private static func le64(_ values: [Int64]) -> [UInt8] {
        values.flatMap { v in (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    }

    @Test("`.cfi_*` emit DW_CFA_advance_loc/1/2/4 and one FDE per procedure, as LLVM MC")
    func cfiAdvanceLoc() {
        let a = Self.assembleObject("""
            .text
        f:
            .cfi_startproc
            pushq %rbp
            .cfi_def_cfa_offset 16
            .space 100, 0x90
            .cfi_offset %rbp, -16
            .space 300, 0x90
            .cfi_def_cfa_register %rbp
            .space 70000, 0x90
            .cfi_def_cfa %rsp, 8
            ret
            .cfi_endproc
        g:
            .cfi_startproc
            subq $24, %rsp
            .cfi_adjust_cfa_offset 24
            ret
            .cfi_endproc
        """, .x86_64)
        #expect(a.errors == 0)
        // llvm-mc 21 (`llvm-objdump -s -j .eh_frame`; GNU as 2.46 agrees): CIE, FDE f (advance_loc 1, advance_loc1
        // 100, advance_loc2 300, advance_loc4 70000), FDE g (advance_loc 4)
        #expect(a.sections[".eh_frame"] == [
            0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7A, 0x52, 0x00, 0x01, 0x78, 0x10, 0x01,
            0x1B, 0x0C, 0x07, 0x08, 0x90, 0x01, 0x00, 0x00, 0x24, 0x00, 0x00, 0x00, 0x1C, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x02, 0x13, 0x01, 0x00, 0x00, 0x41, 0x0E, 0x10, 0x02, 0x64, 0x86, 0x02,
            0x03, 0x2C, 0x01, 0x0D, 0x06, 0x04, 0x70, 0x11, 0x01, 0x00, 0x0C, 0x07, 0x08, 0x00, 0x00, 0x00,
            0x14, 0x00, 0x00, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
            0x00, 0x44, 0x0E, 0x20, 0x00, 0x00, 0x00, 0x00,
        ])
        let relocs = a.relocs[".eh_frame"] ?? []
        #expect(relocs.map(\.offset) == [0x20, 0x48])
        // PC-begin of each FDE: .text + 0 and .text + 0x11302 (local targets compared as section + offset)
        #expect(relocs.map { r in (a.symbols[r.symbol]?.value ?? 0) &+ UInt64(bitPattern: r.addend) } == [0, 0x11302])
        #expect(relocs.allSatisfy { a.symbols[$0.symbol]?.section == ".text" })
    }

    @Test("FDEs are grouped by CIE key as in LLVM MC, not kept in source order as in GNU as")
    func cfiFDEOrderByCIE() {
        let a = Self.assembleObject("""
            .text
        a:  .cfi_startproc
            pushq %rbp
            .cfi_def_cfa_offset 16
            popq %rbp
            ret
            .cfi_endproc
        b:  .cfi_startproc
            .cfi_signal_frame
            nop
            .cfi_def_cfa_offset 16
            ret
            .cfi_endproc
        c:  .cfi_startproc
            subq $8, %rsp
            .cfi_adjust_cfa_offset 8
            ret
            .cfi_endproc
        d:  .cfi_startproc simple
            .cfi_def_cfa %rsp, 8
            ret
            .cfi_endproc
        e:  .cfi_startproc
            .cfi_return_column 16
            ret
            .cfi_endproc
        f:  .cfi_startproc
            .cfi_return_column 5
            .cfi_signal_frame
            ret
            .cfi_endproc
        g:  .cfi_startproc
            ret
            .cfi_endproc
        """, .x86_64)
        #expect(a.errors == 0)
        // llvm-mc 21: FDEs stable-sorted by (signal frame, simple, return column; an explicit column sorts before
        // the default and gets its own CIE even when equal to it), one CIE before each group:
        // CIE, e | CIE, a, c, g | CIE (simple), d | CIE zRS ra=5, f | CIE zRS, b
        #expect(a.sections[".eh_frame"] == [
            0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7A, 0x52, 0x00, 0x01, 0x78, 0x10, 0x01,
            0x1B, 0x0C, 0x07, 0x08, 0x90, 0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x1C, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x7A, 0x52, 0x00, 0x01, 0x78, 0x10, 0x01, 0x1B, 0x0C, 0x07, 0x08,
            0x90, 0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x1C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0x00, 0x41, 0x0E, 0x10, 0x10, 0x00, 0x00, 0x00, 0x30, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x44, 0x0E, 0x10, 0x10, 0x00, 0x00, 0x00,
            0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7A, 0x52, 0x00, 0x01, 0x78, 0x10, 0x01,
            0x1B, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x07, 0x08, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x7A, 0x52, 0x53, 0x00, 0x01, 0x78, 0x05, 0x01, 0x1B, 0x0C, 0x07, 0x08, 0x90, 0x01, 0x00,
            0x10, 0x00, 0x00, 0x00, 0x1C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7A, 0x52, 0x53,
            0x00, 0x01, 0x78, 0x10, 0x01, 0x1B, 0x0C, 0x07, 0x08, 0x90, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00,
            0x1C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x41, 0x0E, 0x10,
        ])
        let relocs = a.relocs[".eh_frame"] ?? []
        #expect(relocs.map(\.offset) == [0x20, 0x4C, 0x60, 0x74, 0x9C, 0xC8, 0xF4])
        // pc_begin targets in emission order: e, a, c, g, d, f, b
        #expect(relocs.map { r in (a.symbols[r.symbol]?.value ?? 0) &+ UInt64(bitPattern: r.addend) } == [0xB, 0x0, 0x5, 0xD, 0xA, 0xC, 0x3])

        // LLVM MC rejects CFI outside a procedure and a procedure started inside another
        let bad = Self.assembleObject(".cfi_def_cfa_offset 16\n.cfi_startproc\n.cfi_startproc\n.cfi_endproc\n.cfi_endproc\n", .x86_64, fileName: "cfi.s")
        #expect(bad.errors == 3)
        #expect(bad.rendered.contains("cfi.s:1:1: error: this directive must appear between .cfi_startproc and .cfi_endproc directives"))
        #expect(bad.rendered.contains("cfi.s:3:1: error: starting new .cfi frame before finishing the previous one"))
        #expect(bad.rendered.contains("cfi.s:5:1: error: this directive must appear between .cfi_startproc and .cfi_endproc directives"))
    }

    @Test("`.equ`/`.set` of a label difference resolve to constants, including forward references")
    func equLabelDifference() {
        let a = Self.assembleObject("""
            .text
        start:
            movl $len, %eax
            ret
        end:
            .equ len, fwd_end - fwd_start
            .set code_len, end - start
            .size start, code_len
            .data
            .long len, code_len
        fwd_start:
            .ascii "abcdefg"
        fwd_end:
        """, .x86_64)
        #expect(a.errors == 0)
        #expect(a.sections[".text"] == [0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3])
        #expect(a.sections[".data"] == [0x07, 0, 0, 0, 0x06, 0, 0, 0] + Array("abcdefg".utf8))
        #expect(a.relocs[".text"]?.isEmpty ?? true)
        #expect(a.relocs[".data"]?.isEmpty ?? true)
        #expect(a.symbols["len"]?.section == "*ABS*" && a.symbols["len"]?.value == 7)
        #expect(a.symbols["code_len"]?.section == "*ABS*" && a.symbols["code_len"]?.value == 6)
        #expect(a.symbols["start"]?.size == 6)

        // llvm-mc 21: a fixed label difference in another section is folded at once, so reassigning the symbol
        // later does not change an earlier use
        let reassigned = Self.assembleObject(".text\na: nop\nmovl $1, %eax\nb:\n.data\n.set y, b - a\n.byte y\n.set y, 3\n.byte y\n", .x86_64)
        #expect(reassigned.errors == 0)
        #expect(reassigned.sections[".data"] == [6, 3])
    }

    @Test("Expressions use LLVM MC's ELF (GNU-compatible) operator precedence and semantics")
    func gnuExpressionPrecedence() {
        let a = Self.assembleObject("""
            .data
            .quad 1 + 2 << 3, 2 << 3 + 1, 6 & 3 * 2, 1 | 2 ^ 3, 3 + 1 | 1
            .quad 1 < 2, 2 < 1, 1 <> 2, 3 >= 3, 1 == 1 && 2 == 2, 1 || 0 && 0
            .quad 5 ! 1, -7 / 2, -7 % 2, -16 >> 2, ~1 & 3, !1 + 1, 2 > 1 + 1
        """, .x86_64)
        #expect(a.errors == 0)
        // llvm-mc 21 (GNU as 2.46 agrees): `<<` binds tighter than `+`, `| ^ & !` share a level above `+ -`,
        // comparisons yield -1, `>>` is a logical shift
        #expect(a.sections[".data"] == Self.le64([
            17, 17, 6, 0, 4,
            -1, 0, -1, -1, 1, 1,
            -1, -3, -1, 0x3FFF_FFFF_FFFF_FFFC, 2, 1, 0,
        ]))
    }

    @Test("`.macro` parameters with `:req`, `:vararg`, defaults and `\\()` concatenation")
    func macroVarargReq() {
        let a = Self.assembleObject("""
            .macro emit first:req, rest:vararg
            .byte \\first
            .ifnb \\rest
            .byte \\rest
            .endif
            .endm
            .macro lbl name, n=3
        \\name\\()_\\n:
            .byte \\n
            .endm
            .data
            emit 1, 2, 3, 4
            emit 5
            lbl foo
            lbl bar, 9
            emit 6 7, 8
            emit 9 -2
        """, .x86_64)
        #expect(a.errors == 0)
        // llvm-mc 21. A blank separates arguments unless an operator follows it (`emit 6 7, 8` passes `6` and
        // `7, 8`; `emit 9 -2` passes `9-2` as one argument, where GNU as passes `9` and `-2`), and a `:vararg`
        // parameter takes the rest of the line verbatim.
        #expect(a.sections[".data"] == [1, 2, 3, 4, 5, 3, 9, 6, 7, 8, 7])
        #expect(a.symbols["foo_3"]?.value == 5)
        #expect(a.symbols["bar_9"]?.value == 6)

        let missing = Self.assembleObject(".macro m a:req\n.byte \\a\n.endm\nm\n", .x86_64, fileName: "req.s")
        #expect(missing.errors == 1)
        #expect(missing.rendered.contains("req.s:4:1: error: missing value for required parameter 'a' in macro 'm'"))

        // Runaway recursion is diagnosed at LLVM MC's 20-level limit, not a stack overflow
        let recursive = Self.assembleObject(".macro r\nr\n.endm\nr\n", .x86_64, fileName: "rec.s")
        #expect(recursive.errors == 1)
        #expect(recursive.rendered.contains("rec.s:2:1: error: macros cannot be nested more than 20 levels deep"))
        #expect(recursive.rendered.contains("rec.s:4:1: note: in expansion of macro 'r'"))
    }

    @Test("Macro and `.irp` arguments split, substitute and number (`\\@`) as in LLVM MC")
    func macroArgumentsLLVM() {
        let a = Self.assembleObject("""
            .macro two a, b=100
            .byte \\a
            .byte \\b
            .endm
            .macro str s
            .ascii "<\\s>"
            .endm
            .macro at
            .byte \\@
            .endm
            .data
            at
            at
            two 1 2
            two 3 -4
            two 5 - 6
            two -9 10
            two (1 + 2) 4
            two 6 <<1
            two , 17
            two b=18, a=19
            str "a b"
            .irp r, 1 2, 4 -1
            .byte \\r
            .endr
            .irp r, 5, , 7
            .byte 9\\r
            .endr
            .irp r,
            .byte 0xEE
            .endr
            .irpc c, 789
            .byte \\c
            .endr
        """, .x86_64)
        #expect(a.errors == 0)
        // llvm-mc 21: an operator joins blank-separated tokens (`3 -4` is `3-4`), only parentheses group, a string
        // argument loses its quotes, `\\@` counts from 0, and `.irp` values split like macro arguments
        // (`.irp r,` iterates zero times)
        #expect(a.sections[".data"] == [
            0, 1, 1, 2, 0xFF, 100, 0xFF, 100, 0xF7, 10, 3, 4, 12, 100, 17, 19, 18,
        ] + Array("<a b>".utf8) + [1, 2, 3, 95, 9, 97, 7, 8, 9])

        // Rejected by llvm-mc 21 with these messages (the previous GNU-style parser accepted most of them silently)
        let bad = Self.assembleObject("""
            .macro two a, b=100
            .byte \\a, \\b
            .endm
            .macro none
            .endm
            .data
            two b=1, 2
            two c=1
            two 1, 2, 3
            two (1
            two 1=2
            none 5
            .macro bad x:foo
            .endm
            .macro dup x, x
            .endm
            .macro va x:vararg, y
            .endm
            .macro two
            .endm
            .purgem nosuch
            .irp r 1 2
            .endr
            .irpc c, ab cd
            .endr
        """, .x86_64, fileName: "m.s")
        #expect(bad.errors == 13)
        for expected in [
            "m.s:7:5: error: cannot mix positional and keyword arguments",
            "m.s:8:5: error: parameter named 'c' does not exist for macro 'two'",
            "m.s:9:5: error: too many positional arguments",
            "m.s:10:5: error: unbalanced parentheses in macro argument",
            "m.s:11:5: error: unexpected token in macro instantiation",
            "m.s:12:5: error: Wrong number of arguments",
            "m.s:13:5: error: foo is not a valid parameter qualifier for 'x' in macro 'bad'",
            "m.s:15:5: error: macro 'dup' has multiple parameters named 'x'",
            "m.s:17:5: error: vararg parameter 'x' should be the last parameter",
            "m.s:19:5: error: macro 'two' is already defined",
            "m.s:21:5: error: macro 'nosuch' is not defined",
            "m.s:22:5: error: expected comma",
            "m.s:24:5: error: unexpected token in '.irpc' directive",
        ] {
            #expect(bad.rendered.contains(expected), Comment(rawValue: expected))
        }
        let warn = Self.assembleObject(".macro rq x:req=3\n.endm\n", .x86_64, fileName: "w.s")
        #expect(warn.errors == 0)
        #expect(warn.rendered.contains("w.s:1:1: warning: pointless default value for required parameter 'x' in macro 'rq'"))
    }

    @Test("Assembler diagnostics carry file:line:col through .include, macros, .rept and .S preprocessing")
    func diagnosticLocations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-asm-loc-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inc = dir.appendingPathComponent("inc.s").path
        let hdr = dir.appendingPathComponent("defs.h").path
        try "nop\n  bogus1 %eax\n".write(toFile: inc, atomically: true, encoding: .utf8)
        try "#define BAD bogus3 %ecx\n\n  bogus4\n".write(toFile: hdr, atomically: true, encoding: .utf8)

        let plain = Self.assembleObject("""
            .macro m
            nop
            bogus2
            .endm
            .include "\(inc)"
            m
            .rept 2
              bogus5
            .endr
            bogus6
        """, .x86_64, fileName: "plain.s")
        #expect(plain.errors == 5)
        #expect(plain.rendered.contains("\(inc):2:3: error: invalid instruction 'bogus1 %eax'"))
        #expect(plain.rendered.contains("plain.s:3:5: error: invalid instruction 'bogus2'"))
        #expect(plain.rendered.contains("plain.s:6:5: note:"))
        #expect(plain.rendered.contains("plain.s:8:7: error: invalid instruction 'bogus5'"))
        #expect(plain.rendered.contains("plain.s:10:5: error: invalid instruction 'bogus6'"))

        let src = dir.appendingPathComponent("pp.S").path
        try """
        #include "defs.h"
        /* comment
           spanning lines */
            nop
            BAD
        #if 1

            bogus7
        #endif
        """.write(toFile: src, atomically: true, encoding: .utf8)
        var diags = DiagnosticBag()
        let sm = SourceManager()
        let obj = try Assembler.assembleFile(path: src, arch: .x86_64, sourceManager: sm, diagnostics: &diags)
        let pp = Self.describe(obj, diags: diags, sourceManager: sm)
        #expect(pp.errors == 3)
        #expect(pp.rendered.contains("\(hdr):3:3: error: invalid instruction 'bogus4'"))
        #expect(pp.rendered.contains("\(src):5:5: error: invalid instruction 'bogus3 %ecx'"))
        #expect(pp.rendered.contains("\(src):8:5: error: invalid instruction 'bogus7'"))
    }

    @Test("`A - B` with `B` in the current section is a PC-relative relocation against `A` (VectraOS vDSO header)")
    func differenceAgainstCurrentSectionLabel() {
        // VectraOS user/vdso/header.S: `.long <entry point> - vdso_header` for each vDSO entry, defined in
        // vdso.c. LLVM MC folds `P - B` into the addend: `ext - hdr` at offset 4 is `ext - P + 4`.
        let src = """
            .section .vdso.header, "a"
            .balign 16
            hdr:
                .long 0x53445643
                .long ext - hdr
                .quad ext2 - hdr + 4
            """
        for (arch, pc32, pc64) in [(AssemblerArch.x86_64, RelocKind.x86_64_pc32, RelocKind.x86_64_pc64),
                                   (.aarch64, .aarch64_prel32, .aarch64_prel64)] {
            var diags = DiagnosticBag()
            let obj = Assembler.assemble(source: src, arch: arch, diagnostics: &diags)
            #expect(diags.errorCount == 0, "\(arch)")
            guard let sec = obj.findSection(name: ".vdso.header") else {
                Issue.record("\(arch): no .vdso.header")
                continue
            }
            let relocs = obj.relocs(for: sec).map { ($0.offset, obj.symbolName($0.symbol), $0.addend, $0.kind) }
            #expect(relocs.count == 2, "\(arch)")
            guard relocs.count == 2 else { continue }
            #expect(relocs[0] == (4, "ext", 4, pc32), "\(arch)")
            #expect(relocs[1] == (8, "ext2", 12, pc64), "\(arch)")
        }
    }

    @Test("RISC-V `-march` without Zbs, and linker relaxation's R_RISCV_RELAX/R_RISCV_ALIGN (VectraOS rv64 kernel)")
    func riscvKernelISAAndRelaxation() {
        // VectraOS builds its rv64 kernel for rv64imac_zicsr_zifencei, PIE, with clang's default relaxation.
        let src = """
                li t0, (8 << 60)
                call ext
                .balign 8
            1:  j 1b
            """
        var diags = DiagnosticBag()
        let opts = RVAsmOptions(march: "rv64imac_zicsr_zifencei", pic: true, relax: true)
        let obj = Assembler.assemble(source: src, arch: .riscv64, riscvOptions: opts, diagnostics: &diags)
        #expect(diags.errorCount == 0)
        guard let text = obj.findSection(name: ".text") else {
            Issue.record("no .text")
            return
        }
        // `c.li t0, -1; c.slli t0, 63` (no `bseti`), `call`, worst-case `c.nop; nop` padding, `c.j` to itself
        #expect(obj.sectionData(text) == [0xfd, 0x52, 0xfe, 0x12, 0x97, 0x00, 0x00, 0x00, 0xe7, 0x80, 0x00, 0x00,
                                          0x01, 0x00, 0x13, 0x00, 0x00, 0x00, 0x01, 0xa0])
        let relocs = obj.relocs(for: text).map { ($0.offset, $0.symbol.isValid ? obj.symbolName($0.symbol) : "", $0.addend, $0.kind) }
        #expect(relocs.count == 3)
        guard relocs.count == 3 else { return }
        #expect(relocs[0] == (4, "ext", 0, RelocKind.riscv_call_plt))
        #expect(relocs[1] == (4, "", 0, RelocKind.riscv_relax))
        #expect(relocs[2] == (12, "", 6, RelocKind.riscv_align))
    }

    @Test("ELF reader rejects truncated and corrupted objects with an error, never a crash")
    func elfReaderFuzz() throws {
        var seeds: [[UInt8]] = []
        for (src, arch) in [
            (".text\nf: .cfi_startproc\ncall g\nret\n.cfi_endproc\n.data\n.quad f, g + 4\n.bss\n.zero 8\n", AssemblerArch.x86_64),
            (".text\nf: bl g\nadrp x0, h\nret\n.data\n.quad h\n", .aarch64),
            (".text\nf: call g\nla a0, h\nret\n", .riscv64),
        ] {
            var diags = DiagnosticBag()
            let obj = Assembler.assemble(source: src, arch: arch, diagnostics: &diags)
            #expect(diags.errorCount == 0)
            let bytes = ELFObjectWriter.write(obj)
            _ = try ELFObjectReader.read(bytes: bytes)
            seeds.append(bytes)
        }

        // Deterministic xorshift64* so failures reproduce
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
        var rejected = 0
        for seed in seeds {
            // Every truncation
            for len in 0..<seed.count {
                if (try? ELFObjectReader.read(bytes: Array(seed[..<len]))) == nil { rejected += 1 }
            }
            for _ in 0..<4000 {
                var m = seed
                for _ in 0..<(1 + Int(next() % 4)) {
                    let at = Int(next() % UInt64(m.count))
                    switch next() % 4 {
                    case 0: m[at] = UInt8(truncatingIfNeeded: next())
                    case 1: m[at] ^= 1 << UInt8(next() % 8)
                    case 2: m[at] = 0xFF
                    default:  // overwrite a 4/8-byte field with a boundary value
                        let width = next() % 2 == 0 ? 4 : 8
                        let values: [UInt64] = [0, 1, 0x7FFF_FFFF, 0xFFFF_FFFF, UInt64(m.count), .max, 1 << 63]
                        let v = values[Int(next() % UInt64(values.count))]
                        for k in 0..<width where at + k < m.count { m[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) }
                    }
                }
                if (try? ELFObjectReader.read(bytes: m)) == nil { rejected += 1 }
            }
        }
        #expect(rejected > 0)
    }

    // MARK: clang -S directives, local-symbol relocations, RISC-V relaxation, `.rept`, `.include` (LLVM MC 22)

    /// Assembles `src` and parses the serialized object with the test-only ELF reader.
    private static func elf(_ src: String, _ arch: AssemblerArch, riscv: RVAsmOptions = RVAsmOptions()) throws -> (elf: TestELF, errors: Int, rendered: String) {
        var diags = DiagnosticBag()
        let sm = SourceManager()
        let obj = Assembler.assemble(source: src, arch: arch, fileName: "t.s", riscvOptions: riscv, sourceManager: sm, diagnostics: &diags)
        return (try TestELF(bytes: ELFObjectWriter.write(obj)), diags.errorCount, DiagnosticRenderer.render(diagnostics: diags, sourceManager: sm))
    }

    /// The relocations of `section` as `offset type target+addend`, a section symbol written `[sec name]`.
    private static func relocs(_ e: TestELF, _ section: String) -> [String] {
        e.relas.filter { e.sections[$0.targetSection].name == section }.map { r in
            let sym = e.symbols[r.symbol]
            let target = r.symbol == 0 ? "-" : (sym.type == TestELF.STT_SECTION ? "[sec \(e.sections[Int(sym.shndx)].name)]" : sym.name)
            return "\(r.offset) \(r.type) \(target)\(r.addend >= 0 ? "+" : "")\(r.addend)"
        }
    }

    private static func section(_ e: TestELF, _ name: String) -> TestELF.Section? { e.sections.first { $0.name == name } }

    @Test("AArch64 `.aeabi_subsection`/`.aeabi_attribute` build `.ARM.attributes` byte for byte as llvm-mc 22")
    func a64BuildAttributes() throws {
        let (e, errors, _) = try Self.elf("""
            .aeabi_subsection aeabi_pauthabi, required, uleb128
            .aeabi_attribute Tag_PAuth_Platform, 5
            .aeabi_attribute 2, 7
            .aeabi_subsection aeabi_feature_and_bits, optional, ULEB128
            .aeabi_attribute Tag_Feature_BTI, 1
            .aeabi_attribute Tag_Feature_BTI, 0
            .aeabi_subsection private_x, required, ntbs
            .aeabi_attribute 7, "hello"
            .aeabi_subsection aeabi_pauthabi
            .aeabi_attribute 1, 3
            nop
        """, .aarch64)
        #expect(errors == 0)
        let attributes = try #require(Self.section(e, ".ARM.attributes"))
        #expect(attributes.type == 0x7000_0003 && attributes.flags == 0 && attributes.align == 1)
        // llvm-mc 22 (`llvm-readelf -x .ARM.attributes`): a later value replaces a tag in place; an NTBS value keeps
        // its quotes
        let expected: [UInt8] = [0x41, 0x19, 0, 0, 0] + Array("aeabi_pauthabi".utf8) + [0, 0, 0, 1, 3, 2, 7]
            + [0x1F, 0, 0, 0] + Array("aeabi_feature_and_bits".utf8) + [0, 1, 0, 0, 0]
            + [0x19, 0, 0, 0] + Array("private_x".utf8) + [0, 0, 1, 7] + Array("\"hello\"".utf8) + [0]
        #expect(attributes.data == expected)
        #expect(e.symbols.contains { $0.name == "$d" && e.sections[Int($0.shndx)].name == ".ARM.attributes" })
    }

    @Test("AArch64 build-attribute directives are diagnosed with LLVM MC's messages")
    func a64BuildAttributeDiagnostics() throws {
        let cases: [(String, String)] = [
            (".aeabi_attribute 1, 1", "no active subsection, build attribute can not be added"),
            (".aeabi_subsection aeabi_feature_and_bits, required, uleb128", "aeabi_feature_and_bits must be marked as optional"),
            (".aeabi_subsection aeabi_pauthabi, required, ntbs", "aeabi_pauthabi must be marked as ULEB128"),
            (".aeabi_subsection foo", "Could not switch to subsection 'foo' using subsection name, subsection has not been defined"),
            (".aeabi_subsection f, Optional, uleb128", "unknown AArch64 build attributes optionality, expected required|optional"),
            (".aeabi_subsection f, optional, uleb128\n.aeabi_subsection f, optional, ntbs",
             "type mismatch! subsection 'f' already exists with type defined as 'uleb128' and not 'ntbs'"),
            (".aeabi_subsection aeabi_feature_and_bits, optional, uleb128\n.aeabi_attribute Tag_Feature_GCS, 2",
             "unknown AArch64 build attributes Value for Tag 'Tag_Feature_GCS' options are 0|1"),
            (".aeabi_subsection aeabi_feature_and_bits, optional, uleb128\n.aeabi_attribute Tag_PAuth_Platform, 1",
             "unknown AArch64 build attribute 'Tag_PAuth_Platform' for subsection 'aeabi_feature_and_bits'"),
            (".aeabi_subsection f, optional, ntbs\n.aeabi_attribute 0, 1", "active subsection type is NTBS (string), found ULEB128 (unsigned)"),
        ]
        for (src, message) in cases {
            let (_, errors, rendered) = try Self.elf(src + "\n", .aarch64)
            #expect(errors == 1, "\(src)")
            #expect(rendered.contains(message), "\(src): \(rendered)")
        }
    }

    @Test("`.xword` (AArch64) and `.dword` (AArch64, RISC-V) are 8-byte data; x86-64 rejects both, as llvm-mc does")
    func eightByteDataDirectives() throws {
        #expect(Self.assemble(".xword 1, 0x123456789\n.dword -1\n", .aarch64).text == Self.le64([1, 0x1_2345_6789, -1]))
        #expect(Self.assemble(".dword 2\n.half 3\n", .riscv64).text == Self.le64([2]) + [3, 0])
        #expect(Self.assemble(".xword 1\n", .riscv64).errors == 1)
        #expect(Self.assemble(".xword 1\n", .x86_64).errors == 1)
        #expect(Self.assemble(".dword 1\n", .x86_64).errors == 1)
    }

    @Test("`.file`, `.ident` and `.addrsig` give the STT_FILE symbol, `.comment` and `.llvm_addrsig` of LLVM MC")
    func objectMetadataDirectives() throws {
        let (e, errors, _) = try Self.elf("""
            .file "t.c"
            .text
        f:  nop
        .Ll: nop
            .ident "one"
            .ident "two"
            .addrsig
            .addrsig_sym f
            .addrsig_sym .Ll
            .addrsig_sym undef
        """, .aarch64)
        #expect(errors == 0)
        #expect(e.symbols.contains { $0.name == "t.c" && $0.type == TestELF.STT_FILE && $0.shndx == TestELF.SHN_ABS })
        let comment = try #require(Self.section(e, ".comment"))
        #expect(comment.data == [0] + Array("one".utf8) + [0] + Array("two".utf8) + [0])
        #expect(comment.flags == TestELF.SHF_MERGE | TestELF.SHF_STRINGS && comment.entsize == 1)
        let addrsig = try #require(Self.section(e, ".llvm_addrsig"))
        #expect(addrsig.type == 0x6FFF_4C03 && addrsig.flags == 0x8000_0000)
        // ULEB128 `.symtab` indices: `f`, the section symbol standing for `.Ll`, and `undef` (now in `.symtab`)
        let listed = addrsig.data.map { Int($0) }.map { e.symbols[$0].type == TestELF.STT_SECTION ? "[sec]" : e.symbols[$0].name }
        #expect(listed == ["f", "[sec]", "undef"])
        #expect(!e.symbols.contains { $0.name == ".Ll" })
        // Mapping symbols: `$x` in .text, `$d` in .comment
        #expect(e.symbols.filter { $0.name == "$x" }.count == 1 && e.symbols.filter { $0.name == "$d" }.count == 1)
    }

    @Test("AArch64 mapping symbols mark each change between code and data; a TLS section's are STT_TLS")
    func a64MappingSymbols() throws {
        let (e, errors, _) = try Self.elf("""
            nop
            .word 1
            .word 2
            nop
            .section .tbss,"awT",@nobits
            .zero 8
            .text
            nop
        """, .aarch64)
        #expect(errors == 0)
        let mapping = e.symbols.filter { $0.name.hasPrefix("$") }.map { "\($0.name)@\(e.sections[Int($0.shndx)].name)+\($0.value) type=\($0.type)" }
        #expect(mapping.sorted() == ["$d@.tbss+0 type=6", "$d@.text+4 type=0", "$x@.text+0 type=0", "$x@.text+12 type=0"])
    }

    @Test("Relocations against local symbols use the section symbol plus offset (x86-64, AArch64), as LLVM MC does")
    func localSymbolRelocations() throws {
        let (e, errors, _) = try Self.elf("""
            .text
            call loc
            call loc@PLT
            leaq .Lstr(%rip), %rax
            movl $.Lstr, %eax
            movq loc@GOTPCREL(%rip), %rax
            .section .text.o,"ax",@progbits
            nop
        loc: nop
            .section .rodata.str1.1,"aMS",@progbits,1
        .Lstr: .asciz "hi"
            .data
            .quad .Ld
        .Ld: .quad loc+3
        """, .x86_64)
        #expect(errors == 0)
        // llvm-mc 22: `call loc` and `movl $.Lstr` take the section symbol; `@PLT`, a mergeable section with a nonzero
        // addend and GOT loads keep the symbol (`R_X86_64_REX_GOTPCRELX` for the relaxable `movq` load)
        #expect(Self.relocs(e, ".text") == ["1 4 [sec .text.o]-3", "6 4 loc-4", "13 2 .Lstr-4", "18 10 [sec .rodata.str1.1]+0", "25 42 loc-4"])
        #expect(Self.relocs(e, ".data") == ["0 1 [sec .data]+8", "8 1 [sec .text.o]+4"])
        #expect(!e.symbols.contains { $0.name == ".Ld" })
        #expect(e.symbols.contains { $0.name == ".Lstr" })
        #expect(Self.section(e, ".rodata.str1.1")?.entsize == 1)
    }

    @Test("RISC-V relocations keep local and `.L` symbols (LLVM MC's RISC-V `needsRelocateWithSymbol`)")
    func riscvLocalSymbolRelocations() throws {
        let (e, errors, _) = try Self.elf("""
            .text
            .dword .Ldat
            .dword dat+4
            .data
        dat: .dword 1
        .Ldat: .dword 2
        """, .riscv64)
        #expect(errors == 0)
        #expect(Self.relocs(e, ".text") == ["0 2 .Ldat+0", "8 2 dat+4"])
    }

    @Test("A branch to a global symbol in its own section is relocated, never resolved (the symbol may be preempted)")
    func branchToGlobalSymbol() throws {
        let x86 = try Self.elf(".globl g\njmp g\njne g\ng: nop\n", .x86_64)
        #expect(x86.errors == 0)
        #expect(Self.relocs(x86.elf, ".text") == ["1 4 g-4", "7 4 g-4"])
        let a64 = try Self.elf(".globl g\nb g\ncbz x0, g\ng: nop\n", .aarch64)
        #expect(Self.relocs(a64.elf, ".text") == ["0 282 g+0", "4 280 g+0"])
        // RISC-V: relaxed to an inverted branch over `jal` (`c.bnez a0, +6`), as for an undefined target
        let rv = try Self.elf(".globl g\nbeqz a0, g\nbeq a1, a2, g\ng: nop\n", .riscv64)
        #expect(Self.relocs(rv.elf, ".text") == ["2 17 g+0", "10 17 g+0"])
        #expect(Array(rv.elf.sections.first { $0.name == ".text" }!.data.prefix(2)) == [0x19, 0xE1])
    }

    @Test("RISC-V under relaxation (llvm-mc 22): forward branches keep relocations, `jal` gets R_RISCV_RELAX, and code alignment is relaxed only after a branch or relaxable instruction")
    func riscvRelaxationRules() throws {
        let relax = RVAsmOptions(march: "rv64gc", relax: true)
        let (e, errors, _) = try Self.elf("""
            .p2align 3
            nop
            beqz a0, 1f
            nop
        1:  nop
            beqz a0, 1b
            j ext
            .p2align 3
            nop
        """, .riscv64, riscv: relax)
        #expect(errors == 0)
        // llvm-mc -mattr=+c,+relax: the first `.p2align` pads nothing (nothing relaxable before it), the forward
        // `c.beqz` gets R_RISCV_RVC_BRANCH, the backward one is folded, `j ext` is `jal` + R_RISCV_JAL + R_RISCV_RELAX,
        // the second `.p2align` emits 6 bytes of NOPs + R_RISCV_ALIGN
        #expect(Self.relocs(e, ".text") == ["2 44 .Ltmp0+0", "10 17 ext+0", "10 51 -+0", "14 43 -+6"])
        #expect(Self.section(e, ".text")?.size == 22)
    }

    @Test("RISC-V `.attribute` builds `.riscv.attributes`; `arch` resets compression; e_flags follow -march/-mabi")
    func riscvAttributes() throws {
        let (e, errors, _) = try Self.elf("""
            .attribute 4, 16
            .attribute arch, "rv64i2p1_m2p0"
            .attribute unaligned_access, 1
            nop
        """, .riscv64, riscv: RVAsmOptions(march: "rv64gc", abi: "lp64"))
        #expect(errors == 0)
        // clang-22 -march=rv64gc -mabi=lp64 -c: Tag_RISCV_arch (from -march) first, replaced in place
        let contents: [UInt8] = [5] + Array("rv64i2p1_m2p0".utf8) + [0, 4, 16, 6, 1]
        let vendor: [UInt8] = Array("riscv".utf8) + [0, 1] + [UInt8(5 + contents.count), 0, 0, 0] + contents
        #expect(Self.section(e, ".riscv.attributes")?.data == [0x41, UInt8(4 + vendor.count), 0, 0, 0] + vendor)
        #expect(Self.section(e, ".text")?.data == [0x13, 0, 0, 0])   // no C after `.attribute arch`
        #expect(e.flags == 0x1)                                      // EF_RISCV_RVC (from -march), soft-float ABI
        #expect(RVAsmOptions(march: "rv64gc_zba_zbb_zbs_v").targetArchAttribute == "rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_b1p0_v1p0_zicsr2p0_zifencei2p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0_zcd1p0_zba1p0_zbb1p0_zbs1p0_zve32f1p0_zve32x1p0_zve64d1p0_zve64f1p0_zve64x1p0_zvl128b1p0_zvl32b1p0_zvl64b1p0")
    }

    @Test("x86-64 NOP padding uses LLVM MC's 10-byte `nopw %cs:` form")
    func x86TenByteNop() {
        let (text, errors, _) = Self.assemble("ret\n.p2align 4\nret\n", .x86_64)
        #expect(errors == 0)
        #expect(Array(text[1..<16]) == [0x66, 0x2E, 0x0F, 0x1F, 0x84, 0, 0, 0, 0, 0, 0x0F, 0x1F, 0x44, 0, 0])
    }

    @Test("`.rept` takes a label difference already laid out; otherwise LLVM MC's diagnostics")
    func reptLabelDifference() throws {
        let (text, errors, _) = Self.assemble("start: .long 1, 2, 3\nend:\n.rept (end - start) / 4\n.byte 0xaa\n.endr\n", .x86_64)
        #expect(errors == 0)
        #expect(Array(text.suffix(3)) == [0xAA, 0xAA, 0xAA])
        // Not absolute yet: across a relaxable branch, a forward reference, another section, an undefined symbol
        for src in ["a1: jmp a1\na2: .rept a2 - a1\nnop\n.endr\n", ".rept fwd - x\nnop\n.endr\nx: nop\nfwd:\n",
                    "x: nop\n.data\ny: .byte 0\n.text\n.rept y - x\n.endr\n", ".rept ext\n.endr\n"] {
            let a = Self.assembleObject(src, .x86_64)
            #expect(a.errors == 1, "\(src)")
            #expect(a.rendered.contains("t.s:") && a.rendered.contains("unexpected token in '.rept' directive"), "\(a.rendered)")
        }
        let negative = Self.assembleObject("a: .byte 0\nb:\n.rept a - b\nnop\n.endr\n", .x86_64)
        #expect(negative.errors == 1 && negative.rendered.contains("Count is negative"))
    }

    @Test("A self-including `.include` stops at 64 levels with an include-depth error and the include chain")
    func includeRecursion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_include_\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try ".include \"self.s\"\n".write(toFile: "\(dir)/self.s", atomically: true, encoding: .utf8)
        var diags = DiagnosticBag()
        let sm = SourceManager()
        _ = try Assembler.assembleFile(path: "\(dir)/self.s", arch: .x86_64, sourceManager: sm, diagnostics: &diags)
        let rendered = DiagnosticRenderer.render(diagnostics: diags, sourceManager: sm)
        #expect(diags.errorCount == 1)
        #expect(rendered.contains("'.include' nested too deeply (more than 64 levels)"))
        #expect(!rendered.contains("cannot open"))
        #expect(rendered.components(separatedBy: "in file included from here").count - 1 == 64)
    }
}
