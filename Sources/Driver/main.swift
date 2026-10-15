// Sources/Driver/main.swift
import Foundation
import SwiftStack

func printUsage() {
    print("""
    swift-stack: A Data-Oriented Swift 6.x & C23 Toolchain
    Usage: swift-stack [options] <input-files...>

    Options:
      -o <file>            Output binary executable path (default: a.out)
      --run                Compile and execute immediately on Linux
      --dump=<stage>       Dump internal stage (tokens, parse-tree, air, asm)
      --stats              Display compiler table statistics and memory usage
      --time-phases        Display execution time and throughput for each phase
      --bench              Run micro-benchmark repetitions for each phase
      --profile=<file>     Write execution trace to Chrome trace JSON file
      --lang=<swift|c|asm> Explicitly set input language (default: inferred from extension)
      -c                   Compile or assemble only (assembly input: write a relocatable object)
      --target=<triple>    Target triple (also -target <triple>); --arch=<x86_64|aarch64|riscv64>
      -I<dir>, -D<name>[=<value>]
                           Include path and macro definition (C and .S input)
      -march=<isa>, -mabi=<abi>, -mrelax, -mno-relax, -fPIC, -fPIE, -fno-pic
                           Assembler target options, as clang passes them (RISC-V ISA, ABI, relaxation, PIC)
      -Wa,--noexecstack, -Wa,-mrelax-relocations=<yes|no>
                           Assembler options (non-executable stack note; x86-64 GOTPCRELX relocations)
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
        print("swift-stack version 0.5.0 (Milestone 0.5: Vertical Slice)")
        exit(0)
    }

    let (options, warnings) = DriverOptions.parse(args.dropFirst())
    for warning in warnings {
        FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
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
