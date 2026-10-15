import Foundation
import Testing
@testable import SwiftStack

// Encoder/disassembler check against an independent oracle (09-roadmap.md §6.2). `verifyRoundTrip()`
// only checks self-consistency (encode → disassemble → re-encode), so an encoder and disassembler that
// agree on a wrong encoding pass it. Here every table sample is also checked against LLVM MC:
//
//   1. LLVM assembles our disassembly text; the bytes must equal ours, or LLVM must decode both byte
//      strings to the same instruction (an equivalent alternative encoding, e.g. `mov` 0x89 vs 0x8B).
//   2. Branch samples (whose numeric target LLVM reads as a fixup) must decode, by LLVM, to our text.
//   3. LLVM must accept the syntax our disassembler prints.

struct EncoderSample: Sendable {
    let mnemonic: String
    let text: String
    let bytes: [UInt8]
}

enum EncoderOracle {
    static var llvmMC: String? { ExternalTool.find("llvm-mc") }

    static func samples(_ arch: AssemblerArch) throws -> [EncoderSample] {
        switch arch {
        case .x86_64:
            // `lgdtl` is sampled in 16-bit mode, which a 64-bit triple cannot express.
            return try X86InstructionTable.verifyRoundTrip()
                .filter { $0.mnemonic != "lgdtl" }
                .map { EncoderSample(mnemonic: $0.mnemonic, text: $0.disassembled, bytes: $0.bytes) }
        case .aarch64:
            return A64InstructionTable.verifyRoundTrip().map {
                let w = $0.encoded
                return EncoderSample(mnemonic: $0.mnemonic, text: $0.disassembled, bytes: (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * $0)) })
            }
        case .riscv64:
            return RV64InstructionTable.verifyRoundTrip().map { EncoderSample(mnemonic: $0.mnemonic, text: $0.disassembled, bytes: $0.bytes) }
        }
    }

    static func llvmArgs(_ arch: AssemblerArch) -> [String] {
        switch arch {
        case .x86_64:  return ["-triple=x86_64"]
        case .aarch64: return ["-triple=aarch64", "-mattr=+all"]
        case .riscv64:
            // The ratified RVA23S64 profile: every RVA23U64 extension plus Zifencei, Svinval, H (Sha), Sstc, ...
            return ["-triple=riscv64", "-mattr=+rva23s64"]
        }
    }

    enum LLVMEncoding {
        case bytes([UInt8])
        /// The encoding contains a fixup (e.g. a branch to an absolute target): compare by decoding instead.
        case fixup
        case rejected
    }

    /// Assembles one instruction per line with LLVM MC.
    static func assembleLines(_ lines: [String], arch: AssemblerArch) throws -> [LLVMEncoding] {
        guard let mc = llvmMC else { return lines.map { _ in .rejected } }
        let r = try ExternalTool.run(mc, llvmArgs(arch) + ["-show-encoding"], stdin: lines.joined(separator: "\n") + "\n")
        var failed = Set<Int>()
        for line in r.stderr.split(separator: "\n") where line.hasPrefix("<stdin>:") && line.contains("error") {
            if let n = Int(line.split(separator: ":")[1]) { failed.insert(n - 1) }
        }
        var encodings: [LLVMEncoding] = []
        for line in r.stdout.split(separator: "\n") {
            guard let lb = line.range(of: "encoding: ["), let rb = line[lb.upperBound...].firstIndex(of: "]") else { continue }
            let fields = line[lb.upperBound..<rb].split(separator: ",")
            let bytes = fields.compactMap { $0.hasPrefix("0x") ? UInt8($0.dropFirst(2), radix: 16) : nil }
            encodings.append(bytes.count == fields.count ? .bytes(bytes) : .fixup)
        }
        var out: [LLVMEncoding] = []
        var next = 0
        for i in lines.indices {
            if failed.contains(i) || next >= encodings.count {
                out.append(.rejected)
            } else {
                out.append(encodings[next])
                next += 1
            }
        }
        return out
    }

    /// Canonical form of an instruction's text for comparison: single spaces, and `xchg` operands sorted
    /// (it is commutative, and the two operand orders have distinct but equivalent encodings).
    static func canonical(_ text: String) -> String {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let mnem = parts.first else { return "" }
        let operands = parts.dropFirst().joined().split(separator: ",").map(String.init)
        if mnem.hasPrefix("xchg") { return "\(mnem) " + operands.sorted().joined(separator: ",") }
        return "\(mnem) " + operands.joined(separator: ",")
    }

    /// LLVM's decoding of `bytes` if it is exactly one valid instruction.
    static func decodeOne(_ bytes: [UInt8], arch: AssemblerArch) throws -> String? {
        guard let mc = llvmMC else { return nil }
        let hex = bytes.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        let r = try ExternalTool.run(mc, llvmArgs(arch) + ["--disassemble"], stdin: hex + "\n")
        if r.stderr.contains("invalid instruction encoding") || r.stderr.contains("potentially undefined") { return nil }
        let insts = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix(".text") }
        guard insts.count == 1 else { return nil }
        return canonical(insts[0])
    }

    struct Mismatch: CustomStringConvertible {
        let sample: EncoderSample
        let detail: String
        var description: String {
            "\(sample.text) ours=[\(sample.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))] \(detail)"
        }
    }

    /// Returns (mismatches, mnemonics whose syntax LLVM rejected).
    static func check(_ arch: AssemblerArch) throws -> (mismatches: [Mismatch], syntaxRejected: [EncoderSample]) {
        let samples = try samples(arch)
        let llvmBytes = try assembleLines(samples.map(\.text), arch: arch)
        var mismatches: [Mismatch] = []
        var rejected: [EncoderSample] = []
        for (s, enc) in zip(samples, llvmBytes) {
            switch enc {
            case .bytes(let lb):
                if lb == s.bytes { continue }
                let ours = try decodeOne(s.bytes, arch: arch)
                let theirs = try decodeOne(lb, arch: arch)
                if ours == nil || ours != theirs {
                    mismatches.append(Mismatch(sample: s, detail: "llvm=[\(lb.map { String(format: "%02x", $0) }.joined(separator: " "))] llvm-decodes-ours=\(ours ?? "<invalid>")"))
                }
            case .fixup:
                // LLVM reads a numeric branch target as an absolute address (a fixup), while our disassembler prints
                // the displacement. LLVM's own disassembler prints displacements, so compare against that.
                let ours = try decodeOne(s.bytes, arch: arch)
                let oursCanon = canonical(s.text)
                let oursMnem = oursCanon.split(separator: " ").first.map(String.init) ?? ""
                if let ours, ours.split(separator: " ").first.map({ $0.hasPrefix(oursMnem) }) == true,
                   ours.split(separator: " ").dropFirst().joined() == oursCanon.split(separator: " ").dropFirst().joined() {
                    continue
                }
                mismatches.append(Mismatch(sample: s, detail: "branch: llvm-decodes-ours=\(ours ?? "<invalid>")"))
            case .rejected:
                if try decodeOne(s.bytes, arch: arch) == nil {
                    mismatches.append(Mismatch(sample: s, detail: "llvm rejects the text and cannot decode the bytes"))
                } else {
                    rejected.append(s)
                }
            }
        }
        return (mismatches, rejected)
    }
}

@Suite("M2 — Encoder tables against LLVM MC")
struct M2EncoderOracleTests {
    @Test("Encoder table samples agree with llvm-mc", .enabled(if: EncoderOracle.llvmMC != nil), arguments: [AssemblerArch.x86_64, .aarch64, .riscv64])
    func encoderMatchesLLVM(_ arch: AssemblerArch) throws {
        let (mismatches, rejected) = try EncoderOracle.check(arch)
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("ss_encoder_oracle_\(arch).txt").path
        let lines = ["MISMATCHES \(mismatches.count)"] + mismatches.map(\.description)
            + ["SYNTAX-REJECTED \(rejected.count)"] + rejected.map { "\($0.mnemonic)\t\($0.text)" }
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        #expect(rejected.isEmpty, Comment(rawValue: "\(arch): llvm-mc rejects our disassembly syntax for: " + rejected.map(\.text).joined(separator: "; ")))
        #expect(mismatches.isEmpty, Comment(rawValue: "\(arch): \(mismatches.count) encodings disagree with llvm-mc (report: \(report)):\n  " + mismatches.prefix(20).map(\.description).joined(separator: "\n  ")))
    }
}
