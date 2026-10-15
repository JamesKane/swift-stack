import Foundation
import Testing
@testable import SwiftStack

// M3 phase 1 gates (milestones/M3-plan.md §2): the SemIR verifier passes on every C corpus the M1 tests check, and
// golden `--dump=sem-ir` tests. The layout and data-image comparisons with clang are in M3ClangProbeTests.

enum SemIRCorpusCheck {
    /// Front-end counts over a corpus, for the gate report.
    final class Totals: @unchecked Sendable {
        private let lock = NSLock()
        var files = 0, instructions = 0, unmodeled = 0, poisoned = 0, globals = 0, imagesMissing = 0
        var missingReasons: [String: Int] = [:]

        func add(_ s: SemIRVerifier.Summary, globals: [SemGlobal]) {
            lock.lock()
            defer { lock.unlock() }
            files += 1
            instructions += s.instructions
            unmodeled += s.unmodeled
            poisoned += s.poisoned
            self.globals += globals.count
            for g in globals where g.image == nil {
                imagesMissing += 1
                missingReasons[g.unsupportedReason, default: 0] += 1
            }
        }
    }

    static let totals = Totals()

    /// Runs the front end on a corpus file; if it is accepted (accept/reject is the M1 gate), verifies its SemIR.
    static func verify(_ file: CCorpusFile) throws -> [String] {
        try CCorpora.prepare(file)
        let outcome = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
        guard outcome.accepted, let module = outcome.module else { return [] }
        var verifier = SemIRVerifier(module: module)
        verifier.run()
        totals.add(verifier.summary, globals: module.globals)
        return verifier.issues.prefix(8).map { "\($0)  [\(describe($0, module))]" }
    }

    /// The instruction an issue is about, as `--dump=sem-ir` prints it.
    static func describe(_ issue: SemIRVerifier.Issue, _ module: SemModule) -> String {
        let c = module.block(InstBlockId(UInt32(issue.block)))
        guard issue.inst > 0, issue.inst < c.block.count else { return "" }
        return module.format(SemInstId(issue.inst), c)
    }
}

@Suite("M3 — SemIR verifier on the C corpora")
struct M3SemIRCorpusTests {
    static func check(_ file: CCorpusFile) throws {
        let issues = try SemIRCorpusCheck.verify(file)
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

    /// The share of each corpus that sema leaves unmodeled, and the static objects without a data image: printed
    /// for the M3 plan's record, and bounded so that a regression shows.
    @Test("Corpus totals: unmodeled instructions and missing data images")
    func totals() throws {
        let corpora: [(String, [CCorpusFile])] = [("c-testsuite", CCorpora.cTestsuite), ("SQLite", CCorpora.sqlite), ("Lua", CCorpora.lua),
                                                  ("VectraOS", CCorpora.vectraOS)]
        for (name, files) in corpora where !files.isEmpty {
            var s = SemIRVerifier.Summary()
            var globals = 0, missing = 0, issues = 0
            var reasons: [String: Int] = [:]
            for file in files {
                let outcome = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
                guard let module = outcome.module else { continue }
                var v = SemIRVerifier(module: module)
                v.run()
                issues += v.issues.count
                s.instructions += v.summary.instructions
                s.unmodeled += v.summary.unmodeled
                s.poisoned += v.summary.poisoned
                s.functions += v.summary.functions
                globals += module.globals.count
                for g in module.globals where g.image == nil {
                    missing += 1
                    reasons[g.unsupportedReason, default: 0] += 1
                }
            }
            print("SemIR \(name): \(files.count) files, \(s.functions) functions, \(s.instructions) instructions, \(s.unmodeled) unmodeled, "
                  + "\(s.poisoned) poisoned, \(issues) verifier issues; \(globals) static objects, \(missing) without an image \(reasons)")
            #expect(issues == 0)
            #expect(s.unmodeled * 100 <= s.instructions, "\(name): over 1% of instructions unmodeled")
        }
    }

    @Test("glibc top-level headers", .enabled(if: !CCorpora.glibcHeaders.isEmpty))
    func glibcHeaders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_m3_glibc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var verified = 0
        for header in CCorpora.glibcHeaders {
            let path = dir.appendingPathComponent("h_\(header).c").path
            try "#include <\(header)>\nint main(void) { return 0; }\n".write(toFile: path, atomically: true, encoding: .utf8)
            let issues = try SemIRCorpusCheck.verify(CCorpusFile(path: path, includePaths: []))
            #expect(issues.isEmpty, "<\(header)>: \(issues.joined(separator: "\n"))")
            verified += 1
        }
        #expect(verified > 100)
    }
}

/// Golden `--dump=sem-ir` tests (`Tests/Golden/sem-ir`): each `.c` file's SemIR for x86-64, verified and compared with
/// the `.sem-ir` file beside it. `SWIFTSTACK_UPDATE_GOLDEN=1` rewrites the expectations; review the diff.
@Suite("M3 — golden SemIR dumps")
struct M3SemIRGoldenTests {
    static var directory: String { CCorpora.repoTests.appendingPathComponent("Golden/sem-ir").path }
    static var sources: [String] { CCorpora.cFiles(in: directory) }

    @Test("Golden SemIR", arguments: sources)
    func golden(_ path: String) throws {
        let outcome = try CFrontendCheck.run(path: path, target: CTarget(arch: "x86_64", triple: "x86_64-unknown-linux-gnu", flags: []))
        let module = try #require(outcome.module, "\(path): \(outcome.firstError)")
        var verifier = SemIRVerifier(module: module)
        verifier.run()
        #expect(verifier.issues.isEmpty, "\(path): \(verifier.issues.prefix(5))")
        #expect(verifier.summary.unmodeled == 0, "\(path): unmodeled instructions")

        let actual = module.dumpText()
        let expectedPath = String(path.dropLast(2)) + ".sem-ir"
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
