import Foundation
import Testing
@testable import SwiftStack

// M2 exit criterion (09-roadmap.md §M2, §6.1; 05-assembler.md §4.11): assembly corpora assemble identically
// to the oracles. Section bytes, section flags/alignment, relocations and symbols are all compared.
//
// External corpora are located via environment variables (defaults are the reference workstation layout).
// A missing corpus or oracle tool marks the test as *skipped* rather than letting it pass vacuously.

struct AsmCorpusFile: CustomTestStringConvertible, Sendable {
    let path: String
    let arch: AssemblerArch
    let includePaths: [String]
    let clangFlags: [String]
    var testDescription: String { path.split(separator: "/").suffix(3).joined(separator: "/") }

    var target: DifferentialAssembly.Target {
        let base = DifferentialAssembly.target(for: arch)
        return DifferentialAssembly.Target(arch: arch, clangTriple: base.clangTriple, clangFlags: clangFlags)
    }
}

enum AsmCorpora {
    static let env = ProcessInfo.processInfo.environment
    static let todhchaiRoot = env["SWIFTSTACK_TODHCHAI_ROOT"] ?? "/home/jkane/Projects/OS/todhchai"
    static let croiRoot = env["SWIFTSTACK_CROI_ROOT"] ?? "/home/jkane/Projects/OS/croi"
    static var todhchaiEntryDir: String { "\(todhchaiRoot)/system/sys/floor/entry" }
    static var croiArchDir: String { "\(croiRoot)/kernel/arch" }

    /// In-repo corpus (`Tests/Differential/asm/<arch>/*.S`): always available, covers fixed regressions.
    static var inRepoDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Differential/asm").path
    }

    static func listS(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".S") || $0.hasSuffix(".s") }
            .sorted()
            .map { "\(dir)/\($0)" }
    }

    static var todhchai: [AsmCorpusFile] {
        let d = todhchaiEntryDir
        return [
            AsmCorpusFile(path: "\(d)/amd64.S", arch: .x86_64, includePaths: [d], clangFlags: []),
            AsmCorpusFile(path: "\(d)/arm64.S", arch: .aarch64, includePaths: [d], clangFlags: []),
            AsmCorpusFile(path: "\(d)/rv64.S", arch: .riscv64, includePaths: [d], clangFlags: ["-march=rv64gc", "-mabi=lp64d", "-mno-relax"]),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var croi: [AsmCorpusFile] {
        let inc = ["\(croiRoot)/kernel/include", "\(croiRoot)/kernel"]
        var files: [AsmCorpusFile] = []
        for (dir, arch) in [("amd64", AssemblerArch.x86_64), ("arm64", .aarch64), ("rv64", .riscv64)] {
            let archDir = "\(croiArchDir)/\(dir)"
            for p in listS(archDir) {
                files.append(AsmCorpusFile(path: p, arch: arch, includePaths: inc + [archDir], clangFlags: DifferentialAssembly.target(for: arch).clangFlags))
            }
        }
        return files
    }

    static var inRepo: [AsmCorpusFile] {
        var files: [AsmCorpusFile] = []
        for (dir, arch) in [("x86_64", AssemblerArch.x86_64), ("aarch64", .aarch64), ("riscv64", .riscv64)] {
            for p in listS("\(inRepoDir)/\(dir)") {
                files.append(AsmCorpusFile(path: p, arch: arch, includePaths: [], clangFlags: DifferentialAssembly.target(for: arch).clangFlags))
            }
        }
        return files
    }

    static var hasClang: Bool { ExternalTool.find("clang") != nil }
    static var hasGNUAs: Bool { ExternalTool.find("gcc") != nil && ExternalTool.find("as") != nil }
}

/// Differences from GNU `as` on x86-64 that are intentional and documented in 05-assembler.md §4.11.
/// Swift-Stack follows LLVM MC for these, and the clang comparison still checks those sections exactly:
/// - `.text` alignment (LLVM MC: 4, GNU: 1);
/// - multi-byte NOP padding (LLVM MC: one 6-byte `nopw`; GNU: `nop` + 5-byte `nopl`);
/// - a memory displacement given by a label difference unresolved at parse time is encoded as `disp32`
///   (GNU `as` relaxes it to `disp8`), which changes the size of the containing section.
func gnuDocumentedDifferences(for file: AsmCorpusFile) -> DiffOptions {
    var opts = DiffOptions(compareAlignment: false)
    if file.path.hasSuffix("/kernel/arch/amd64/smp.S") {
        opts.excludedSections = [".text.arch_ap_prepare_trampoline"]  // `lea T_OFF(t_gdt)(%rsi), %rax`
        opts.bytesExemptSections = [".text.ap_trampoline"]              // NOP padding before `.balign 8` data
    }
    return opts
}

@Suite("M2 — Differential assembly against clang and GNU as")
struct M2DifferentialAssemblyTests {

    static func check(_ file: AsmCorpusFile, oracle: TestELF, options: DiffOptions = DiffOptions(), oracleName: String) throws {
        let (ours, errors) = try DifferentialAssembly.assembleOurs(path: file.path, target: file.target, includePaths: file.includePaths)
        #expect(errors == 0, "\(file.testDescription): \(errors) assembler errors")
        let diffs = NormalizedObject(ours).differences(from: NormalizedObject(oracle), options: options)
        #expect(diffs.isEmpty, Comment(rawValue: "\(file.testDescription) vs \(oracleName):\n  " + diffs.prefix(25).joined(separator: "\n  ")))
    }

    @Test("In-repo corpus matches clang (bytes, relocations, symbols)", .enabled(if: AsmCorpora.hasClang), arguments: AsmCorpora.inRepo)
    func inRepoVsClang(_ file: AsmCorpusFile) throws {
        try Self.check(file, oracle: DifferentialAssembly.assembleWithClang(path: file.path, target: file.target, includePaths: file.includePaths), oracleName: "clang")
    }

    @Test("Todhchai floor entry stubs match clang", .enabled(if: AsmCorpora.hasClang && !AsmCorpora.todhchai.isEmpty), arguments: AsmCorpora.todhchai)
    func todhchaiVsClang(_ file: AsmCorpusFile) throws {
        try Self.check(file, oracle: DifferentialAssembly.assembleWithClang(path: file.path, target: file.target, includePaths: file.includePaths), oracleName: "clang")
    }

    @Test("Croi kernel arch assembly matches clang", .enabled(if: AsmCorpora.hasClang && AsmCorpora.croi.count == 21), arguments: AsmCorpora.croi)
    func croiVsClang(_ file: AsmCorpusFile) throws {
        try Self.check(file, oracle: DifferentialAssembly.assembleWithClang(path: file.path, target: file.target, includePaths: file.includePaths), oracleName: "clang")
    }

    @Test(
        "x86-64 corpora match GNU as (relocations, symbols, data; documented encoding choices excepted)",
        .enabled(if: AsmCorpora.hasGNUAs),
        arguments: (AsmCorpora.inRepo + AsmCorpora.todhchai + AsmCorpora.croi).filter { $0.arch == .x86_64 }
    )
    func x86VsGNU(_ file: AsmCorpusFile) throws {
        try Self.check(file, oracle: DifferentialAssembly.assembleWithGNU(path: file.path, includePaths: file.includePaths), options: gnuDocumentedDifferences(for: file), oracleName: "GNU as")
    }
}
