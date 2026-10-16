// Sources/SwiftStack/Driver/DriverArguments.swift
//
// Command-line parsing for the `swift-stack` driver, and the target options it passes to the assembler as clang's
// driver passes them to its integrated assembler (05-assembler.md §4.13, 15-driver-and-diagnostics.md).

import Foundation

extension DriverOptions {
    /// Parses `swift-stack` arguments (without the program name). Unrecognized options are returned as warnings and
    /// otherwise ignored.
    public static func parse<Args: Collection>(_ arguments: Args) -> (options: DriverOptions, warnings: [String]) where Args.Element == String {
        var options = DriverOptions()
        var warnings: [String] = []
        let args = Array(arguments)

        func define(_ def: String) {
            if let eq = def.firstIndex(of: "=") {
                options.defines.append((name: String(def[..<eq]), value: String(def[def.index(after: eq)...])))
            } else {
                options.defines.append((name: def, value: "1"))
            }
        }

        var i = 0
        while i < args.count {
            let arg = args[i]
            let hasValue = i + 1 < args.count
            if arg == "-o" && hasValue {
                i += 1
                options.outputBinaryPath = args[i]
            } else if arg.hasPrefix("-o") {
                options.outputBinaryPath = String(arg.dropFirst(2))
            } else if arg == "--run" {
                options.runBinary = true
            } else if arg.hasPrefix("--dump=") {
                options.dumpStage = String(arg.dropFirst("--dump=".count))
            } else if arg == "--verify-each" {
                options.verifyEach = true
            } else if arg == "--stats" {
                options.showStats = true
            } else if arg == "--time-phases" {
                options.timePhases = true
            } else if arg == "--bench" || arg == "--repetition" {
                options.benchRepetition = true
            } else if arg.hasPrefix("--profile=") {
                options.profilePath = String(arg.dropFirst("--profile=".count))
            } else if arg == "--lang=swift" {
                options.language = .swift
            } else if arg == "--lang=c" {
                options.language = .c
            } else if arg == "--lang=asm" {
                options.language = .assembly
            } else if arg == "-c" {
                options.compileOnly = true
            } else if arg == "-S" {
                options.emitAssembly = true
            } else if arg.hasPrefix("-l") && arg.count > 2 {
                options.libraries.append(String(arg.dropFirst(2)))
            } else if arg.hasPrefix("--arch=") {
                switch String(arg.dropFirst("--arch=".count)).lowercased() {
                case "x86_64", "amd64": options.targetArch = .x86_64
                case "aarch64", "arm64": options.targetArch = .aarch64
                case "riscv64", "rv64": options.targetArch = .riscv64
                default: warnings.append("unknown architecture in '\(arg)'")
                }
            } else if (arg == "-target" || arg == "--target") && hasValue {
                i += 1
                options.setTarget(triple: args[i])
            } else if arg.hasPrefix("--target=") || arg.hasPrefix("-target=") {
                options.setTarget(triple: String(arg[arg.index(after: arg.firstIndex(of: "=")!)...]))
            } else if arg == "-I" && hasValue {
                i += 1
                options.includePaths.append(args[i])
            } else if arg.hasPrefix("-I") {
                options.includePaths.append(String(arg.dropFirst(2)))
            } else if arg == "-D" && hasValue {
                i += 1
                define(args[i])
            } else if arg.hasPrefix("-D") {
                define(String(arg.dropFirst(2)))
            } else if arg.hasPrefix("-march=") {
                options.march = String(arg.dropFirst("-march=".count))
            } else if arg.hasPrefix("-mabi=") {
                options.mabi = String(arg.dropFirst("-mabi=".count))
            } else if arg == "-mrelax" || arg == "-mno-relax" {
                options.relax = arg == "-mrelax"
            } else if ["-fPIC", "-fpic", "-fPIE", "-fpie"].contains(arg) {
                options.pic = true
            } else if ["-fno-PIC", "-fno-pic", "-fno-PIE", "-fno-pie"].contains(arg) {
                options.pic = false
            } else if arg.hasPrefix("-Wa,") {
                // Comma-separated assembler options, as clang's `CollectArgsForIntegratedAssembler` takes them.
                for value in arg.dropFirst("-Wa,".count).split(separator: ",").map(String.init) {
                    switch value {
                    case "--noexecstack":
                        options.assemblerOptions.noExecStack = true
                    case "-mrelax-relocations=yes", "--mrelax-relocations=yes":
                        options.assemblerOptions.x86RelaxRelocations = true
                    case "-mrelax-relocations=no", "--mrelax-relocations=no":
                        options.assemblerOptions.x86RelaxRelocations = false
                    default:
                        warnings.append("unsupported assembler option '\(value)' in '\(arg)'")
                    }
                }
            } else if !arg.hasPrefix("-") {
                options.inputFiles.append(arg)
            } else {
                warnings.append("unrecognized option '\(arg)'")
            }
            i += 1
        }
        return (options, warnings)
    }

    /// Sets the target from a triple: its architecture selects the backend and assembler, and its OS the RISC-V
    /// defaults (`riscvAssemblerOptions`).
    public mutating func setTarget(triple: String) {
        targetTriple = triple
        let lower = triple.lowercased()
        if lower.hasPrefix("aarch64") || lower.hasPrefix("arm64") {
            targetArch = .aarch64
        } else if lower.hasPrefix("riscv64") || lower.hasPrefix("rv64") {
            targetArch = .riscv64
        } else {
            targetArch = .x86_64
        }
    }

    /// The operating system component of the target triple, or nil for a bare-metal target (`none`, `unknown`,
    /// `elf`, or no triple), as LLVM's `Triple` classifies it for the RISC-V defaults.
    var targetOS: String? {
        guard let triple = targetTriple?.lowercased() else { return nil }
        let parts = triple.split(separator: "-").dropFirst()
        let knownOSes = ["linux", "android", "freebsd", "netbsd", "openbsd", "fuchsia", "haiku", "serenity", "managarm"]
        for part in parts {
            if let os = knownOSes.first(where: { part.hasPrefix($0) }) { return os }
        }
        return nil
    }

    /// The RISC-V assembler state clang's driver gives its integrated assembler for these options:
    ///
    /// - the ISA is `-march`, or by default (`riscv::getRISCVArch`) `rv64imafdc` with an `lp64*` `-mabi`, else per
    ///   target OS: `rv64imac` bare-metal, `rv64imafdcv_zba_zbb_zbs` on Android, `rv64imafdc` otherwise;
    /// - the ABI is `-mabi`, or the ISA's default (`lp64d` with D, `lp64f` with F, else `lp64`);
    /// - linker relaxation is on unless the last of `-mrelax`/`-mno-relax` is `-mno-relax`;
    /// - `la` is PIC (a GOT load) when the last of `-f[no-]pic`/`-f[no-]pie` enables it, never by default.
    ///
    /// The ISA also gives the ELF `e_flags` and the `Tag_RISCV_arch` build attribute.
    public var riscvAssemblerOptions: RVAsmOptions {
        let isa: String
        if let march {
            isa = march
        } else if let mabi, mabi.lowercased().hasPrefix("lp64") {
            isa = "rv64imafdc"
        } else {
            switch targetOS {
            case nil:       isa = "rv64imac"
            case "android": isa = "rv64imafdcv_zba_zbb_zbs"
            default:        isa = "rv64imafdc"
            }
        }
        return RVAsmOptions(march: isa, pic: pic ?? false, relax: relax ?? true, abi: mabi)
    }
}
