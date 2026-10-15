import Foundation
import Testing
@testable import SwiftStack

// Exhaustive RV64 (RVA23) encoder/disassembler check: the M2 exit criterion "encoder/disassembler round-trip
// is exhaustive over the instruction tables" (09-roadmap.md §M2, 05-assembler.md §4.8).
//
// `RV64Sweep` generates, for EVERY descriptor in `RV64InstructionTable`, every operand form: each register
// operand swept over its whole register file (x0..x31, f0..f31, v0..v31, or x8..x15 for RVC 3-bit fields),
// masked and unmasked (`v0.t`), every rounding mode, every `aq`/`rl` pair, every immediate value of fields of
// up to 8 significant bits and min/max/every-bit/alternating-bit edges (honoring alignment) of wider ones,
// every `vtypei` (all 2048 `vsetvli` and 1024 `vsetivli` values, i.e. every SEW x LMUL x ta/tu x ma/mu plus the
// reserved encodings), every CSR number, every `fence` set pair, and every Zfa `fli` constant. 32-bit scalar
// descriptors also get operand combinations that probe RVC compression (x0, ra, sp, x8..x15, other registers;
// tied `rd == rs1`; immediates at the RVC field limits).
//
// Each form is encoded, disassembled, and re-encoded (bytes must be identical), with and without RVC. Then every
// disassembly is assembled by `llvm-mc -mattr=+rva23s64` (C/Zca/Zcb/Zcmop on, so LLVM compresses what it can:
// the bytes must equal `encode(rvcEnabled: true)`) and by `llvm-mc -mattr=+rva23s64,-c,-zca,-zcb,-zcd,-zcmop`
// (the bytes must equal `encode(rvcEnabled: false)`), and by our own assembler. Forms that break an RVV
// register-overlap or register-group rule (`RV64Encoder.validate`) are generated too, and both LLVM and our
// assembler must reject exactly those.

enum RV64Sweep {
    /// One generated operand form of `desc`.
    struct Form {
        let desc: RV64InstrDesc
        let inst: RV64Instruction
    }

    /// An operand slot: the values it is swept over and how a value is stored into the instruction.
    struct Slot {
        let values: [UInt8]
        let apply: (inout RV64Instruction, UInt8) -> Void
    }

    static let all32 = Array(UInt8(0)...31)
    static let nonZero = Array(UInt8(1)...31)
    static let prime = Array(UInt8(8)...15)
    /// Registers that select different RVC forms: zero, ra, sp, both ends of x8..x15, and outside it.
    static let interesting: [UInt8] = [0, 1, 2, 8, 15, 16, 31]

    // MARK: Immediate domains

    /// Every value of a field with at most 8 significant bits; otherwise min, max, 0, +-1 step, every single
    /// bit (both signs), and alternating-bit patterns. All values are multiples of `align`.
    static func signedImm(bits: Int, align: Int64 = 1) -> [Int64] {
        let lo = -(Int64(1) << (bits - 1)), hi = (Int64(1) << (bits - 1)) - 1
        if bits <= 8 { return (lo...hi).map { $0 * align } }
        var v: Set<Int64> = [lo, hi, 0, 1, -1]
        for b in 0..<(bits - 1) {
            v.insert(Int64(1) << b)
            v.insert(-(Int64(1) << b))
        }
        let a5 = Int64(0x5555_5555_5555) & hi, aa = Int64(0x2AAA_AAAA_AAAA) & hi
        v.formUnion([a5, aa, -a5 - 1, -aa - 1])
        return v.sorted().map { $0 * align }
    }

    static func unsignedImm(bits: Int, align: Int64 = 1) -> [Int64] {
        let hi = (Int64(1) << bits) - 1
        if bits <= 8 { return (0...hi).map { $0 * align } }
        var v: Set<Int64> = [0, hi, 1, hi - 1]
        for b in 0..<bits { v.insert(Int64(1) << b) }
        v.formUnion([Int64(0x5555_5555_5555) & hi, Int64(0xAAAA_AAAA_AAAA) & hi])
        return v.sorted().map { $0 * align }
    }

    // MARK: Per-format operand slots and immediates

    static func gpr(_ path: WritableKeyPath<RV64Instruction, UInt8>, _ values: [UInt8] = all32) -> Slot {
        Slot(values: values) { $0[keyPath: path] = $1 }
    }

    /// Register slots of `desc` (vector, FP, and GPR fields share `rd`/`rs1`/`rs2`/`rs3` storage).
    static func slots(_ desc: RV64InstrDesc) -> [Slot] {
        let op = desc.opcode
        switch desc.format {
        case .r, .rFP, .rFPFixed, .rFPCmp, .vsetvl, .vVV, .vMAccVV, .vVX, .vMAccVX, .vVF, .vMAccVF,
             .vLoadStrided, .vStoreStrided, .vLoadIndexed, .vStoreIndexed, .rAMO:
            return [gpr(\.rd), gpr(\.rs1), gpr(\.rs2)]
        case .rFMA:
            return [gpr(\.rd), gpr(\.rs1), gpr(\.rs2), gpr(\.rs3)]
        case .rUnary, .rFPUnary, .rFPCvtF2I, .rFPCvtMod, .rFPCvtI2F, .rFPMvF2I, .rFPMvI2F, .rShift64, .rShift32,
             .i, .iLoad, .iFPLoad, .hlv, .rLR, .vsetvli, .vLoadUnit, .vStoreUnit, .vLoadWhole, .vStoreWhole,
             .csrReg, .vMvVV, .vMvVX, .vMvVF:
            return [gpr(\.rd), gpr(\.rs1)]
        case .csrImm, .vsetivli:
            return [gpr(\.rd), gpr(\.rs1)] // rs1 holds the 5-bit immediate
        case .s, .sFP, .b, .sfenceVMA, .hsv:
            return [gpr(\.rs1), gpr(\.rs2)]
        case .u, .j, .rFLI, .vNullary, .vMvVI:
            return [gpr(\.rd)]
        case .cbo, .prefetch:
            return [gpr(\.rs1)]
        case .vVI, .vVUI, .vVUI6, .vUnary, .vToX, .vToF:
            return [gpr(\.rd), gpr(\.rs2)]
        case .fence, .systemFixed, .cFixed, .cNop, .cAddi16sp, .cJ:
            return []
        // RVC: only the registers the 3-/5-bit fields can name. The x0 HINT forms (c.li, c.lui, c.slli, c.mv,
        // c.add) are included; reserved x0 forms (c.addiw, c.lwsp, c.ldsp) and c.lui sp (c.addi16sp) are not.
        case .cAddi:
            return [Slot(values: op == .c_li ? all32 : nonZero) { $0.rd = $1; $0.rs1 = op == .c_li ? 0 : $1 }]
        case .cLui:
            return [Slot(values: all32.filter { $0 != 2 }) { $0.rd = $1 }]
        case .cSlli:
            return [Slot(values: all32) { $0.rd = $1; $0.rs1 = $1 }]
        case .cShift, .cAndi, .cZcbUnary:
            return [Slot(values: prime) { $0.rd = $1; $0.rs1 = $1 }]
        case .cAlu:
            return [Slot(values: prime) { $0.rd = $1; $0.rs1 = $1 }, gpr(\.rs2, prime)]
        case .cCR:
            return [Slot(values: all32) { $0.rd = $1; $0.rs1 = op == .c_add ? $1 : 0 }, gpr(\.rs2, nonZero)]
        case .cJr:
            return [gpr(\.rs1, nonZero)]
        case .cAddi4spn:
            return [gpr(\.rd, prime)]
        case .cLw, .cLd, .cFld:
            return [gpr(\.rd, prime), gpr(\.rs1, prime)]
        case .cSw, .cSd, .cFsd:
            return [gpr(\.rs2, prime), gpr(\.rs1, prime)]
        case .cZcbByte, .cZcbHalf:
            let isStore = op == .c_sb || op == .c_sh
            return [gpr(isStore ? \.rs2 : \.rd, prime), gpr(\.rs1, prime)]
        case .cLwsp, .cLdsp:
            return [gpr(\.rd, nonZero)]
        case .cFldsp:
            return [gpr(\.rd)]
        case .cSwsp, .cSdsp, .cFsdsp:
            return [gpr(\.rs2)]
        case .cBranch:
            return [gpr(\.rs1, prime)]
        }
    }

    /// Immediate values of `desc` (empty if it has no immediate).
    static func immediates(_ desc: RV64InstrDesc) -> [Int64] {
        switch desc.format {
        case .i, .iLoad, .iFPLoad, .s, .sFP: return signedImm(bits: 12)
        case .b: return signedImm(bits: 12, align: 2)
        case .j: return signedImm(bits: 20, align: 2)
        case .u: return unsignedImm(bits: 20)
        case .rShift64, .vVUI6: return unsignedImm(bits: 6)
        case .rShift32, .rFLI, .vVUI: return unsignedImm(bits: 5)
        case .vVI, .vMvVI: return signedImm(bits: 5)
        case .fence: return unsignedImm(bits: 8)
        case .csrReg, .csrImm: return (0...0xFFF).map { Int64($0) }
        case .prefetch: return signedImm(bits: 7, align: 32)
        case .vsetvli: return (0...0x7FF).map { Int64($0) }
        case .vsetivli: return (0...0x3FF).map { Int64($0) }
        // Zero immediates of c.addi and shamt 0 of the shifts are HINTs (c.slli64, ...); c.lui 0 is reserved.
        case .cAddi, .cAndi, .cNop: return signedImm(bits: 6)
        case .cLui: return signedImm(bits: 6).filter { $0 != 0 }
        case .cShift, .cSlli: return unsignedImm(bits: 6)
        case .cAddi16sp: return signedImm(bits: 6, align: 16).filter { $0 != 0 }
        case .cAddi4spn: return unsignedImm(bits: 8, align: 4).filter { $0 != 0 }
        case .cLw, .cSw: return unsignedImm(bits: 5, align: 4)
        case .cLd, .cSd, .cFld, .cFsd: return unsignedImm(bits: 5, align: 8)
        case .cLwsp, .cSwsp: return unsignedImm(bits: 6, align: 4)
        case .cLdsp, .cSdsp, .cFldsp, .cFsdsp: return unsignedImm(bits: 6, align: 8)
        case .cJ: return signedImm(bits: 11, align: 2)
        case .cBranch: return signedImm(bits: 8, align: 2)
        case .cZcbByte: return [0, 1, 2, 3]
        case .cZcbHalf: return [0, 2]
        default: return []
        }
    }

    static func hasRoundingMode(_ desc: RV64InstrDesc) -> Bool {
        switch desc.format {
        case .rFP, .rFMA, .rFPUnary, .rFPCvtF2I, .rFPCvtI2F: return true
        default: return false
        }
    }

    /// Extra register/immediate combinations for 32-bit scalar descriptors that steer `tryCompress`
    /// (and LLVM's compressor) through every RVC form and its boundaries.
    static func compressionProbes(_ desc: RV64InstrDesc, base: RV64Instruction) -> [RV64Instruction] {
        let rvcImms: [Int64] = [0, 1, -1, 2, 3, 4, 8, 16, 31, -32, 32, -33, 63, 64, 124, 128, 248, 252, 255, 256,
                                496, 504, 508, 512, -512, -496, 1020, 1024, -2048, 2047, -256, 254, -258, 2046, -2050]
        var out: [RV64Instruction] = []
        func sweep2(_ a: WritableKeyPath<RV64Instruction, UInt8>, _ b: WritableKeyPath<RV64Instruction, UInt8>, imms: [Int64?]) {
            for x in interesting {
                for y in interesting {
                    for imm in imms {
                        var i = base
                        i[keyPath: a] = x
                        i[keyPath: b] = y
                        if let imm { i.imm = imm }
                        out.append(i)
                    }
                }
            }
        }
        switch desc.format {
        case .r:
            for x in interesting {
                for y in interesting {
                    for z in interesting {
                        var i = base
                        (i.rd, i.rs1, i.rs2) = (x, y, z)
                        out.append(i)
                    }
                }
            }
        case .rUnary:
            sweep2(\.rd, \.rs1, imms: [nil])
        case .i, .iLoad:
            sweep2(\.rd, \.rs1, imms: rvcImms.filter { (-2048...2047).contains($0) })
        case .iFPLoad:
            sweep2(\.rd, \.rs1, imms: rvcImms.filter { (-2048...2047).contains($0) })
        case .s, .sFP:
            sweep2(\.rs2, \.rs1, imms: rvcImms.filter { (-2048...2047).contains($0) })
        case .rShift64:
            sweep2(\.rd, \.rs1, imms: [0, 1, 31, 32, 63])
        case .b:
            sweep2(\.rs1, \.rs2, imms: [0, 2, -256, 254, 256, -258, 100])
        case .j:
            for x in interesting {
                for imm: Int64 in [0, 2, -2, 2046, -2048, 2048, -2050, 1 << 19] {
                    var i = base
                    i.rd = x
                    i.imm = imm
                    out.append(i)
                }
            }
        case .u:
            for x in interesting {
                for imm: Int64 in [0, 1, 31, 32, 0xFFFFF, 0xFFFE0, 0xFFFDF, 0x80000] {
                    var i = base
                    i.rd = x
                    i.imm = imm
                    out.append(i)
                }
            }
        default:
            break
        }
        return out
    }

    /// Register ties and zero registers for a 32-bit descriptor: its first three register slots over {x0, ra, a0}
    /// (or v0, v1, v10 / f0, f1, f10), so every operand pattern an alias keys on (`rd == rs1 == rs2`, `rs1 == x0`,
    /// `rd == ra`, ...) is generated, with the immediates aliases key on (`addi rd, rs1, 0`, `sltiu ..., 1`,
    /// `xori ..., -1`, `andi ..., 255`) and the CSRs with dedicated aliases (`frflags`, `rdcycle`, `unimp`, ...).
    static func aliasProbes(_ desc: RV64InstrDesc, base: RV64Instruction) -> [RV64Instruction] {
        var combos = [base]
        for slot in slots(desc).prefix(3) {
            combos = combos.flatMap { c in [UInt8(0), 1, 10].map { var i = c; slot.apply(&i, $0); return i } }
        }
        let imms: [Int64]
        switch desc.format {
        case .i: imms = [0, 1, -1, 255]
        case .csrReg, .csrImm: imms = [RVCSR.fflags, .frm, .fcsr, .cycle, .time, .instret].map { Int64($0.rawValue) }
        default: imms = []
        }
        return combos + combos.flatMap { c in imms.map { var i = c; i.imm = $0; return i } }
    }

    // MARK: Generation

    /// Every generated form of `desc`.
    static func forms(for desc: RV64InstrDesc) -> [Form] {
        let base = RV64InstructionTable.sampleInstruction(for: desc)
        var insts: [RV64Instruction] = [base]
        for slot in slots(desc) {
            for v in slot.values {
                var i = base
                slot.apply(&i, v)
                insts.append(i)
            }
        }
        for imm in immediates(desc) {
            var i = base
            i.imm = imm
            insts.append(i)
        }
        if hasRoundingMode(desc) {
            for mode in RVRoundingMode.allCases {
                var i = base
                i.rm = mode
                insts.append(i)
            }
        }
        if desc.format == .rAMO || desc.format == .rLR {
            for (aq, rl) in [(false, false), (true, false), (false, true), (true, true)] {
                var i = base
                (i.aq, i.rl) = (aq, rl)
                insts.append(i)
            }
        }
        if desc.format == .vsetivli {
            // Every AVL immediate against the extreme vtypes.
            for avl in all32 {
                for vt: Int64 in [0, 0x3FF] {
                    var i = base
                    (i.rs1, i.imm) = (avl, vt)
                    insts.append(i)
                }
            }
        }
        if !desc.isCompressed {
            insts += compressionProbes(desc, base: base)
            insts += aliasProbes(desc, base: base)
        }
        if desc.isMaskable {
            insts += insts.map { var m = $0; m.vm = false; return m }
        }
        return insts.map { Form(desc: desc, inst: $0) }
    }

    /// Forms of every descriptor, generated once and shared by the tests.
    static let allForms: [Form] = RV64InstructionTable.descriptors.flatMap { forms(for: $0) }
}

/// The result of checking one form against the encoder and disassembler.
struct RV64SweepResult {
    let form: RV64Sweep.Form
    /// `nil` for an invalid form (`RV64Encoder.validate` rejects it).
    let bytes: [UInt8]?
    /// The encoding with RVC enabled (`nil` for a compressed descriptor or an invalid form).
    let bytesRVC: [UInt8]?
    /// Disassembly of `bytes` as `llvm-objdump` prints it (preferred aliases).
    let text: String
    /// Disassembly of `bytes` under the instruction's own mnemonic (for an invalid form, the formatted instruction).
    let canonical: String
}

private func hex(_ b: [UInt8]) -> String {
    b.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// Canonical text for comparing our disassembly with LLVM's: single spaces between mnemonic and operands.
private func canonicalRV(_ text: String) -> String {
    let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let mnem = parts.first else { return "" }
    return parts.count == 1 ? String(mnem) : "\(mnem) " + parts.dropFirst().joined(separator: " ")
}

/// `.text` bytes of `lines` assembled by our own assembler (Asm/RV64Assembler.swift) after `prefix`, and the
/// error count.
private func ownAssembleRV(_ lines: [String], prefix: String = ".option norvc\n") -> (bytes: [UInt8], errors: Int) {
    var diags = DiagnosticBag()
    let obj = Assembler.assemble(source: prefix + lines.joined(separator: "\n") + "\n", arch: .riscv64, diagnostics: &diags)
    return (obj.findSection(name: ".text").map { obj.sectionData($0) } ?? [], diags.errorCount)
}

@Suite("M2 — RV64 exhaustive encoder/disassembler sweep")
struct M2RV64ExhaustiveTests {
    static var llvmMC: String? { ExternalTool.find("llvm-mc") }
    /// The ratified RVA23S64 profile (every RVA23U64 extension, including C, Zcb, Zcmop, V, Zvbb, Zvfhmin, Zfa,
    /// Zfhmin, ..., plus Zifencei, Svinval, H, Sstc, ...): LLVM compresses whatever C/Zcb allow.
    static let llvmArgsC = ["--triple=riscv64", "-mattr=+rva23s64"]
    /// The same without any compressed extension: nothing is compressed.
    static let llvmArgsNoC = ["--triple=riscv64", "-mattr=+rva23s64,-c,-zca,-zcb,-zcd,-zcmop"]

    /// `decoded` is `desc` itself, or a strictly more specific alias of it whose fixed bits the encoding
    /// happens to match (`fence w, 0` = `pause`, `ori zero, rs1, 32k` = `prefetch.i`, `add zero, zero, a2` = `ntl.p1`).
    private static func isSameOrAlias(_ decoded: RV64Opcode, of desc: RV64InstrDesc) -> Bool {
        if decoded == desc.opcode { return true }
        let d = RV64InstructionTable.descriptor(for: decoded)
        return (d.mask & desc.mask) == desc.mask && d.mask != desc.mask && (d.match & desc.mask) == desc.match
    }

    /// Round-trips every form; returns the per-form results and the failures.
    static func roundTrip() -> (results: [RV64SweepResult], failures: [String]) {
        var results: [RV64SweepResult] = []
        var failures: [String] = []
        results.reserveCapacity(RV64Sweep.allForms.count)
        for form in RV64Sweep.allForms {
            let desc = form.desc
            if let problem = RV64Encoder.validate(form.inst) {
                // Only the RVV register rules may reject a generated form; scalar domains are generated valid.
                if !desc.mnemonic.hasPrefix("v") {
                    failures.append("\(desc.mnemonic): generator produced invalid form \(form.inst): \(problem)")
                }
                let text = RV64Disassembler.format(form.inst, aliases: false)
                results.append(RV64SweepResult(form: form, bytes: nil, bytesRVC: nil, text: text, canonical: text))
                continue
            }
            let bytes = RV64Encoder.encode(form.inst, rvcEnabled: false)
            guard bytes.count == (desc.isCompressed ? 2 : 4),
                  let (decoded, size) = RV64Disassembler.decode(from: bytes), size == bytes.count else {
                failures.append("\(desc.mnemonic): [\(hex(bytes))] does not decode")
                continue
            }
            if !isSameOrAlias(decoded.opcode, of: desc) {
                failures.append("\(desc.mnemonic): [\(hex(bytes))] decodes as \(RV64InstructionTable.descriptor(for: decoded.opcode).mnemonic)")
            }
            let reencoded = RV64Encoder.encode(decoded, rvcEnabled: false)
            if reencoded != bytes {
                failures.append("\(desc.mnemonic): [\(hex(bytes))] -> \(RV64Disassembler.format(decoded)) -> [\(hex(reencoded))]")
            }
            var bytesRVC: [UInt8]? = nil
            if !desc.isCompressed {
                let c = RV64Encoder.encode(form.inst, rvcEnabled: true)
                bytesRVC = c
                if let (dc, sc) = RV64Disassembler.decode(from: c), sc == c.count {
                    let rc = RV64Encoder.encode(dc, rvcEnabled: false)
                    if rc != c {
                        failures.append("\(desc.mnemonic) (RVC): [\(hex(c))] -> \(RV64Disassembler.format(dc)) -> [\(hex(rc))]")
                    }
                } else {
                    failures.append("\(desc.mnemonic) (RVC): [\(hex(c))] does not decode")
                }
            }
            results.append(RV64SweepResult(form: form, bytes: bytes, bytesRVC: bytesRVC, text: RV64Disassembler.format(decoded),
                                           canonical: RV64Disassembler.format(decoded, aliases: false)))
        }
        return (results, failures)
    }

    @Test("Every RV64 descriptor round-trips (encode -> disassemble -> re-encode) over its full operand sweep")
    func roundTripIsExhaustive() {
        let (results, failures) = Self.roundTrip()
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) round-trip failures:\n  " + failures.prefix(30).joined(separator: "\n  ")))

        // Nothing escapes the sweep: every descriptor has valid forms that decode back to it.
        var covered = Set<RV64Opcode>()
        for r in results {
            if let bytes = r.bytes, let (d, _) = RV64Disassembler.decode(from: bytes), d.opcode == r.form.desc.opcode {
                covered.insert(d.opcode)
            }
        }
        #expect(RV64InstructionTable.descriptors.count == RV64Opcode.allCases.count)
        let missing = RV64InstructionTable.descriptors.filter { !covered.contains($0.opcode) }.map(\.mnemonic)
        #expect(missing.isEmpty, Comment(rawValue: "descriptors without a round-tripping form: \(missing)"))
    }

    /// Compares LLVM's assembly of `lines` with `expected` (`nil`: the line must be rejected).
    private static func compareEncodings(_ lines: [String], expected: [[UInt8]?], args: [String], run: String,
                                         mc: String, failures: inout [String]) throws -> Int {
        var checked = 0
        for (i, got) in try LLVMMC.assemble(lines, mc: mc, args: args).enumerated() {
            switch (got, expected[i]) {
            case (.some(let l), .some(let ours)) where !l.fixup && l.bytes == ours:
                checked += 1
            case (.none, .none):
                checked += 1
            case (.some(let l), .some(let ours)):
                failures.append("[\(run)] \(lines[i]): ours=[\(hex(ours))] llvm=[\(hex(l.bytes))\(l.fixup ? " +fixup" : "")]")
            case (.some(let l), .none):
                failures.append("[\(run)] \(lines[i]): rejected by our encoder, llvm=[\(hex(l.bytes))]")
            case (.none, .some(let ours)):
                failures.append("[\(run)] \(lines[i]): ours=[\(hex(ours))], llvm-mc rejects it")
            }
        }
        return checked
    }

    @Test("Every swept RV64 encoding and disassembly matches llvm-mc (RVA23S64, with and without C) and our assembler",
          .enabled(if: M2RV64ExhaustiveTests.llvmMC != nil))
    func sweepMatchesLLVM() throws {
        let mc = try #require(Self.llvmMC)
        let (results, roundTripFailures) = Self.roundTrip()
        try #require(roundTripFailures.isEmpty, "round trip must pass first")
        let valid = results.filter { $0.bytes != nil }
        let wide = valid.filter { !$0.form.desc.isCompressed }
        var failures: [String] = []

        // 1. LLVM with C enabled assembles every canonical line (and every alias line) to our encoding with RVC
        //    enabled (a compressed descriptor to its own encoding), and rejects exactly the forms our encoder
        //    rejects (RVV register-group alignment and overlap rules).
        //    The alias text of a compressed instruction is its 32-bit expansion, which compresses as that
        //    instruction does (`c.addi16sp sp, -16` prints `addi sp, sp, -16`, which is `c.addi`); `unimp` is
        //    always `c.unimp` with C.
        func expectedC(_ r: RV64SweepResult) -> [UInt8]? { r.form.desc.isCompressed ? r.bytes : r.bytesRVC }
        func expectedAliasC(_ r: RV64SweepResult) -> [UInt8]? {
            if r.text == "unimp" { return [0, 0] }
            if r.form.desc.isCompressed, let wide = RV64Disassembler.uncompress(r.form.inst) {
                return RV64Encoder.encode(wide, rvcEnabled: true)
            }
            return expectedC(r)
        }
        var encodingChecked = try Self.compareEncodings(results.map(\.canonical), expected: results.map(expectedC),
                                                        args: Self.llvmArgsC, run: "C", mc: mc, failures: &failures)
        encodingChecked += try Self.compareEncodings(valid.map(\.text), expected: valid.map(expectedAliasC),
                                                     args: Self.llvmArgsC, run: "C alias", mc: mc, failures: &failures)
        // 2. Without C, every 32-bit form assembles to its uncompressed encoding.
        encodingChecked += try Self.compareEncodings(wide.map(\.canonical), expected: wide.map(\.bytes),
                                                     args: Self.llvmArgsNoC, run: "noC", mc: mc, failures: &failures)
        encodingChecked += try Self.compareEncodings(wide.map(\.text), expected: wide.map(\.bytes),
                                                     args: Self.llvmArgsNoC, run: "noC alias", mc: mc, failures: &failures)

        // 3. LLVM disassembles our bytes to our text (the preferred alias, as llvm-objdump prints it).
        var textChecked = 0
        for (r, t) in zip(valid, try LLVMMC.disassemble(valid.map { $0.bytes! }, mc: mc, args: Self.llvmArgsC)) {
            guard let t else {
                failures.append("llvm-mc cannot disassemble [\(hex(r.bytes!))] ours=\(r.text)")
                continue
            }
            if canonicalRV(t) == canonicalRV(r.text) {
                textChecked += 1
            } else {
                failures.append("disassembly text: ours=\(r.text) llvm=\(t) [\(hex(r.bytes!))]")
            }
        }

        // 4. Our own assembler (`.option norvc`: explicit RVC mnemonics stay 16-bit, nothing else is compressed)
        //    reproduces the bytes from the canonical text of every form and the alias text of every 32-bit form,
        //    and rejects every invalid form. Lines are checked in chunks; a mismatching chunk is re-assembled
        //    line by line to name the culprits.
        var asmChecked = 0
        let asmLines = valid.map { ($0.canonical, $0.bytes!) } + wide.map { ($0.text, $0.bytes!) }
        let chunkSize = 4096
        for start in stride(from: 0, to: asmLines.count, by: chunkSize) {
            let chunk = asmLines[start..<min(start + chunkSize, asmLines.count)]
            let (bytes, errors) = ownAssembleRV(chunk.map(\.0))
            if errors == 0 && bytes == chunk.flatMap(\.1) {
                asmChecked += chunk.count
                continue
            }
            for (line, expected) in chunk {
                let (b, e) = ownAssembleRV([line])
                if e != 0 || b != expected {
                    failures.append("assembler: \(line) ours=[\(hex(expected))] assembled=[\(hex(b))] errors=\(e)")
                } else {
                    asmChecked += 1
                }
            }
        }
        for r in results where r.bytes == nil {
            let (b, e) = ownAssembleRV([r.canonical])
            if e == 0 || !b.isEmpty {
                failures.append("assembler accepts invalid form: \(r.canonical) -> [\(hex(b))]")
            } else {
                asmChecked += 1
            }
        }

        let invalid = results.count - valid.count
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("ss_rv64_exhaustive.txt").path
        let summary = "descriptors \(RV64InstructionTable.descriptors.count), forms \(results.count) (valid \(valid.count), "
            + "invalid \(invalid), compressed \(valid.count - wide.count), 32-bit compressed with C \(wide.filter { $0.bytesRVC?.count == 2 }.count)), "
            + "llvm-encoding-checked \(encodingChecked), llvm-text-checked \(textChecked), assembler-checked \(asmChecked), "
            + "failures \(failures.count)"
        try ([summary] + failures).joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        print("RV64 exhaustive sweep: \(summary) (report: \(report))")

        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures (report: \(report)):\n  "
            + failures.prefix(40).joined(separator: "\n  ")))
        #expect(failures.isEmpty == (encodingChecked == results.count + valid.count + 2 * wide.count
                                     && textChecked == valid.count && asmChecked == results.count + wide.count))
    }
}
