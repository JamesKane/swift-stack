import Foundation
import Testing
@testable import SwiftStack

// Differential-testing support (09-roadmap.md §6.1, 05-assembler.md §4.11).
//
// Objects from Swift-Stack and from an oracle (GNU `as`, `clang -c`) are both serialized to ELF and
// parsed by `TestELF`, a deliberately independent ELF64 reader, so a bug in `ELFObjectReader` or
// `ELFObjectWriter` cannot hide a difference by affecting both sides the same way.

// MARK: - External tools

enum ExternalTool {
    /// Absolute path of `name` on `PATH`, or nil if it is not installed.
    static func find(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The `clang` whose integrated assembler is the reference (LLVM MC 22, 05-assembler.md §4.11): `clang-22` when
    /// installed (a toolchain's `clang` earlier on `PATH` may be another release), else `clang`.
    static var referenceClang: String? { find("clang-22") ?? find("clang") }

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        // Capture through temporary files: no pipe-buffer deadlocks and no concurrent draining needed.
        let outPath = temporaryPath(".out"), errPath = temporaryPath(".err")
        _ = FileManager.default.createFile(atPath: outPath, contents: nil)
        _ = FileManager.default.createFile(atPath: errPath, contents: nil)
        defer {
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: errPath)
        }
        let outHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        let errHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: errPath))
        proc.standardOutput = outHandle
        proc.standardError = errHandle
        var inPath: String? = nil
        if let stdin {
            let p = temporaryPath(".in")
            _ = FileManager.default.createFile(atPath: p, contents: Data(stdin.utf8))
            proc.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: p))
            inPath = p
        }
        defer { if let inPath { try? FileManager.default.removeItem(atPath: inPath) } }
        try proc.run()
        proc.waitUntilExit()
        try outHandle.close()
        try errHandle.close()
        return Result(
            status: proc.terminationStatus,
            stdout: (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        )
    }

    static func temporaryPath(_ suffix: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ss_diff_\(UUID().uuidString)\(suffix)").path
    }
}

// MARK: - Independent ELF64 reader (test-only)

struct TestELF {
    struct Section {
        let name: String
        let type: UInt32
        let flags: UInt64
        let align: UInt64
        let size: UInt64
        let link: UInt32
        let info: UInt32
        let entsize: UInt64
        let data: [UInt8]
    }

    struct Symbol {
        let name: String
        let info: UInt8
        let other: UInt8
        let shndx: UInt16
        let value: UInt64
        let size: UInt64
        var binding: UInt8 { info >> 4 }
        var type: UInt8 { info & 0xF }
        var visibility: UInt8 { other & 0x3 }
    }

    struct Rela {
        let targetSection: Int
        let offset: UInt64
        let symbol: Int
        let type: UInt32
        let addend: Int64
    }

    static let SHT_SYMTAB: UInt32 = 2
    static let SHT_RELA: UInt32 = 4
    static let SHT_NOBITS: UInt32 = 8
    static let SHF_WRITE: UInt64 = 0x1
    static let SHF_ALLOC: UInt64 = 0x2
    static let SHF_EXECINSTR: UInt64 = 0x4
    static let SHF_MERGE: UInt64 = 0x10
    static let SHF_STRINGS: UInt64 = 0x20
    static let SHF_TLS: UInt64 = 0x400
    static let STT_SECTION: UInt8 = 3
    static let STT_FILE: UInt8 = 4
    static let SHN_UNDEF: UInt16 = 0
    static let SHN_ABS: UInt16 = 0xFFF1
    static let SHN_COMMON: UInt16 = 0xFFF2

    let machine: UInt16
    /// `e_flags` (RISC-V: `EF_RISCV_RVC` and the float ABI).
    let flags: UInt32
    let sections: [Section]
    let symbols: [Symbol]
    let relas: [Rela]

    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    init(bytes b: [UInt8]) throws {
        func u16(_ o: Int) throws -> UInt16 {
            guard o >= 0, o + 2 <= b.count else { throw FormatError(description: "truncated at \(o)") }
            return UInt16(b[o]) | UInt16(b[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> UInt32 {
            guard o >= 0, o + 4 <= b.count else { throw FormatError(description: "truncated at \(o)") }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * UInt32($1)) }
        }
        func u64(_ o: Int) throws -> UInt64 {
            guard o >= 0, o + 8 <= b.count else { throw FormatError(description: "truncated at \(o)") }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
        }
        func cstring(_ table: [UInt8], _ off: Int) -> String {
            guard off < table.count else { return "" }
            var end = off
            while end < table.count && table[end] != 0 { end += 1 }
            return String(decoding: table[off..<end], as: UTF8.self)
        }

        guard b.count >= 64, b[0] == 0x7F, b[1] == 0x45, b[2] == 0x4C, b[3] == 0x46, b[4] == 2, b[5] == 1 else {
            throw FormatError(description: "not a little-endian ELF64 file")
        }
        machine = try u16(18)
        flags = try u32(48)
        let shoff = Int(try u64(40))
        let shentsize = Int(try u16(58))
        let shnum = Int(try u16(60))
        let shstrndx = Int(try u16(62))

        struct RawHeader { let name: UInt32, type: UInt32, flags: UInt64, offset: Int, size: UInt64, link: UInt32, info: UInt32, align: UInt64, entsize: UInt64 }
        var raw: [RawHeader] = []
        for i in 0..<shnum {
            let h = shoff + i * shentsize
            raw.append(RawHeader(
                name: try u32(h), type: try u32(h + 4), flags: try u64(h + 8), offset: Int(try u64(h + 24)),
                size: try u64(h + 32), link: try u32(h + 40), info: try u32(h + 44), align: try u64(h + 48), entsize: try u64(h + 56)
            ))
        }
        func dataOf(_ h: RawHeader) throws -> [UInt8] {
            if h.type == TestELF.SHT_NOBITS { return [] }
            let end = h.offset + Int(h.size)
            guard h.offset >= 0, end <= b.count else { throw FormatError(description: "section data out of bounds") }
            return Array(b[h.offset..<end])
        }
        let shstr = shstrndx < raw.count ? try dataOf(raw[shstrndx]) : []
        var secs: [Section] = []
        for h in raw {
            secs.append(Section(
                name: cstring(shstr, Int(h.name)), type: h.type, flags: h.flags, align: h.align, size: h.size,
                link: h.link, info: h.info, entsize: h.entsize, data: try dataOf(h)
            ))
        }
        sections = secs

        var syms: [Symbol] = []
        if let symtab = secs.first(where: { $0.type == TestELF.SHT_SYMTAB }) {
            let strtab = Int(symtab.link) < secs.count ? secs[Int(symtab.link)].data : []
            let d = symtab.data
            var o = 0
            while o + 24 <= d.count {
                func r32(_ x: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[x + $1]) << (8 * UInt32($1)) } }
                func r64(_ x: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[x + $1]) << (8 * UInt64($1)) } }
                syms.append(Symbol(
                    name: cstring(strtab, Int(r32(o))), info: d[o + 4], other: d[o + 5],
                    shndx: UInt16(d[o + 6]) | UInt16(d[o + 7]) << 8, value: r64(o + 8), size: r64(o + 16)
                ))
                o += 24
            }
        }
        symbols = syms

        var relocs: [Rela] = []
        for s in secs where s.type == TestELF.SHT_RELA {
            let d = s.data
            var o = 0
            while o + 24 <= d.count {
                func r64(_ x: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[x + $1]) << (8 * UInt64($1)) } }
                let info = r64(o + 8)
                relocs.append(Rela(
                    targetSection: Int(s.info), offset: r64(o), symbol: Int(info >> 32),
                    type: UInt32(truncatingIfNeeded: info), addend: Int64(bitPattern: r64(o + 16))
                ))
                o += 24
            }
        }
        relas = relocs
    }

    init(path: String) throws {
        try self.init(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: path))))
    }
}

// MARK: - Normalized comparison

/// Knobs for differences that are documented as intentional (05-assembler.md §4.11).
struct DiffOptions {
    /// Compare `sh_addralign` of allocatable sections.
    var compareAlignment = true
    /// Sections whose bytes are not compared (size, flags, relocations and symbols still are), for a documented
    /// difference in alignment-padding NOP sequences.
    var bytesExemptSections: Set<String> = []
    /// Sections excluded entirely (with their relocations and the symbols defined in them), for a documented
    /// encoding choice that changes a section's size.
    var excludedSections: Set<String> = []
}

/// A comparable, layout-independent view of a relocatable object.
struct NormalizedObject {
    struct SectionInfo: Equatable, CustomStringConvertible {
        let name: String
        /// `sh_type` (`SHT_PROGBITS`, `SHT_NOTE`, ...); a linker reads `.note.gnu.property` only as `SHT_NOTE`.
        let type: UInt32
        let nobits: Bool
        let flags: UInt64
        let align: UInt64
        let size: UInt64
        let data: [UInt8]
        var description: String { "\(name) flags=0x\(String(flags, radix: 16)) align=\(align) size=\(size)" }
    }

    struct RelocInfo: Hashable, Comparable, CustomStringConvertible {
        let section: String
        let offset: UInt64
        let type: UInt32
        /// Undefined/global symbols by name; local and section symbols as `[section]` with the value folded into `addend`.
        let target: String
        let addend: Int64
        static func < (a: Self, b: Self) -> Bool {
            (a.section, a.offset, a.type, a.target, a.addend) < (b.section, b.offset, b.type, b.target, b.addend)
        }
        var description: String { "\(section)+0x\(String(offset, radix: 16)) type=\(type) \(target)\(addend >= 0 ? "+" : "")\(addend)" }
    }

    struct SymbolInfo: Hashable, Comparable, CustomStringConvertible {
        let name: String
        let binding: UInt8
        let type: UInt8
        let visibility: UInt8
        let section: String
        let value: UInt64
        let size: UInt64
        static func < (a: Self, b: Self) -> Bool { (a.name, a.section, a.value) < (b.name, b.section, b.value) }
        var description: String { "\(name) bind=\(binding) type=\(type) vis=\(visibility) \(section)+0x\(String(value, radix: 16)) size=\(size)" }
    }

    var sections: [String: SectionInfo] = [:]
    var relocs: [RelocInfo] = []
    var symbols: [SymbolInfo] = []

    init(_ elf: TestELF) {
        func sectionName(_ shndx: UInt16) -> String {
            switch shndx {
            case TestELF.SHN_UNDEF: return "*UND*"
            case TestELF.SHN_ABS: return "*ABS*"
            case TestELF.SHN_COMMON: return "*COM*"
            default: return Int(shndx) < elf.sections.count ? elf.sections[Int(shndx)].name : "?"
            }
        }
        let flagMask = TestELF.SHF_WRITE | TestELF.SHF_ALLOC | TestELF.SHF_EXECINSTR | TestELF.SHF_MERGE | TestELF.SHF_STRINGS | TestELF.SHF_TLS
        for s in elf.sections where (s.flags & TestELF.SHF_ALLOC) != 0 && s.size > 0 {
            sections[s.name] = SectionInfo(
                name: s.name, type: s.type, nobits: s.type == TestELF.SHT_NOBITS, flags: s.flags & flagMask,
                align: s.align, size: s.size, data: s.data
            )
        }
        for r in elf.relas {
            let target: String
            var addend = r.addend
            if r.symbol < elf.symbols.count {
                let sym = elf.symbols[r.symbol]
                let isLocalDefined = sym.binding == 0 && sym.shndx != TestELF.SHN_UNDEF && sym.shndx != TestELF.SHN_ABS
                if sym.type == TestELF.STT_SECTION || isLocalDefined {
                    target = "[\(sectionName(sym.shndx))]"
                    addend &+= Int64(bitPattern: sym.value)
                } else {
                    target = sym.name
                }
            } else {
                target = "?"
            }
            relocs.append(RelocInfo(section: elf.sections[r.targetSection].name, offset: r.offset, type: r.type, target: target, addend: addend))
        }
        relocs.sort()
        for (i, s) in elf.symbols.enumerated() where i > 0 {
            if s.type == TestELF.STT_SECTION || s.type == TestELF.STT_FILE || s.name.isEmpty { continue }
            if s.name.hasPrefix(".L") { continue }
            // AArch64/RISC-V mapping symbols (`$x`, `$d`, `$x.123`) mark code/data regions for disassemblers
            if s.name.hasPrefix("$x") || s.name.hasPrefix("$d") { continue }
            symbols.append(SymbolInfo(
                name: s.name, binding: s.binding, type: s.type, visibility: s.visibility,
                section: sectionName(s.shndx), value: s.value, size: s.size
            ))
        }
        symbols.sort()
    }

    /// Human-readable list of every difference between `self` (Swift-Stack) and `oracle`. Empty means equivalent.
    func differences(from oracle: NormalizedObject, options: DiffOptions = DiffOptions()) -> [String] {
        var out: [String] = []
        let ex = options.excludedSections
        for name in Set(sections.keys).union(oracle.sections.keys).subtracting(ex).sorted() {
            guard let ours = sections[name] else { out.append("missing section \(name)"); continue }
            guard let theirs = oracle.sections[name] else { out.append("extra section \(name)"); continue }
            // Processor-specific types (SHT_LOPROC...SHT_HIPROC) are not compared: LLVM marks x86-64 `.eh_frame`
            // SHT_X86_64_UNWIND, which Swift-Stack writes as SHT_PROGBITS (as GNU as does).
            let isProcessorSpecific = { (t: UInt32) in (0x7000_0000...0x7FFF_FFFF).contains(t) }
            if ours.type != theirs.type && !(isProcessorSpecific(ours.type) || isProcessorSpecific(theirs.type)) {
                out.append("\(name): sh_type ours=\(ours.type) oracle=\(theirs.type)")
            }
            if ours.flags != theirs.flags { out.append("\(name): flags ours=0x\(String(ours.flags, radix: 16)) oracle=0x\(String(theirs.flags, radix: 16))") }
            if options.compareAlignment && ours.align != theirs.align { out.append("\(name): align ours=\(ours.align) oracle=\(theirs.align)") }
            if ours.size != theirs.size {
                out.append("\(name): size ours=\(ours.size) oracle=\(theirs.size)")
            } else if !ours.nobits && ours.data != theirs.data {
                if !options.bytesExemptSections.contains(name) {
                    let i = ours.data.indices.first(where: { ours.data[$0] != theirs.data[$0] }) ?? 0
                    let lo = max(0, i - 4), hi = min(ours.data.count, i + 12)
                    func hex(_ d: [UInt8]) -> String { d[lo..<hi].map { String(format: "%02x", $0) }.joined(separator: " ") }
                    out.append("\(name): bytes differ at 0x\(String(i, radix: 16)): ours=[\(hex(ours.data))] oracle=[\(hex(theirs.data))]")
                }
            }
        }
        let ourRelocs = Set(relocs.filter { !ex.contains($0.section) })
        let theirRelocs = Set(oracle.relocs.filter { !ex.contains($0.section) })
        for r in ourRelocs.subtracting(theirRelocs).sorted() { out.append("extra reloc \(r)") }
        for r in theirRelocs.subtracting(ourRelocs).sorted() { out.append("missing reloc \(r)") }
        let ourSyms = Set(symbols.filter { !ex.contains($0.section) })
        let theirSyms = Set(oracle.symbols.filter { !ex.contains($0.section) })
        for s in ourSyms.subtracting(theirSyms).sorted() { out.append("extra/different symbol \(s)") }
        for s in theirSyms.subtracting(ourSyms).sorted() { out.append("missing/different symbol \(s)") }
        return out
    }
}

// MARK: - Exact comparison

/// An exact comparison of two relocatable objects, for assembly that both assemblers must turn into the same
/// object (clang's own `-S` output): every section but the symbol, string and relocation tables (non-allocatable
/// and empty ones included) with its type, flags, alignment, entry size and bytes; every relocation with the
/// symbol it names (a section symbol as `[sec name]`, so a relocation against a local label instead of its section
/// symbol is a difference); every symbol, temporary `.L*`, mapping, file and section symbols included; `e_flags`.
/// `.llvm_addrsig` is compared as the names of the symbols it lists (its size depends on the `.symtab` order).
enum ExactObjectComparison {
    static func differences(ours: TestELF, oracle: TestELF) -> [String] {
        var out: [String] = []
        if ours.flags != oracle.flags {
            out.append("e_flags ours=0x\(String(ours.flags, radix: 16)) oracle=0x\(String(oracle.flags, radix: 16))")
        }
        func sectionName(_ elf: TestELF, _ shndx: UInt16) -> String {
            switch shndx {
            case TestELF.SHN_UNDEF: return "*UND*"
            case TestELF.SHN_ABS: return "*ABS*"
            case TestELF.SHN_COMMON: return "*COM*"
            default: return Int(shndx) < elf.sections.count ? elf.sections[Int(shndx)].name : "?"
            }
        }
        func symbolName(_ elf: TestELF, _ index: Int) -> String {
            guard index > 0, index < elf.symbols.count else { return index == 0 ? "-" : "?" }
            let sym = elf.symbols[index]
            return sym.type == TestELF.STT_SECTION ? "[sec \(sectionName(elf, sym.shndx))]" : sym.name
        }
        func contents(_ elf: TestELF) -> [String: TestELF.Section] {
            var map: [String: TestELF.Section] = [:]
            for s in elf.sections.dropFirst() where ![TestELF.SHT_SYMTAB, 3, TestELF.SHT_RELA].contains(s.type) {
                map[s.name] = s
            }
            return map
        }
        /// `.llvm_addrsig`: ULEB128 symbol indices, as names.
        func addrsig(_ elf: TestELF, _ data: [UInt8]) -> [String] {
            var names: [String] = []
            var value = 0, shift = 0
            for b in data {
                value |= Int(b & 0x7F) << shift
                shift += 7
                if b & 0x80 == 0 {
                    names.append(symbolName(elf, value))
                    value = 0
                    shift = 0
                }
            }
            return names
        }
        let a = contents(ours), b = contents(oracle)
        for name in Set(a.keys).union(b.keys).sorted() {
            guard let x = a[name] else { out.append("missing section \(name)"); continue }
            guard let y = b[name] else { out.append("extra section \(name)"); continue }
            for (field, l, r) in [("type", UInt64(x.type), UInt64(y.type)), ("flags", x.flags, y.flags), ("align", x.align, y.align),
                                  ("entsize", x.entsize, y.entsize), ("size", x.size, y.size)]
            where l != r && !(field == "size" && name == ".llvm_addrsig") {
                out.append("\(name): \(field) ours=0x\(String(l, radix: 16)) oracle=0x\(String(r, radix: 16))")
            }
            if name == ".llvm_addrsig" {
                let l = addrsig(ours, x.data), r = addrsig(oracle, y.data)
                if l != r { out.append(".llvm_addrsig: ours=\(l) oracle=\(r)") }
            } else if x.size == y.size && x.data != y.data {
                let i = x.data.indices.first { x.data[$0] != y.data[$0] } ?? 0
                func hex(_ d: [UInt8]) -> String { d[max(0, i - 4)..<min(d.count, i + 12)].map { String(format: "%02x", $0) }.joined(separator: " ") }
                out.append("\(name): bytes differ at 0x\(String(i, radix: 16)): ours=[\(hex(x.data))] oracle=[\(hex(y.data))]")
            }
        }
        func relocs(_ elf: TestELF) -> [String] {
            elf.relas.map { r in
                let addend = r.addend >= 0 ? "+\(r.addend)" : "\(r.addend)"
                return "\(elf.sections[r.targetSection].name)+0x\(String(r.offset, radix: 16)) type=\(r.type) \(symbolName(elf, r.symbol))\(addend)"
            }.sorted()
        }
        func symbols(_ elf: TestELF) -> [String] {
            elf.symbols.indices.dropFirst().map { i in
                let s = elf.symbols[i]
                return "\(symbolName(elf, i)) bind=\(s.binding) type=\(s.type) vis=\(s.visibility) \(sectionName(elf, s.shndx))+0x\(String(s.value, radix: 16)) size=\(s.size)"
            }.sorted()
        }
        func multisetDifference(_ l: [String], _ r: [String]) -> [String] {
            var counts: [String: Int] = [:]
            for x in r { counts[x, default: 0] += 1 }
            var extra: [String] = []
            for x in l {
                if let c = counts[x], c > 0 { counts[x] = c - 1 } else { extra.append(x) }
            }
            return extra
        }
        let (ra, rb) = (relocs(ours), relocs(oracle))
        out += multisetDifference(ra, rb).map { "extra reloc \($0)" } + multisetDifference(rb, ra).map { "missing reloc \($0)" }
        let (sa, sb) = (symbols(ours), symbols(oracle))
        out += multisetDifference(sa, sb).map { "extra symbol \($0)" } + multisetDifference(sb, sa).map { "missing symbol \($0)" }
        return out
    }
}

// MARK: - Assembling with Swift-Stack and with oracles

enum DifferentialAssembly {
    struct Target {
        let arch: AssemblerArch
        let clangTriple: String
        let clangFlags: [String]
    }

    /// The `-DNAME[=VALUE]` flags of `flags` as preprocessor definitions (`VALUE` defaults to `1`, as in clang).
    static func defines(in flags: [String]) -> [(name: String, value: String)] {
        flags.filter { $0.hasPrefix("-D") }.map { flag in
            let def = flag.dropFirst(2)
            guard let eq = def.firstIndex(of: "=") else { return (String(def), "1") }
            return (String(def[..<eq]), String(def[def.index(after: eq)...]))
        }
    }

    /// The RISC-V assembler state clang's driver derives from `flags`: `-march`, PIC from `-fPIC`/`-fPIE`, and linker
    /// relaxation, which clang enables unless `-mno-relax` is given.
    static func riscvOptions(for flags: [String]) -> RVAsmOptions {
        guard let march = flags.last(where: { $0.hasPrefix("-march=") }) else { return RVAsmOptions() }
        let pic = flags.contains { ["-fPIC", "-fPIE", "-fpic", "-fpie"].contains($0) }
        let abi = flags.last { $0.hasPrefix("-mabi=") }.map { String($0.dropFirst("-mabi=".count)) }
        return RVAsmOptions(march: String(march.dropFirst("-march=".count)), pic: pic, relax: !flags.contains("-mno-relax"), abi: abi)
    }

    /// Assembles `path` with Swift-Stack and returns the serialized object plus error diagnostics count. The
    /// target's `-D` flags are applied, and for RISC-V its ISA, PIC and relaxation flags, as clang applies them.
    static func assembleOurs(path: String, target: Target, includePaths: [String]) throws -> (elf: TestELF, errors: Int) {
        var diags = DiagnosticBag()
        let obj = try Assembler.assembleFile(
            path: path, arch: target.arch, includePaths: includePaths, defines: defines(in: target.clangFlags),
            riscvOptions: riscvOptions(for: target.clangFlags), diagnostics: &diags)
        let bytes = ELFObjectWriter.write(obj)
        return (try TestELF(bytes: bytes), diags.errorCount)
    }

    static func assembleWithClang(path: String, target: Target, includePaths: [String]) throws -> TestELF {
        guard let clang = ExternalTool.referenceClang else { throw TestELF.FormatError(description: "clang not found") }
        let out = ExternalTool.temporaryPath(".o")
        defer { try? FileManager.default.removeItem(atPath: out) }
        let args = ["-target", target.clangTriple, "-c", path, "-o", out] + includePaths.map { "-I\($0)" } + target.clangFlags
        let r = try ExternalTool.run(clang, args)
        guard r.status == 0 else { throw TestELF.FormatError(description: "clang failed on \(path): \(r.stderr)") }
        return try TestELF(path: out)
    }

    /// x86-64 only: GNU `as` (via `gcc -c`, which runs `cpp` then the host GNU assembler).
    static func assembleWithGNU(path: String, includePaths: [String], defines: [String] = []) throws -> TestELF {
        guard let gcc = ExternalTool.find("gcc") else { throw TestELF.FormatError(description: "gcc not found") }
        let out = ExternalTool.temporaryPath(".o")
        defer { try? FileManager.default.removeItem(atPath: out) }
        // `-mx86-used-note=no`: Fedora's GNU `as` otherwise adds a `.note.gnu.property` ISA note not present in the source.
        let r = try ExternalTool.run(gcc, ["-c", path, "-o", out, "-Wa,-mx86-used-note=no"] + includePaths.map { "-I\($0)" } + defines)
        guard r.status == 0 else { throw TestELF.FormatError(description: "gcc/as failed on \(path): \(r.stderr)") }
        return try TestELF(path: out)
    }

    static let x86 = Target(arch: .x86_64, clangTriple: "x86_64-unknown-none-elf", clangFlags: [])
    static let a64 = Target(arch: .aarch64, clangTriple: "aarch64-unknown-none-elf", clangFlags: ["-march=armv8.2-a+sve"])
    static let rv64 = Target(arch: .riscv64, clangTriple: "riscv64-unknown-none-elf", clangFlags: ["-march=rv64gc_zba_zbb_zbs_v", "-mabi=lp64d", "-mno-relax"])

    static func target(for arch: AssemblerArch) -> Target {
        switch arch {
        case .x86_64: return x86
        case .aarch64: return a64
        case .riscv64: return rv64
        }
    }
}

// MARK: - Batched LLVM MC

/// One llvm-mc invocation per batch of instructions, for the exhaustive encoder sweeps.
enum LLVMMC {
    /// Assembles one instruction per line with `--show-encoding`; `nil` for a line LLVM rejects. An encoding
    /// with unresolved (fixup) bytes is returned with the known bytes only and flagged. `header` lines (such
    /// as `.code16`) are prepended and produce no encoding.
    static func assemble(_ lines: [String], mc: String, args: [String], header: [String] = []) throws -> [(bytes: [UInt8], fixup: Bool)?] {
        let r = try ExternalTool.run(mc, args + ["-show-encoding"], stdin: (header + lines).joined(separator: "\n") + "\n")
        var failed = Set<Int>()
        for line in r.stderr.split(separator: "\n") where line.hasPrefix("<stdin>:") && line.contains(": error:") {
            let fields = line.split(separator: ":")
            if fields.count > 1, let n = Int(fields[1]) { failed.insert(n - 1 - header.count) }
        }
        var encodings: [(bytes: [UInt8], fixup: Bool)] = []
        encodings.reserveCapacity(lines.count)
        for line in r.stdout.split(separator: "\n") {
            guard let lb = line.range(of: "encoding: ["), let rb = line[lb.upperBound...].firstIndex(of: "]") else { continue }
            let fields = line[lb.upperBound..<rb].split(separator: ",")
            let bytes = fields.compactMap { $0.hasPrefix("0x") ? UInt8($0.dropFirst(2), radix: 16) : nil }
            encodings.append((bytes, bytes.count != fields.count))
        }
        var out: [(bytes: [UInt8], fixup: Bool)?] = []
        out.reserveCapacity(lines.count)
        var next = 0
        for i in lines.indices {
            if failed.contains(i) || next >= encodings.count {
                out.append(nil)
            } else {
                out.append(encodings[next])
                next += 1
            }
        }
        return out
    }

    /// Disassembles one instruction per element; `nil` where LLVM reports an invalid encoding. Each
    /// instruction's bytes are on their own input line so diagnostics map back to it.
    static func disassemble(_ instructions: [[UInt8]], mc: String, args: [String]) throws -> [String?] {
        let input = instructions.map { $0.map { String(format: "0x%02x", $0) }.joined(separator: " ") }.joined(separator: "\n") + "\n"
        let r = try ExternalTool.run(mc, args + ["--disassemble"], stdin: input)
        // An invalid encoding (reported as a warning or an error) produces no output line; a "potentially
        // undefined" (unpredictable) one is still printed.
        var failed = Set<Int>()
        for line in r.stderr.split(separator: "\n") where line.hasPrefix("<stdin>:") && line.contains("invalid instruction encoding") {
            let fields = line.split(separator: ":")
            if fields.count > 1, let n = Int(fields[1]) { failed.insert(n - 1) }
        }
        let decoded = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".text") }
        var out: [String?] = []
        out.reserveCapacity(instructions.count)
        var next = 0
        for i in instructions.indices {
            if failed.contains(i) || next >= decoded.count {
                out.append(nil)
            } else {
                // Drop a trailing `// ...` comment (LLVM annotates `mov` immediates with their value).
                let text = decoded[next]
                out.append(text.range(of: "//").map { String(text[..<$0.lowerBound]).trimmingCharacters(in: .whitespaces) } ?? text)
                next += 1
            }
        }
        return out
    }
}
