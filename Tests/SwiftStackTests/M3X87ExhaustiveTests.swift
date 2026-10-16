import Foundation
import Testing
@testable import SwiftStack

// Exhaustive x87 sweep against LLVM MC (M3-plan.md phase 3: "The encoder gains the x87 subset `long double` code
// needs ... with exhaustive llvm-mc sweep coverage").
//
// M2X86ExhaustiveTests already generates every table form of the x87 descriptors (all eight stack registers, every
// memory special case) from the structured `X86Instruction` side. This sweep starts from the text LLVM MC accepts:
// every x87 spelling (table mnemonics and aliases, and each base name with every AT&T size suffix) crossed with
// every operand shape (none, `%st`, `%st(0)`..`%st(7)` in each position and order, two stack registers, `%ax`,
// immediates, memory). LLVM MC decides which lines are valid; then
//
//   1. a line LLVM accepts must assemble through our assembler to exactly LLVM's bytes, and one it rejects must be
//      rejected (the shorthand forms `fxch`, `faddp`, `fadd`, `fucomi %st(2)`, `fnstsw` included);
//   2. every memory-capable spelling is also swept over the M2 memory operands (RIP-relative, SIB, REX-extended
//      base and index, disp8/disp32, segment overrides, 32-bit addressing);
//   3. our disassembly of those bytes must print exactly what LLVM's disassembler prints for them, instruction by
//      instruction (`fstcw` is `wait` then `fnstcw`), and must assemble back to the same bytes.
//
// LLVM MC is the reference where it and GNU `as` disagree (they agree on the x87 encodings used here).

enum X87Sweep {
    /// x87 descriptors: the D8..DF escape opcodes, and `wait`.
    static func isX87(_ d: X86InstrDesc) -> Bool {
        d.encodingKind == .legacy && d.opcodeMap == .primary && ((0xD8...0xDF).contains(d.opcode) || d.opcode == 0x9B)
    }

    /// Base names of the covered instructions; each is also probed with every AT&T size suffix.
    static let baseNames = [
        "fld", "fst", "fstp", "fild", "fist", "fistp", "fisttp",
        "fadd", "fsub", "fsubr", "fmul", "fdiv", "fdivr", "faddp", "fsubp", "fsubrp", "fmulp", "fdivp", "fdivrp",
        "fiadd", "fisub", "fisubr", "fimul", "fidiv", "fidivr",
        "fcom", "fcomp", "fcompp", "fucom", "fucomp", "fucompp", "fcomi", "fcomip", "fcompi", "fucomi", "fucomip", "fucompi",
        "ficom", "ficomp", "fxch", "ffree", "ffreep",
        "fldcw", "fnstcw", "fstcw", "fnstsw", "fstsw", "fldenv", "fnstenv", "fstenv", "fnsave", "fsave", "frstor",
    ]
    static let suffixes = ["", "s", "l", "t", "ll", "q", "w", "b"]

    /// Every spelling probed.
    static var mnemonics: [String] {
        var names = Set<String>()
        for d in X86InstructionTable.descriptors where isX87(d) {
            names.insert(d.mnemonic)
            names.formUnion(d.aliases)
        }
        for b in baseNames { for s in suffixes { names.insert(b + s) } }
        return names.sorted()
    }

    /// Operand shapes probed for every spelling (memory: one probe here, expanded by `memoryShapes`).
    static let shapes: [String] = {
        var s = ["", "(%rax)", "%st", "%st, %st", "%st(1), %st(2)", "%st(2), %st(1)", "%ax", "%eax", "%al", "%rax",
                 "$1", "(%rax), %st", "%st, (%rax)", "%st(1), (%rax)", "%xmm0"]
        for i in 0..<8 {
            s += ["%st(\(i))", "%st(\(i)), %st", "%st, %st(\(i))", "%st(\(i)), %st(0)", "%st(0), %st(\(i))"]
        }
        return s
    }()

    /// Memory operands for a spelling that takes memory: the M2 sweep's special cases and swept forms.
    static var memoryShapes: [String] { X86Sweep.memForms64.map(\.attString) }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// LLVM MC's `.text` bytes for each line (`nil` if rejected). Each line gets its own label, so a line that
    /// assembles to several instructions (`fstcw` is `wait` + `fnstcw`) is one entry.
    static func llvmAssemble(_ lines: [String], mc: String) throws -> [[UInt8]?] {
        var rejected = Set<Int>()
        for _ in 0..<2 {
            var src = ""
            src.reserveCapacity(lines.count * 32)
            for (i, line) in lines.enumerated() {
                src += "x\(i):\n" + (rejected.contains(i) ? "" : line) + "\n"
            }
            src += "xend:\n"
            let input = ExternalTool.temporaryPath(".s"), output = ExternalTool.temporaryPath(".o")
            defer {
                try? FileManager.default.removeItem(atPath: input)
                try? FileManager.default.removeItem(atPath: output)
            }
            try src.write(toFile: input, atomically: true, encoding: .utf8)
            let r = try ExternalTool.run(mc, ["-triple=x86_64", "-filetype=obj", "-o", output, input])
            if r.status != 0 {
                // "<file>:<line>:<col>: error: ...": line 2i+2 holds instruction i. Retry once without them.
                let before = rejected.count
                for line in r.stderr.split(separator: "\n") where line.contains(": error: ") {
                    let fields = line.split(separator: ":")
                    if fields.count > 2, let n = Int(fields[1]), n >= 2 { rejected.insert((n - 2) / 2) }
                }
                if rejected.count == before { throw TestELF.FormatError(description: "llvm-mc failed: \(r.stderr.prefix(500))") }
                continue
            }
            let elf = try TestELF(path: output)
            let text = elf.sections.first(where: { $0.name == ".text" })?.data ?? []
            var offsets = [Int](repeating: -1, count: lines.count + 1)
            for sym in elf.symbols where sym.name.hasPrefix("x") {
                if sym.name == "xend" { offsets[lines.count] = Int(sym.value) }
                else if let i = Int(sym.name.dropFirst()), i < lines.count { offsets[i] = Int(sym.value) }
            }
            return lines.indices.map { i in
                guard !rejected.contains(i), offsets[i] >= 0, offsets[i + 1] >= offsets[i] else { return nil }
                let bytes = Array(text[offsets[i]..<offsets[i + 1]])
                return bytes.isEmpty ? nil : bytes
            }
        }
        throw TestELF.FormatError(description: "llvm-mc kept failing")
    }

    /// `.text` bytes of `lines` assembled by our assembler, and the number of diagnosed errors.
    static func ownAssemble(_ lines: [String]) -> (bytes: [UInt8], errors: Int) {
        var diags = DiagnosticBag()
        let obj = Assembler.assemble(source: lines.joined(separator: "\n") + "\n", arch: .x86_64, diagnostics: &diags)
        return (obj.findSection(name: ".text").map { obj.sectionData($0) } ?? [], diags.errorCount)
    }

    /// Our disassembly of `bytes`: each instruction's text and bytes.
    static func disassemble(_ bytes: [UInt8]) throws -> [(text: String, bytes: [UInt8])] {
        let disassembler = X86Disassembler()
        var out: [(text: String, bytes: [UInt8])] = []
        var offset = 0
        while offset < bytes.count {
            let (inst, length) = try disassembler.disassembleOne(bytes, at: offset)
            out.append((inst.attString, Array(bytes[offset..<(offset + length)])))
            offset += length
        }
        return out
    }
}

@Suite("M3 — Exhaustive x87 encoder sweep against LLVM MC")
struct M3X87ExhaustiveTests {
    static var llvmMC: String? { ExternalTool.find("llvm-mc") }

    @Test("Every x87 spelling and operand shape: assembler, encoder and disassembler match llvm-mc",
          .enabled(if: M3X87ExhaustiveTests.llvmMC != nil))
    func exhaustiveX87Sweep() throws {
        let mc = try #require(Self.llvmMC)
        var failures: [String] = []

        // 1. Probe every spelling with every shape; expand the spellings that take memory over all memory forms.
        let mnemonics = X87Sweep.mnemonics
        var lines = mnemonics.flatMap { m in X87Sweep.shapes.map { $0.isEmpty ? m : "\(m) \($0)" } }
        let probe = try X87Sweep.llvmAssemble(lines, mc: mc)
        let memoryMnemonics = mnemonics.filter { m in
            lines.indices.contains { probe[$0] != nil && lines[$0] == "\(m) (%rax)" }
        }
        let memoryLines = memoryMnemonics.flatMap { m in X87Sweep.memoryShapes.map { "\(m) \($0)" } }
        let memoryBytes = try X87Sweep.llvmAssemble(memoryLines, mc: mc)
        lines += memoryLines
        let llvm = probe + memoryBytes

        // 2. Our assembler: identical bytes for accepted lines, an error for each rejected line.
        let accepted = lines.indices.filter { llvm[$0] != nil }
        let rejected = lines.indices.filter { llvm[$0] == nil }
        var asmChecked = 0
        for start in stride(from: 0, to: accepted.count, by: 2048) {
            let chunk = accepted[start..<min(start + 2048, accepted.count)]
            let (bytes, errors) = X87Sweep.ownAssemble(chunk.map { lines[$0] })
            if errors == 0 && bytes == chunk.flatMap({ llvm[$0]! }) {
                asmChecked += chunk.count
                continue
            }
            for i in chunk {
                let (b, e) = X87Sweep.ownAssemble([lines[i]])
                if e != 0 || b != llvm[i]! {
                    failures.append("assembler: \(lines[i]) ours=[\(X87Sweep.hex(b))] errors=\(e) llvm=[\(X87Sweep.hex(llvm[i]!))]")
                } else {
                    asmChecked += 1
                }
            }
        }
        var rejectChecked = 0
        for start in stride(from: 0, to: rejected.count, by: 256) { // one diagnostic per line; the bag is bounded
            let chunk = rejected[start..<min(start + 256, rejected.count)]
            let (bytes, errors) = X87Sweep.ownAssemble(chunk.map { lines[$0] })
            if errors == chunk.count && bytes.isEmpty {
                rejectChecked += chunk.count
                continue
            }
            for i in chunk {
                let (b, e) = X87Sweep.ownAssemble([lines[i]])
                if e == 0 || !b.isEmpty {
                    failures.append("accepted by us, rejected by llvm-mc: \(lines[i]) ours=[\(X87Sweep.hex(b))]")
                } else {
                    rejectChecked += 1
                }
            }
        }

        // 3. Disassembly of every distinct encoding, instruction by instruction, against LLVM's disassembler.
        var seen = Set<[UInt8]>()
        var instructions: [(text: String, bytes: [UInt8], source: String)] = []
        for i in accepted where seen.insert(llvm[i]!).inserted {
            do {
                let decoded = try X87Sweep.disassemble(llvm[i]!)
                instructions += decoded.map { ($0.text, $0.bytes, lines[i]) }
                // Our disassembly assembles back to the same bytes.
                let (b, e) = X87Sweep.ownAssemble(decoded.map(\.text))
                if e != 0 || b != llvm[i]! {
                    failures.append("disassembly re-assembles differently: \(decoded.map(\.text).joined(separator: "; ")) [\(X87Sweep.hex(llvm[i]!))] -> [\(X87Sweep.hex(b))]")
                }
            } catch {
                failures.append("disassembly: \(lines[i]) [\(X87Sweep.hex(llvm[i]!))]: \(error)")
            }
        }
        let theirs = try LLVMMC.disassemble(instructions.map(\.bytes), mc: mc, args: ["-triple=x86_64"])
        var disasmChecked = 0
        for (ours, t) in zip(instructions, theirs) {
            if let t, EncoderOracle.canonical(t) == EncoderOracle.canonical(ours.text) {
                disasmChecked += 1
            } else {
                failures.append("disassembly text: ours=\(ours.text) llvm=\(t ?? "<invalid>") [\(X87Sweep.hex(ours.bytes))] (from \(ours.source))")
            }
        }

        let report = FileManager.default.temporaryDirectory.appendingPathComponent("ss_x87_exhaustive.txt").path
        let summary = "spellings \(mnemonics.count), lines \(lines.count), llvm-accepted \(accepted.count) (memory spellings \(memoryMnemonics.count)), "
            + "assembler-checked \(asmChecked), rejections-checked \(rejectChecked), encodings \(seen.count), disassembly-checked \(disasmChecked), failures \(failures.count)"
        let acceptedText = accepted.filter { !lines[$0].contains("(%r") || lines[$0].hasSuffix(" (%rax)") }.map { "\(lines[$0])\t[\(X87Sweep.hex(llvm[$0]!))]" }
        try ([summary] + failures + ["ACCEPTED (register, implied and (%rax) forms):"] + acceptedText)
            .joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        print("x87 exhaustive sweep: \(summary) (report: \(report))")
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures (report: \(report)):\n  " + failures.prefix(40).joined(separator: "\n  ")))
    }

    /// The forms the code generator emits, built as `X86Instruction` values (not parsed), against llvm-mc.
    @Test("Code generator x87 forms (structured X86Instruction) encode as llvm-mc does",
          .enabled(if: M3X87ExhaustiveTests.llvmMC != nil))
    func codegenForms() throws {
        let mc = try #require(Self.llvmMC)
        let mems: [X86Mem] = [.baseDisp(.rbp, disp: -16), .baseDisp(.rsp, disp: 8), X86Mem(base: .r12, index: .r9, scale: 8, disp: 0x100),
                              .ripRelative(disp: 0x40), .baseDisp(.r13)]
        var insts: [X86Instruction] = []
        for m in ["fldt", "fstpt", "flds", "fldl", "fstps", "fstpl", "filds", "fildl", "fildll", "fistps", "fistpl", "fistpll",
                  "fisttps", "fisttpl", "fisttpll", "fldcw", "fnstcw"] {
            insts += mems.map { X86Instruction(mnemonic: m, operands: [.mem($0)]) }
        }
        for i: UInt8 in 0..<8 {
            let sti = X86Operand.reg(.st(i))
            insts += ["fld", "fstp", "fxch"].map { X86Instruction(mnemonic: $0, operands: [sti]) }
            insts += ["faddp", "fsubp", "fsubrp", "fmulp", "fdivp", "fdivrp"].flatMap { m in
                [X86Instruction(mnemonic: m, operands: [.reg(.st), sti]), X86Instruction(mnemonic: m, operands: [.reg(.st0), sti])]
            }
            insts += ["fucomip", "fucomi", "fucompi", "fcomi", "fcomip"].flatMap { m in
                [X86Instruction(mnemonic: m, operands: [sti, .reg(.st)]), X86Instruction(mnemonic: m, operands: [sti, .reg(.st0)])]
            }
        }
        insts += ["fchs", "fabs", "fldz", "fld1", "fxch", "faddp", "fsubp", "fsubrp", "fmulp", "fdivp", "fdivrp", "fucomip", "fucomi"]
            .map { X86Instruction(mnemonic: $0) }

        let encoder = X86TableEncoder()
        let llvm = try X87Sweep.llvmAssemble(insts.map(\.attString), mc: mc)
        var failures: [String] = []
        for (inst, l) in zip(insts, llvm) {
            let ours = try? encoder.encode(inst).bytes
            if ours == nil || ours != l {
                failures.append("\(inst.attString): ours=[\(ours.map(X87Sweep.hex) ?? "rejected")] llvm=[\(l.map(X87Sweep.hex) ?? "rejected")]")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(40).joined(separator: "\n")))
    }
}
