import Foundation
import Testing
@testable import SwiftStack

// M3 phase 1 gates against clang 22 (milestones/M3-plan.md §2):
// - `sizeof`, `_Alignof` and `offsetof` of generated types match clang on x86-64, AArch64 and RISC-V. The probe file
//   folds them into `unsigned long long probes[]`, so our side is the static-initializer image of that array and
//   clang's is its `-emit-llvm` constant;
// - the data images of generated global initializers match `clang -c -O0` on the three targets;
// - the data image of every global in the C corpora matches `clang -c -O0` for x86-64.
// Generated files are deterministic (seeded) and kept in the temporary directory when a comparison fails.

/// SplitMix64: a small, seedable generator, so a failing probe file can be regenerated from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A probe target: the front end's arch name and clang's triple.
struct ProbeTarget: Sendable {
    let arch: String
    let triple: String

    static let all = [
        ProbeTarget(arch: "x86_64", triple: "x86_64-unknown-linux-gnu"),
        ProbeTarget(arch: "aarch64", triple: "aarch64-unknown-linux-gnu"),
        ProbeTarget(arch: "riscv64", triple: "riscv64-unknown-linux-gnu"),
    ]

    var cTarget: CTarget { CTarget(arch: arch, triple: triple, flags: []) }
    var clangArgs: [String] { ["--target=\(triple)", "-ffreestanding", "-std=c23", "-w", "-O0"] }
}

// MARK: - Generator

/// Generates C types and initializers for the probes.
struct CProbeGenerator {
    struct Member {
        /// The member's name ("" for an unnamed bit-field).
        let name: String
        let decl: String
        /// The type when the member is not a bit-field, for initializers.
        let type: GenType?
        let bitWidth: Int?
        let bitSigned: Bool
        /// Members inside an anonymous struct or union, named directly in the enclosing type.
        let anonymous: [Member]
    }

    indirect enum GenType {
        case scalar(String, Scalar)
        case array(GenType, Int)
        case record(name: String, isUnion: Bool, members: [Member], hasFlexibleArray: Bool)

        var spelling: String {
            switch self {
            case .scalar(let s, _): return s
            case .array(let e, _): return e.spelling
            case .record(let name, _, _, _): return name
            }
        }
    }

    enum Scalar {
        case integer(bits: Int, signed: Bool)
        case bool
        case float(Int)
        case pointer
        case enumeration
    }

    var rng: SplitMix64
    let target: ProbeTarget
    /// Initializer probes leave out arrays of `_BitInt` wider than 128 bits: clang 22 emits an initialized one with
    /// `iN` elements of LLVM's (larger) allocation size, so its symbol is bigger than `sizeof` (`_BitInt(300) a[6]`
    /// is 240 bytes but emitted as 280); the layout probes check those arrays' `sizeof`.
    var forImages = false
    var definitions: [String] = []
    var records: [GenType] = []
    var counter = 0

    init(seed: UInt64, target: ProbeTarget) {
        rng = SplitMix64(seed: seed)
        self.target = target
    }

    mutating func chance(_ p: Double) -> Bool { Double(rng.next() % 10_000) < p * 10_000 }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...items.count - 1)] }
    mutating func fresh(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }

    var longBits: Int { 64 }
    var charSigned: Bool { target.arch == "x86_64" }

    mutating func scalarType() -> GenType {
        let t = anyScalarType()
        // A wide `_BitInt` element or member trips clang's emission (see `forImages`): images keep them top-level
        return forImages && isWideBitInt(t) ? .scalar("_BitInt(128)", .integer(bits: 128, signed: true)) : t
    }

    mutating func anyScalarType() -> GenType {
        switch int(0...21) {
        case 0: return .scalar("char", .integer(bits: 8, signed: charSigned))
        case 1: return .scalar("signed char", .integer(bits: 8, signed: true))
        case 2: return .scalar("unsigned char", .integer(bits: 8, signed: false))
        case 3: return .scalar("short", .integer(bits: 16, signed: true))
        case 4: return .scalar("unsigned short", .integer(bits: 16, signed: false))
        case 5, 6: return .scalar("int", .integer(bits: 32, signed: true))
        case 7: return .scalar("unsigned", .integer(bits: 32, signed: false))
        case 8: return .scalar("long", .integer(bits: longBits, signed: true))
        case 9: return .scalar("unsigned long", .integer(bits: longBits, signed: false))
        case 10: return .scalar("long long", .integer(bits: 64, signed: true))
        case 11: return .scalar("float", .float(32))
        case 12: return .scalar("double", .float(64))
        case 13: return .scalar("long double", .float(target.arch == "x86_64" ? 80 : 128))
        case 14: return .scalar("_Bool", .bool)
        case 15: return .scalar("void *", .pointer)
        case 16: return .scalar("int *", .pointer)
        case 17: return .scalar("__int128", .integer(bits: 128, signed: true))
        case 18: return .scalar("unsigned __int128", .integer(bits: 128, signed: false))
        case 19:
            let maxWidth = target.arch == "x86_64" ? 300 : 128
            let width = chance(0.5) ? int(1...64) : int(65...maxWidth)
            let signed = width > 1 && chance(0.5)
            return .scalar("\(signed ? "" : "unsigned ")_BitInt(\(width))", .integer(bits: width, signed: signed))
        case 20:
            let name = fresh("E")
            let base = pick(["short", "unsigned char", "long long", "int"])
            definitions.append("enum \(name) : \(base) { \(name)_a = 1, \(name)_b = 7 };")
            return .scalar("enum \(name)", .enumeration)
        default: return .scalar("_Float16", .float(16))
        }
    }

    /// A bit-field's declared type, its width in bits and signedness.
    mutating func bitFieldType() -> (String, Int, Bool) {
        switch int(0...7) {
        case 0: return ("int", 32, true)
        case 1: return ("unsigned", 32, false)
        case 2: return ("char", 8, charSigned)
        case 3: return ("unsigned short", 16, false)
        case 4: return ("long long", 64, true)
        case 5: return ("unsigned long", 64, false)
        case 6: return ("_Bool", 1, false)
        default: return ("short", 16, true)
        }
    }

    mutating func memberType(depth: Int) -> GenType {
        if depth < 2, !records.isEmpty, chance(0.2) {
            let usable = records.filter { if case .record(_, _, _, false) = $0 { return true } else { return false } }
            if !usable.isEmpty { return pick(usable) }
        }
        let element = scalarType()
        return chance(0.2) ? .array(element, int(1...5)) : element
    }

    func isWideBitInt(_ t: GenType) -> Bool {
        if case .scalar(_, .integer(let bits, _)) = t { return bits > 128 }
        return false
    }

    mutating func members(depth: Int, prefix: String) -> [Member] {
        var result: [Member] = []
        for _ in 0..<int(1...6) {
            let name = fresh(prefix)
            if chance(0.25) {
                let (t, bits, signed) = bitFieldType()
                if chance(0.1) {
                    result.append(Member(name: "", decl: "\(t) : 0;", type: nil, bitWidth: 0, bitSigned: signed, anonymous: []))
                    continue
                }
                let width = int(1...bits)
                let named = !chance(0.1)
                result.append(Member(name: named ? name : "", decl: "\(t) \(named ? name : "") : \(width);", type: nil, bitWidth: width,
                                     bitSigned: signed, anonymous: []))
            } else if depth < 2, chance(0.08) {
                let isUnion = chance(0.5)
                let inner = members(depth: depth + 1, prefix: prefix)
                result.append(Member(name: "", decl: "\(isUnion ? "union" : "struct") { \(inner.map(\.decl).joined(separator: " ")) };",
                                     type: nil, bitWidth: nil, bitSigned: false, anonymous: inner))
            } else {
                let t = memberType(depth: depth)
                if chance(0.08) {
                    // The attribute only raises alignment (unless packed); `_Alignas` may not lower it, so it asks for
                    // at least the largest scalar alignment
                    result.append(member(name, t, attr: " __attribute__((aligned(\(pick([1, 2, 4, 8, 16, 32])))))"))
                } else if case .scalar = t, chance(0.06) {
                    result.append(member(name, t, prefix: "_Alignas(\(pick([16, 32]))) "))
                } else {
                    result.append(member(name, t))
                }
            }
        }
        return result
    }

    func member(_ name: String, _ t: GenType, prefix: String = "", attr: String = "") -> Member {
        let decl: String
        if case .array(let e, let n) = t { decl = "\(prefix)\(e.spelling) \(name)[\(n)]\(attr);" }
        else { decl = "\(prefix)\(t.spelling) \(name)\(attr);" }
        return Member(name: name, decl: decl, type: t, bitWidth: nil, bitSigned: false, anonymous: [])
    }

    /// Defines a new struct or union type.
    mutating func record(allowFlexible: Bool) -> GenType {
        let isUnion = chance(0.25)
        let tag = fresh(isUnion ? "U" : "S")
        var ms = members(depth: 0, prefix: "m")
        var flexible = false
        if !isUnion, allowFlexible, ms.contains(where: { !$0.name.isEmpty }), chance(0.15) {
            let e = scalarType()
            if case .scalar(_, let s) = e, case .integer = s {
                flexible = true
                ms.append(Member(name: fresh("fam"), decl: "\(e.spelling) fam\(counter)[];", type: .array(e, 0), bitWidth: nil,
                                 bitSigned: false, anonymous: []))
            }
        }
        var attrs = ""
        if chance(0.15) { attrs += " __attribute__((packed))" }
        if chance(0.1) { attrs += chance(0.3) ? " __attribute__((aligned))" : " __attribute__((aligned(\(pick([2, 4, 8, 16, 32, 64])))))" }
        let keyword = isUnion ? "union" : "struct"
        var def = "\(keyword)\(attrs) \(tag) { \(ms.map(\.decl).joined(separator: " ")) };"
        if chance(0.1) { def = "#pragma pack(push, \(pick([1, 2, 4])))\n\(def)\n#pragma pack(pop)" }
        definitions.append(def)
        let t = GenType.record(name: "\(keyword) \(tag)", isUnion: isUnion, members: ms, hasFlexibleArray: flexible)
        records.append(t)
        return t
    }

    /// `offsetof` designators of a record's members (non-bit-fields, through anonymous members, one array element,
    /// and one level into a nested record).
    func offsetPaths(_ members: [Member]) -> [String] {
        var paths: [String] = []
        for m in members {
            if !m.anonymous.isEmpty { paths += offsetPaths(m.anonymous); continue }
            guard m.bitWidth == nil, !m.name.isEmpty, let t = m.type else { continue }
            paths.append(m.name)
            switch t {
            case .array(_, let n) where n > 1: paths.append("\(m.name)[\(n - 1)]")
            case .record(_, _, let inner, _):
                if let first = offsetPaths(inner).last { paths.append("\(m.name).\(first)") }
            default: break
            }
        }
        return paths
    }

    // MARK: Layout probes

    /// A probe file and a description of each element of `probes`.
    mutating func layoutFile() -> (source: String, labels: [String]) {
        var exprs: [(String, String)] = []
        for _ in 0..<int(4...8) {
            let t = record(allowFlexible: true)
            guard case .record(let name, _, let ms, _) = t else { continue }
            exprs.append(("sizeof(\(name))", "sizeof(\(name))"))
            exprs.append(("_Alignof(\(name))", "_Alignof(\(name))"))
            for p in offsetPaths(ms) { exprs.append(("offsetof(\(name), \(p))", "offsetof(\(name), \(p))")) }
        }
        for _ in 0..<4 {
            let s = scalarType()
            exprs.append(("sizeof(\(s.spelling))", "sizeof(\(s.spelling))"))
            exprs.append(("_Alignof(\(s.spelling))", "_Alignof(\(s.spelling))"))
        }
        let source = "#include <stddef.h>\n" + definitions.joined(separator: "\n") + "\nunsigned long long probes[] = {\n"
            + exprs.map { "  \($0.0)," }.joined(separator: "\n") + "\n};\n"
        return (source, exprs.map(\.1))
    }

    // MARK: Initializer probes

    var globals: [(name: String, type: GenType)] = []

    mutating func integerLiteral(bits: Int, signed: Bool) -> String {
        switch int(0...9) {
        case 0: return "0"
        case 1: return signed ? "-1" : "\(UInt64.max)ull"
        case 2: return "\(int(-300...300))"
        case 3: return "0x\(String(rng.next(), radix: 16))ull"
        case 4: return "(1ull << \(int(0...63)))"
        case 5: return "(\(rng.next() % 1_000_000)u * \(rng.next() % 100_000)u)"
        case 6: return "(\(Int(rng.next() % 2000) - 1000) / \(pick([-7, -3, 2, 5, 13])))"
        case 7: return "(\(Int(rng.next() % 2000) - 1000) % \(pick([-7, -3, 2, 5, 13])))"
        case 8:
            // A floating value converted to the integer type, in range (an out-of-range conversion is undefined)
            guard bits >= 16 else { return "\(int(0...1))" }
            return signed ? "(\(pick(["-3.75", "-0.5", "100.9", "-127.99"])))" : "(\(pick(["3.75", "0.5", "200.9", "65535.5"])))"
        default: return "(~\(int(0...1000))ull >> \(int(0...63)))"
        }
    }

    mutating func floatLiteral(_ bits: Int) -> String {
        let suffix = bits == 32 ? "f" : bits >= 80 ? "L" : ""
        let lits = ["0.1", "1.0", "-0.0", "3.25", "1e-5", "6.02214076e23", "0x1.8p-3", "123456789.123456789", "1e-38", "2.5e-41"]
        let wide = ["1e300", "1e-310", "0x1.fffffffffffffp+1023", "4.9e-324"]
        var lit = pick(lits) + suffix
        if bits >= 64, chance(0.2) { lit = pick(wide) + suffix }
        switch int(0...6) {
        case 0: return "(\(lit) + \(pick(lits))\(suffix))"
        case 1: return "(\(lit) / 3\(bits == 16 ? ".0f" : ".0")\(suffix))"
        case 2: return "(\(lit) * -7)"
        case 3: return "(\(pick(["18446744073709551615ull", "9007199254740993ll", "-17", "16777217"])))"
        case 4: return "(float)\(pick(lits))"
        default: return lit
        }
    }

    /// An address constant pointing into an earlier global.
    mutating func addressConstant() -> String? {
        guard !globals.isEmpty else { return nil }
        let (name, t) = pick(globals)
        switch int(0...4) {
        case 0: return "&\(name)"
        case 1: return "(char *)&\(name) + \(int(-4...24))"
        case 2:
            if case .array(_, let n) = t, n > 0 { return "&\(name)[\(int(0...n - 1))]" }
            return "&\(name)"
        case 3:
            if case .record(_, _, let ms, _) = t, let p = offsetPaths(ms).first { return "&\(name).\(p)" }
            return "&\(name) + 1"
        default: return "&\(name)"
        }
    }

    mutating func scalarInitializer(_ s: Scalar, spelling: String) -> String {
        switch s {
        case .integer(let bits, let signed):
            if ["long", "unsigned long", "long long"].contains(spelling), chance(0.1), let a = addressConstant() { return "(\(spelling))(\(a))" }
            return "(\(spelling))\(integerLiteral(bits: bits, signed: signed))"
        case .bool: return pick(["0", "1", "5", "0.25", "-1", "0.0"])
        case .float(let bits): return floatLiteral(bits)
        case .enumeration: return pick(["1", "7", "3", "-2"])
        case .pointer:
            switch int(0...5) {
            case 0: return "0"
            case 1: return "(\(spelling))16"
            case 2: return spelling == "int *" ? "(int[]){\(int(0...9)), \(int(0...9))}" : "\"str\(int(0...99))\" + \(int(0...3))"
            default: return addressConstant().map { "(\(spelling))(\($0))" } ?? "0"
            }
        }
    }

    mutating func initializer(_ t: GenType, depth: Int = 0) -> String {
        switch t {
        case .scalar(let spelling, let s):
            return scalarInitializer(s, spelling: spelling)
        case .array(let element, let n):
            if case .scalar("char", _) = element, chance(0.5) {
                // As many characters as fit; `n` characters drop the terminator (C23 6.7.10p15)
                let len = n == 0 ? int(0...6) : int(max(0, n - 2)...n)
                return "\"" + String((0..<len).map { _ in "abcdefgh".randomElement(using: &rng)! }) + "\""
            }
            if n == 0 {
                // A flexible array member: in order (clang cannot emit some designated forms)
                return "{" + (0..<int(1...4)).map { _ in initializer(element, depth: depth + 1) }.joined(separator: ", ") + "}"
            }
            let count = n
            var items: [String] = []
            var i = 0
            while i < count {
                if count > 3, chance(0.15) {
                    let hi = min(count - 1, i + int(1...2))
                    items.append("[\(i) ... \(hi)] = \(initializer(element, depth: depth + 1))")
                    i = hi + 1
                } else if chance(0.2) {
                    i += 1 // left zero
                } else {
                    items.append("[\(i)] = \(initializer(element, depth: depth + 1))")
                    i += 1
                }
            }
            return "{" + items.joined(separator: ", ") + "}"
        case .record(_, let isUnion, let ms, _):
            let flat = initializable(ms)
            if flat.isEmpty { return "{}" }
            if isUnion {
                let m = chance(0.5) ? flat[0] : pick(flat)
                return "{ .\(m.name) = \(memberInitializer(m, depth: depth)) }"
            }
            var items: [String] = []
            for m in flat where chance(0.8) {
                if case .array(_, 0) = m.type { if depth > 0 { continue } }
                items.append(".\(m.name) = \(memberInitializer(m, depth: depth))")
            }
            if chance(0.3) { items.reverse() }
            return "{" + items.joined(separator: ", ") + "}"
        }
    }

    /// Named members that a designated initializer can name (anonymous members' members included).
    func initializable(_ members: [Member]) -> [Member] {
        members.flatMap { m -> [Member] in
            if !m.anonymous.isEmpty { return [] } // designating through anonymous unions is kept out: overlap rules
            return m.name.isEmpty ? [] : [m]
        }
    }

    mutating func memberInitializer(_ m: Member, depth: Int) -> String {
        if let width = m.bitWidth {
            if m.decl.hasPrefix("_Bool") { return pick(["0", "1"]) }
            let limit = width >= 62 ? Int.max >> 2 : 1 << width
            return chance(0.2) ? "\(Int(rng.next() % 100_000))" : "\(m.bitSigned ? Int.random(in: -(limit / 2)...(limit / 2 - 1), using: &rng) : Int.random(in: 0...limit - 1, using: &rng))"
        }
        return initializer(m.type!, depth: depth + 1)
    }

    mutating func imageFile() -> String {
        forImages = true
        var decls: [String] = []
        for _ in 0..<int(2...4) { _ = record(allowFlexible: true) }
        let funcs = ["fa", "fb"]
        decls.append("int fa(int); static int fb(void) { return 0; }")
        for _ in 0..<int(8...16) {
            let name = fresh("g")
            let storage = chance(0.25) ? "static " : chance(0.1) ? "const " : ""
            var t: GenType
            switch int(0...5) {
            case 0, 1: t = pick(records)
            case 2: t = .array(scalarType(), int(1...6))
            case 3: t = .array(.scalar("char", .integer(bits: 8, signed: charSigned)), chance(0.3) ? 0 : int(1...8))
            default: t = anyScalarType()
            }
            if case .scalar("void *", _) = t, chance(0.3) {
                let qualifier = storage == "const " ? "const " : ""
                decls.append("\(storage == "static " ? storage : "")int (*\(qualifier)\(name))(int) = \(chance(0.5) ? funcs[0] : "(int (*)(int))\(funcs[1])");")
                continue
            }
            let initText = initializer(t)
            switch t {
            case .array(let e, let n): decls.append("\(storage)\(e.spelling) \(name)[\(n == 0 ? "" : String(n))] = \(initText);")
            default: decls.append("\(storage)\(t.spelling) \(name) = \(initText);")
            }
            if case .record(_, _, _, true) = t {} else { globals.append((name, t)) }
            if storage == "static " { decls.append("void *use_\(name) = &\(name);") }
        }
        return definitions.joined(separator: "\n") + "\n" + decls.joined(separator: "\n") + "\n"
    }
}

// MARK: - Comparison against clang's object

enum ClangImageCheck {
    /// A relocation target, resolved to something both sides can name.
    enum Place: Equatable, CustomStringConvertible {
        /// A defined location: section index and offset in it.
        case location(Int, Int64)
        /// An undefined symbol plus addend.
        case symbol(String, Int64)

        var description: String {
            switch self {
            case .location(let s, let o): return "section \(s)+\(o)"
            case .symbol(let n, let a): return "\(n)\(a >= 0 ? "+" : "")\(a)"
            }
        }
    }

    /// Compiles `path` with clang and returns its object.
    static func clangObject(path: String, args: [String]) throws -> TestELF {
        guard let clang = ExternalTool.referenceClang else { throw TestELF.FormatError(description: "no clang") }
        let out = ExternalTool.temporaryPath(".o")
        defer { try? FileManager.default.removeItem(atPath: out) }
        let r = try ExternalTool.run(clang, args + ["-c", "-o", out, path])
        guard r.status == 0 else { throw TestELF.FormatError(description: "clang failed on \(path): \(r.stderr.prefix(600))") }
        return try TestELF(bytes: [UInt8](try Data(contentsOf: URL(fileURLWithPath: out))))
    }

    /// Compares every global of `module` that clang emitted with clang's bytes and relocations. Returns the
    /// mismatches and the number of globals compared.
    static func compare(_ module: SemModule, with elf: TestELF) -> (issues: [String], compared: Int) {
        var bySymbol: [String: [Int]] = [:]
        for (i, s) in elf.symbols.enumerated() where !s.name.isEmpty && s.type != TestELF.STT_SECTION && s.type != TestELF.STT_FILE {
            bySymbol[s.name, default: []].append(i)
        }
        var ourCount: [String: Int] = [:]
        for g in module.globals { ourCount[g.symbol, default: 0] += 1 }

        func defined(_ name: String) -> TestELF.Symbol? {
            guard let list = bySymbol[name], list.count == 1 else { return nil }
            let s = elf.symbols[list[0]]
            return s.shndx == TestELF.SHN_UNDEF || s.shndx >= 0xFF00 ? nil : s
        }

        func clangPlace(_ r: TestELF.Rela) -> Place {
            let s = elf.symbols[r.symbol]
            if s.shndx == TestELF.SHN_UNDEF { return .symbol(s.name, r.addend) }
            return .location(Int(s.shndx), Int64(s.value) + r.addend)
        }

        func bytes(section: Int, at offset: Int, count: Int) -> [UInt8]? {
            guard section < elf.sections.count else { return nil }
            let sec = elf.sections[section]
            if sec.type == TestELF.SHT_NOBITS { return offset + count <= Int(sec.size) ? [UInt8](repeating: 0, count: count) : nil }
            guard offset >= 0, offset + count <= sec.data.count else { return nil }
            return Array(sec.data[offset..<offset + count])
        }

        var issues: [String] = []
        var compared = 0
        for g in module.globals where ourCount[g.symbol] == 1 && g.symbol != ".compoundliteral" {
            guard let sym = defined(g.symbol) else {
                if g.isExternal { issues.append("\(g.symbol): not defined in clang's object") }
                continue // clang does not emit unused internal objects
            }
            guard let image = g.image else {
                issues.append("\(g.symbol): no image (\(g.unsupportedReason))")
                continue
            }
            compared += 1
            let section = Int(sym.shndx)
            // LLVM gives an internal object of size 0 one byte, so that distinct objects have distinct addresses;
            // that is the object writer's concern (M3-plan phase 4), not the image's
            if image.bytes.isEmpty && !g.isExternal && sym.size == 1 { continue }
            guard Int(sym.size) == image.bytes.count else {
                issues.append("\(g.symbol): size \(image.bytes.count), clang \(sym.size)")
                continue
            }
            if g.alignment > 0, section < elf.sections.count, sym.value % UInt64(g.alignment) != 0 || elf.sections[section].align < UInt64(g.alignment) {
                // clang aligns the section to the object's alignment at least
                issues.append("\(g.symbol): alignment \(g.alignment), clang's section is aligned to \(elf.sections[section].align)")
            }
            guard let theirs = bytes(section: section, at: Int(sym.value), count: image.bytes.count) else {
                issues.append("\(g.symbol): clang's bytes out of range")
                continue
            }
            if theirs != image.bytes {
                let at = zip(theirs, image.bytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? 0
                let lo = max(0, at - 4), hi = min(theirs.count, at + 12)
                func hex(_ b: ArraySlice<UInt8>) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
                issues.append("\(g.symbol): bytes differ at +\(at): ours [\(hex(image.bytes[lo..<hi]))], clang [\(hex(theirs[lo..<hi]))]")
                continue
            }
            // Relocations, by offset in the object
            var theirRelocs: [Int: TestELF.Rela] = [:]
            for r in elf.relas where r.targetSection == section && r.offset >= sym.value && r.offset < sym.value + sym.size {
                theirRelocs[Int(r.offset - sym.value)] = r
            }
            if theirRelocs.count != image.relocations.count {
                issues.append("\(g.symbol): \(image.relocations.count) relocations, clang \(theirRelocs.count)")
                continue
            }
            for ours in image.relocations {
                guard let theirs = theirRelocs[ours.offset] else {
                    issues.append("\(g.symbol): relocation at +\(ours.offset) not in clang's object")
                    continue
                }
                let place = clangPlace(theirs)
                let problem: String?
                switch ours.target {
                case .decl(let d):
                    let name = module.symbolName(of: d)
                    if name == ".compoundliteral" {
                        // An unnamed object: compare what the address points at
                        let target = module.globals.first { $0.declId == d }?.image
                        if case .location(let s, let o) = place, let target, bytes(section: s, at: Int(o) - Int(ours.addend), count: target.bytes.count) == target.bytes {
                            problem = nil
                        } else {
                            problem = "compound literal+\(ours.addend), clang \(place)"
                        }
                    } else if let s = defined(name) {
                        let want = Place.location(Int(s.shndx), Int64(s.value) + ours.addend)
                        problem = want == place ? nil : "\(name)+\(ours.addend) (\(want)), clang \(place)"
                    } else {
                        let want = Place.symbol(name, ours.addend)
                        problem = want == place ? nil : "\(want), clang \(place)"
                    }
                case .string(let index):
                    let str = module.staticStrings[index].bytes
                    if case .location(let s, let o) = place, bytes(section: s, at: Int(o) - Int(ours.addend), count: str.count) == str {
                        problem = nil
                    } else {
                        problem = "string \"\(String(decoding: str, as: UTF8.self))\"+\(ours.addend), clang \(place)"
                    }
                case .label:
                    if case .location(let s, _) = place, s < elf.sections.count, elf.sections[s].flags & TestELF.SHF_EXECINSTR != 0 {
                        problem = nil
                    } else {
                        problem = "label, clang \(place)"
                    }
                }
                if let problem { issues.append("\(g.symbol): relocation at +\(ours.offset): \(problem)") }
            }
        }
        return (issues, compared)
    }
}

// MARK: - Tests

struct ProbeCase: CustomTestStringConvertible, Sendable {
    let seed: UInt64
    let target: ProbeTarget
    var testDescription: String { "\(target.arch) seed \(seed)" }

    static func cases(count: Int, base: UInt64) -> [ProbeCase] {
        ProbeTarget.all.flatMap { t in (0..<UInt64(count)).map { ProbeCase(seed: base + $0, target: t) } }
    }
}

@Suite("M3 — data layout and static initializer images against clang")
struct M3ClangProbeTests {
    static let directory: String = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftstack-m3-probes").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var hasClang: Bool { ExternalTool.referenceClang != nil }

    static func write(_ source: String, name: String) throws -> String {
        let path = "\(directory)/\(name).c"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Our module for a probe file, failing the test with the front end's error if it is rejected.
    static func module(_ path: String, _ target: ProbeTarget) throws -> SemModule? {
        let outcome = try CFrontendCheck.run(path: path, target: target.cTarget)
        #expect(outcome.accepted, "\(path): \(outcome.firstError)")
        return outcome.module
    }

    @Test("sizeof, _Alignof and offsetof", .enabled(if: hasClang), arguments: ProbeCase.cases(count: 100, base: 0x4D33_0000))
    func layout(_ c: ProbeCase) throws {
        var gen = CProbeGenerator(seed: c.seed, target: c.target)
        let (source, labels) = gen.layoutFile()
        let path = try Self.write(source, name: "layout-\(c.target.arch)-\(c.seed)")

        let r = try ExternalTool.run(ExternalTool.referenceClang!, c.target.clangArgs + ["-S", "-emit-llvm", "-o", "-", path])
        try #require(r.status == 0, "clang rejects \(path): \(r.stderr.prefix(400))")
        guard let line = r.stdout.split(separator: "\n").first(where: { $0.hasPrefix("@probes = ") }),
              let open = line.range(of: "] [") else {
            Issue.record("\(path): no probes array in clang's IR")
            return
        }
        let theirs = line[open.upperBound...].split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces).dropFirst(4).prefix { $0 != "]" }) }
        try #require(theirs.count == labels.count, "\(path): clang gave \(theirs.count) values for \(labels.count) probes")

        guard let module = try Self.module(path, c.target) else { return }
        guard let image = module.globals.first(where: { $0.symbol == "probes" })?.image else {
            Issue.record("\(path): no image for probes")
            return
        }
        var mismatches: [String] = []
        for (i, label) in labels.enumerated() {
            let ours = (0..<8).reduce(Int64(0)) { $0 | Int64(image.bytes[i * 8 + $1]) << (8 * $1) }
            if ours != theirs[i] { mismatches.append("\(label): \(ours), clang \(theirs[i])") }
        }
        #expect(mismatches.isEmpty, "\(path):\n\(mismatches.prefix(10).joined(separator: "\n"))")
        if mismatches.isEmpty { try? FileManager.default.removeItem(atPath: path) }
    }

    @Test("Generated initializers", .enabled(if: hasClang), arguments: ProbeCase.cases(count: 300, base: 0x4D33_1000))
    func images(_ c: ProbeCase) throws {
        var gen = CProbeGenerator(seed: c.seed, target: c.target)
        let path = try Self.write(gen.imageFile(), name: "image-\(c.target.arch)-\(c.seed)")
        let elf = try ClangImageCheck.clangObject(path: path, args: c.target.clangArgs)
        guard let module = try Self.module(path, c.target) else { return }
        let (issues, compared) = ClangImageCheck.compare(module, with: elf)
        #expect(issues.isEmpty, "\(path):\n\(issues.prefix(10).joined(separator: "\n"))")
        #expect(compared > 0, "\(path): no globals compared")
        if issues.isEmpty { try? FileManager.default.removeItem(atPath: path) }
    }

    /// The x86-64 corpus files: c-testsuite, SQLite and Lua (hosted, with the host's headers) and VectraOS's x86-64
    /// sources (freestanding, with its build flags).
    static var corpus: [CCorpusFile] {
        CCorpora.cTestsuite + CCorpora.sqlite + CCorpora.lua + CCorpora.vectraOS.filter { $0.target?.arch == "x86_64" }
    }

    /// Globals whose images differ from clang's for a known reason, by file name and symbol. The test fails on any
    /// other difference, and when a listed one disappears.
    static let knownDivergences: [String: String] = [
        "sqlite3.c:sqlite3azCompileOpt": "holds `__clang_version__`: Swift-Stack's compatibility profile (D7) predefines 19.1.0, clang 22 its own",
    ]

    @Test("Corpus global images (x86-64)", .enabled(if: hasClang), arguments: corpus)
    func corpusImages(_ file: CCorpusFile) throws {
        let outcome = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
        guard outcome.accepted, let module = outcome.module, !module.globals.isEmpty else { return }
        var args = ["-std=c23", "-w", "-O0"] + file.includePaths.map { "-I\($0)" }
        if let t = file.target { args += ["--target=\(t.triple)", "-ffreestanding"] + t.flags }
        let elf = try ClangImageCheck.clangObject(path: file.path, args: args)
        let fileName = URL(fileURLWithPath: file.path).lastPathComponent
        var (issues, _) = ClangImageCheck.compare(module, with: elf)
        for key in Self.knownDivergences.keys where key.hasPrefix(fileName + ":") {
            let symbol = key.dropFirst(fileName.count + 1)
            let before = issues.count
            issues.removeAll { $0.hasPrefix(symbol + ":") }
            #expect(issues.count < before, "\(key) no longer differs: remove it from knownDivergences")
        }
        #expect(issues.isEmpty, "\(file.testDescription):\n\(issues.prefix(10).joined(separator: "\n"))")
    }
}
