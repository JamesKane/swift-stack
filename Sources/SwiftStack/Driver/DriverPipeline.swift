// Sources/SwiftStack/Driver/DriverPipeline.swift
import Foundation
import CSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum SourceLanguage {
    case swift
    case c
    case assembly
}

public struct DriverOptions {
    public var inputFiles: [String] = []
    public var outputBinaryPath: String? = nil
    public var runBinary: Bool = false
    public var compileOnly: Bool = false
    /// `-S`: write the assembly instead of an object or executable.
    public var emitAssembly: Bool = false
    /// `-l` libraries to link.
    public var libraries: [String] = []
    public var targetArch: AssemblerArch = .x86_64
    public var dumpStage: String? = nil
    /// `--verify-each`: run the IR verifiers after each stage that has one (SemIR now; AIR from M3 phase 2).
    public var verifyEach: Bool = false
    public var showStats: Bool = false
    public var timePhases: Bool = false
    public var profilePath: String? = nil
    public var language: SourceLanguage? = nil
    public var benchRepetition: Bool = false
    public var includePaths: [String] = []
    public var defines: [(name: String, value: String)] = []

    // Target options for the assembler (`DriverArguments.swift`), as clang's driver passes them to its integrated
    // assembler. They change the object only for RISC-V (`riscvAssemblerOptions`) and through `assemblerOptions`.
    /// The `--target=`/`-target` triple, if given.
    public var targetTriple: String? = nil
    public var march: String? = nil
    public var mabi: String? = nil
    /// The last of `-mrelax`/`-mno-relax`.
    public var relax: Bool? = nil
    /// The last of `-fPIC`/`-fpic`/`-fPIE`/`-fpie` and their `-fno-` forms.
    public var pic: Bool? = nil
    /// `-Wa,--noexecstack`, `-Wa,-mrelax-relocations=yes|no`.
    public var assemblerOptions = AsmOptions()

    public init() {}
}

public struct PhaseTiming {
    public let name: String
    public let durationSeconds: Double
    public let bytesProcessed: Int
    public let itemsProcessed: Int

    public var throughputMBs: Double {
        durationSeconds > 0 ? (Double(bytesProcessed) / durationSeconds) / 1_000_000.0 : 0
    }

    public var cyclesPerByte: Double {
        let cycles = durationSeconds * 3_000_000_000.0 // nominal 3 GHz clock
        return bytesProcessed > 0 ? cycles / Double(bytesProcessed) : 0
    }

    public var cyclesPerItem: Double {
        let cycles = durationSeconds * 3_000_000_000.0
        return itemsProcessed > 0 ? cycles / Double(itemsProcessed) : 0
    }
}

public final class DriverPipeline {
    public let options: DriverOptions
    public let sourceManager: SourceManager
    public private(set) var tokenBuffer: TokenBuffer
    public private(set) var phaseTimings: [PhaseTiming] = []

    // M0.5 / M2 Vertical Slice Statistics
    public private(set) var parseTreeNodeCount: Int = 0
    public private(set) var parseTreeCommittedBytes: Int = 0
    public private(set) var parseTreeReservedBytes: Int = 0
    public private(set) var airInstructionCount: UInt32 = 0
    public private(set) var airCommittedBytes: Int = 0
    public private(set) var airReservedBytes: Int = 0
    public private(set) var lirInstructionCount: Int = 0
    public private(set) var lastObjectSectionCount: Int = 0
    public private(set) var lastObjectSymbolCount: Int = 0
    public private(set) var lastObjectRelocCount: Int = 0
    public private(set) var lastObjectBytesCommitted: Int = 0
    public private(set) var lastOutputSize: Int = 0

    public init(options: DriverOptions) {
        self.options = options
        self.sourceManager = SourceManager()
        self.tokenBuffer = TokenBuffer()
        if let profPath = options.profilePath, !profPath.isEmpty {
            Profiler.shared.isEnabled = true
        }
    }

    public func run() throws -> Int32 {
        guard !options.inputFiles.isEmpty else {
            FileHandle.standardError.write(Data("Error: no input files provided\n".utf8))
            return 1
        }

        // Check if primary input is an assembly file (`.s` or `.S` or `--lang=asm`)
        let firstFile = options.inputFiles[0]
        if options.language == .assembly || firstFile.hasSuffix(".s") || firstFile.hasSuffix(".S") {
            return try runAssemblyPipeline(path: firstFile)
        }

        var totalBytes = 0
        var totalTokens = 0
        var loadedFiles: [(FileId, SourceLanguage)] = []

        // Phase 0: I/O + Mapping (B0)
        let p0_start = ss_monotonic_time_ns()
        try Profiler.shared.timeBlock(name: "Phase 0: I/O + Mapping", category: "io") {
            for file in options.inputFiles {
                let fileId = try sourceManager.loadFile(path: file)
                let lang = options.language ?? (file.hasSuffix(".c") || file.hasSuffix(".h") ? .c : .swift)
                loadedFiles.append((fileId, lang))
                totalBytes += sourceManager[fileId].length
            }
        }
        let p0_end = ss_monotonic_time_ns()
        let p0_dur = Double(p0_end - p0_start) / 1_000_000_000.0
        phaseTimings.append(PhaseTiming(
            name: "I/O + Mapping",
            durationSeconds: p0_dur,
            bytesProcessed: totalBytes,
            itemsProcessed: loadedFiles.count
        ))

        // Phase 1: Lexing (B1)
        let p1_start = ss_monotonic_time_ns()
        Profiler.shared.timeBlock(name: "Phase 1: Lexing", category: "frontend") {
            for (fileId, lang) in loadedFiles {
                let sourceFile = sourceManager[fileId]
                let prevCount = tokenBuffer.count

                if lang == .swift {
                    let lexer = SwiftLexer(fileId: fileId, buffer: sourceFile.buffer, length: sourceFile.length, baseLocation: sourceFile.baseLocation)
                    lexer.lexInto(&tokenBuffer)
                } else {
                    let lexer = CLexer(fileId: fileId, buffer: sourceFile.buffer, length: sourceFile.length, baseLocation: sourceFile.baseLocation)
                    lexer.lexInto(&tokenBuffer)
                }

                totalTokens += (tokenBuffer.count - prevCount)
            }
        }
        let p1_end = ss_monotonic_time_ns()
        let p1_dur = Double(p1_end - p1_start) / 1_000_000_000.0
        phaseTimings.append(PhaseTiming(
            name: "Lexing",
            durationSeconds: p1_dur,
            bytesProcessed: totalBytes,
            itemsProcessed: totalTokens
        ))

        // Early dump if only tokens requested (Gate 3 determinism compatibility)
        if options.dumpStage == "tokens" {
            dumpTokens()
            if options.showStats { printStats(totalBytes: totalBytes) }
            if options.timePhases { printTimePhases() }
            return 0
        }

        // Check if any C source is present to run vertical slice M0.5
        let hasC = loadedFiles.contains { $0.1 == .c }
        guard hasC else {
            // Swift frontend stops at lexing in M0
            if options.showStats { printStats(totalBytes: totalBytes) }
            if options.timePhases { printTimePhases() }
            if options.benchRepetition { runRepetitionBenchmark(loadedFiles: loadedFiles) }
            return 0
        }

        // For M0.5 / M1 slice, process the primary C unit
        let cFile = loadedFiles.first { $0.1 == .c }!
        let sourceFile = sourceManager[cFile.0]
        guard let sourcePtr = sourceFile.buffer.baseAddress else { return 1 }

        // Phase 1.5: Preprocessing
        var parseTokens = TokenBuffer()
        let pp = CPreprocessor(sourceManager: sourceManager)
        pp.includePaths.append(contentsOf: options.includePaths)
        pp.configureTargetArch(options.targetArch.description)
        for def in options.defines {
            pp.defineMacro(def.name, replacement: def.value)
        }
        let p15_start = ss_monotonic_time_ns()
        Profiler.shared.timeBlock(name: "Phase 1.5: Preprocessing", category: "frontend") {
            pp.preprocess(fileId: cFile.0, into: &parseTokens)
        }
        let p15_end = ss_monotonic_time_ns()
        let p15_dur = Double(p15_end - p15_start) / 1_000_000_000.0
        phaseTimings.append(PhaseTiming(
            name: "Preprocessing",
            durationSeconds: p15_dur,
            bytesProcessed: totalBytes,
            itemsProcessed: Int(parseTokens.count)
        ))

        if pp.diagnostics.errorCount > 0 {
            let rendered = DiagnosticRenderer.render(diagnostics: pp.diagnostics, sourceManager: sourceManager)
            FileHandle.standardError.write(Data(rendered.utf8))
            return 1
        }

        return try withUnsafePointer(to: parseTokens) { tokPtr in
            // Phase 2: Parsing (ParseTree)
            var pTree: ParseTree? = nil
            let p2_start = ss_monotonic_time_ns()
            Profiler.shared.timeBlock(name: "Phase 2: Parsing", category: "frontend") {
                let parser = CParser(
                    tokens: tokPtr,
                    sourceBuffer: sourcePtr,
                    sourceLength: sourceFile.length,
                    sourceManager: sourceManager
                )
                pTree = parser.parse()
            }
            let p2_end = ss_monotonic_time_ns()
            let p2_dur = Double(p2_end - p2_start) / 1_000_000_000.0
            let nodeCount = Int(pTree?.count ?? 1) - 1
            phaseTimings.append(PhaseTiming(
                name: "Parsing",
                durationSeconds: p2_dur,
                bytesProcessed: totalBytes,
                itemsProcessed: nodeCount
            ))

            guard let tree = pTree else { return 1 }
            self.parseTreeNodeCount = Int(tree.count) - 1
            self.parseTreeCommittedBytes = tree.bytesCommitted
            self.parseTreeReservedBytes = tree.bytesReserved

            if options.dumpStage == "parse-tree" {
                dumpParseTree(tree: tree)
                return 0
            }

            if tree.errorNodeCount > 0 {
                var detail = ""
                for i in 1..<Int(tree.count) {
                    let nid = NodeId(UInt32(i))
                    if tree.kind(of: nid) == .errorNode || (tree.hasError(node: nid) && tree.subtreeSize(of: nid) == 1) {
                        let tid = tree.token(of: nid)
                        if tid.isValid {
                            let loc = parseTokens.start(of: tid)
                            if let (f, off) = sourceManager.file(containing: loc) {
                                let (line, col) = f.lineTable().lineAndColumn(at: off)
                                detail = " at \(f.path):\(line):\(col)"
                            }
                        }
                        break
                    }
                }
                FileHandle.standardError.write(Data("Parse error: source contains syntax errors or unsupported constructs\(detail)\n".utf8))
                return 1
            }

            // Phase 3: Semantic Analysis / SemIR
            let typePool = TypePool(dataLayout: DataLayout.forArch(options.targetArch))
            var sem: SemResult? = nil
            let p3_start = ss_monotonic_time_ns()
            Profiler.shared.timeBlock(name: "Phase 3: Semantic Analysis", category: "sem") {
                let analyzer = CSemanticAnalyzer(
                    typePool: typePool,
                    sourceBuffer: sourcePtr,
                    sourceLength: sourceFile.length,
                    sourceManager: sourceManager
                )
                sem = analyzer.analyze(tree: tree, tokens: parseTokens)
            }
            let p3_end = ss_monotonic_time_ns()
            let p3_dur = Double(p3_end - p3_start) / 1_000_000_000.0
            let fnCount = sem?.functions.count ?? 0
            phaseTimings.append(PhaseTiming(
                name: "Semantic Analysis",
                durationSeconds: p3_dur,
                bytesProcessed: totalBytes,
                itemsProcessed: fnCount
            ))

            guard let semRes = sem else { return 1 }
            if semRes.semModule.diagnosticBag.errorCount > 0 {
                let rendered = DiagnosticRenderer.render(diagnostics: semRes.semModule.diagnosticBag, sourceManager: sourceManager)
                FileHandle.standardError.write(Data(rendered.utf8))
                return 1
            }

            if options.verifyEach {
                let issues = SemIRVerifier.verify(semRes.semModule)
                if !issues.isEmpty {
                    let text = issues.prefix(50).map { "SemIR verifier: \($0)" }.joined(separator: "\n")
                    FileHandle.standardError.write(Data((text + "\n").utf8))
                    return 1
                }
            }

            if options.dumpStage == "sem-ir" {
                dumpSemIR(sem: semRes)
                return 0
            }

            // AIR from SemIR (M3 phase 2)
            let p4_start = ss_monotonic_time_ns()
            let lowering = AIRLowering.lower(semRes.semModule)
            if !lowering.issues.isEmpty {
                let text = lowering.issues.prefix(50).map { "AIR lowering: \($0)" }.joined(separator: "\n")
                FileHandle.standardError.write(Data((text + "\n").utf8))
                return 1
            }
            if options.verifyEach {
                let issues = AIRVerifier.verify(lowering.module)
                if !issues.isEmpty {
                    let text = issues.prefix(50).map { "AIR verifier: \($0)" }.joined(separator: "\n")
                    FileHandle.standardError.write(Data((text + "\n").utf8))
                    return 1
                }
            }
            self.airInstructionCount = UInt32(lowering.module.totalInstructions)
            phaseTimings.append(PhaseTiming(name: "AIR Lowering", durationSeconds: Double(ss_monotonic_time_ns() - p4_start) / 1e9,
                                            bytesProcessed: totalBytes, itemsProcessed: lowering.module.totalInstructions))
            if options.dumpStage == "air" {
                print(lowering.module.dumpText(), terminator: "")
                return 0
            }

            // Code generation (M3 phase 3): selection, allocation, frame layout, assembly
            let p5_start = ss_monotonic_time_ns()
            let generated = X86CodeGenerator.generate(lowering.module, verifyAllocation: options.verifyEach)
            if !generated.issues.isEmpty {
                let text = generated.issues.prefix(50).map { "codegen: \($0)" }.joined(separator: "\n")
                FileHandle.standardError.write(Data((text + "\n").utf8))
                return 1
            }
            self.lirInstructionCount = generated.functions.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + $1.insts.count } }
            phaseTimings.append(PhaseTiming(name: "Codegen", durationSeconds: Double(ss_monotonic_time_ns() - p5_start) / 1e9,
                                            bytesProcessed: totalBytes, itemsProcessed: lirInstructionCount))
            if options.dumpStage == "asm" || options.emitAssembly {
                if let out = options.outputBinaryPath, options.emitAssembly {
                    try generated.assembly.write(toFile: out, atomically: true, encoding: .utf8)
                } else {
                    print(generated.assembly, terminator: "")
                }
                return 0
            }

            // Assembly to an object by Swift-Stack's assembler
            var asmDiagnostics = DiagnosticBag()
            let object = Assembler.assemble(source: generated.assembly, arch: .x86_64, fileName: options.inputFiles[0] + ".s",
                                            options: options.assemblerOptions, sourceManager: sourceManager, diagnostics: &asmDiagnostics)
            if asmDiagnostics.errorCount > 0 {
                let rendered = DiagnosticRenderer.render(diagnostics: asmDiagnostics, sourceManager: sourceManager)
                FileHandle.standardError.write(Data(rendered.utf8))
                return 1
            }
            let elf = ELFObjectWriter.write(object)
            if options.compileOnly {
                let out = options.outputBinaryPath ?? (URL(fileURLWithPath: options.inputFiles[0]).deletingPathExtension().lastPathComponent + ".o")
                try Data(elf).write(to: URL(fileURLWithPath: out))
                return 0
            }

            // Linking: by ld.lld through clang's driver, until Swift-Stack's linker (M3 phase 5)
            let outputPath = options.outputBinaryPath ?? (options.runBinary ? "/tmp/ss_m3_exec_\(getpid())" : "a.out")
            let p6_start = ss_monotonic_time_ns()
            let objectPath = outputPath + ".ss.o"
            try Data(elf).write(to: URL(fileURLWithPath: objectPath))
            defer { try? FileManager.default.removeItem(atPath: objectPath) }
            let linkStatus = Self.link(objects: [objectPath], output: outputPath, libraries: options.libraries)
            if linkStatus != 0 {
                FileHandle.standardError.write(Data("Error: linking failed (status \(linkStatus))\n".utf8))
                return 1
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath), let sz = attrs[.size] as? Int {
                lastOutputSize = sz
            }
            phaseTimings.append(PhaseTiming(name: "Linking (ld.lld)", durationSeconds: Double(ss_monotonic_time_ns() - p6_start) / 1e9,
                                            bytesProcessed: totalBytes, itemsProcessed: lastOutputSize))

            // Stats & Timings
            if options.showStats {
                printStats(totalBytes: totalBytes)
            }
            if options.timePhases {
                printTimePhases()
            }

            // Repetition benchmark if requested
            if options.benchRepetition {
                runRepetitionBenchmark(loadedFiles: loadedFiles)
            }

            // Write profile trace if requested
            if let profPath = options.profilePath {
                let json = Profiler.shared.exportTraceJSON()
                try json.write(toFile: profPath, atomically: true, encoding: .utf8)
                print("Trace profile written to \(profPath)")
            }

            // If --run is requested, execute the binary and return exit code!
            if options.runBinary {
                return runExecutable(path: outputPath)
            }

            return 0
        }
    }

    /// Links objects into an executable with `clang -fuse-ld=lld` (the C runtime and libc as clang links them).
    public static func link(objects: [String], output: String, libraries: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["clang", "-fuse-ld=lld"] + objects + ["-o", output] + libraries.map { "-l" + $0 } + ["-lm"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    private func runExecutable(path: String) -> Int32 {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(path),
            nil
        ]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]

        let spawnResult = posix_spawn(&pid, path, nil, nil, &argv, &envp)
        argv[0].map { free($0) }

        guard spawnResult == 0 else {
            FileHandle.standardError.write(Data("Error: posix_spawn failed with error \(spawnResult)\n".utf8))
            return 1
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)

        #if os(macOS)
        let exitCode = (status >> 8) & 0xFF
        #else
        let exitCode = (status & 0xFF00) >> 8
        #endif
        return exitCode
    }

    private func runRepetitionBenchmark(loadedFiles: [(FileId, SourceLanguage)]) {
        let tester = RepetitionTester(targetDurationSeconds: 0.5, maxIterations: 50)
        for (fileId, lang) in loadedFiles {
            let file = sourceManager[fileId]
            let name = lang == .swift ? "SwiftLexer [\(file.path)]" : "CLexer [\(file.path)]"
            var tb = TokenBuffer()
            let res = tester.testKernel(name: name, byteCount: file.length) {
                tb = TokenBuffer()
                if lang == .swift {
                    let lex = SwiftLexer(fileId: fileId, buffer: file.buffer, length: file.length)
                    lex.lexInto(&tb)
                } else {
                    let lex = CLexer(fileId: fileId, buffer: file.buffer, length: file.length)
                    lex.lexInto(&tb)
                }
            }
            print(res)

            if lang == .c, let srcPtr = file.buffer.baseAddress {
                let parseRes = tester.testKernel(name: "CParser [\(file.path)]", byteCount: file.length) {
                    withUnsafePointer(to: tb) { tokPtr in
                        let p = CParser(tokens: tokPtr, sourceBuffer: srcPtr, sourceLength: file.length, predeclaredTypedefs: CParser.benchmarkPredeclaredTypedefs)
                        _ = p.parse()
                    }
                }
                print(parseRes)
            }
        }
    }

    public func dumpTokens() {
        print("=== Token Dump (\(tokenBuffer.count - 1) tokens) ===")
        print("Index | Kind | Flags | Start..End | Length")
        print("------------------------------------------")
        for i in 1..<tokenBuffer.count {
            let id = TokenId(UInt32(i))
            let k = tokenBuffer.kind(of: id)
            let f = tokenBuffer.flag(of: id)
            let s = tokenBuffer.start(of: id).rawValue
            let e = tokenBuffer.end(of: id).rawValue
            let len = e >= s ? e - s : 0
            print(String(format: "%5d | %4d | 0x%02X | %6d..%-6d | %4d", i, k, f, s, e, len))
        }
    }

    public func dumpParseTree(tree: borrowing ParseTree) {
        print("=== Postorder ParseTree Dump (\(tree.count - 1) nodes) ===")
        print("Index | NodeKind             | TokenId | SubtreeSize | HasError")
        print("------+----------------------+---------+-------------+---------")
        for i in 1..<Int(tree.count) {
            let id = NodeId(UInt32(i))
            let k = tree.kind(of: id)
            let t = tree.token(of: id).rawIndex
            let sz = tree.subtreeSize(of: id)
            let err = tree.hasError(node: id)
            let kindStr = "\(k)".padding(toLength: 20, withPad: " ", startingAt: 0)
            print(String(format: "%5d | %@ | %7d | %11d | %@", i, kindStr, t, sz, err ? "YES" : "no"))
        }
    }

    public func dumpSemIR(sem: SemResult) {
        sem.semModule.dump()
    }

    public func printStats(totalBytes: Int) {
        var usage = rusage()
        #if os(macOS)
        getrusage(RUSAGE_SELF, &usage)
        let peakRssKB = usage.ru_maxrss / 1024
        #else
        getrusage(RUSAGE_SELF.rawValue, &usage)
        let peakRssKB = usage.ru_maxrss
        #endif

        print("=== Compiler Data Catalog Statistics (18-data-catalog.md) ===")
        print("Source Bytes:     \(totalBytes) bytes")
        print("TokenBuffer:      \(tokenBuffer.count - 1) tokens | Committed: \(tokenBuffer.bytesCommitted) B | Reserved: \(tokenBuffer.bytesReserved) B (10 B/row)")
        if parseTreeNodeCount > 0 {
            print("ParseTree:        \(parseTreeNodeCount) nodes  | Committed: \(parseTreeCommittedBytes) B | Reserved: \(parseTreeReservedBytes) B (9 B/row)")
        }
        if airInstructionCount > 0 {
            print("AIRFunction:      \(airInstructionCount) insts  | Committed: \(airCommittedBytes) B | Reserved: \(airReservedBytes) B (17 B/row)")
        }
        if lirInstructionCount > 0 {
            print("LIRFunction:      \(lirInstructionCount) insts  | Committed: \(lirInstructionCount * 28) B | Reserved: \(lirInstructionCount * 28) B (28 B/row SoA vs 32 B/row AoS)")
        }
        if lastObjectSectionCount > 0 {
            print("RelocatableObj:   \(lastObjectSectionCount) sections | \(lastObjectSymbolCount) symbols | \(lastObjectRelocCount) relocs | \(lastObjectBytesCommitted) B SoA")
        }
        if lastOutputSize > 0 {
            print("Output Binary:    \(lastOutputSize) bytes")
        }
        print("Peak RSS:         \(peakRssKB) KB")
    }

    private func runAssemblyPipeline(path: String) throws -> Int32 {
        var diagnostics = DiagnosticBag()
        let t0 = ss_monotonic_time_ns()
        let obj = try Assembler.assembleFile(
            path: path,
            arch: options.targetArch,
            includePaths: options.includePaths,
            defines: options.defines,
            riscvOptions: options.riscvAssemblerOptions,
            options: options.assemblerOptions,
            sourceManager: sourceManager,
            diagnostics: &diagnostics
        )
        let t1 = ss_monotonic_time_ns()
        let dur = Double(t1 - t0) / 1_000_000_000.0
        let totalBytes = (try? Data(contentsOf: URL(fileURLWithPath: path)).count) ?? 0

        phaseTimings.append(PhaseTiming(
            name: "Assembly (\(options.targetArch))",
            durationSeconds: dur,
            bytesProcessed: totalBytes,
            itemsProcessed: Int(obj.sectionCount)
        ))
        self.lastObjectSectionCount = Int(obj.sectionCount)
        self.lastObjectSymbolCount = Int(obj.symbolCount)
        self.lastObjectRelocCount = Int(obj.relocCount)
        self.lastObjectBytesCommitted = obj.bytesCommitted

        if diagnostics.errorCount > 0 {
            let rendered = DiagnosticRenderer.render(diagnostics: diagnostics, sourceManager: sourceManager)
            FileHandle.standardError.write(Data(rendered.utf8))
            return 1
        }

        if options.dumpStage == "asm" || options.dumpStage == "disasm" || options.dumpStage == "code" {
            dumpRelocatableDisassembly(object: obj)
            if options.showStats { printStats(totalBytes: totalBytes) }
            if options.timePhases { printTimePhases() }
            return 0
        }

        let outputPath = options.outputBinaryPath ?? "a.o"
        let elfBytes = ELFObjectWriter.write(obj)
        try Data(elfBytes).write(to: URL(fileURLWithPath: outputPath))
        self.lastOutputSize = elfBytes.count

        if options.showStats { printStats(totalBytes: totalBytes) }
        if options.timePhases { printTimePhases() }
        return 0
    }

    public func dumpRelocatableDisassembly(object: borrowing RelocatableObject) {
        print("=== RelocatableObject Disassembly (\(object.arch), \(object.sectionCount) sections) ===")
        for sIdx in 0..<object.sectionCount {
            let handle = SectionIndex(UInt32(sIdx))
            let name = object.sectionName(handle)
            let flags = SectionFlags(rawValue: object.sectionFlags[handle])
            guard flags.contains(.execInstr) else { continue }
            let bytes = Array(object.sectionData(handle))
            print("Section \(name) (\(bytes.count) bytes):")
            switch object.arch {
            case .x86_64:
                let disasm = X86Disassembler()
                var offset = 0
                while offset < bytes.count {
                    guard let (inst, len) = try? disasm.disassembleOne(bytes, at: offset), len > 0 else { break }
                    print(String(format: "  %4x: %@", offset, inst.attString))
                    offset += len
                }
            case .aarch64:
                var offset = 0
                while offset + 4 <= bytes.count {
                    let word = UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24)
                    let text = A64Disassembler.disassemble(word) ?? String(format: ".inst 0x%08x", word)
                    print(String(format: "  %4x: %@", offset, text))
                    offset += 4
                }
            case .riscv64:
                for item in RV64Disassembler.disassemble(bytes) {
                    print(String(format: "  %4x: %@", item.offset, item.text))
                }
            }
        }
    }

    public func printTimePhases() {
        print("=== Phase Timing & Throughput (14-measurement-methodology.md) ===")
        print("Phase              | Time (s) | Throughput (MB/s) | Cycles/Byte | Cycles/Item | Items")
        print("-------------------+----------+-------------------+-------------+-------------+----------")
        for pt in phaseTimings {
            let paddedName = pt.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            let formatted = String(
                format: "%@ | %8.4f | %17.2f | %11.2f | %11.2f | %8d",
                paddedName, pt.durationSeconds, pt.throughputMBs, pt.cyclesPerByte, pt.cyclesPerItem, pt.itemsProcessed
            )
            print(formatted)
        }
    }
}
