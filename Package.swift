// swift-tools-version: 6.2
import PackageDescription

// Planned structure (docs/architecture/00 D10, 09 §4.1): the compiler, assemblers and linker
// are ONE library module, `SwiftStack`, organized by folders (Source/, Lex/, Parse/, Sem/,
// AIR/, Opt/, LIR/, Codegen/, Encode/, Object/, Asm/, Linker/), plus a thin `Driver`
// executable. One module lets hot generics (`Column`, handles) specialize and inline
// everywhere. Merging the current `Source` and `Lex` targets into `SwiftStack` is an M0 task.

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
