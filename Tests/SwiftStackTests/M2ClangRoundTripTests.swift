import Foundation
import Testing
@testable import SwiftStack

// Clang's own assembly output must assemble exactly as clang assembles it (05-assembler.md §4.11): every VectraOS
// C file is compiled with `clang -S` for each architecture with the flags of its CMake build, at -O0 and -O2, and
// the `.s` is assembled by Swift-Stack and by `clang -c`. The objects are compared exactly
// (`ExactObjectComparison`): all sections including `.comment`, `.llvm_addrsig` and the build attributes, every
// relocation with the symbol it names, every symbol including `.L*`, mapping and section symbols, and `e_flags`.
// Skipped when VectraOS or clang is absent.

struct ClangRoundTripFile: CustomTestStringConvertible, Sendable {
    let source: String
    let arch: AssemblerArch
    let triple: String
    /// `clang -S` flags (the target's CMake flags plus the optimization level).
    let compileFlags: [String]
    var testDescription: String {
        "\(arch) \(compileFlags.last ?? ""): " + source.split(separator: "/").suffix(2).joined(separator: "/")
            + (compileFlags.contains("-fPIE") ? " (PIE)" : "")
            + (compileFlags.contains("-mbranch-protection=pac-ret+bti") ? " (pac-ret+bti)" : "")
    }

    /// The assembler-relevant target flags `clang -c` receives for the `.s` (ISA, ABI, PIC).
    var assemblerFlags: [String] {
        compileFlags.filter { $0.hasPrefix("-march=") || $0.hasPrefix("-mabi=") || $0 == "-fPIE" }
    }
}

enum ClangRoundTripCorpus {
    /// Every C file VectraOS builds, per architecture, with the flags its CMake build gives it
    /// (`cmake/toolchain.cmake`, `cmake/arch/*.cmake`, `cmake/CroiUser.cmake`, the `CMakeLists.txt` files).
    /// AArch64 code gets `-mbranch-protection=bti` (the kernel's `trace.c` also with its `pac-ret+bti`).
    static var files: [ClangRoundTripFile] {
        let root = AsmCorpora.vectraRoot
        guard FileManager.default.fileExists(atPath: "\(root)/cmake/toolchain.cmake") else { return [] }
        let codegen = ["-fPIE", "-fvisibility=hidden", "-ffunction-sections", "-fdata-sections", "-fno-omit-frame-pointer",
                       "-fstack-protector-strong"]
        var out: [ClangRoundTripFile] = []
        for (arch, triple) in [(AssemblerArch.x86_64, "x86_64-unknown-none-elf"), (.aarch64, "aarch64-unknown-none-elf"),
                               (.riscv64, "riscv64-unknown-none-elf")] {
            let kernel: [String], user: [String], bti: [String]
            switch arch {
            case .x86_64:
                (kernel, user, bti) = (["-mno-red-zone", "-mgeneral-regs-only"], [], [])
            case .aarch64:
                (kernel, user, bti) = (["-mgeneral-regs-only"], ["-mbranch-protection=bti"], ["-mbranch-protection=bti"])
            case .riscv64:
                (kernel, user, bti) = (["-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany"],
                                       ["-march=rv64gc", "-mabi=lp64d", "-mcmodel=medany"], [])
            }
            let userInclude = ["-I\(root)/user/include", "-I\(root)/kernel/include"]
            let runtime = user + ["-fno-omit-frame-pointer", "-ffunction-sections", "-fdata-sections", "-fstack-protector-strong"] + userInclude
            var configs: [(String, [String])] = [
                ("boot/entry.c", kernel + codegen + bti + ["-I\(root)/boot/include"]),
                ("kernel/trace.c", kernel + codegen + bti + ["-I\(root)/kernel/include"]),
                ("lib/rt/string.c", kernel + codegen + bti),
                ("lib/rt/int128.c", kernel + codegen + bti),
                ("lib/rt/stack_protector.c", kernel + codegen + bti + ["-fno-stack-protector"]),
                ("user/test/usertest.c", user + ["-fno-omit-frame-pointer", "-fno-stack-protector", "-fno-builtin", "-fno-pic", "-fno-pie"] + userInclude),
                ("user/vdso/vdso.c", user + ["-fno-omit-frame-pointer", "-fno-stack-protector", "-fno-builtin", "-fPIE", "-fvisibility=hidden"] + userInclude),
            ]
            if arch == .aarch64 {
                configs.append(("kernel/trace.c", kernel + codegen + ["-mbranch-protection=pac-ret+bti", "-I\(root)/kernel/include"]))
            }
            for name in ["start", "stdout", "malloc", "timing", "image"] {
                configs.append(("user/lib/runtime/\(name).c", runtime + ["-fno-pic", "-fno-pie"]))
                configs.append(("user/lib/runtime/\(name).c", runtime + ["-fPIE"]))
            }
            for (source, flags) in configs {
                for opt in ["-O0", "-O2"] {
                    out.append(ClangRoundTripFile(source: "\(root)/\(source)", arch: arch, triple: triple,
                                                  compileFlags: ["-std=c23", "-ffreestanding"] + flags + [opt]))
                }
            }
        }
        return out.filter { FileManager.default.fileExists(atPath: $0.source) }
    }
}

@Suite("M2 — clang -S output assembles as clang assembles it")
struct M2ClangRoundTripTests {

    @Test("VectraOS C files: clang -S, then Swift-Stack vs clang -c (exact)",
          .enabled(if: ExternalTool.referenceClang != nil && !ClangRoundTripCorpus.files.isEmpty), arguments: ClangRoundTripCorpus.files)
    func roundTrip(_ file: ClangRoundTripFile) throws {
        let clang = try #require(ExternalTool.referenceClang)
        let asm = ExternalTool.temporaryPath(".s"), ref = ExternalTool.temporaryPath(".o")
        defer {
            try? FileManager.default.removeItem(atPath: asm)
            try? FileManager.default.removeItem(atPath: ref)
        }
        let compile = try ExternalTool.run(clang, ["--target=\(file.triple)"] + file.compileFlags + ["-S", file.source, "-o", asm])
        try #require(compile.status == 0, "clang -S failed: \(compile.stderr)")
        let assemble = try ExternalTool.run(clang, ["--target=\(file.triple)"] + file.assemblerFlags + ["-c", asm, "-o", ref])
        try #require(assemble.status == 0, "clang -c failed: \(assemble.stderr)")

        var diags = DiagnosticBag()
        let sm = SourceManager()
        let obj = try Assembler.assembleFile(path: asm, arch: file.arch, riscvOptions: DifferentialAssembly.riscvOptions(for: file.assemblerFlags),
                                             sourceManager: sm, diagnostics: &diags)
        #expect(diags.errorCount == 0, Comment(rawValue: DiagnosticRenderer.render(diagnostics: diags, sourceManager: sm)))
        let diffs = ExactObjectComparison.differences(ours: try TestELF(bytes: ELFObjectWriter.write(obj)), oracle: try TestELF(path: ref))
        #expect(diffs.isEmpty, Comment(rawValue: "\(file.testDescription):\n  " + diffs.prefix(30).joined(separator: "\n  ")))
    }
}
