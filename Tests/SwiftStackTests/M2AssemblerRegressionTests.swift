import Foundation
import Testing
@testable import SwiftStack

// Regressions for M2 assembler defects whose correct behavior has no clang/GNU oracle: clang reports
// out-of-range AArch64/RISC-V branches as errors, whereas 05-assembler.md §4.5 requires relaxing them.

@Suite("M2 — Assembler regressions")
struct M2AssemblerRegressionTests {

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
        // bnez a0,+8 ; j far | bne a1,a2,+8 ; j far | c.j near
        #expect(Self.words(text, count: 4) == [0x0005_1463, 0x3980_106F, 0x00C5_9463, 0x3900_106F])
        #expect(Array(text[16..<18]) == [0x09, 0xA0])

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
}
