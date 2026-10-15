import Foundation
import Testing
@testable import SwiftStack

// M1 exit criteria (09-roadmap.md §M1, §6.1): the C front end (preprocess → parse → type-check) must accept
// and reject the same programs as Clang. Each corpus is compared file by file against `clang -std=c23
// -fsyntax-only`. External corpora are located via environment variables (defaults are the reference
// workstation layout); a missing corpus or a missing `clang` marks the test as skipped, never as passed.

/// Runs the C front end in-process exactly as `swift-stack --dump=sem-ir` does.
enum CFrontendCheck {
    struct Outcome {
        let accepted: Bool
        let firstError: String
    }

    static func run(path: String, includePaths: [String] = []) throws -> Outcome {
        let sm = SourceManager()
        let fileId = try sm.loadFile(path: path)
        let pp = CPreprocessor(sourceManager: sm)
        pp.includePaths.append(contentsOf: includePaths)
        var tokens = TokenBuffer()
        pp.preprocess(fileId: fileId, into: &tokens)
        if pp.diagnostics.errorCount > 0 {
            return Outcome(accepted: false, firstError: firstLine(DiagnosticRenderer.render(diagnostics: pp.diagnostics, sourceManager: sm)))
        }
        let sf = sm[fileId]
        let tree = withUnsafePointer(to: tokens) { tokPtr in
            CParser(tokens: tokPtr, sourceBuffer: sf.buffer.baseAddress!, sourceLength: sf.length, sourceManager: sm).parse()
        }
        if tree.errorNodeCount > 0 {
            return Outcome(accepted: false, firstError: "syntax error")
        }
        let analyzer = CSemanticAnalyzer(typePool: TypePool(), sourceBuffer: sf.buffer.baseAddress!, sourceLength: sf.length, sourceManager: sm)
        let sem = analyzer.analyze(tree: tree, tokens: tokens)
        if sem.semModule.diagnosticBag.errorCount > 0 {
            return Outcome(accepted: false, firstError: firstLine(DiagnosticRenderer.render(diagnostics: sem.semModule.diagnosticBag, sourceManager: sm)))
        }
        return Outcome(accepted: true, firstError: "")
    }

    static func clangAccepts(path: String, includePaths: [String] = []) throws -> Bool {
        guard let clang = ExternalTool.find("clang") else { return false }
        let r = try ExternalTool.run(clang, ["-std=c23", "-fsyntax-only", "-w", path] + includePaths.map { "-I\($0)" })
        return r.status == 0
    }

    private static func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n").first ?? "")
    }
}

struct CCorpusFile: CustomTestStringConvertible, Sendable {
    let path: String
    let includePaths: [String]
    var testDescription: String { path.split(separator: "/").suffix(2).joined(separator: "/") }
}

enum CCorpora {
    static let env = ProcessInfo.processInfo.environment
    static var repoTests: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    static var hasClang: Bool { ExternalTool.find("clang") != nil }

    static func cFiles(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".c") }.sorted().map { "\(dir)/\($0)" }
    }

    /// Small programs probing individual C23 constraints (`Tests/Differential/c-accept-reject`).
    static var acceptReject: [CCorpusFile] {
        cFiles(in: repoTests.appendingPathComponent("Differential/c-accept-reject").path).map { CCorpusFile(path: $0, includePaths: []) }
    }

    /// c-testsuite (https://github.com/c-testsuite/c-testsuite), fetched into `External/` (09-roadmap.md §4.2).
    static var cTestsuiteDir: String {
        env["SWIFTSTACK_CTESTSUITE_ROOT"].map { "\($0)/tests/single-exec" }
            ?? repoTests.deletingLastPathComponent().appendingPathComponent("External/c-testsuite/tests/single-exec").path
    }
    static var cTestsuite: [CCorpusFile] { cFiles(in: cTestsuiteDir).map { CCorpusFile(path: $0, includePaths: []) } }

    static var sqlite: [CCorpusFile] {
        let dir = env["SWIFTSTACK_SQLITE_DIR"] ?? "/home/jkane/Projects/OS/freebsd-src/contrib/sqlite3"
        let file = "\(dir)/sqlite3.c"
        return FileManager.default.fileExists(atPath: file) ? [CCorpusFile(path: file, includePaths: [dir])] : []
    }

    static var lua: [CCorpusFile] {
        let dir = env["SWIFTSTACK_LUA_SRC"] ?? "/home/jkane/Projects/OS/AbyssBSD-old/contrib/lua/src"
        // FreeBSD's Lua build supplies `luaconf.local.h` from lib/liblua
        let extra = URL(fileURLWithPath: dir).appendingPathComponent("../../../lib/liblua").standardized.path
        return cFiles(in: dir).map { CCorpusFile(path: $0, includePaths: [dir, extra]) }
    }

    static var todhchai: [CCorpusFile] {
        let root = env["SWIFTSTACK_TODHCHAI_ROOT"] ?? "/home/jkane/Projects/OS/todhchai"
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        let skipped = ["build/", "cmake-build-debug/", ".cache/", ".build/", ".git/"]
        var includeDirs = ["system/libc", "sdk/capi/c/include", "system/ipc/tests/c/generated"].map { "\(root)/\($0)" }
        var sources: [String] = []
        while let rel = walker.nextObject() as? String {
            if skipped.contains(where: { rel.hasPrefix($0) || rel.contains("/\($0)") }) { continue }
            if rel.hasSuffix("/include") || rel == "include" { includeDirs.append("\(root)/\(rel)") }
            if rel.hasSuffix(".c") { sources.append("\(root)/\(rel)") }
        }
        includeDirs.sort()
        return sources.sorted().map { src in
            CCorpusFile(path: src, includePaths: [URL(fileURLWithPath: src).deletingLastPathComponent().path] + includeDirs)
        }
    }

    /// Every top-level glibc header that Clang accepts on its own, included from a one-line program.
    static var glibcHeaders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/usr/include")) ?? []).filter { $0.hasSuffix(".h") }.sorted()
    }
}

/// Known accept/reject divergences from Clang, each with its cause. The test fails on any other divergence,
/// and also when a listed one disappears, so the list always matches reality.
let knownAcceptRejectDivergences: [String: String] = [
    "a05_bitint.c": "`uwb`/`wb` literal suffixes not lexed",
    "b03_wb_suffix.c": "`uwb`/`wb` literal suffixes not lexed",
    "a21_tag_compat.c": "struct redefinition in the same scope not diagnosed",
    "b24_enum_redef.c": "enumerator redefinition not diagnosed",
    "r28_neg_array.c": "negative array size not diagnosed",
    "r29_bitfield_too_wide.c": "bit-field width larger than its type not diagnosed",
    "b01_attrs_ok.c": "`[[fallthrough]];` parsed as an expression statement",
    "b11_void_var.c": "file-scope `void` object not diagnosed",
    "b13_ternary.c": "struct/pointer `?:` operand mismatch not diagnosed when cast to void",
    "s5.c": "enum fixed underlying type ignored in sizeof",
    "x3.c": "incomplete struct object not diagnosed",
    "y11.c": "`_BitInt(N)` size not modeled",
    "y12.c": "`_BitInt(N)` size not modeled",
    "z11_bitint_size.c": "`_BitInt(N)` size not modeled",
    "y1.c": "block-scope struct tag does not shadow the file-scope tag (TypePool caches tags by name)",
    "y4.c": "integer constant evaluation is untyped (`sizeof(1ull)`)",
    "y5.c": "integer constant evaluation is untyped (`-1 < 0u`)",
    "z8_ull.c": "integer constant evaluation is untyped",
    "y6.c": "`sizeof` of an array expression in constant evaluation",
    "y7.c": "`sizeof` of an array expression in constant evaluation",
    "y9.c": "`sizeof` of an array expression in constant evaluation",
    "z6_array_size.c": "`sizeof` of an array expression in constant evaluation",
    "z7_ptr_arr.c": "`sizeof` through a parenthesized declarator",
    "z15_sizeof_complit.c": "`sizeof` of a compound literal in constant evaluation",
    "z1_bitfield_size.c": "bit-fields are laid out as whole storage units",
]

let knownCTestsuiteDivergences: [String: String] = [
    "00053.c": "member lookup through an anonymous/nested aggregate",
    "00089.c": "member lookup on a function-pointer struct member",
    "00098.c": "parse: unsupported declarator form",
    "00121.c": "parse: unsupported declarator form",
    "00152.c": "`#line` directive not implemented",
    "00162.c": "parse: unsupported declarator form",
    "00201.c": "macro rescanning: painted-blue / function-like name after expansion",
    "00210.c": "parse: unsupported declarator form",
    "00220.c": "parse: unsupported declarator form",
]

@Suite("M1 — C front end accept/reject against Clang")
struct M1AcceptRejectTests {

    static func compare(_ file: CCorpusFile, known: [String: String]) throws {
        let name = URL(fileURLWithPath: file.path).lastPathComponent
        let ours = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths)
        let clang = try CFrontendCheck.clangAccepts(path: file.path, includePaths: file.includePaths)
        let agrees = ours.accepted == clang
        if let reason = known[name] {
            #expect(!agrees, "\(name) now agrees with Clang; remove it from the known-divergence list (\(reason))")
        } else {
            #expect(agrees, "\(name): clang \(clang ? "accepts" : "rejects"), swift-stack \(ours.accepted ? "accepts" : "rejects") \(ours.firstError)")
        }
    }

    @Test("Constraint probes (Tests/Differential/c-accept-reject)", .enabled(if: CCorpora.hasClang), arguments: CCorpora.acceptReject)
    func probes(_ file: CCorpusFile) throws {
        try Self.compare(file, known: knownAcceptRejectDivergences)
    }

    @Test("c-testsuite single-exec programs", .enabled(if: CCorpora.hasClang && !CCorpora.cTestsuite.isEmpty), arguments: CCorpora.cTestsuite)
    func cTestsuite(_ file: CCorpusFile) throws {
        try Self.compare(file, known: knownCTestsuiteDivergences)
    }

    @Test("SQLite amalgamation", .enabled(if: CCorpora.hasClang && !CCorpora.sqlite.isEmpty), arguments: CCorpora.sqlite)
    func sqlite(_ file: CCorpusFile) throws {
        try Self.compare(file, known: [:])
    }

    @Test("Lua 5.4 sources", .enabled(if: CCorpora.hasClang && !CCorpora.lua.isEmpty), arguments: CCorpora.lua)
    func lua(_ file: CCorpusFile) throws {
        try Self.compare(file, known: [:])
    }

    @Test("Todhchai C sources", .enabled(if: CCorpora.hasClang && !CCorpora.todhchai.isEmpty), arguments: CCorpora.todhchai)
    func todhchai(_ file: CCorpusFile) throws {
        try Self.compare(file, known: [:])
    }

    @Test("Every glibc top-level header that Clang accepts", .enabled(if: CCorpora.hasClang && !CCorpora.glibcHeaders.isEmpty))
    func glibcHeaders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_glibc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var compared = 0
        for header in CCorpora.glibcHeaders {
            let path = dir.appendingPathComponent("h_\(header).c").path
            try "#include <\(header)>\nint main(void) { return 0; }\n".write(toFile: path, atomically: true, encoding: .utf8)
            guard try CFrontendCheck.clangAccepts(path: path) else { continue }
            let ours = try CFrontendCheck.run(path: path)
            #expect(ours.accepted, "<\(header)>: \(ours.firstError)")
            compared += 1
        }
        #expect(compared > 100)
    }
}
