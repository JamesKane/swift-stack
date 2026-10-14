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
}

public struct DriverOptions {
    public var inputFiles: [String] = []
    public var outputBinaryPath: String? = nil
    public var runBinary: Bool = false
    public var dumpStage: String? = nil
    public var showStats: Bool = false
    public var timePhases: Bool = false
    public var profilePath: String? = nil
    public var language: SourceLanguage? = nil
    public var benchRepetition: Bool = false

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

    // M0.5 Vertical Slice Statistics
    public private(set) var parseTreeNodeCount: Int = 0
    public private(set) var parseTreeCommittedBytes: Int = 0
    public private(set) var parseTreeReservedBytes: Int = 0
    public private(set) var airInstructionCount: UInt32 = 0
    public private(set) var airCommittedBytes: Int = 0
    public private(set) var airReservedBytes: Int = 0
    public private(set) var lirInstructionCount: Int = 0
    public private(set) var encodedFunctions: [EncodedFunction] = []
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
                    let lexer = SwiftLexer(fileId: fileId, buffer: sourceFile.buffer, length: sourceFile.length)
                    lexer.lexInto(&tokenBuffer)
                } else {
                    let lexer = CLexer(fileId: fileId, buffer: sourceFile.buffer, length: sourceFile.length)
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

        // For M0.5 slice, process the primary C unit
        let cFile = loadedFiles.first { $0.1 == .c }!
        let sourceFile = sourceManager[cFile.0]
        guard let sourcePtr = sourceFile.buffer.baseAddress else { return 1 }

        return try withUnsafePointer(to: tokenBuffer) { tokPtr in
            // Phase 2: Parsing (ParseTree)
            var pTree: ParseTree? = nil
            let p2_start = ss_monotonic_time_ns()
            Profiler.shared.timeBlock(name: "Phase 2: Parsing", category: "frontend") {
                let parser = CParser(
                    tokens: tokPtr,
                    sourceBuffer: sourcePtr,
                    sourceLength: sourceFile.length
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

            // Phase 3: Semantic Analysis / Minimal Type Checking
            let typePool = TypePool()
            var sem: SemResult? = nil
            let p3_start = ss_monotonic_time_ns()
            Profiler.shared.timeBlock(name: "Phase 3: Semantic Analysis", category: "sem") {
                var analyzer = CSemanticAnalyzer(
                    typePool: typePool,
                    sourceBuffer: sourcePtr,
                    sourceLength: sourceFile.length
                )
                sem = analyzer.analyze(tree: tree, tokens: tokenBuffer)
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
            if !semRes.diagnostics.isEmpty {
                for diag in semRes.diagnostics {
                    FileHandle.standardError.write(Data("Semantic error: \(diag)\n".utf8))
                }
            }

            // Phase 4: AIR Lowering
            var airMod: AIRModule? = nil
            let p4_start = ss_monotonic_time_ns()
            withUnsafePointer(to: tree) { treePtr in
                Profiler.shared.timeBlock(name: "Phase 4: AIR Lowering", category: "air") {
                    var lowering = AIRLowering(
                        tree: treePtr,
                        tokens: tokPtr,
                        semResult: semRes,
                        typePool: typePool,
                        sourceBuffer: sourcePtr,
                        sourceLength: sourceFile.length
                    )
                    airMod = lowering.lower()
                }
            }
            let p4_end = ss_monotonic_time_ns()
            let p4_dur = Double(p4_end - p4_start) / 1_000_000_000.0
            let airInstCount = Int(airMod?.totalInstructions ?? 0)
            phaseTimings.append(PhaseTiming(
                name: "AIR Lowering",
                durationSeconds: p4_dur,
                bytesProcessed: totalBytes,
                itemsProcessed: airInstCount
            ))

            guard let module = airMod else { return 1 }
            self.airInstructionCount = module.totalInstructions
            self.airCommittedBytes = module.bytesCommitted
            self.airReservedBytes = module.bytesReserved

            if options.dumpStage == "air" {
                dumpAIR(module: module)
                return 0
            }

            // Phase 5: Codegen (Isel + Linear Scan RegAlloc + x86-64 Encoding)
            var encoded: [EncodedFunction] = []
            var totalLIRCount = 0
            let p5_start = ss_monotonic_time_ns()
            Profiler.shared.timeBlock(name: "Phase 5: Codegen", category: "codegen") {
                var selector = InstructionSelector()
                let regAlloc = LinearScanRegAlloc()
                var encoder = X86Encoder()

                for i in 0..<module.functionCount {
                    module.withFunction(i) { airFn in
                        let lir = selector.select(function: airFn)
                        totalLIRCount += Int(lir.instructionCount)
                        let allocFn = regAlloc.allocate(function: lir)
                        var calleeMap: [UInt32: String] = [:]
                        for (name, _) in semRes.functions {
                            calleeMap[fnv1a16(name)] = name
                        }
                        calleeMap[fnv1a16("write")] = "write"
                        calleeMap[fnv1a16("exit")] = "exit"

                        let enc = encoder.encode(
                            function: allocFn,
                            stringTable: semRes.stringLiterals,
                            calleeNames: calleeMap
                        )
                        encoded.append(enc)
                    }
                }
            }
            let p5_end = ss_monotonic_time_ns()
            let p5_dur = Double(p5_end - p5_start) / 1_000_000_000.0
            phaseTimings.append(PhaseTiming(
                name: "Codegen & Encoding",
                durationSeconds: p5_dur,
                bytesProcessed: totalBytes,
                itemsProcessed: totalLIRCount
            ))

            self.encodedFunctions = encoded
            self.lirInstructionCount = totalLIRCount

            if options.dumpStage == "asm" || options.dumpStage == "code" {
                dumpCode(functions: encoded)
                return 0
            }

            // Phase 6: Static ELF Linking
            let outputPath = options.outputBinaryPath ?? (options.runBinary ? "/tmp/ss_m05_exec" : "a.out")
            let p6_start = ss_monotonic_time_ns()
            try Profiler.shared.timeBlock(name: "Phase 6: Static ELF Linking", category: "linker") {
                let writer = StaticELFWriter()
                try writer.linkAndWrite(
                    functions: encoded,
                    stringLiterals: module.orderedStrings,
                    outputPath: outputPath
                )
            }
            let p6_end = ss_monotonic_time_ns()
            let p6_dur = Double(p6_end - p6_start) / 1_000_000_000.0

            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
               let sz = attrs[.size] as? Int {
                lastOutputSize = sz
            }
            phaseTimings.append(PhaseTiming(
                name: "Static ELF Linking",
                durationSeconds: p6_dur,
                bytesProcessed: totalBytes,
                itemsProcessed: lastOutputSize
            ))

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
                        let p = CParser(tokens: tokPtr, sourceBuffer: srcPtr, sourceLength: file.length)
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

    public func dumpAIR(module: borrowing AIRModule) {
        print("=== AIR Module Dump (\(module.functionCount) functions) ===")
        for i in 0..<module.functionCount {
            module.withFunction(i) { fn in
                print("function @\(fn.name)() -> TypeId(\(fn.returnType.rawIndex)) {")
                for j in 1..<Int(fn.instructionCount) {
                    let id = InstId(UInt32(j))
                    let op = AIROpcode(rawValue: fn.opcode[id]) ?? .nilOp
                    let ty = fn.type[id]
                    let op0 = fn.op0[id]
                    let op1 = fn.op1[id]
                    let aux = fn.aux[id]
                    print(String(format: "  %%%3d = %-12@ [type:%d, op0:%d, op1:%d, aux:0x%X]", j, "\(op)", ty, op0, op1, aux))
                }
                print("}")
            }
        }
    }

    public func dumpCode(functions: [EncodedFunction]) {
        print("=== Encoded Machine Code (\(functions.count) functions) ===")
        for fn in functions {
            print("Function '\(fn.name)' (\(fn.code.count) bytes):")
            var hex = ""
            for (idx, b) in fn.code.enumerated() {
                hex += String(format: "%02X ", b)
                if (idx + 1) % 16 == 0 {
                    print("  " + hex)
                    hex = ""
                }
            }
            if !hex.isEmpty {
                print("  " + hex)
            }
        }
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
        if lastOutputSize > 0 {
            print("Output Binary:    \(lastOutputSize) bytes (ELF64 static executable)")
        }
        print("Peak RSS:         \(peakRssKB) KB")
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
