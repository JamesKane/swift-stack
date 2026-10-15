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
    var testDescription: String { "\(arch): " + path.split(separator: "/").suffix(3).joined(separator: "/") }

    var target: DifferentialAssembly.Target {
        let base = DifferentialAssembly.target(for: arch)
        return DifferentialAssembly.Target(arch: arch, clangTriple: base.clangTriple, clangFlags: clangFlags)
    }
}

enum AsmCorpora {
    static let env = ProcessInfo.processInfo.environment
    static let vectraRoot = env["SWIFTSTACK_VECTRAOS_ROOT"] ?? "/home/jkane/Projects/OS/VectraOS-swift"

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

    /// Stand-ins for the build outputs `kernel/userprogram.S` embeds with `.incbin` (the user test program,
    /// the vDSO, the Swift test programs and userboot). Both assemblers read the same files, so their
    /// contents only need to be fixed and distinct. They are written once per process, into a per-process
    /// directory: the parameterized tests run in parallel and must never see a file being rewritten.
    static let incbinDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ss_vectraos_incbin_\(ProcessInfo.processInfo.processIdentifier)").path
    static let incbinMacros = ["CROI_USER_PROGRAM", "CROI_VDSO", "CROI_SWIFT_TEST", "CROI_SWIFT_TEST_EXEC", "CROI_USERBOOT"]

    private static let incbinStandIns: Result<Void, any Error> = Result {
        try FileManager.default.createDirectory(atPath: incbinDir, withIntermediateDirectories: true)
        for (i, name) in incbinMacros.enumerated() {
            let bytes = (0..<(37 * (i + 1))).map { UInt8(truncatingIfNeeded: $0 * 7 + i) }
            try Data(bytes).write(to: URL(fileURLWithPath: "\(incbinDir)/\(name).bin"), options: .atomic)
        }
    }

    static func prepareIncbinStandIns() throws {
        try incbinStandIns.get()
    }

    /// The VectraOS assembly (all 26 `.S` files), each assembled for its architecture with the flags its CMake
    /// build uses (`cmake/toolchain.cmake`, the per-arch files in `cmake/arch/`, the user-binary rules in `cmake/`,
    /// `kernel/CMakeLists.txt`). Arch-independent files are assembled once per architecture. `-g` is left out:
    /// assembler-generated DWARF for `.S` sources is not part of M2.
    static var vectraOS: [AsmCorpusFile] {
        let root = vectraRoot
        guard FileManager.default.fileExists(atPath: "\(root)/cmake/toolchain.cmake") else { return [] }
        let common = ["-fPIE", "-fvisibility=hidden", "-ffunction-sections", "-fdata-sections", "-fno-omit-frame-pointer",
                      "-fstack-protector-strong", "-O2", "-DNDEBUG"]
        var files: [AsmCorpusFile] = []
        for (dir, arch) in [("amd64", AssemblerArch.x86_64), ("arm64", .aarch64), ("rv64", .riscv64)] {
            let kernelFlags: [String], userFlags: [String]
            switch arch {
            case .x86_64:
                kernelFlags = ["-mno-red-zone", "-mgeneral-regs-only"]
                userFlags = []
            case .aarch64:
                kernelFlags = ["-mgeneral-regs-only"]
                userFlags = ["-mbranch-protection=bti"]
            case .riscv64:
                kernelFlags = ["-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany"]
                userFlags = ["-march=rv64gc", "-mabi=lp64d", "-mcmodel=medany"]
            }
            func file(_ rel: String, _ inc: [String], _ flags: [String]) -> AsmCorpusFile {
                AsmCorpusFile(path: "\(root)/\(rel)", arch: arch, includePaths: inc.map { "\(root)/\($0)" }, clangFlags: flags)
            }
            // The loader (boot/CMakeLists.txt) and the kernel (kernel/CMakeLists.txt): the kernel flag set.
            files.append(file("boot/arch/\(dir)/enter.S", ["boot/include"], kernelFlags + common))
            for name in ["cpu", "exceptions", "smp", "start", "thread", "usercopy", "usertest"] {
                files.append(file("kernel/arch/\(dir)/\(name).S", ["kernel/include"], kernelFlags + common))
            }
            let incbin = incbinMacros.map { "-D\($0)=\"\(incbinDir)/\($0).bin\"" }
            files.append(file("kernel/userprogram.S", ["kernel/include"], incbin + kernelFlags + common))
            // The vDSO (a position-independent user binary): the user flag set.
            files.append(file("user/vdso/header.S", ["user/include", "kernel/include"],
                              userFlags + ["-O2", "-fno-omit-frame-pointer", "-ffreestanding", "-fno-stack-protector", "-fno-builtin",
                                           "-fPIE", "-fvisibility=hidden"]))
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var inRepo: [AsmCorpusFile] {
        var files: [AsmCorpusFile] = []
        for (dir, arch) in [("x86_64", AssemblerArch.x86_64), ("aarch64", .aarch64), ("riscv64", .riscv64)] {
            for p in listS("\(inRepoDir)/\(dir)") {
                files.append(AsmCorpusFile(path: p, arch: arch, includePaths: [], clangFlags: DifferentialAssembly.target(for: arch).clangFlags))
            }
        }
        // RISC-V with linker relaxation on (clang's default), for VectraOS's kernel ISA and PIE.
        for p in listS("\(inRepoDir)/riscv64-relax") {
            files.append(AsmCorpusFile(path: p, arch: .riscv64, includePaths: [],
                                       clangFlags: ["-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-fPIE"]))
        }
        return files
    }

    static var hasClang: Bool { ExternalTool.referenceClang != nil }
    static var hasGNUAs: Bool { ExternalTool.find("gcc") != nil && ExternalTool.find("as") != nil }
}

/// Differences from GNU `as` on x86-64 that are intentional and documented in 05-assembler.md §4.11.
/// LLVM MC is the reference assembler, Swift-Stack matches it, and the clang comparison checks these sections
/// exactly:
/// - `.text` alignment (LLVM MC: 4, GNU: 1);
/// - multi-byte NOP padding (LLVM MC: one 6-byte `nopw`; GNU: `nop` + 5-byte `nopl`);
/// - a memory displacement given by a label difference unresolved at parse time is encoded as `disp32`
///   (GNU `as` relaxes it to `disp8`), which changes the size of the containing section;
/// - `.eh_frame` FDE order and CIE sharing (LLVM MC groups FDEs by CIE key; GNU keeps source order and shares
///   CIEs by content). Only `cfi_cie_order.s` has FDEs with different CIEs out of key order.
func gnuDocumentedDifferences(for file: AsmCorpusFile) -> DiffOptions {
    var opts = DiffOptions(compareAlignment: false)
    if file.path.hasSuffix("/kernel/arch/amd64/smp.S") {
        opts.excludedSections = [".text.arch_ap_prepare_trampoline"]  // `lea T_OFF(t_gdt)(%rsi), %rax`
        opts.bytesExemptSections = [".text.ap_trampoline"]              // NOP padding before `.balign 8` data
    }
    if file.path.hasSuffix("/Differential/asm/x86_64/cfi_cie_order.s") {
        opts.excludedSections = [".eh_frame"]
    }
    return opts
}

/// In-repo files GNU `as` cannot assemble, compared with clang only: `macro_args.s` uses macro arguments that
/// LLVM MC splits at operators after a blank and GNU `as` splits differently or rejects, and `local_relocs.s`
/// pins LLVM MC's relocation choices (a local `call` as `R_X86_64_PLT32` against the section symbol, branches to a
/// global symbol in the same section relocated, relaxable GOT loads), where GNU `as` emits `R_X86_64_PC32`, resolves
/// the branches and adds `_GLOBAL_OFFSET_TABLE_` (05-assembler.md §4.11).
let gnuIncompatibleFiles: Set<String> = ["macro_args.s", "local_relocs.s"]

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

    @Test("In-repo corpus matches clang exactly (every section, relocation symbol and symbol, e_flags)",
          .enabled(if: AsmCorpora.hasClang), arguments: AsmCorpora.inRepo)
    func inRepoVsClangExact(_ file: AsmCorpusFile) throws {
        let (ours, errors) = try DifferentialAssembly.assembleOurs(path: file.path, target: file.target, includePaths: file.includePaths)
        #expect(errors == 0)
        let oracle = try DifferentialAssembly.assembleWithClang(path: file.path, target: file.target, includePaths: file.includePaths)
        let diffs = ExactObjectComparison.differences(ours: ours, oracle: oracle)
        #expect(diffs.isEmpty, Comment(rawValue: "\(file.testDescription):\n  " + diffs.prefix(25).joined(separator: "\n  ")))
    }

    @Test("VectraOS assembly matches clang (all 26 .S files, per architecture)",
          .enabled(if: AsmCorpora.hasClang && AsmCorpora.vectraOS.count == 30), arguments: AsmCorpora.vectraOS)
    func vectraOSVsClang(_ file: AsmCorpusFile) throws {
        try AsmCorpora.prepareIncbinStandIns()
        let oracle = try DifferentialAssembly.assembleWithClang(path: file.path, target: file.target, includePaths: file.includePaths)
        try Self.check(file, oracle: oracle, oracleName: "clang")
        let (ours, _) = try DifferentialAssembly.assembleOurs(path: file.path, target: file.target, includePaths: file.includePaths)
        let exact = ExactObjectComparison.differences(ours: ours, oracle: oracle)
        #expect(exact.isEmpty, Comment(rawValue: "\(file.testDescription) (exact):\n  " + exact.prefix(25).joined(separator: "\n  ")))
    }

    @Test(
        "x86-64 corpora match GNU as (relocations, symbols, data; documented encoding choices excepted)",
        .enabled(if: AsmCorpora.hasGNUAs),
        arguments: (AsmCorpora.inRepo.filter { !gnuIncompatibleFiles.contains(URL(fileURLWithPath: $0.path).lastPathComponent) }
            + AsmCorpora.vectraOS).filter { $0.arch == .x86_64 }
    )
    func x86VsGNU(_ file: AsmCorpusFile) throws {
        try AsmCorpora.prepareIncbinStandIns()
        try Self.check(file, oracle: DifferentialAssembly.assembleWithGNU(
            path: file.path, includePaths: file.includePaths, defines: file.clangFlags.filter { $0.hasPrefix("-D") }), options: gnuDocumentedDifferences(for: file), oracleName: "GNU as")
    }
}
