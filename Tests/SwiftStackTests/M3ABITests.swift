import Foundation
import Testing
@testable import SwiftStack

// M3 phase 3: the System V x86-64 calling convention (04 §4.7.1) checked against clang. Generated functions with
// random signatures (integers, floats, `long double`, `__int128`, pointers, structs and unions of them, arrays and
// bit-fields inside, variadic arguments) are defined in one translation unit and called from another. Each unit is
// compiled by clang and by Swift-Stack, and every mix must print what the all-clang program prints.

extension SplitMix64 {
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// A C type in the generated programs.
indirect enum ABIGenType {
    case scalar(String)
    case record(name: String, isUnion: Bool, fields: [(name: String, type: ABIGenType, bits: Int?, count: Int?)])

    var cName: String {
        switch self {
        case .scalar(let n): return n
        case .record(let name, let isUnion, _): return (isUnion ? "union " : "struct ") + name
        }
    }
}

struct ABIProgramGenerator {
    var rng: SplitMix64
    var records: [ABIGenType] = []
    var counter = 0

    static let scalars = ["char", "signed char", "unsigned char", "short", "unsigned short", "int", "unsigned", "long",
                          "unsigned long", "long long", "_Bool", "float", "double", "long double", "__int128",
                          "unsigned __int128", "int *", "_BitInt(37)", "unsigned _BitInt(100)", "_BitInt(200)",
                          "_Float16", "__float128"]
    static let fieldScalars = ["char", "unsigned char", "short", "int", "unsigned", "long", "float", "double", "long double",
                               "int *", "_Bool"]

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func scalar(_ pool: [String]) -> ABIGenType { .scalar(pool[rng.below(pool.count)]) }

    mutating func record(depth: Int = 0) -> ABIGenType {
        let isUnion = rng.chance(15)
        let name = "R\(records.count)"
        var fields: [(String, ABIGenType, Int?, Int?)] = []
        let n = 1 + rng.below(isUnion ? 3 : 5)
        for k in 0..<n {
            if depth < 1 && rng.chance(15), !records.isEmpty {
                fields.append(("f\(k)", records[rng.below(records.count)], nil, nil))
            } else if !isUnion && rng.chance(12) {
                let t = ["unsigned", "int", "unsigned char", "unsigned short", "unsigned long"][rng.below(5)]
                let maxBits = t.contains("char") ? 8 : t.contains("short") ? 16 : t.contains("long") ? 64 : 32
                fields.append(("f\(k)", .scalar(t), 1 + rng.below(maxBits - 1), nil))
            } else if rng.chance(12) {
                fields.append(("f\(k)", scalar(["char", "short", "int", "float", "double"]), nil, 1 + rng.below(4)))
            } else {
                fields.append(("f\(k)", scalar(Self.fieldScalars), nil, nil))
            }
        }
        let r = ABIGenType.record(name: name, isUnion: isUnion, fields: fields)
        records.append(r)
        return r
    }

    mutating func type() -> ABIGenType {
        if rng.chance(45) { return rng.chance(30) && !records.isEmpty ? records[rng.below(records.count)] : record() }
        return scalar(Self.scalars)
    }

    /// Statements assigning a deterministic value to lvalue `e` of type `t`.
    mutating func assign(_ e: String, _ t: ABIGenType, into out: inout String) {
        counter += 1
        let v = counter
        switch t {
        case .scalar(let n):
            switch n {
            case "float", "double", "long double", "_Float16", "__float128":
                out += "  \(e) = \(Double(v) * 1.25 - 37.0 + 1.0 / Double(v + 2))\(n == "float" ? "f" : n == "long double" ? "L" : "");\n"
            case "_BitInt(37)", "unsigned _BitInt(100)", "_BitInt(200)":
                out += "  \(e) = ((\(n))\(v * 7919) << 30) * \(Int64(v) * 1_000_003) + \(v);\n"
            case "_Bool": out += "  \(e) = \(v % 2);\n"
            case "int *": out += "  \(e) = &pool[\(v % 16)];\n"
            case "__int128", "unsigned __int128":
                out += "  \(e) = ((\(n))\(v * 7919) << 64) | \(UInt64(v) &* 0x9E37_79B9_7F4A_7C15)ULL;\n"
            case "char", "signed char", "unsigned char": out += "  \(e) = \(v * 37 % 256 - 128);\n"
            case "short", "unsigned short": out += "  \(e) = \(v * 4099 % 65536 - 32768);\n"
            default: out += "  \(e) = \(Int64(v) * 1_000_003 * (v % 3 == 0 ? -1 : 1));\n"
            }
        case .record(_, let isUnion, let fields):
            for f in (isUnion ? Array(fields.prefix(1)) : fields) {
                if let count = f.count {
                    for k in 0..<count { assign("\(e).\(f.name)[\(k)]", f.type, into: &out) }
                } else if let bits = f.bits {
                    counter += 1
                    out += "  \(e).\(f.name) = \(counter * 13 % (1 << min(bits, 20)));\n"
                } else {
                    assign("\(e).\(f.name)", f.type, into: &out)
                }
            }
        }
    }

    /// Statements printing the value of `e` of type `t`.
    static func print(_ e: String, _ t: ABIGenType, into out: inout String) {
        switch t {
        case .scalar(let n):
            switch n {
            case "float", "double", "_Float16": out += "  printf(\" %a\", (double)\(e));\n"
            case "__float128":
                out += "  { __float128 q = \(e); unsigned long long w[2]; memcpy(w, &q, 16); printf(\" q%llx:%llx\", w[1], w[0]); }\n"
            case "_BitInt(37)", "unsigned _BitInt(100)", "_BitInt(200)":
                out += "  { unsigned _BitInt(256) b = (unsigned _BitInt(256))(\(e)); for (int k = 3; k >= 0; k--) printf(\"%s%llx\", k == 3 ? \" \" : \".\", (unsigned long long)(b >> (64 * k))); }\n"
            case "long double": out += "  printf(\" %La\", \(e));\n"
            case "int *": out += "  printf(\" p%ld\", (long)(\(e) - pool));\n"
            case "__int128", "unsigned __int128":
                out += "  printf(\" %llx:%llx\", (unsigned long long)((unsigned __int128)(\(e)) >> 64), (unsigned long long)(\(e)));\n"
            case "unsigned", "unsigned long", "unsigned long long", "unsigned char", "unsigned short", "_Bool":
                out += "  printf(\" %llu\", (unsigned long long)\(e));\n"
            default: out += "  printf(\" %lld\", (long long)\(e));\n"
            }
        case .record(_, let isUnion, let fields):
            for f in (isUnion ? Array(fields.prefix(1)) : fields) {
                if let count = f.count {
                    for k in 0..<count { print("\(e).\(f.name)[\(k)]", f.type, into: &out) }
                } else if f.bits != nil {
                    out += "  printf(\" b%llu\", (unsigned long long)\(e).\(f.name));\n"
                } else {
                    print("\(e).\(f.name)", f.type, into: &out)
                }
            }
        }
    }

    static func declare(_ r: ABIGenType) -> String {
        guard case .record(let name, let isUnion, let fields) = r else { return "" }
        var s = (isUnion ? "union " : "struct ") + name + " {"
        for f in fields {
            s += " \(f.type.cName) \(f.name)"
            if let count = f.count { s += "[\(count)]" }
            if let bits = f.bits { s += " : \(bits)" }
            s += ";"
        }
        return s + " };\n"
    }

    /// The two translation units: the callees, and `main` calling each.
    mutating func generate(functions: Int) -> (callee: String, caller: String) {
        var defs = "", calls = "", protos = ""
        for k in 0..<functions {
            let variadic = rng.chance(15)
            let n = variadic ? 1 + rng.below(6) : rng.below(10)
            let params = (0..<n).map { _ in type() }
            let result: ABIGenType? = rng.chance(20) ? nil : type()
            let named = variadic ? "int count, ..." : (params.isEmpty ? "void" : params.enumerated().map { "\($1.cName) a\($0)" }.joined(separator: ", "))
            let proto = "\(result?.cName ?? "void") fn\(k)(\(named))"
            protos += proto + ";\n"
            // The callee prints what it received and returns a value
            defs += proto + " {\n  printf(\"fn\(k):\");\n"
            if variadic {
                defs += "  va_list ap;\n  va_start(ap, count);\n"
                for (j, p) in params.enumerated() {
                    // Variadic arguments are promoted: float to double, small integers to int
                    let promoted: String
                    switch p.cName {
                    case "float": promoted = "double"
                    case "char", "signed char", "unsigned char", "short", "unsigned short", "_Bool": promoted = "int"
                    default: promoted = p.cName
                    }
                    defs += "  \(promoted) a\(j) = va_arg(ap, \(promoted));\n"
                    Self.print("a\(j)", p.cName == promoted ? p : .scalar(promoted), into: &defs)
                }
                defs += "  va_end(ap);\n"
            } else {
                for (j, p) in params.enumerated() { Self.print("a\(j)", p, into: &defs) }
            }
            defs += "  printf(\"\\n\");\n"
            if let result {
                defs += "  \(result.cName) r;\n  memset(&r, 0, sizeof r);\n"
                assign("r", result, into: &defs)
                defs += "  return r;\n"
            }
            defs += "}\n"
            // The caller builds the arguments, calls, and prints the result
            calls += "  {\n"
            for (j, p) in params.enumerated() {
                calls += "  \(p.cName) a\(j);\n  memset(&a\(j), 0, sizeof a\(j));\n"
                assign("a\(j)", p, into: &calls)
            }
            let args = (variadic ? ["\(n)"] : []) + params.indices.map { "a\($0)" }
            if let result {
                calls += "  \(result.cName) r = fn\(k)(\(args.joined(separator: ", ")));\n  printf(\"ret\(k):\");\n"
                Self.print("r", result, into: &calls)
                calls += "  printf(\"\\n\");\n"
            } else {
                calls += "  fn\(k)(\(args.joined(separator: ", ")));\n"
            }
            calls += "  }\n"
        }
        let header = "#include <stdio.h>\n#include <string.h>\n#include <stdarg.h>\nextern int pool[16];\n"
            + records.map(Self.declare).joined() + protos
        let callee = header + "int pool[16];\n" + defs
        let caller = header + "int main(void) {\n" + calls + "  return 0;\n}\n"
        return (callee, caller)
    }
}

@Suite("M3 — System V ABI against clang")
struct M3ABITests {
    static func clangObject(_ source: String, _ path: String) throws -> String {
        let object = path + ".clang.o"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["clang", "-c", "-O0", "-w", "-std=c2x", path, "-o", object]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return object
    }

    static func link(_ objects: [String], _ output: String) -> Bool {
        DriverPipeline.link(objects: objects, output: output, libraries: []) == 0
    }

    /// Our object for a C file (written beside it, or to `output`).
    static func ownObject(_ path: String, includePaths: [String] = [], defines: [(String, String)] = [],
                          output: String? = nil) throws -> (object: String?, message: String) {
        let outcome = try CFrontendCheck.run(path: path, includePaths: includePaths, defines: defines)
        guard outcome.accepted, let module = outcome.module else { return (nil, outcome.firstError) }
        let lowering = AIRLowering.lower(module)
        guard lowering.issues.isEmpty else { return (nil, "\(lowering.issues.prefix(3))") }
        let generated = X86CodeGenerator.generate(lowering.module, verifyAllocation: true)
        guard generated.issues.isEmpty else { return (nil, "\(generated.issues.prefix(3))") }
        var diagnostics = DiagnosticBag()
        let sm = SourceManager()
        let object = Assembler.assemble(source: generated.assembly, arch: .x86_64, sourceManager: sm, diagnostics: &diagnostics)
        guard diagnostics.errorCount == 0 else { return (nil, DiagnosticRenderer.render(diagnostics: diagnostics, sourceManager: sm)) }
        let out = output ?? path + ".ss.o"
        try Data(ELFObjectWriter.write(object)).write(to: URL(fileURLWithPath: out))
        return (out, "")
    }

    @Test("Generated calls across clang and Swift-Stack objects", .enabled(if: CCorpora.hasClang),
          arguments: Array(1...(Int(ProcessInfo.processInfo.environment["SWIFTSTACK_ABI_SEEDS"] ?? "") ?? 16)))
    func generated(seed: Int) throws {
        var gen = ABIProgramGenerator(seed: UInt64(seed) &* 0x1234_5678_9ABC)
        let (callee, caller) = gen.generate(functions: 60)
        let dir = ProgramRunner.scratch.appendingPathComponent("abi\(seed)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["SWIFTSTACK_KEEP_ABI"] == nil { try? FileManager.default.removeItem(at: dir) } }
        let calleePath = dir.appendingPathComponent("callee.c").path, callerPath = dir.appendingPathComponent("caller.c").path
        try callee.write(toFile: calleePath, atomically: true, encoding: .utf8)
        try caller.write(toFile: callerPath, atomically: true, encoding: .utf8)

        let clangCallee = try Self.clangObject(callee, calleePath), clangCaller = try Self.clangObject(caller, callerPath)
        let (ourCallee, m1) = try Self.ownObject(calleePath)
        let (ourCaller, m2) = try Self.ownObject(callerPath)
        guard let ourCallee, let ourCaller else {
            Issue.record("seed \(seed): does not compile: \(m1) \(m2)")
            return
        }
        var outputs: [String: Data] = [:]
        for (label, objects) in [("clang", [clangCallee, clangCaller]), ("ours-callee", [ourCallee, clangCaller]),
                                 ("ours-caller", [clangCallee, ourCaller]), ("ours", [ourCallee, ourCaller])] {
            let binary = dir.appendingPathComponent(label).path
            guard Self.link(objects, binary) else {
                Issue.record("seed \(seed): \(label) does not link")
                continue
            }
            let (status, output) = try ProgramRunner.run(binary)
            #expect(status == 0, "seed \(seed): \(label) exits with \(status)")
            outputs[label] = output
        }
        guard let reference = outputs["clang"] else { return }
        let refLines = String(decoding: reference, as: UTF8.self).split(separator: "\n")
        for (label, output) in outputs where label != "clang" && output != reference {
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
            let k = zip(lines, refLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(lines.count, refLines.count)
            Issue.record("seed \(seed): \(label) differs at line \(k + 1): '\(k < lines.count ? lines[k] : "<end>")' vs clang '\(k < refLines.count ? refLines[k] : "<end>")'")
        }
    }
}
