import Foundation
import Testing
@testable import SwiftStack

// M3 phase 3: arithmetic, comparisons and conversions of every scalar type checked against clang. Generated
// functions evaluate random expressions over globals of integer types (8 to 128 bits, `_BitInt` of odd widths,
// `bool`), `float`, `double` and `long double`, and print the results; Swift-Stack's program must print what clang's
// does. Expressions avoid undefined behavior that compilers resolve differently (division by zero, overflowing
// float-to-integer conversions, oversized shifts).

struct ArithmeticProgramGenerator {
    var rng: SplitMix64

    struct CType {
        let name: String
        let bits: Int
        let signed: Bool
        let isFloat: Bool
        var isInteger: Bool { !isFloat }
    }

    static let types: [CType] = [
        CType(name: "_Bool", bits: 1, signed: false, isFloat: false),
        CType(name: "signed char", bits: 8, signed: true, isFloat: false),
        CType(name: "unsigned char", bits: 8, signed: false, isFloat: false),
        CType(name: "short", bits: 16, signed: true, isFloat: false),
        CType(name: "unsigned short", bits: 16, signed: false, isFloat: false),
        CType(name: "int", bits: 32, signed: true, isFloat: false),
        CType(name: "unsigned", bits: 32, signed: false, isFloat: false),
        CType(name: "long", bits: 64, signed: true, isFloat: false),
        CType(name: "unsigned long", bits: 64, signed: false, isFloat: false),
        CType(name: "__int128", bits: 128, signed: true, isFloat: false),
        CType(name: "unsigned __int128", bits: 128, signed: false, isFloat: false),
        CType(name: "_BitInt(7)", bits: 7, signed: true, isFloat: false),
        CType(name: "unsigned _BitInt(13)", bits: 13, signed: false, isFloat: false),
        CType(name: "_BitInt(24)", bits: 24, signed: true, isFloat: false),
        CType(name: "unsigned _BitInt(37)", bits: 37, signed: false, isFloat: false),
        CType(name: "_BitInt(48)", bits: 48, signed: true, isFloat: false),
        CType(name: "unsigned _BitInt(63)", bits: 63, signed: false, isFloat: false),
        CType(name: "_BitInt(65)", bits: 65, signed: true, isFloat: false),
        CType(name: "unsigned _BitInt(100)", bits: 100, signed: false, isFloat: false),
        CType(name: "_BitInt(129)", bits: 129, signed: true, isFloat: false),
        CType(name: "unsigned _BitInt(200)", bits: 200, signed: false, isFloat: false),
        CType(name: "_BitInt(256)", bits: 256, signed: true, isFloat: false),
        CType(name: "unsigned _BitInt(511)", bits: 511, signed: false, isFloat: false),
        CType(name: "float", bits: 32, signed: true, isFloat: true),
        CType(name: "double", bits: 64, signed: true, isFloat: true),
        CType(name: "long double", bits: 80, signed: true, isFloat: true),
    ]

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    func cast(_ e: String, to t: CType, from f: CType) -> String {
        // Float to integer: within range for every integer type, so the conversion is defined
        if f.isFloat && t.isInteger { return "((\(t.name))\(t.signed ? "clampf" : "clampu")((long double)(\(e))))" }
        return "((\(t.name))(\(e)))"
    }

    /// A random expression of type `t` (after a cast if needed) of depth at most `depth`.
    mutating func expression(_ t: CType, depth: Int) -> String {
        if depth == 0 || rng.chance(25) {
            if rng.chance(20) { return constant(t) }
            let g = rng.below(Self.types.count)
            let source = Self.types[g]
            let leaf = "g\(g)_\(rng.below(3))"
            return source.name == t.name ? leaf : cast(leaf, to: t, from: source)
        }
        let a = expression(t, depth: depth - 1), b = expression(t, depth: depth - 1)
        if t.isFloat {
            switch rng.below(7) {
            case 0: return "(\(a) + \(b))"
            case 1: return "(\(a) - \(b))"
            case 2: return "(\(a) * \(b))"
            case 3: return "(\(a) / \(b))"
            case 4: return "(-\(a))"
            case 5:
                let c = comparison(depth: depth - 1)
                return "(\(c) ? \(a) : \(b))"
            default:
                let other = Self.types[rng.below(Self.types.count)]
                return cast(expression(other, depth: depth - 1), to: t, from: other)
            }
        }
        let mask = t.bits >= 64 ? 63 : max(t.bits - 1, 0)
        let op = rng.below(14)
        let r: String
        // Signed overflow is undefined (Clang folds overflowing constants to poison): wrap in the unsigned type
        let u = unsignedName(t)
        func wrapped(_ o: String) -> String { t.signed ? "((\(t.name))((\(u))(\(a)) \(o) (\(u))(\(b))))" : "(\(a) \(o) \(b))" }
        switch op {
        case 0: r = wrapped("+")
        case 1: r = wrapped("-")
        case 2: r = wrapped("*")
        case 3: r = "div_\(index(of: t))(\(a), \(b))"
        case 4: r = "mod_\(index(of: t))(\(a), \(b))"
        case 5: r = "(\(a) & \(b))"
        case 6: r = "(\(a) | \(b))"
        case 7: r = "(\(a) ^ \(b))"
        case 8: r = t.bits == 1 ? a : t.signed ? "((\(t.name))((\(u))(\(a)) << ((\(b)) & \(mask))))" : "(\(a) << ((\(b)) & \(mask)))"
        case 9: r = t.bits == 1 ? a : "(\(a) >> ((\(b)) & \(mask)))"
        case 10: r = "(~\(a))"
        case 11: r = "(\(comparison(depth: depth - 1)) ? \(a) : \(b))"
        case 12: r = "(!\(a))"
        default:
            let other = Self.types[rng.below(Self.types.count)]
            r = cast(expression(other, depth: depth - 1), to: t, from: other)
        }
        return cast(r, to: t, from: t)
    }

    mutating func comparison(depth: Int) -> String {
        let t = Self.types[rng.below(Self.types.count)]
        let ops = ["==", "!=", "<", "<=", ">", ">="]
        return "(\(expression(t, depth: depth)) \(ops[rng.below(ops.count)]) \(expression(t, depth: depth)))"
    }

    func unsignedName(_ t: CType) -> String {
        switch t.name {
        case "signed char": return "unsigned char"
        case "short": return "unsigned short"
        case "int": return "unsigned"
        case "long": return "unsigned long"
        case "__int128": return "unsigned __int128"
        default: return t.name.hasPrefix("_BitInt") ? "unsigned " + t.name : t.name
        }
    }

    func index(of t: CType) -> Int { Self.types.firstIndex { $0.name == t.name }! }

    mutating func constant(_ t: CType) -> String {
        if t.isFloat {
            let v = Double(Int64(bitPattern: rng.next()) % 100_000) / Double(1 + rng.below(1000))
            return "(\(v)\(t.name == "float" ? "f" : t.name == "long double" ? "L" : ""))"
        }
        if t.bits == 1 { return "\(rng.below(2))" }
        let v = rng.next() >> UInt64(64 - min(t.bits, 63))
        return "((\(t.name))\(v)ULL)"
    }

    /// The statements printing value `e` of type `t`.
    func print(_ e: String, _ t: CType) -> String {
        // The sign of a NaN an operation produces is unspecified (C23 F.10.13, and LLVM rewrites -(x*y) as x*-y)
        if t.isFloat {
            let fmt = t.name == "long double" ? "printf(\" %La\", (long double)v);" : "printf(\" %a\", (double)v);"
            return "{ \(t.name) v = \(e); if (v != v) printf(\" nan\"); else \(fmt) }"
        }
        if t.bits > 128 {
            let u = "unsigned _BitInt(\(t.bits))"
            let words = (t.bits + 63) / 64
            return "{ \(u) v = (\(u))(\(e)); printf(\" \"); for (int k = \(words - 1); k >= 0; k--) printf(\"%llx.\", (unsigned long long)(v >> (64 * k))); }"
        }
        if t.bits > 64 {
            return "{ unsigned __int128 v = (unsigned __int128)(\(e)); printf(\" %llx:%llx\", (unsigned long long)(v >> 64), (unsigned long long)v); }"
        }
        return "printf(\" %llx\", (unsigned long long)(\(e)));"
    }

    mutating func generate(functions: Int) -> String {
        var s = "#include <stdio.h>\n"
        s += "static long double clampf(long double x) { return x != x ? 0 : x > 60 ? 60 : x < -60 ? -60 : x; }\n"
        s += "static long double clampu(long double x) { return x != x ? 0 : x > 60 ? 60 : x < 0 ? 0 : x; }\n"
        for (k, t) in Self.types.enumerated() {
            for j in 0..<3 {
                var initial = constant(t)
                if t.isFloat && rng.chance(30) { initial = "-" + initial }
                s += "\(t.name) g\(k)_\(j) = \(initial);\n"
            }
            if t.isInteger {
                // Division and remainder defined for every operand: by zero or -1 the dividend is the result
                s += "static \(t.name) div_\(k)(\(t.name) a, \(t.name) b) { return b == 0 || b == (\(t.name))-1 ? a : a / b; }\n"
                s += "static \(t.name) mod_\(k)(\(t.name) a, \(t.name) b) { return b == 0 || b == (\(t.name))-1 ? a : a % b; }\n"
            }
        }
        var calls = ""
        for k in 0..<functions {
            let t = Self.types[rng.below(Self.types.count)]
            let e = expression(t, depth: 1 + rng.below(4))
            s += "void t\(k)(void) {\n  \(t.name) r = \(e);\n  printf(\"t\(k):\");\n  \(print("r", t))\n  printf(\"\\n\");\n"
            // Update a global, so later functions see stored values of the type
            let g = index(of: t)
            s += "  g\(g)_\(k % 3) = r;\n}\n"
            calls += "  t\(k)();\n"
        }
        s += "int main(void) {\n" + calls + "  return 0;\n}\n"
        return s
    }
}

@Suite("M3 — arithmetic and conversions against clang")
struct M3ArithmeticTests {
    @Test("Generated expressions", .enabled(if: CCorpora.hasClang),
          arguments: Array(1...(Int(ProcessInfo.processInfo.environment["SWIFTSTACK_ARITH_SEEDS"] ?? "") ?? 16)))
    func generated(seed: Int) throws {
        var gen = ArithmeticProgramGenerator(seed: UInt64(seed) &* 0x5DEE_CE66_D1CE)
        let source = gen.generate(functions: 150)
        let dir = ProgramRunner.scratch.appendingPathComponent("arith\(seed)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["SWIFTSTACK_KEEP_ABI"] == nil { try? FileManager.default.removeItem(at: dir) } }
        let path = dir.appendingPathComponent("arith.c").path
        try source.write(toFile: path, atomically: true, encoding: .utf8)

        let clangObject = try M3ABITests.clangObject(source, path)
        let reference = dir.appendingPathComponent("clang").path
        guard M3ABITests.link([clangObject], reference) else {
            Issue.record("seed \(seed): clang's program does not link")
            return
        }
        let (ourObject, message) = try M3ABITests.ownObject(path)
        guard let ourObject else {
            Issue.record("seed \(seed): does not compile: \(message.prefix(600))")
            return
        }
        let ours = dir.appendingPathComponent("ours").path
        guard M3ABITests.link([ourObject], ours) else {
            Issue.record("seed \(seed): does not link")
            return
        }
        let (refStatus, refOutput) = try ProgramRunner.run(reference)
        let (status, output) = try ProgramRunner.run(ours)
        #expect(status == refStatus, "seed \(seed): exits with \(status), clang's with \(refStatus)")
        guard output != refOutput else { return }
        // A second opinion where clang differs: GCC (Clang 22 converts unsigned _BitInt values with the top bit set
        // to floating types with the wrong sign, where GCC is right)
        let gccOutput: Data? = try {
            let binary = dir.appendingPathComponent("gcc").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["gcc", "-O0", "-w", "-std=c2x", path, "-o", binary]
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? try ProgramRunner.run(binary).output : nil
        }()
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let refLines = String(decoding: refOutput, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let gccLines = gccOutput.map { String(decoding: $0, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) }
        for k in 0..<max(lines.count, refLines.count) {
            let mine = k < lines.count ? lines[k] : "<end>"
            let theirs = k < refLines.count ? refLines[k] : "<end>"
            if mine == theirs { continue }
            if let gccLines, k < gccLines.count, gccLines[k] == mine { continue }
            let name = String(theirs.prefix { $0 != ":" })
            let body = source.components(separatedBy: "void \(name)(void) {\n").dropFirst().first?.split(separator: "\n").first ?? ""
            let gcc = gccLines.map { k < $0.count ? String($0[k]) : "<end>" } ?? "<no gcc>"
            Issue.record("seed \(seed): differs at line \(k + 1): '\(mine)' vs clang '\(theirs)', gcc '\(gcc)'\n\(body)")
            break
        }
    }
}
