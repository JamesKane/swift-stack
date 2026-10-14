// Sources/Driver/main.swift
import Foundation
import SwiftStack

func printUsage() {
    print("""
    swift-stack: A Data-Oriented Swift 6.x & C23 Toolchain
    Usage: swift-stack [options] <input-files...>

    Options:
      --dump=<stage>       Dump internal stage representation (tokens)
      --stats              Display compiler table statistics and memory usage
      --time-phases        Display execution time and throughput for each phase
      --profile=<file>     Write execution trace to Chrome trace JSON file
      --lang=<swift|c>     Explicitly set input language (default: inferred from extension)
      -v, --version        Print version and exit
      -h, --help           Print this help message and exit
    """)
}

func main() {
    let args = CommandLine.arguments

    if args.count <= 1 || args.contains("-h") || args.contains("--help") {
        printUsage()
        exit(0)
    }

    if args.contains("-v") || args.contains("--version") {
        print("swift-stack version 0.1.0 (Milestone 0)")
        exit(0)
    }

    var options = DriverOptions()

    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg.hasPrefix("--dump=") {
            let stage = String(arg.dropFirst("--dump=".count))
            options.dumpStage = stage
        } else if arg == "--stats" {
            options.showStats = true
        } else if arg == "--time-phases" {
            options.timePhases = true
        } else if arg == "--bench" || arg == "--repetition" {
            options.benchRepetition = true
        } else if arg.hasPrefix("--profile=") {
            let file = String(arg.dropFirst("--profile=".count))
            options.profilePath = file
        } else if arg == "--lang=swift" {
            options.language = .swift
        } else if arg == "--lang=c" {
            options.language = .c
        } else if !arg.hasPrefix("-") {
            options.inputFiles.append(arg)
        } else {
            FileHandle.standardError.write(Data("Warning: unrecognized option '\(arg)'\n".utf8))
        }
        i += 1
    }

    let pipeline = DriverPipeline(options: options)
    do {
        let code = try pipeline.run()
        exit(code)
    } catch {
        FileHandle.standardError.write(Data("swift-stack error: \(error)\n".utf8))
        exit(1)
    }
}

main()
