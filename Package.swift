// swift-tools-version: 6.2
import PackageDescription

// Targets are added here as their Sources/<Name> directories come into existence.
// The planned module graph (see docs/architecture/09-roadmap.md §Module graph) is:
//
//   Source ─► Lex ─► Parse ─► Sem ─► AIR ─► Opt ─► LIR ─► Codegen ─┐
//                 └────────────────► Asm ──────────────────────────┤
//                                     Encode (shared by Codegen, Asm)
//                                     Object (shared by Codegen, Asm, Linker)
//                                                      Linker ◄────┘
//   Driver depends on all of the above.

let package = Package(
    name: "swift-stack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SwiftStackSource", targets: ["Source"]),
        .library(name: "SwiftStackLex", targets: ["Lex"]),
    ],
    targets: [
        // Source memory management and file buffering
        .target(name: "Source"),

        // Lexical analysis & C23 preprocessor (SoA TokenBuffer)
        .target(name: "Lex", dependencies: ["Source"]),
    ]
)
