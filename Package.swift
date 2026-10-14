// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-stack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "swift-stack", targets: ["Driver"]),
        .library(name: "SwiftStackSource", targets: ["Source"]),
        .library(name: "SwiftStackLex", targets: ["Lex"]),
        .library(name: "SwiftStackParse", targets: ["Parse"]),
        .library(name: "SwiftStackSem", targets: ["Sem"]),
        .library(name: "SwiftStackAIR", targets: ["AIR"]),
        .library(name: "SwiftStackOpt", targets: ["Opt"]),
        .library(name: "SwiftStackLIR", targets: ["LIR"]),
        .library(name: "SwiftStackCodegen", targets: ["Codegen"]),
        .library(name: "SwiftStackAsm", targets: ["Asm"]),
        .library(name: "SwiftStackLinker", targets: ["Linker"]),
    ],
    targets: [
        // 1. Source memory management and file buffering
        .target(
            name: "Source",
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 2. Lexical analysis & C23 preprocessor (SoA TokenBuffer)
        .target(
            name: "Lex",
            dependencies: ["Source"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 3. Syntactic parsing (Postorder ParseTree)
        .target(
            name: "Parse",
            dependencies: ["Source", "Lex"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 4. Semantic analysis, TypePool, C23 semantics, staged constraint solver
        .target(
            name: "Sem",
            dependencies: ["Source", "Lex", "Parse"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 5. Arena Intermediate Representation (AIR)
        .target(
            name: "AIR",
            dependencies: ["Source", "Sem"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 6. 80-90% Parity High-Throughput Optimizer
        .target(
            name: "Opt",
            dependencies: ["AIR"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 7. Low-Level Machine IR (LIR)
        .target(
            name: "LIR",
            dependencies: ["AIR"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 8. Instruction selection, register allocation, encoders (x86_64, aarch64, riscv64)
        .target(
            name: "Codegen",
            dependencies: ["AIR", "LIR"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 9. Native assemblers (AMD64, ARM64, RV64)
        .target(
            name: "Asm",
            dependencies: ["Source", "Lex", "Codegen"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 10. Data-oriented in-process native linker
        .target(
            name: "Linker",
            dependencies: ["Codegen", "Asm"],
            swiftSettings: [.enableExperimentalFeature("NoncopyableGenerics")]
        ),

        // 11. CLI Driver and pipeline coordinator
        .executableTarget(
            name: "Driver",
            dependencies: [
                "Source",
                "Lex",
                "Parse",
                "Sem",
                "AIR",
                "Opt",
                "LIR",
                "Codegen",
                "Asm",
                "Linker"
            ]
        ),

        // Test Targets
        .testTarget(
            name: "SourceTests",
            dependencies: ["Source"]
        ),
        .testTarget(
            name: "LexTests",
            dependencies: ["Source", "Lex"]
        ),
    ]
)
