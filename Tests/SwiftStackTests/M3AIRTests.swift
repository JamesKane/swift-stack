import Foundation
import Testing
@testable import SwiftStack

// M3 phase 2 gates (milestones/M3-plan.md §2): every C corpus the M1 tests check lowers from SemIR to AIR without
// an unsupported construct, and the AIR verifier passes; golden `--dump=air` tests.

enum AIRCorpusCheck {
    /// Lowers a corpus file's SemIR to AIR (if the front end accepts it) and verifies it: the lowering issues and
    /// verifier issues, at most 8 of each.
    static func check(_ file: CCorpusFile) throws -> [String] {
        try CCorpora.prepare(file)
        let outcome = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
        guard outcome.accepted, let module = outcome.module else { return [] }
        // AIR is lowered for x86-64 in M3; other targets' corpora check the target-independent part
        let lowering = AIRLowering.lower(module)
        let verifier = AIRVerifier.verify(lowering.module)
        return lowering.issues.prefix(8).map { "lowering: \($0)" } + verifier.prefix(8).map { "verifier: \($0)" }
    }
}

/// Probes that AIR lowering does not support, each with its cause. The test fails if one of them lowers cleanly, so
/// the list always matches reality.
let knownAIRUnsupported: [String: String] = [
    "b15_complex_ok.c": "_Complex is not supported (02 §4.2.6): the object has no type sema models, so no data image",
]

@Suite("M3 — AIR lowering and verifier on the C corpora")
struct M3AIRCorpusTests {
    static func check(_ file: CCorpusFile) throws {
        let issues = try AIRCorpusCheck.check(file)
        if let reason = knownAIRUnsupported[URL(fileURLWithPath: file.path).lastPathComponent] {
            #expect(!issues.isEmpty, "\(file.testDescription) now lowers; remove it from knownAIRUnsupported (\(reason))")
            return
        }
        #expect(issues.isEmpty, "\(file.testDescription): \(issues.joined(separator: "\n"))")
    }

    @Test("Constraint probes", arguments: CCorpora.acceptReject)
    func probes(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("c-testsuite single-exec programs", .enabled(if: !CCorpora.cTestsuite.isEmpty), arguments: CCorpora.cTestsuite)
    func cTestsuite(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("SQLite amalgamation", .enabled(if: !CCorpora.sqlite.isEmpty), arguments: CCorpora.sqlite)
    func sqlite(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("Lua 5.4 sources", .enabled(if: !CCorpora.lua.isEmpty), arguments: CCorpora.lua)
    func lua(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("VectraOS C sources (per architecture)", .enabled(if: CCorpora.vectraOS.count == 36), arguments: CCorpora.vectraOS)
    func vectraOS(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("VectraOS headers (per architecture)", .enabled(if: !CCorpora.vectraOSHeaders.isEmpty && CCorpora.hasClang),
          arguments: CCorpora.vectraOSHeaders)
    func vectraOSHeaders(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("glibc top-level headers", .enabled(if: !CCorpora.glibcHeaders.isEmpty))
    func glibcHeaders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_m3_air_glibc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var checked = 0
        for header in CCorpora.glibcHeaders {
            let path = dir.appendingPathComponent("h_\(header).c").path
            try "#include <\(header)>\nint main(void) { return 0; }\n".write(toFile: path, atomically: true, encoding: .utf8)
            let issues = try AIRCorpusCheck.check(CCorpusFile(path: path, includePaths: []))
            #expect(issues.isEmpty, "<\(header)>: \(issues.joined(separator: "\n"))")
            checked += 1
        }
        #expect(checked > 100)
    }

    /// The AIR of each corpus, for the M3 plan's record: functions, instructions, blocks and symbols.
    @Test("Corpus totals")
    func totals() throws {
        let corpora: [(String, [CCorpusFile])] = [("c-testsuite", CCorpora.cTestsuite), ("SQLite", CCorpora.sqlite), ("Lua", CCorpora.lua),
                                                  ("VectraOS", CCorpora.vectraOS)]
        for (name, files) in corpora where !files.isEmpty {
            var functions = 0, instructions = 0, blocks = 0, symbols = 0, issues = 0
            for file in files {
                let outcome = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
                guard let module = outcome.module else { continue }
                let lowering = AIRLowering.lower(module)
                issues += lowering.issues.count + AIRVerifier.verify(lowering.module).count
                functions += lowering.module.functions.count
                instructions += lowering.module.totalInstructions
                blocks += lowering.module.functions.reduce(0) { $0 + Int($1.function.blockCount) - 1 }
                symbols += lowering.module.symbols.count
            }
            print("AIR \(name): \(files.count) files, \(functions) functions, \(instructions) instructions, \(blocks) blocks, \(symbols) symbols, \(issues) issues")
            #expect(issues == 0)
        }
    }
}

/// Golden `--dump=air` tests (`Tests/Golden/air`): each `.c` file's AIR for x86-64, verified and compared with the
/// `.air` file beside it. `SWIFTSTACK_UPDATE_GOLDEN=1` rewrites the expectations; review the diff.
@Suite("M3 — golden AIR dumps")
struct M3AIRGoldenTests {
    static var directory: String { CCorpora.repoTests.appendingPathComponent("Golden/air").path }
    static var sources: [String] { CCorpora.cFiles(in: directory) }

    @Test("Golden AIR", arguments: sources)
    func golden(_ path: String) throws {
        let outcome = try CFrontendCheck.run(path: path, target: CTarget(arch: "x86_64", triple: "x86_64-unknown-linux-gnu", flags: []))
        let module = try #require(outcome.module, "\(path): \(outcome.firstError)")
        let lowering = AIRLowering.lower(module)
        #expect(lowering.issues.isEmpty, "\(path): \(lowering.issues.prefix(5))")
        let issues = AIRVerifier.verify(lowering.module)
        #expect(issues.isEmpty, "\(path): \(issues.prefix(5))")

        let actual = lowering.module.dumpText()
        let expectedPath = String(path.dropLast(2)) + ".air"
        if ProcessInfo.processInfo.environment["SWIFTSTACK_UPDATE_GOLDEN"] == "1" {
            try actual.write(toFile: expectedPath, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOfFile: expectedPath, encoding: .utf8)
        if actual != expected {
            let a = actual.split(separator: "\n", omittingEmptySubsequences: false), e = expected.split(separator: "\n", omittingEmptySubsequences: false)
            let line = zip(a, e).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, e.count)
            Issue.record("\(expectedPath):\(line + 1): expected '\(line < e.count ? e[line] : "<end>")', got '\(line < a.count ? a[line] : "<end>")'")
        }
    }
}

/// The verifier itself: functions built by hand with one defect each are rejected with the expected message, and a
/// well-formed one is accepted.
@Suite("M3 — AIR verifier")
struct M3AIRVerifierTests {
    /// A module holding one function `int f(int)` built by `build`; the verifier's messages.
    static func issues(_ build: (inout AIRBuilder) -> Void) -> [String] {
        let pool = TypePool()
        let module = AIRModule(typePool: pool)
        let fnType = pool.functionType(returnType: .int, paramTypes: [.int])
        let s = module.add(AIRSymbol(name: "f", kind: .function, linkage: .external, isThreadLocal: false, isConstant: true,
                                     cType: QualType(typeId: fnType), size: 0, alignment: 1, isTentative: false, image: nil, function: 0))
        var b = AIRBuilder()
        build(&b)
        let f = b.finish(symbol: s, name: "f", cType: fnType, returnType: .i32, returnsAggregate: false, paramTypes: [.i32],
                         paramIsAggregate: [false])
        module.functions.append(AIRFunctionBox(f))
        return AIRVerifier.verify(module).map(\.message)
    }

    @Test("A well-formed function passes")
    func wellFormed() {
        let found = Self.issues { b in
            let x = b.emit(.add, .i32, .parameter(0), b.constants.intern(.i32, [1]))
            let then = b.newBlock(), join = b.newBlock()
            let c = b.emit(.icmp, .i1, x, .parameter(0), aux: AIRICmp.sgt.rawValue)
            b.emit(.condBr, .void, c.rawIndex, then.rawIndex, aux: join.rawIndex)
            let entry = b.current
            b.position(at: then)
            let y = b.emit(.mul, .i32, x, x)
            b.branch(to: join)
            b.position(at: join)
            let merged = b.emit(.phi, .i32, aux: b.list([entry.rawIndex, x.rawIndex, then.rawIndex, y.rawIndex]))
            b.emit(.ret, .void, merged)
        }
        #expect(found.isEmpty, "\(found)")
    }

    @Test("Defects are reported")
    func defects() {
        // Operand types
        let mixed = Self.issues { b in
            let wide = b.emit(.sext, .i64, .parameter(0))
            b.emit(.ret, .void, b.emit(.add, .i32, .parameter(0), wide))
        }
        #expect(mixed.contains { $0.contains("add: i32, i64 -> i32") }, "\(mixed)")
        // A use its definition does not dominate
        let undominated = Self.issues { b in
            let other = b.newBlock(), join = b.newBlock()
            let c = b.emit(.icmp, .i1, .parameter(0), b.constants.intern(.i32, [0]), aux: AIRICmp.eq.rawValue)
            b.emit(.condBr, .void, c.rawIndex, other.rawIndex, aux: join.rawIndex)
            b.position(at: other)
            let v = b.emit(.add, .i32, .parameter(0), .parameter(0))
            b.branch(to: join)
            b.position(at: join)
            b.emit(.ret, .void, v)
        }
        #expect(undominated.contains { $0.contains("does not dominate its use") }, "\(undominated)")
        // A phi missing a predecessor's value, and a result of the wrong type
        let badPhi = Self.issues { b in
            let other = b.newBlock(), join = b.newBlock()
            let c = b.emit(.icmp, .i1, .parameter(0), b.constants.intern(.i32, [0]), aux: AIRICmp.eq.rawValue)
            b.emit(.condBr, .void, c.rawIndex, other.rawIndex, aux: join.rawIndex)
            b.position(at: other)
            b.branch(to: join)
            b.position(at: join)
            let p = b.emit(.phi, .i32, aux: b.list([other.rawIndex, UInt32(0x8000_0001)]))
            b.emit(.ret, .void, b.emit(.zext, .i64, p))
        }
        #expect(badPhi.contains { $0.contains("no value from predecessor") }, "\(badPhi)")
        #expect(badPhi.contains { $0.contains("returns i64 from a function returning i32") }, "\(badPhi)")
        // A block without a terminator
        let open = Self.issues { b in
            _ = b.emit(.add, .i32, .parameter(0), .parameter(0))
        }
        #expect(open.contains { $0.contains("does not end in a terminator") }, "\(open)")
    }
}
