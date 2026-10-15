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

    static func run(path: String, includePaths: [String] = [], target: CTarget? = nil) throws -> Outcome {
        let sm = SourceManager()
        let fileId = try sm.loadFile(path: path)
        let pp = CPreprocessor(sourceManager: sm)
        pp.includePaths.append(contentsOf: includePaths)
        if let target {
            // `-ffreestanding --target=<triple>`: the target's arch macros, no hosted OS, and the compiler's own
            // freestanding headers (`<stdint.h>`, `<stddef.h>`, `<stdbool.h>`) in place of glibc's.
            pp.configureTargetArch(target.arch)
            pp.defineMacro("__STDC_HOSTED__", replacement: "0")
            for name in ["__linux__", "__linux", "__gnu_linux__", "__unix__", "__unix", "_GNU_SOURCE"] {
                pp.undefMacro(name)
            }
            pp.systemIncludePaths = freestandingIncludePaths
            for (name, value) in DifferentialAssembly.defines(in: target.flags) {
                pp.defineMacro(name, replacement: value)
            }
        }
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
            // Point at the first error node's token, so a divergence report says where parsing failed.
            var at = ""
            for i in 0..<tree.count where tree.kinds[NodeId(i)] == CNodeKind.errorNode.rawValue {
                let tok = TokenId(tree.tokens[NodeId(i)])
                let loc = tokens.start(of: tok)
                if let (file, offset) = sm.file(containing: loc) {
                    let (line, column) = file.lineTable().lineAndColumn(at: offset)
                    at = " at \(file.path):\(line):\(column) near '\(sm.text(from: loc, to: tokens.end(of: tok)) ?? "")'"
                }
                break
            }
            return Outcome(accepted: false, firstError: "syntax error" + at)
        }
        let analyzer = CSemanticAnalyzer(typePool: TypePool(), sourceBuffer: sf.buffer.baseAddress!, sourceLength: sf.length, sourceManager: sm)
        let sem = analyzer.analyze(tree: tree, tokens: tokens)
        if sem.semModule.diagnosticBag.errorCount > 0 {
            return Outcome(accepted: false, firstError: firstLine(DiagnosticRenderer.render(diagnostics: sem.semModule.diagnosticBag, sourceManager: sm)))
        }
        return Outcome(accepted: true, firstError: "")
    }

    static func clangAccepts(path: String, includePaths: [String] = [], target: CTarget? = nil) throws -> Bool {
        guard let clang = ExternalTool.find("clang") else { return false }
        let cross = target.map { ["--target=\($0.triple)", "-ffreestanding"] + $0.flags } ?? []
        let r = try ExternalTool.run(clang, ["-std=c23", "-fsyntax-only", "-w"] + cross + [path] + includePaths.map { "-I\($0)" })
        return r.status == 0
    }

    /// Clang's resource-directory headers, the freestanding set a `-ffreestanding` cross build sees.
    static let freestandingIncludePaths: [String] = {
        guard let clang = ExternalTool.find("clang"),
              let r = try? ExternalTool.run(clang, ["-print-resource-dir"]), r.status == 0 else { return [] }
        return [r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + "/include"]
    }()

    private static func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n").first ?? "")
    }
}

/// A freestanding cross target for the C front end: the arch whose predefined macros apply, the clang triple, and
/// the clang flags (arch flags and `-D` definitions) of the build being reproduced.
struct CTarget: Sendable {
    let arch: String
    let triple: String
    let flags: [String]
}

struct CCorpusFile: CustomTestStringConvertible, Sendable {
    let path: String
    let includePaths: [String]
    var target: CTarget? = nil
    /// For a header checked on its own: the header's path, and the translation unit (`#include <...>`) written to
    /// `path` before the comparison.
    var header: String? = nil
    var source: String? = nil
    var testDescription: String {
        let name = (header ?? path).split(separator: "/").suffix(2).joined(separator: "/")
        return target.map { "\($0.arch): \(name)" } ?? name
    }
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

    static let vectraRoot = env["SWIFTSTACK_VECTRAOS_ROOT"] ?? "/home/jkane/Projects/OS/VectraOS-swift"

    /// VectraOS's C23 for each architecture, with the flags its CMake build uses (`cmake/toolchain.cmake`, the
    /// per-arch files in `cmake/arch/`, the user-binary rules in `cmake/`, and the `CMakeLists.txt` of `kernel/`
    /// and `lib/rt/`): the loader, the kernel and `lib/rt` with the kernel flag set and `-DNDEBUG`; the user
    /// runtime, `usertest` and the vDSO with the user flag set.
    static var vectraOS: [CCorpusFile] {
        let root = vectraRoot
        guard FileManager.default.fileExists(atPath: "\(root)/cmake/toolchain.cmake") else { return [] }
        var files: [CCorpusFile] = []
        for t in vectraOSTargets {
            func file(_ rel: String, _ inc: [String], _ flags: [String]) -> CCorpusFile {
                CCorpusFile(path: "\(root)/\(rel)", includePaths: inc.map { "\(root)/\($0)" },
                            target: CTarget(arch: t.arch, triple: t.triple, flags: flags))
            }
            let kernel = t.kernelFlags + ["-DNDEBUG"]
            files.append(file("boot/entry.c", ["boot/include"], kernel))
            files.append(file("kernel/trace.c", ["kernel/include"], kernel + t.kernelCFlags))
            for name in ["string", "int128", "stack_protector"] {
                files.append(file("lib/rt/\(name).c", [], kernel + t.rtFlags))
            }
            let userInc = ["user/include", "kernel/include"]
            for name in ["start", "stdout", "malloc", "timing", "image"] {
                files.append(file("user/lib/runtime/\(name).c", userInc, t.userFlags))
            }
            files.append(file("user/test/usertest.c", userInc, t.userFlags))
            files.append(file("user/vdso/vdso.c", userInc, t.userFlags))
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every VectraOS header on its own, for each architecture, included from a one-line translation unit with the
    /// include paths of the targets that use it. The kernel, loader, handoff and runtime headers are also imported
    /// into Embedded Swift through their module maps.
    static var vectraOSHeaders: [CCorpusFile] {
        let root = vectraRoot
        guard FileManager.default.fileExists(atPath: "\(root)/cmake/toolchain.cmake") else { return [] }
        func headers(_ dir: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? []).filter { $0.hasSuffix(".h") }.sorted()
        }
        let tuDir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_vectraos_headers").path
        var files: [CCorpusFile] = []
        for t in vectraOSTargets {
            // (directory, include paths, prefix in `#include <...>`, flags)
            let groups: [(String, [String], String, [String])] = [
                ("kernel/include", ["kernel/include"], "", t.kernelFlags + t.kernelCFlags),
                ("boot/include", ["boot/include", "lib/handoff/include"], "", t.kernelFlags),
                ("lib/handoff/include", ["lib/handoff/include"], "", t.kernelFlags),
                ("user/include/croi", ["user/include", "kernel/include"], "croi/", t.userFlags),
            ]
            for (dir, inc, prefix, flags) in groups {
                for h in headers(dir) {
                    files.append(CCorpusFile(
                        path: "\(tuDir)/\(t.arch)_\(dir.replacingOccurrences(of: "/", with: "_"))_\(h).c",
                        includePaths: inc.map { "\(root)/\($0)" }, target: CTarget(arch: t.arch, triple: t.triple, flags: flags),
                        header: "\(dir)/\(h)", source: "#include <\(prefix)\(h)>\n"))
                }
            }
        }
        return files
    }

    /// Writes the translation unit of a header entry.
    static func prepare(_ file: CCorpusFile) throws {
        guard let source = file.source else { return }
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: file.path).deletingLastPathComponent().path,
                                                withIntermediateDirectories: true)
        try source.write(toFile: file.path, atomically: true, encoding: .utf8)
    }

    /// Per architecture: the target's arch name and clang triple, the kernel flag set (also the loader's and
    /// `lib/rt`'s), what the kernel adds for its C (`kernel/CMakeLists.txt`) and `lib/rt` adds
    /// (`lib/rt/CMakeLists.txt`), and the user flag set.
    static let vectraOSTargets: [(arch: String, triple: String, kernelFlags: [String], kernelCFlags: [String], rtFlags: [String],
                                  userFlags: [String])] = [
        ("x86_64", "x86_64-unknown-none-elf", ["-mno-red-zone", "-mgeneral-regs-only"], [], [], []),
        ("aarch64", "aarch64-unknown-none-elf", ["-mgeneral-regs-only"], ["-mbranch-protection=pac-ret+bti"],
         ["-mbranch-protection=bti"], ["-mbranch-protection=bti"]),
        ("riscv64", "riscv64-unknown-none-elf", ["-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany"], [], [],
         ["-march=rv64gc", "-mabi=lp64d", "-mcmodel=medany"]),
    ]

    /// Every top-level glibc header that Clang accepts on its own, included from a one-line program.
    static var glibcHeaders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/usr/include")) ?? []).filter { $0.hasSuffix(".h") }.sorted()
    }
}

/// Known accept/reject divergences from Clang, each with its cause. The test fails on any other divergence,
/// and also when a listed one disappears, so the list always matches reality.
let knownAcceptRejectDivergences: [String: String] = [:]

let knownCTestsuiteDivergences: [String: String] = [:]

@Suite("M1 — C front end accept/reject against Clang")
struct M1AcceptRejectTests {

    static func compare(_ file: CCorpusFile, known: [String: String]) throws {
        try CCorpora.prepare(file)
        let name = file.header == nil ? URL(fileURLWithPath: file.path).lastPathComponent : file.testDescription
        let ours = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
        let clang = try CFrontendCheck.clangAccepts(path: file.path, includePaths: file.includePaths, target: file.target)
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

    @Test("VectraOS C sources (12 files, per architecture, freestanding)",
          .enabled(if: CCorpora.hasClang && CCorpora.vectraOS.count == 36), arguments: CCorpora.vectraOS)
    func vectraOS(_ file: CCorpusFile) throws {
        try Self.compare(file, known: [:])
    }

    @Test("VectraOS headers, each on its own (per architecture, freestanding)",
          .enabled(if: CCorpora.hasClang && !CCorpora.vectraOSHeaders.isEmpty), arguments: CCorpora.vectraOSHeaders)
    func vectraOSHeaders(_ file: CCorpusFile) throws {
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
