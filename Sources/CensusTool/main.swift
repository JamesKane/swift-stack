// Sources/CensusTool/main.swift
import Foundation
import SwiftStack

func printUsage() {
    print("""
    ss-census: Swift feature usage and roadmap ordering tool
    Usage: ss-census [options] <directory...>

    Options:
      --markdown       Output report as markdown table (default)
      --unsupported    Only show unsupported features ranked by count
      --help           Display this help
    """)
}

func main() {
    let args = CommandLine.arguments
    if args.count < 2 || args.contains("--help") {
        printUsage()
        exit(0)
    }

    var paths: [String] = []
    var onlyUnsupported = false

    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--unsupported" {
            onlyUnsupported = true
        } else if arg == "--markdown" {
            // default
        } else if !arg.hasPrefix("-") {
            paths.append(arg)
        }
        i += 1
    }

    if paths.isEmpty {
        paths.append(".")
    }

    let census = FeatureCensus()
    for path in paths {
        do {
            try census.scanDirectory(at: path)
        } catch {
            FileHandle.standardError.write(Data("Error scanning \(path): \(error)\n".utf8))
        }
    }

    if onlyUnsupported {
        let unsupp = census.unsupportedRanked()
        print("# Top Unsupported Features")
        if unsupp.isEmpty {
            print("None found.")
        } else {
            for (idx, e) in unsupp.enumerated() {
                print("\(idx + 1). \(e.name) (\(e.count) occurrences) -> Target: \(e.milestone)")
            }
        }
    } else {
        print(census.generateMarkdownReport())
    }
}

main()
