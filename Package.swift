// swift-tools-version: 6.2
import PackageDescription

// docs/architecture/00 D10, 09 §4.1: The compiler, assemblers, and linker are ONE library module,
// `SwiftStack`, organized by folders (Source/, Lex/, Parse/, Sem/, AIR/, Opt/, LIR/, Codegen/,
// Encode/, Object/, Asm/, Linker/, Profile/, Census/), plus thin executable targets.
// One module lets hot generics (`Column`, handles) specialize and inline everywhere.

let package = Package(
    name: "swift-stack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftStack", targets: ["SwiftStack"]),
        .executable(name: "swift-stack", targets: ["Driver"]),
        .executable(name: "ss-census", targets: ["CensusTool"]),
    ],
    targets: [
        // Low-level hardware timer & cycle counter support (rdtsc, cntvct_el0)
        .target(
            name: "CSupport",
            path: "Sources/CSupport"
        ),

        // Core single library module containing the entire compiler pipeline
        .target(
            name: "SwiftStack",
            dependencies: ["CSupport"],
            path: "Sources/SwiftStack"
        ),

        // Driver executable (swift-stack)
        .executableTarget(
            name: "Driver",
            dependencies: ["SwiftStack"],
            path: "Sources/Driver"
        ),

        // Feature census and roadmap ordering tool (ss-census)
        .executableTarget(
            name: "CensusTool",
            dependencies: ["SwiftStack"],
            path: "Sources/CensusTool"
        ),

        // Comprehensive test suite
        .testTarget(
            name: "SwiftStackTests",
            dependencies: ["SwiftStack"],
            path: "Tests/SwiftStackTests"
        ),
    ]
)
