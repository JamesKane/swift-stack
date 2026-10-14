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
}

public final class DriverPipeline {
    public let options: DriverOptions
    public let sourceManager: SourceManager
    public private(set) var tokenBuffer: TokenBuffer
    public private(set) var phaseTimings: [PhaseTiming] = []

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

        // Dump stage
        if let stage = options.dumpStage {
            if stage == "tokens" {
                dumpTokens()
            } else {
                FileHandle.standardError.write(Data("Warning: unknown dump stage '\(stage)'\n".utf8))
            }
        }

        // Stats
        if options.showStats {
            printStats(totalBytes: totalBytes)
        }

        // Time phases
        if options.timePhases {
            printTimePhases()
        }

        // Repetition benchmark
        if options.benchRepetition {
            runRepetitionBenchmark(loadedFiles: loadedFiles)
        }

        // Profile export
        if let profPath = options.profilePath {
            let json = Profiler.shared.exportTraceJSON()
            try json.write(toFile: profPath, atomically: true, encoding: .utf8)
            print("Trace profile written to \(profPath)")
        }

        return 0
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

    public func printStats(totalBytes: Int) {
        var usage = rusage()
        #if os(macOS)
        getrusage(RUSAGE_SELF, &usage)
        let peakRssKB = usage.ru_maxrss / 1024
        #else
        getrusage(RUSAGE_SELF.rawValue, &usage)
        let peakRssKB = usage.ru_maxrss // on Linux ru_maxrss is already in KB
        #endif

        print("=== Statistics ===")
        print("Source Bytes:     \(totalBytes) bytes")
        print("Token Count:      \(tokenBuffer.count - 1) tokens")
        print("Memory Committed: \(tokenBuffer.bytesCommitted) bytes")
        print("Memory Reserved:  \(tokenBuffer.bytesReserved) bytes")
        print("Peak RSS:         \(peakRssKB) KB")
    }

    public func printTimePhases() {
        print("=== Phase Timing ===")
        print("Phase              | Time (s) | Throughput (MB/s) | Items")
        print("-------------------+----------+-------------------+----------")
        for pt in phaseTimings {
            let paddedName = pt.name.padding(toLength: 18, withPad: " ", startingAt: 0)
            let formatted = String(
                format: "%@ | %8.4f | %17.2f | %8d",
                paddedName, pt.durationSeconds, pt.throughputMBs, pt.itemsProcessed
            )
            print(formatted)
        }
    }
}
