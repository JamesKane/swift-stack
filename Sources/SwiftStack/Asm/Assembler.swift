// Sources/SwiftStack/Asm/Assembler.swift
//
// Native Multi-Target Assembler (05-assembler.md).
// Supports x86-64 (AT&T syntax), AArch64 (GNU A64 syntax), and RV64 (RVA23),
// with C23 `.S` preprocessing, GNU `as` directives, macros, numeric local labels,
// fixpoint branch relaxation, CFI -> `.eh_frame` synthesis, and `RelocatableObject` output.
//
// Layering rule: Asm/ uses Source/, Lex/, Encode/, and Object/. It MUST NOT reference Codegen/.

import Foundation

// MARK: - 1. Architecture Dispatch (`AssemblerArch`, 05-assembler.md §4.3)

/// Closed architecture enum for the assembler (05-assembler.md §4.3).
/// Selects per-architecture instruction parsing, relaxation, and relocation rules
/// via exhaustive `switch` statements with zero existential/protocol overhead.
@frozen
public enum AssemblerArch: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case x86_64  = 0
    case aarch64 = 1
    case riscv64 = 2

    public init(objectArch: ObjectArch) {
        switch objectArch {
        case .x86_64:  self = .x86_64
        case .aarch64: self = .aarch64
        case .riscv64: self = .riscv64
        }
    }

    public var objectArch: ObjectArch {
        switch self {
        case .x86_64:  return .x86_64
        case .aarch64: return .aarch64
        case .riscv64: return .riscv64
        }
    }

    public var description: String {
        switch self {
        case .x86_64:  return "x86_64"
        case .aarch64: return "aarch64"
        case .riscv64: return "riscv64"
        }
    }

    /// Default alignment log2 for `.text` sections on this architecture.
    public var defaultTextAlignLog2: UInt8 {
        switch self {
        case .x86_64:  return 2 // 4-byte alignment
        case .aarch64: return 2 // 4-byte alignment
        case .riscv64: return 1 // 2-byte alignment (RVC)
        }
    }

    /// Default alignment log2 for `.text.*` subsection when not explicitly aligned.
    public var defaultSubsectionTextAlignLog2: UInt8 {
        switch self {
        case .x86_64:  return 0 // 1-byte alignment
        case .aarch64: return 2 // 4-byte alignment
        case .riscv64: return 0 // 1-byte (or 2-byte) alignment
        }
    }

    /// Whether `.align N` interprets `N` as byte count (`true` on x86) or power-of-two (`false` on ARM/RISC-V).
    public var alignDirectiveIsBytes: Bool {
        switch self {
        case .x86_64:               return true
        case .aarch64, .riscv64:    return false
        }
    }
}

// MARK: - 2. Relocation Modifiers & Expression Evaluator (`05-assembler.md` §4.4)

/// Symbolic relocation modifier attached to a symbol in an assembler expression.
@frozen
public enum AsmRelocModifier: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case none = 0

    // x86-64 suffix modifiers (`sym@PLT`, `sym@GOTPCREL`, `sym@TPOFF`, `sym@GOTTPOFF`)
    case x86PLT = 1
    case x86GOTPCREL = 2
    case x86TPOFF = 3
    case x86GOTTPOFF = 4

    // AArch64 prefix modifiers (`:lo12:sym`, `:got:sym`, `:got_lo12:sym`, `:tprel_hi12:sym`, `:tprel_lo12_nc:sym`, `:pg_hi21:sym`)
    case a64Lo12 = 10
    case a64Got = 11
    case a64GotLo12 = 12
    case a64TprelHi12 = 13
    case a64TprelLo12Nc = 14
    case a64PgHi21 = 15

    // RV64 prefix modifiers (`%pcrel_hi(sym)`, `%pcrel_lo(sym)`, `%hi(sym)`, `%lo(sym)`, `%got_pcrel_hi(sym)`, `%tprel_hi(sym)`, `%tprel_lo(sym)`, `%tprel_add(sym)`)
    case rvPcrelHi = 20
    case rvPcrelLo = 21
    case rvHi = 22
    case rvLo = 23
    case rvGotPcrelHi = 24
    case rvTprelHi = 25
    case rvTprelLo = 26
    case rvTprelAdd = 27
}

/// Result of evaluating an assembler expression.
public enum AsmExprValue: Sendable, Equatable {
    /// Pure integer constant (`42`, `0x1000`, `(1 << 60)`).
    case constant(Int64)
    /// Single symbol + constant addend + optional relocation modifier (`foo + 4`, `:lo12:bar`, `%pcrel_hi(baz)`).
    case symbolOffset(symbol: String, addend: Int64, modifier: AsmRelocModifier)
    /// Difference between two symbols + addend (`end_label - start_label + 4`).
    case symbolDiff(plusSymbol: String, minusSymbol: String, addend: Int64)

    public var constantValue: Int64? {
        if case .constant(let v) = self { return v }
        return nil
    }
}

/// Evaluates assembler integer and symbolic expressions with the GNU-style operator precedence (not C's) that
/// LLVM MC uses for ELF targets.
public enum AsmExprEvaluator {

    /// Evaluates an expression string using `constants` (from `.equ`/`.set`/`=`) and optional section symbol positions.
    public static func evaluate(
        _ rawExpr: String,
        constants: [String: Int64] = [:],
        currentSectionSymbols: [String: Int64] = [:],
        dotOffset: Int64? = nil
    ) -> AsmExprValue? {
        let trimmed = rawExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Check for top-level AArch64 `:mod:expr` prefix
        if trimmed.hasPrefix(":") {
            if let (mod, rest) = parseA64ModifierPrefix(trimmed) {
                guard let inner = evaluate(rest, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else {
                    return nil
                }
                switch inner {
                case .symbolOffset(let sym, let addend, _):
                    return .symbolOffset(symbol: sym, addend: addend, modifier: mod)
                case .constant(let v):
                    return .constant(v)
                case .symbolDiff:
                    return nil
                }
            }
        }

        // Check for top-level RV64 `%mod(expr)` prefix
        if trimmed.hasPrefix("%") {
            if let (mod, innerStr, trailingStr) = parseRVModifierPrefix(trimmed) {
                guard let inner = evaluate(innerStr, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else {
                    return nil
                }
                var extraAddend: Int64 = 0
                if !trailingStr.isEmpty {
                    guard let trailVal = evaluate("0" + trailingStr, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)?.constantValue else {
                        return nil
                    }
                    extraAddend = trailVal
                }
                switch inner {
                case .symbolOffset(let sym, let addend, _):
                    return .symbolOffset(symbol: sym, addend: addend &+ extraAddend, modifier: mod)
                case .constant(let v):
                    return .constant(v &+ extraAddend)
                case .symbolDiff:
                    return nil
                }
            }
        }

        let tokens = tokenizeExpr(trimmed)
        var pos = 0
        let ctx = EvalContext(constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)
        guard let result = parseBinary(tokens, &pos, minRank: 0, ctx),
              pos == tokens.count else {
            return nil
        }
        return result
    }

    private static func parseA64ModifierPrefix(_ str: String) -> (AsmRelocModifier, String)? {
        let prefixes: [(String, AsmRelocModifier)] = [
            (":got_lo12:", .a64GotLo12),
            (":got:", .a64Got),
            (":lo12:", .a64Lo12),
            (":tprel_hi12:", .a64TprelHi12),
            (":tprel_lo12_nc:", .a64TprelLo12Nc),
            (":tprel_lo12:", .a64TprelLo12Nc),
            (":pg_hi21:", .a64PgHi21),
        ]
        let lower = str.lowercased()
        for (p, mod) in prefixes {
            if lower.hasPrefix(p) {
                let rest = String(str.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                return (mod, rest)
            }
        }
        return nil
    }

    private static func parseRVModifierPrefix(_ str: String) -> (AsmRelocModifier, String, String)? {
        let prefixes: [(String, AsmRelocModifier)] = [
            ("%got_pcrel_hi", .rvGotPcrelHi),
            ("%pcrel_hi", .rvPcrelHi),
            ("%pcrel_lo", .rvPcrelLo),
            ("%tprel_hi", .rvTprelHi),
            ("%tprel_lo", .rvTprelLo),
            ("%tprel_add", .rvTprelAdd),
            ("%hi", .rvHi),
            ("%lo", .rvLo),
        ]
        let lower = str.lowercased()
        for (p, mod) in prefixes {
            if lower.hasPrefix(p) {
                let afterMod = String(str.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                guard afterMod.first == "(" else { continue }
                // Find matching ')'
                var depth = 0
                var matchIdx: String.Index? = nil
                for idx in afterMod.indices {
                    let c = afterMod[idx]
                    if c == "(" { depth += 1 }
                    else if c == ")" {
                        depth -= 1
                        if depth == 0 {
                            matchIdx = idx
                            break
                        }
                    }
                }
                guard let endParen = matchIdx else { return nil }
                let inside = String(afterMod[afterMod.index(after: afterMod.startIndex)..<endParen]).trimmingCharacters(in: .whitespaces)
                let trailing = String(afterMod[afterMod.index(after: endParen)...]).trimmingCharacters(in: .whitespaces)
                return (mod, inside, trailing)
            }
        }
        return nil
    }

    private enum ExprToken: Equatable {
        case int(Int64)
        case symbol(String, AsmRelocModifier)
        case op(String)
        case lparen
        case rparen
    }

    private static func tokenizeExpr(_ s: String) -> [ExprToken] {
        var out: [ExprToken] = []
        let chars = Array(s.utf8)
        let n = chars.count
        var i = 0

        while i < n {
            let c = chars[i]
            if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\r") {
                i += 1
                continue
            }
            if c == UInt8(ascii: "(") {
                out.append(.lparen)
                i += 1
                continue
            }
            if c == UInt8(ascii: ")") {
                out.append(.rparen)
                i += 1
                continue
            }
            // Character literal 'x' or '\n'
            if c == UInt8(ascii: "'") {
                i += 1
                if i < n {
                    let val: UInt8
                    if chars[i] == UInt8(ascii: "\\") && i + 1 < n {
                        i += 1
                        switch chars[i] {
                        case UInt8(ascii: "n"): val = 10
                        case UInt8(ascii: "r"): val = 13
                        case UInt8(ascii: "t"): val = 9
                        case UInt8(ascii: "0"): val = 0
                        default: val = chars[i]
                        }
                    } else {
                        val = chars[i]
                    }
                    i += 1
                    if i < n && chars[i] == UInt8(ascii: "'") {
                        i += 1
                    }
                    out.append(.int(Int64(val)))
                    continue
                }
            }
            // Two-character operators
            if i + 1 < n {
                let c2 = chars[i + 1]
                if (c == UInt8(ascii: "<") && c2 == UInt8(ascii: "<")) ||
                   (c == UInt8(ascii: ">") && c2 == UInt8(ascii: ">")) ||
                   (c == UInt8(ascii: "=") && c2 == UInt8(ascii: "=")) ||
                   (c == UInt8(ascii: "!") && c2 == UInt8(ascii: "=")) ||
                   (c == UInt8(ascii: "<") && c2 == UInt8(ascii: "=")) ||
                   (c == UInt8(ascii: "<") && c2 == UInt8(ascii: ">")) ||
                   (c == UInt8(ascii: ">") && c2 == UInt8(ascii: "=")) ||
                   (c == UInt8(ascii: "&") && c2 == UInt8(ascii: "&")) ||
                   (c == UInt8(ascii: "|") && c2 == UInt8(ascii: "|")) {
                    let opStr = String(decoding: [c, c2], as: UTF8.self)
                    out.append(.op(opStr))
                    i += 2
                    continue
                }
            }
            // Single-character operators
            if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") || c == UInt8(ascii: "*") ||
               c == UInt8(ascii: "/") || c == UInt8(ascii: "%") || c == UInt8(ascii: "&") ||
               c == UInt8(ascii: "|") || c == UInt8(ascii: "^") || c == UInt8(ascii: "~") ||
               c == UInt8(ascii: "!") || c == UInt8(ascii: "<") || c == UInt8(ascii: ">") {
                out.append(.op(String(UnicodeScalar(c))))
                i += 1
                continue
            }
            // Number literal
            if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                let start = i
                while i < n && (isAlnum(chars[i]) || chars[i] == UInt8(ascii: "_")) {
                    i += 1
                }
                let rawNum = String(decoding: chars[start..<i], as: UTF8.self).replacingOccurrences(of: "_", with: "")
                if let val = parseIntegerLiteral(rawNum) {
                    out.append(.int(val))
                } else {
                    out.append(.symbol(rawNum, .none))
                }
                continue
            }
            // Identifier / symbol / `.`
            if isIdentStart(c) {
                let start = i
                while i < n && (isIdentChar(chars[i]) || chars[i] == UInt8(ascii: "@")) {
                    i += 1
                }
                let rawSym = String(decoding: chars[start..<i], as: UTF8.self)
                let (cleanSym, mod) = splitX86SuffixModifier(rawSym)
                out.append(.symbol(cleanSym, mod))
                continue
            }

            // Fallback unknown char -> abort tokenization by appending an invalid op
            out.append(.op("?"))
            i += 1
        }
        return out
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) ||
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
    }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) ||
        c == UInt8(ascii: "_") || c == UInt8(ascii: ".") || c == UInt8(ascii: "$")
    }

    private static func isIdentChar(_ c: UInt8) -> Bool {
        isIdentStart(c) || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
    }

    private static func splitX86SuffixModifier(_ sym: String) -> (String, AsmRelocModifier) {
        guard let atIdx = sym.firstIndex(of: "@") else { return (sym, .none) }
        let base = String(sym[..<atIdx])
        let suffix = String(sym[ sym.index(after: atIdx)... ]).uppercased()
        switch suffix {
        case "PLT":      return (base, .x86PLT)
        case "GOTPCREL": return (base, .x86GOTPCREL)
        case "TPOFF":    return (base, .x86TPOFF)
        case "GOTTPOFF": return (base, .x86GOTTPOFF)
        default:         return (sym, .none)
        }
    }

    public static func parseIntegerLiteral(_ str: String) -> Int64? {
        var s = str
        while let last = s.last, last == "u" || last == "U" || last == "l" || last == "L" {
            s.removeLast()
        }
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let hex = String(s.dropFirst(2))
            guard let u = UInt64(hex, radix: 16) else { return nil }
            return Int64(bitPattern: u)
        }
        if s.hasPrefix("0b") || s.hasPrefix("0B") {
            let bin = String(s.dropFirst(2))
            guard let u = UInt64(bin, radix: 2) else { return nil }
            return Int64(bitPattern: u)
        }
        if s.count > 1 && s.first == "0" && s.allSatisfy({ $0 >= "0" && $0 <= "7" }) {
            guard let u = UInt64(s, radix: 8) else { return nil }
            return Int64(bitPattern: u)
        }
        if let u = UInt64(s, radix: 10) {
            return Int64(bitPattern: u)
        }
        return Int64(s, radix: 10)
    }

    // Precedence-climbing parser with LLVM MC's ELF operator ranks (`AsmParser::getGNUBinOpPrecedence`, the same as
    // binutils `expr.c`), which differ from C:
    //   5: `*` `/` `%` `<<` `>>`     4: `|` `&` `^` `!` (or-not)     3: `+` `-`
    //   2: `==` `!=` `<>` `<` `>` `<=` `>=` (true is -1)     1: `&&`     0: `||` (1 or 0)
    // All binary operators are left-associative; comparisons are signed; `>>` is a logical shift.

    private struct EvalContext {
        let constants: [String: Int64]
        let currentSectionSymbols: [String: Int64]
        let dotOffset: Int64?
    }

    private static func binaryRank(_ op: String) -> Int? {
        switch op {
        case "*", "/", "%", "<<", ">>":                   return 5
        case "|", "&", "^", "!":                          return 4
        case "+", "-":                                    return 3
        case "==", "!=", "<>", "<", ">", "<=", ">=":      return 2
        case "&&":                                        return 1
        case "||":                                        return 0
        default:                                          return nil
        }
    }

    private static func parseBinary(_ tokens: [ExprToken], _ pos: inout Int, minRank: Int, _ ctx: EvalContext) -> AsmExprValue? {
        guard var lhs = parseUnary(tokens, &pos, ctx) else { return nil }
        while pos < tokens.count, case .op(let op) = tokens[pos], let rank = binaryRank(op), rank >= minRank {
            pos += 1
            guard let rhs = parseBinary(tokens, &pos, minRank: rank + 1, ctx),
                  let combined = applyBinary(op, lhs, rhs, ctx) else { return nil }
            lhs = combined
        }
        return lhs
    }

    /// Applies a binary operator. Only `+` and `-` accept symbolic operands; everything else needs constants.
    private static func applyBinary(_ op: String, _ lhs: AsmExprValue, _ rhs: AsmExprValue, _ ctx: EvalContext) -> AsmExprValue? {
        if op == "+" {
            switch (lhs, rhs) {
            case (.constant(let a), .constant(let b)):
                return .constant(a &+ b)
            case (.symbolOffset(let s, let a, let m), .constant(let b)), (.constant(let b), .symbolOffset(let s, let a, let m)):
                return .symbolOffset(symbol: s, addend: a &+ b, modifier: m)
            case (.symbolDiff(let p, let m, let a), .constant(let b)), (.constant(let b), .symbolDiff(let p, let m, let a)):
                return .symbolDiff(plusSymbol: p, minusSymbol: m, addend: a &+ b)
            default:
                return nil
            }
        }
        if op == "-" {
            switch (lhs, rhs) {
            case (.constant(let a), .constant(let b)):
                return .constant(a &- b)
            case (.symbolOffset(let s, let a, let m), .constant(let b)):
                return .symbolOffset(symbol: s, addend: a &- b, modifier: m)
            case (.symbolDiff(let p, let m, let a), .constant(let b)):
                return .symbolDiff(plusSymbol: p, minusSymbol: m, addend: a &- b)
            case (.symbolOffset(let s1, let a1, .none), .symbolOffset(let s2, let a2, .none)):
                if s1 == s2 {
                    return .constant(a1 &- a2)
                } else if let v1 = ctx.currentSectionSymbols[s1], let v2 = ctx.currentSectionSymbols[s2] {
                    return .constant((v1 &- v2) &+ (a1 &- a2))
                }
                return .symbolDiff(plusSymbol: s1, minusSymbol: s2, addend: a1 &- a2)
            default:
                return nil
            }
        }
        guard let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
        let ul = UInt64(bitPattern: l)
        switch op {
        case "*":  return .constant(l &* r)
        case "/":
            guard r != 0 else { return nil }
            return .constant(l.dividedReportingOverflow(by: r).partialValue)
        case "%":
            guard r != 0 else { return nil }
            return .constant(l.remainderReportingOverflow(dividingBy: r).partialValue)
        case "<<": return .constant((r < 0 || r >= 64) ? 0 : Int64(bitPattern: ul << UInt64(r)))
        case ">>": return .constant((r < 0 || r >= 64) ? 0 : Int64(bitPattern: ul >> UInt64(r)))
        case "|":  return .constant(l | r)
        case "&":  return .constant(l & r)
        case "^":  return .constant(l ^ r)
        case "!":  return .constant(l | ~r)
        case "==": return .constant(l == r ? -1 : 0)
        case "!=", "<>": return .constant(l != r ? -1 : 0)
        case "<":  return .constant(l < r ? -1 : 0)
        case ">":  return .constant(l > r ? -1 : 0)
        case "<=": return .constant(l <= r ? -1 : 0)
        case ">=": return .constant(l >= r ? -1 : 0)
        case "&&": return .constant((l != 0 && r != 0) ? 1 : 0)
        case "||": return .constant((l != 0 || r != 0) ? 1 : 0)
        default:   return nil
        }
    }

    private static func parseUnary(_ tokens: [ExprToken], _ pos: inout Int, _ ctx: EvalContext) -> AsmExprValue? {
        guard pos < tokens.count else { return nil }
        if case .op(let op) = tokens[pos], op == "+" || op == "-" || op == "~" || op == "!" {
            pos += 1
            guard let operand = parseUnary(tokens, &pos, ctx) else { return nil }
            if op == "+" { return operand }
            guard let v = operand.constantValue else { return nil }
            switch op {
            case "-": return .constant(0 &- v)
            case "~": return .constant(~v)
            default:  return .constant(v == 0 ? 1 : 0)
            }
        }
        return parsePrimary(tokens, &pos, ctx)
    }

    private static func parsePrimary(_ tokens: [ExprToken], _ pos: inout Int, _ ctx: EvalContext) -> AsmExprValue? {
        guard pos < tokens.count else { return nil }
        switch tokens[pos] {
        case .int(let v):
            pos += 1
            return .constant(v)
        case .symbol(let sym, let mod):
            pos += 1
            if sym == "." {
                if let dot = ctx.dotOffset {
                    return .constant(dot)
                }
                return .symbolOffset(symbol: ".", addend: 0, modifier: .none)
            }
            if mod == .none, let c = ctx.constants[sym] {
                return .constant(c)
            }
            return .symbolOffset(symbol: sym, addend: 0, modifier: mod)
        case .lparen:
            pos += 1
            guard let inner = parseBinary(tokens, &pos, minRank: 0, ctx),
                  pos < tokens.count, tokens[pos] == .rparen else { return nil }
            pos += 1
            return inner
        default:
            return nil
        }
    }
}

// MARK: - 3. Statement Lexing, Macros, Conditionals, and Local Labels (`05-assembler.md` §4.4)

/// Where a statement came from, for diagnostics: its `file:line:col` location plus one note per enclosing
/// macro expansion (innermost first), so an error points at both the macro body line and the macro use.
public struct AsmLoc: Sendable {
    public var location: SourceLocation
    public var notes: [DiagNote]

    public init(_ location: SourceLocation = .invalid, notes: [DiagNote] = []) {
        self.location = location
        self.notes = notes
    }

    public static let unknown = AsmLoc()
}

extension DiagnosticBag {
    /// Reports an assembler diagnostic at a statement location, attaching its macro-expansion notes.
    mutating func report(_ id: DiagId, at loc: AsmLoc, args: [String] = []) {
        report(id, at: GlobalLocation(unitId: UnitId(0), location: loc.location), args: args, notes: loc.notes)
    }
}

/// A parsed line/statement of assembly after comment stripping and macro expansion.
public struct AsmStatement: Sendable {
    public let text: String
    public let loc: AsmLoc

    public init(text: String, loc: AsmLoc) {
        self.text = text
        self.loc = loc
    }
}

/// Maps assembler input back to `SourceManager` files so statements carry real `file:line:col` locations
/// through `.include`, the `# <line> "<file>"` markers emitted by `.S` preprocessing, and in-memory buffers.
final class AsmSourceMap {
    let sourceManager: SourceManager
    private var fileIdsByPath: [String: FileId] = [:]

    init(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
    }

    func register(_ fileId: FileId) {
        fileIdsByPath[sourceManager[fileId].path] = fileId
    }

    /// The file named by a line marker or `.include`, loaded on first use; nil if it cannot be read.
    func fileId(forPath path: String) -> FileId? {
        if let id = fileIdsByPath[path] { return id }
        guard let id = try? sourceManager.loadFile(path: path) else { return nil }
        fileIdsByPath[path] = id
        return id
    }

    func bytes(of fileId: FileId) -> [UInt8] {
        let file = sourceManager[fileId]
        guard let base = file.buffer.baseAddress else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: file.length))
    }

    /// Location of 1-based `line`, 0-based byte `column` in `fileId` (clamped to the line), or `.invalid`.
    func location(fileId: FileId, line: Int, column: Int) -> SourceLocation {
        let file = sourceManager[fileId]
        guard file.id.isValid, file.length > 0 else { return .invalid }
        let starts = file.lineTable().lineStarts
        guard line >= 1 && line <= starts.count else { return .invalid }
        let lineStart = Int(starts[line - 1])
        let lineEnd = line < starts.count ? Int(starts[line]) - 1 : file.length
        let offset = min(lineStart + max(0, column), max(lineStart, lineEnd), file.length - 1)
        return SourceLocation(file.baseLocation.rawValue + UInt32(offset))
    }

    /// Directory of the file containing `location`, for resolving `.include`/`.incbin` relative paths.
    func directory(containing location: SourceLocation) -> String? {
        guard location.isValid, let (file, _) = sourceManager.file(containing: location) else { return nil }
        let dir = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
        return dir.isEmpty ? nil : dir
    }

    /// Resolves an `.include`/`.incbin` operand: relative to the including file, then the working directory,
    /// then each `-I` path (GNU `as` and LLVM MC search order).
    func resolve(_ name: String, from location: SourceLocation, includePaths: [String]) -> String? {
        let fm = FileManager.default
        if name.hasPrefix("/") { return fm.fileExists(atPath: name) ? name : nil }
        var candidates: [String] = []
        if let dir = directory(containing: location) { candidates.append("\(dir)/\(name)") }
        candidates.append(name)
        candidates.append(contentsOf: includePaths.map { "\($0)/\(name)" })
        return candidates.first { fm.fileExists(atPath: $0) }
    }
}

/// Macro parameter: `name`, `name=default`, `name:req`, or `name:vararg`.
private struct AsmMacroParam {
    let name: String
    let defaultValue: String
    let required: Bool
    let vararg: Bool
}

/// Macro definition for `.macro name params...` / `.endm`.
private struct AsmMacroDef {
    let name: String
    let params: [AsmMacroParam]
    let body: [AsmStatement]
}

/// Expands comments, multi-statement `;` lines, `.include`, `.macro`/`.endm`, `.rept`/`.irp`/`.irpc`/`.endr`,
/// `.if*`/`.else`/`.endif`, and numeric local labels (`1:`, `1b`, `1f`).
public enum AsmMacroEngine {

    /// Mutable state threaded through statement splitting and expansion.
    fileprivate struct Context {
        let arch: AssemblerArch
        let sourceMap: AsmSourceMap
        let includePaths: [String]
        var macros: [String: AsmMacroDef] = [:]
        var constants: [String: Int64] = [:]
        var definedSymbols: Set<String> = []
        var macroCounter = 0
        /// Current macro, `.rept` and `.irp` expansion nesting (bounded like LLVM MC, so runaway recursion is
        /// diagnosed).
        var macroDepth = 0
        /// Set by `.exitm`; unwinds the enclosing `.if`/`.rept` blocks up to the macro boundary.
        var exitRequested = false
    }

    private static let maxIncludeDepth = 64
    private static let maxMacroDepth = 20    // LLVM MC `-asm-macro-max-nesting-depth` default

    /// Splits `text` into statements (`physicalFile` is the `SourceManager` buffer holding `text`, or nil for
    /// preprocessor output whose locations come from line markers), expands includes, macros, repetitions and
    /// conditionals, and rewrites numeric local labels (`1:`, `1b`, `1f`) into unique synthetic labels.
    static func expandStatements(
        text: String,
        physicalFile: FileId?,
        arch: AssemblerArch,
        sourceMap: AsmSourceMap,
        includePaths: [String],
        initialConstants: [String: Int64] = [:],
        diagnostics: inout DiagnosticBag
    ) -> [AsmStatement] {
        var ctx = Context(arch: arch, sourceMap: sourceMap, includePaths: includePaths)
        ctx.constants = initialConstants
        ctx.definedSymbols = Set(initialConstants.keys)

        var cleaned: [AsmStatement] = []
        splitLines(Array(text.utf8), physicalFile: physicalFile, depth: 0, ctx: ctx, into: &cleaned, diagnostics: &diagnostics)
        let expanded = expandBlock(cleaned, ctx: &ctx, diagnostics: &diagnostics)
        return rewriteNumericLocalLabels(expanded)
    }

    // MARK: Line splitting, line markers and `.include`

    /// Splits source bytes into comment-free statements, honouring `# <line> "<file>"` / `#line` markers and
    /// inlining `.include` files (each statement's location points into the file it was read from).
    private static func splitLines(
        _ bytes: [UInt8],
        physicalFile: FileId?,
        depth: Int,
        ctx: Context,
        into out: inout [AsmStatement],
        diagnostics: inout DiagnosticBag
    ) {
        let physicalBase: UInt32? = physicalFile.map { ctx.sourceMap.sourceManager[$0].baseLocation.rawValue }
        var logicalFile: FileId? = nil   // set by a line marker; nil means "use the physical position"
        var logicalLine = 0
        var markerSeen = false
        var inBlockComment = false
        var lineStart = 0
        let n = bytes.count

        while lineStart <= n {
            var lineEnd = lineStart
            while lineEnd < n && bytes[lineEnd] != 0x0A { lineEnd += 1 }
            if lineStart == n && lineEnd == n { break }
            var contentEnd = lineEnd
            if contentEnd > lineStart && bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = bytes[lineStart..<contentEnd]

            if !inBlockComment, let (markLine, markPath) = parseLineMarker(line) {
                if let path = markPath { logicalFile = ctx.sourceMap.fileId(forPath: path) }
                logicalLine = markLine
                markerSeen = true
            } else {
                for (text, column) in stripCommentsAndSplit(line, arch: ctx.arch, inBlockComment: &inBlockComment) {
                    let location: SourceLocation
                    if markerSeen {
                        location = logicalFile.map { ctx.sourceMap.location(fileId: $0, line: logicalLine, column: column) } ?? .invalid
                    } else if let base = physicalBase {
                        location = SourceLocation(base + UInt32(lineStart + column))
                    } else {
                        location = .invalid
                    }
                    let loc = AsmLoc(location)
                    let (first, rest) = splitFirstWord(text)
                    if first.lowercased() == ".include" {
                        includeFile(rest, loc: loc, depth: depth, ctx: ctx, into: &out, diagnostics: &diagnostics)
                    } else {
                        out.append(AsmStatement(text: text, loc: loc))
                    }
                }
                logicalLine += 1
            }
            lineStart = lineEnd + 1
        }
    }

    private static func includeFile(
        _ operand: String,
        loc: AsmLoc,
        depth: Int,
        ctx: Context,
        into out: inout [AsmStatement],
        diagnostics: inout DiagnosticBag
    ) {
        guard let nameBytes = parseAsmStringLiteral(operand) else {
            diagnostics.report(.asmInvalidExpression, at: loc, args: [operand])
            return
        }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard depth < maxIncludeDepth,
              let path = ctx.sourceMap.resolve(name, from: loc.location, includePaths: ctx.includePaths),
              let fileId = ctx.sourceMap.fileId(forPath: path) else {
            diagnostics.report(.asmFileNotFound, at: loc, args: [name])
            return
        }
        splitLines(ctx.sourceMap.bytes(of: fileId), physicalFile: fileId, depth: depth + 1, ctx: ctx, into: &out, diagnostics: &diagnostics)
    }

    /// Recognizes a GNU line marker `# <line> ["<file>" [flags]]` or `#line <line> ["<file>"]` (as emitted by
    /// `cpp`), returning the line number of the *next* line and the optional file name.
    private static func parseLineMarker(_ line: ArraySlice<UInt8>) -> (Int, String?)? {
        var i = line.startIndex
        let end = line.endIndex
        guard i < end, line[i] == UInt8(ascii: "#") else { return nil }
        i += 1
        if end - i >= 4, line[i..<(i + 4)].elementsEqual("line".utf8) { i += 4 }
        while i < end && (line[i] == 0x20 || line[i] == 0x09) { i += 1 }
        let digitsStart = i
        while i < end && line[i] >= 0x30 && line[i] <= 0x39 { i += 1 }
        guard i > digitsStart, i == end || line[i] == 0x20 || line[i] == 0x09,
              let number = Int(String(decoding: line[digitsStart..<i], as: UTF8.self)) else { return nil }
        while i < end && (line[i] == 0x20 || line[i] == 0x09) { i += 1 }
        guard i < end, line[i] == UInt8(ascii: "\"") else { return (number, nil) }
        var path: [UInt8] = []
        i += 1
        while i < end && line[i] != UInt8(ascii: "\"") {
            if line[i] == UInt8(ascii: "\\") && i + 1 < end { i += 1 }
            path.append(line[i])
            i += 1
        }
        return (number, String(decoding: path, as: UTF8.self))
    }

    /// Strips comments and splits a line on `;`, returning each statement with the byte column of its first
    /// non-blank character.
    private static func stripCommentsAndSplit(
        _ line: ArraySlice<UInt8>,
        arch: AssemblerArch,
        inBlockComment: inout Bool
    ) -> [(text: String, column: Int)] {
        var statements: [(text: String, column: Int)] = []
        var current: [UInt8] = []
        var currentColumn = -1
        var inString = false
        let base = line.startIndex
        var i = base
        let n = line.endIndex

        func flush() {
            let text = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { statements.append((text, max(0, currentColumn))) }
            current.removeAll(keepingCapacity: true)
            currentColumn = -1
        }
        func append(_ c: UInt8, at index: Int) {
            if currentColumn < 0 && c != 0x20 && c != 0x09 { currentColumn = index - base }
            current.append(c)
        }

        while i < n {
            let c = line[i]
            if inBlockComment {
                if c == UInt8(ascii: "*") && i + 1 < n && line[i + 1] == UInt8(ascii: "/") {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if inString {
                append(c, at: i)
                if c == UInt8(ascii: "\\") && i + 1 < n {
                    i += 1
                    append(line[i], at: i)
                } else if c == UInt8(ascii: "\"") {
                    inString = false
                }
                i += 1
                continue
            }
            switch c {
            case UInt8(ascii: "\""):
                inString = true
                append(c, at: i)
                i += 1
                continue
            case UInt8(ascii: "'"):
                // Character constant (`'a`, `'a'`, `'\n'`): its character is never a comment or separator.
                append(c, at: i)
                i += 1
                if i < n {
                    if line[i] == UInt8(ascii: "\\") && i + 1 < n { append(line[i], at: i); i += 1 }
                    append(line[i], at: i)
                    i += 1
                    if i < n && line[i] == UInt8(ascii: "'") { append(line[i], at: i); i += 1 }
                }
                continue
            case UInt8(ascii: "/") where i + 1 < n && line[i + 1] == UInt8(ascii: "*"):
                inBlockComment = true
                i += 2
                continue
            case UInt8(ascii: "/") where i + 1 < n && line[i + 1] == UInt8(ascii: "/"):
                i = n
                continue
            case UInt8(ascii: "#"):
                // x86-64 and RISC-V: `#` starts a comment anywhere. AArch64: only at the start of a statement,
                // elsewhere it is the immediate prefix.
                if arch == .x86_64 || arch == .riscv64 || currentColumn < 0 {
                    i = n
                    continue
                }
            case UInt8(ascii: ";"):
                // `;` separates statements on the same line for all three targets (LLVM MC `SeparatorString`)
                // (e.g. `1: wfe; b 1b`).
                flush()
                i += 1
                continue
            default:
                break
            }
            append(c, at: i)
            i += 1
        }
        flush()
        return statements
    }

    // MARK: Block expansion

    private static func blockEnd(_ stmts: [AsmStatement], from start: Int, opens: Set<String>, close: String) -> Int? {
        var depth = 1
        var i = start
        while i < stmts.count {
            let word = splitFirstWord(stmts[i].text).0.lowercased()
            if opens.contains(word) {
                depth += 1
            } else if word == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static let repeatOpeners: Set<String> = [".rept", ".irp", ".irpc"]

    private static func expandBlock(_ stmts: [AsmStatement], ctx: inout Context, diagnostics: inout DiagnosticBag) -> [AsmStatement] {
        var out: [AsmStatement] = []
        var i = 0
        while i < stmts.count {
            let rawStmt = stmts[i]
            var lineAfterLabels = rawStmt.text
            while let (label, remainder) = extractLeadingLabel(lineAfterLabels) {
                if !label.allSatisfy({ $0.isNumber }) {
                    ctx.definedSymbols.insert(label)
                }
                out.append(AsmStatement(text: "\(label):", loc: rawStmt.loc))
                lineAfterLabels = remainder
            }
            if lineAfterLabels.isEmpty {
                i += 1
                continue
            }
            let stmt = (lineAfterLabels == rawStmt.text) ? rawStmt : AsmStatement(text: lineAfterLabels, loc: rawStmt.loc)
            let (firstWord, restText) = splitFirstWord(stmt.text)
            let lowerFirst = firstWord.lowercased()

            switch lowerFirst {
            case ".macro":
                guard let end = blockEnd(stmts, from: i + 1, opens: [".macro"], close: ".endm") else {
                    diagnostics.report(.asmUnterminatedBlock, at: stmt.loc, args: [".endm", ".macro"])
                    return out
                }
                if let (name, params) = parseMacroHeader(restText, loc: stmt.loc, diagnostics: &diagnostics) {
                    if ctx.macros[name] != nil {
                        diagnostics.report(.asmMacroError, at: stmt.loc, args: ["macro '\(name)' is already defined"])
                    } else {
                        ctx.macros[name] = AsmMacroDef(name: name, params: params, body: Array(stmts[(i + 1)..<end]))
                    }
                }
                i = end + 1
                continue

            case ".purgem":
                let name = restText.trimmingCharacters(in: .whitespaces)
                if ctx.macros.removeValue(forKey: name) == nil {
                    diagnostics.report(.asmMacroError, at: stmt.loc, args: ["macro '\(name)' is not defined"])
                }
                i += 1
                continue

            case ".exitm":
                ctx.exitRequested = true
                return out

            case ".rept", ".irp", ".irpc":
                guard let end = blockEnd(stmts, from: i + 1, opens: repeatOpeners, close: ".endr") else {
                    diagnostics.report(.asmUnterminatedBlock, at: stmt.loc, args: [".endr", lowerFirst])
                    return out
                }
                let body = Array(stmts[(i + 1)..<end])
                i = end + 1
                var iterations: [[String: String]] = []
                if lowerFirst == ".rept" {
                    guard let count = AsmExprEvaluator.evaluate(restText, constants: ctx.constants)?.constantValue else {
                        diagnostics.report(.asmInvalidExpression, at: stmt.loc, args: [restText])
                        continue
                    }
                    iterations = Array(repeating: [:], count: Int(max(0, min(count, 1 << 20))))
                } else {
                    guard let (param, values) = parseRepeatList(lowerFirst, restText, loc: stmt.loc, diagnostics: &diagnostics) else { continue }
                    iterations = values.map { [param: $0] }
                }
                ctx.macroDepth += 1
                defer { ctx.macroDepth -= 1 }
                for bindings in iterations {
                    let substituted = bindings.isEmpty ? body : body.map {
                        AsmStatement(text: substituteMacroParams(in: $0.text, bindings: bindings, counter: ctx.macroCounter), loc: $0.loc)
                    }
                    out.append(contentsOf: expandBlock(substituted, ctx: &ctx, diagnostics: &diagnostics))
                    if ctx.exitRequested { return out }
                }
                continue

            case _ where lowerFirst.hasPrefix(".if") && conditionalKinds.contains(lowerFirst):
                var branches: [(kind: String, arg: String, body: [AsmStatement])] = []
                var kind = lowerFirst
                var arg = restText
                var body: [AsmStatement] = []
                var depth = 1
                var j = i + 1
                var closed = false
                while j < stmts.count {
                    let (wordRaw, wordRest) = splitFirstWord(stmts[j].text)
                    let word = wordRaw.lowercased()
                    if conditionalKinds.contains(word) {
                        depth += 1
                    } else if word == ".endif" {
                        depth -= 1
                        if depth == 0 { closed = true; break }
                    } else if depth == 1 && (word == ".else" || word == ".elseif") {
                        branches.append((kind, arg, body))
                        kind = word == ".else" ? ".else" : ".if"
                        arg = wordRest
                        body = []
                        j += 1
                        continue
                    }
                    body.append(stmts[j])
                    j += 1
                }
                guard closed else {
                    diagnostics.report(.asmUnterminatedBlock, at: stmt.loc, args: [".endif", lowerFirst])
                    return out
                }
                branches.append((kind, arg, body))
                i = j + 1
                for branch in branches where evaluateConditional(kind: branch.kind, arg: branch.arg, ctx: ctx) {
                    out.append(contentsOf: expandBlock(branch.body, ctx: &ctx, diagnostics: &diagnostics))
                    break
                }
                if ctx.exitRequested { return out }
                continue

            case ".equ", ".set":
                // Track constants so `.rept`/`.if` can reference them (the session handles the directive itself)
                let parts = splitCommaSeparated(restText)
                if parts.count == 2 {
                    let sym = parts[0].trimmingCharacters(in: .whitespaces)
                    ctx.definedSymbols.insert(sym)
                    if let val = AsmExprEvaluator.evaluate(parts[1], constants: ctx.constants)?.constantValue {
                        ctx.constants[sym] = val
                    }
                }

            default:
                if let macro = ctx.macros[firstWord] {
                    guard ctx.macroDepth < maxMacroDepth else {
                        // Only the outermost use: one note per level would be 20 notes
                        let outermost = AsmLoc(stmt.loc.location, notes: Array(stmt.loc.notes.suffix(1)))
                        diagnostics.report(.asmMacroNestedTooDeeply, at: outermost, args: [String(maxMacroDepth)])
                        i += 1
                        continue
                    }
                    // `\@` is the number of macro instantiations before this one (the first is 0)
                    let body = instantiateMacro(macro, arch: ctx.arch, argsText: restText, invocation: stmt, counter: ctx.macroCounter, diagnostics: &diagnostics)
                    ctx.macroCounter += 1
                    ctx.macroDepth += 1
                    out.append(contentsOf: expandBlock(body, ctx: &ctx, diagnostics: &diagnostics))
                    ctx.macroDepth -= 1
                    ctx.exitRequested = false
                    i += 1
                    continue
                }
            }

            out.append(stmt)
            i += 1
        }
        return out
    }

    private static let conditionalKinds: Set<String> = [
        ".if", ".ifdef", ".ifndef", ".ifeq", ".ifne", ".ifge", ".ifgt", ".ifle", ".iflt",
        ".ifc", ".ifnc", ".ifeqs", ".ifnes", ".ifb", ".ifnb", ".ifnotdef",
    ]

    private static func evaluateConditional(kind: String, arg: String, ctx: Context) -> Bool {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)
        func value() -> Int64? { AsmExprEvaluator.evaluate(trimmed, constants: ctx.constants)?.constantValue }
        switch kind {
        case ".else":                  return true
        case ".ifdef":                 return ctx.definedSymbols.contains(trimmed)
        case ".ifndef", ".ifnotdef":   return !ctx.definedSymbols.contains(trimmed)
        case ".ifb":                   return trimmed.isEmpty
        case ".ifnb":                  return !trimmed.isEmpty
        case ".ifeq":                  return value().map { $0 == 0 } ?? false
        case ".ifge":                  return value().map { $0 >= 0 } ?? false
        case ".ifgt":                  return value().map { $0 > 0 } ?? false
        case ".ifle":                  return value().map { $0 <= 0 } ?? false
        case ".iflt":                  return value().map { $0 < 0 } ?? false
        case ".ifc", ".ifnc", ".ifeqs", ".ifnes":
            let parts = splitCommaSeparated(trimmed)
            guard parts.count == 2 else { return false }
            let unquote = { (s: String) -> String in parseAsmStringLiteral(s).map { String(decoding: $0, as: UTF8.self) } ?? s }
            let eq = unquote(parts[0]) == unquote(parts[1])
            return (kind == ".ifc" || kind == ".ifeqs") ? eq : !eq
        default:                       return value().map { $0 != 0 } ?? false   // `.if`, `.ifne`
        }
    }

    // MARK: Macros

    /// Parses `.macro name[,] p1[=default] p2:req, rest:vararg` as LLVM MC's `parseDirectiveMacro` does:
    /// parameters are separated by commas or blanks, a default value is one macro argument, and a malformed
    /// header (unknown qualifier, duplicate parameter, `:vararg` not last) is an error that drops the macro.
    private static func parseMacroHeader(_ header: String, loc: AsmLoc, diagnostics: inout DiagnosticBag) -> (String, [AsmMacroParam])? {
        var p = MacroArgParser(header)
        func fail(_ message: String) -> (String, [AsmMacroParam])? {
            diagnostics.report(.asmMacroError, at: loc, args: [message])
            return nil
        }
        guard let nameTok = p.current, nameTok.kind == .identifier else { return fail("expected identifier in '.macro' directive") }
        let name = nameTok.text
        p.advance()
        if p.current?.kind == .comma { p.advance() }
        var params: [AsmMacroParam] = []
        while let tok = p.current {
            if let last = params.last, last.vararg {
                return fail("vararg parameter '\(last.name)' should be the last parameter")
            }
            guard tok.kind == .identifier else { return fail("expected identifier in '.macro' directive") }
            let param = tok.text
            if params.contains(where: { $0.name == param }) {
                return fail("macro '\(name)' has multiple parameters named '\(param)'")
            }
            p.advance()
            var required = false
            var vararg = false
            if p.current?.text == ":" {
                p.advance()
                guard let qualifier = p.current, qualifier.kind == .identifier else {
                    return fail("missing parameter qualifier for '\(param)' in macro '\(name)'")
                }
                switch qualifier.text {
                case "req":    required = true
                case "vararg": vararg = true
                default:       return fail("\(qualifier.text) is not a valid parameter qualifier for '\(param)' in macro '\(name)'")
                }
                p.advance()
            }
            var defaultValue = ""
            if p.current?.isEqual == true {
                p.advance()
                do {
                    defaultValue = macroArgumentText(try p.argument(vararg: false), vararg: vararg)
                } catch {
                    return fail(error.message)
                }
                if required {
                    diagnostics.report(.asmMacroWarning, at: loc, args: ["pointless default value for required parameter '\(param)' in macro '\(name)'"])
                }
            }
            params.append(AsmMacroParam(name: param, defaultValue: defaultValue, required: required, vararg: vararg))
            if p.current?.kind == .comma { p.advance() }
            p.skipSpace()
        }
        return (name, params)
    }

    /// Binds positional and `name=value` keyword arguments with LLVM MC's `parseMacroArguments` rules (an empty
    /// argument takes the default, keyword arguments may not be followed by positional ones, a string argument
    /// is substituted without its quotes, and a `:vararg` parameter takes the rest of the line verbatim), then
    /// substitutes them into the body. Any argument error is diagnosed and the macro is not expanded. Each
    /// produced statement keeps its body location plus a note pointing at the invocation.
    private static func instantiateMacro(
        _ macro: AsmMacroDef,
        arch: AssemblerArch,
        argsText: String,
        invocation: AsmStatement,
        counter: Int,
        diagnostics: inout DiagnosticBag
    ) -> [AsmStatement] {
        var parser = MacroArgParser(argsText)
        let values: [[MacroToken]]
        do {
            values = try parser.arguments(params: macro.params, macroName: macro.name)
        } catch {
            diagnostics.report(.asmMacroError, at: invocation.loc, args: [error.message])
            return []
        }
        // Only possible for a macro without parameters invoked with arguments
        guard values.count == macro.params.count else {
            diagnostics.report(.asmMacroError, at: invocation.loc, args: ["Wrong number of arguments"])
            return []
        }
        var bindings: [String: String] = [:]
        var missing = false
        for (p, value) in zip(macro.params, values) {
            if value.isEmpty {
                if p.required {
                    diagnostics.report(.asmMacroMissingArgument, at: invocation.loc, args: [p.name, macro.name])
                    missing = true
                }
                bindings[p.name] = p.defaultValue
            } else {
                bindings[p.name] = macroArgumentText(value, vararg: p.vararg)
            }
        }
        if missing { return [] }

        let note = DiagNote(message: "in expansion of macro '\(macro.name)'", location: GlobalLocation(unitId: UnitId(0), location: invocation.loc.location))
        let notes = [note] + invocation.loc.notes
        var result: [AsmStatement] = []
        for bodyStmt in macro.body {
            let sub = substituteMacroParams(in: bodyStmt.text, bindings: bindings, counter: counter)
            // A substituted argument may introduce further `;`-separated statements
            var inBlockComment = false
            for (text, _) in stripCommentsAndSplit(ArraySlice(sub.utf8), arch: arch, inBlockComment: &inBlockComment) {
                result.append(AsmStatement(text: text, loc: AsmLoc(bodyStmt.loc.location, notes: notes)))
            }
        }
        return result
    }

    /// The `.irp`/`.irpc` header `param, values...`: the parameter name and, as LLVM MC lexes them, the value
    /// list (`.irp`: one value per macro argument, blanks separating as in macro calls; `.irpc`: one character
    /// per iteration of a single token). Errors are reported and give nil.
    private static func parseRepeatList(_ kind: String, _ text: String, loc: AsmLoc, diagnostics: inout DiagnosticBag) -> (String, [String])? {
        var p = MacroArgParser(text)
        func fail(_ message: String) -> (String, [String])? {
            diagnostics.report(.asmMacroError, at: loc, args: [message])
            return nil
        }
        guard let paramTok = p.current, paramTok.kind == .identifier else { return fail("expected identifier in '\(kind)' directive") }
        p.advance()
        guard p.current?.kind == .comma else { return fail("expected comma") }
        p.advance()
        let values: [[MacroToken]]
        do {
            values = try p.arguments(params: nil, macroName: kind)
        } catch {
            return fail(error.message)
        }
        if kind == ".irp" {
            return (paramTok.text, values.map { macroArgumentText($0, vararg: false) })
        }
        guard values.count == 1, values[0].count == 1 else { return fail("unexpected token in '.irpc' directive") }
        return (paramTok.text, macroArgumentText(values[0], vararg: false).map { String($0) })
    }

    /// The text substituted for a macro argument: its tokens concatenated without the blanks that separated
    /// them (`m 1 + 2` gives `1+2`; blanks inside parentheses are kept), and each string literal without its
    /// quotes or escape processing. A `:vararg` value keeps strings quoted.
    private static func macroArgumentText(_ tokens: [MacroToken], vararg: Bool) -> String {
        var out = ""
        for t in tokens {
            if t.kind == .string && !vararg {
                out += t.text.count >= 2 && t.text.hasSuffix("\"") ? String(t.text.dropFirst().dropLast()) : String(t.text.dropFirst())
            } else {
                out += t.text
            }
        }
        return out
    }

    /// A token of macro argument text, classified the way LLVM MC's `AsmLexer` classifies it where macro
    /// argument splitting depends on it.
    fileprivate struct MacroToken {
        enum Kind { case space, comma, lparen, rparen, op, string, identifier, other }
        let kind: Kind
        let text: String
        /// Byte offset in the parsed text (for the verbatim rest of line taken by a `:vararg` parameter).
        let offset: Int
        var isEqual: Bool { kind == .op && text == "=" }
    }

    fileprivate struct MacroSyntaxError: Error {
        let message: String
    }

    /// Splits macro arguments as LLVM MC's `AsmParser::parseMacroArguments`/`parseMacroArgument` do (GNU `as`
    /// differs; 05-assembler.md §4.4 and §4.11): a comma ends an argument, and so does a blank, unless the next
    /// token is an operator (`+ - ~ ! * / | ^ & == != < <= << <> > >= >> && || = .`), which joins the tokens on
    /// both sides into one argument (`m 4 -5` passes `4-5`, `m 4 5` passes `4` and `5`). Only parentheses
    /// group (`m (1 2)` is one argument, `m [x0, #8]` is two).
    fileprivate struct MacroArgParser {
        private let source: [UInt8]
        private let tokens: [MacroToken]
        private var pos = 0

        init(_ text: String) {
            source = Array(text.utf8)
            tokens = MacroArgParser.tokenize(source)
            skipSpace()
        }

        var current: MacroToken? { pos < tokens.count ? tokens[pos] : nil }

        /// Consumes the current token and any blanks after it.
        mutating func advance() {
            pos += 1
            skipSpace()
        }

        mutating func skipSpace() {
            if current?.kind == .space { pos += 1 }
        }

        /// `parseMacroArgument`: one argument's tokens (empty if the argument is empty).
        mutating func argument(vararg: Bool) throws(MacroSyntaxError) -> [MacroToken] {
            if vararg {
                guard let first = current else { return [] }
                pos = tokens.count
                let rest = String(decoding: source[first.offset...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                return [MacroToken(kind: .other, text: rest, offset: first.offset)]
            }
            var parenLevel = 0
            var tokensOfArgument: [MacroToken] = []
            while true {
                if current?.isEqual == true { throw MacroSyntaxError(message: "unexpected token in macro instantiation") }
                if parenLevel == 0 {
                    if current?.kind == .comma { break }
                    var spaceEaten = false
                    if current?.kind == .space {
                        pos += 1
                        spaceEaten = true
                    }
                    // A blank followed by an operator does not end the argument; blanks after an operator are ignored
                    if let tok = current, tok.kind == .op {
                        tokensOfArgument.append(tok)
                        advance()
                        continue
                    }
                    if spaceEaten { break }
                }
                guard let tok = current else { break }
                if tok.kind == .lparen {
                    parenLevel += 1
                } else if tok.kind == .rparen && parenLevel > 0 {
                    parenLevel -= 1
                }
                tokensOfArgument.append(tok)
                pos += 1
            }
            if parenLevel != 0 { throw MacroSyntaxError(message: "unbalanced parentheses in macro argument") }
            return tokensOfArgument
        }

        /// `parseMacroArguments`: the value of each parameter, by index (empty where none was given). With
        /// `params == nil` (an `.irp`/`.irpc` list) any number of values is accepted.
        mutating func arguments(params: [AsmMacroParam]?, macroName: String) throws(MacroSyntaxError) -> [[MacroToken]] {
            let paramCount = params?.count ?? 0
            var values = [[MacroToken]](repeating: [], count: paramCount)
            var namedFound = false
            var parameter = 0
            while paramCount == 0 || parameter < paramCount {
                var name = ""
                if let tok = current, tok.kind == .identifier {
                    var peek = pos + 1
                    if peek < tokens.count && tokens[peek].kind == .space { peek += 1 }
                    if peek < tokens.count && tokens[peek].isEqual {
                        name = tok.text
                        pos = peek
                        advance()
                        namedFound = true
                    }
                }
                if namedFound && name.isEmpty { throw MacroSyntaxError(message: "cannot mix positional and keyword arguments") }
                let vararg = parameter < paramCount && params?[parameter].vararg == true
                let value = try argument(vararg: vararg)
                var index = parameter
                if !name.isEmpty {
                    guard let named = params?.firstIndex(where: { $0.name == name }) else {
                        throw MacroSyntaxError(message: "parameter named '\(name)' does not exist for macro '\(macroName)'")
                    }
                    index = named
                }
                if !value.isEmpty {
                    if values.count <= index { values += [[MacroToken]](repeating: [], count: index + 1 - values.count) }
                    values[index] = value
                }
                guard let next = current else { return values }
                if next.kind == .comma { advance() }
                parameter += 1
            }
            throw MacroSyntaxError(message: "too many positional arguments")
        }

        private static let twoCharOperators: Set<String> = ["==", "!=", "<<", ">>", "<=", ">=", "<>", "&&", "||"]

        private static func tokenize(_ b: [UInt8]) -> [MacroToken] {
            func isIdentChar(_ c: UInt8) -> Bool { AsmMacroEngine.isMacroNameByte(c) || c == UInt8(ascii: "@") || c == UInt8(ascii: "?") }
            var tokens: [MacroToken] = []
            var i = 0
            while i < b.count {
                let start = i
                let c = b[i]
                var kind = MacroToken.Kind.other
                switch c {
                case 0x20, 0x09:
                    while i < b.count && (b[i] == 0x20 || b[i] == 0x09) { i += 1 }
                    kind = .space
                case UInt8(ascii: ","):
                    i += 1
                    kind = .comma
                case UInt8(ascii: "("):
                    i += 1
                    kind = .lparen
                case UInt8(ascii: ")"):
                    i += 1
                    kind = .rparen
                case UInt8(ascii: "\""):
                    i += 1
                    while i < b.count && b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                    i = min(i + 1, b.count)
                    kind = .string
                case UInt8(ascii: "'"):
                    // Character constant: `'a'`, `'\n'` (or GNU's unterminated `'a`)
                    i += 1
                    if i < b.count && b[i] == UInt8(ascii: "\\") { i += 1 }
                    if i < b.count { i += 1 }
                    if i < b.count && b[i] == UInt8(ascii: "'") { i += 1 }
                default:
                    if i + 1 < b.count, twoCharOperators.contains(String(decoding: b[i...(i + 1)], as: UTF8.self)) {
                        i += 2
                        kind = .op
                    } else if c == UInt8(ascii: "."), i + 1 >= b.count || !isIdentChar(b[i + 1]) {
                        i += 1
                        kind = .op
                    } else if "+-~/*=|^&!<>".utf8.contains(c) {
                        i += 1
                        kind = .op
                    } else if isIdentChar(c) {
                        while i < b.count && isIdentChar(b[i]) { i += 1 }
                        let letter = (c | 0x20) >= UInt8(ascii: "a") && (c | 0x20) <= UInt8(ascii: "z")
                        kind = letter || c == UInt8(ascii: "_") || c == UInt8(ascii: ".") ? .identifier : .other
                    } else {
                        i += 1
                    }
                }
                tokens.append(MacroToken(kind: kind, text: String(decoding: b[start..<i], as: UTF8.self), offset: start))
            }
            return tokens
        }
    }

    private static func isMacroNameByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2E || c == 0x24
    }

    /// Substitutes `\name` (longest name, as LLVM MC's `expandMacro` scans it), `\@` (invocation counter), and removes the `\()`
    /// separator (`\reg\().4s`). A `\name` that is not a parameter is left untouched.
    private static func substituteMacroParams(in line: String, bindings: [String: String], counter: Int) -> String {
        let bytes = Array(line.utf8)
        guard bytes.contains(UInt8(ascii: "\\")) else { return line }
        let n = bytes.count
        var out: [UInt8] = []
        out.reserveCapacity(n + 16)
        var i = 0
        func isEmptyGroup(_ at: Int) -> Bool {
            at + 2 < n && bytes[at] == UInt8(ascii: "\\") && bytes[at + 1] == UInt8(ascii: "(") && bytes[at + 2] == UInt8(ascii: ")")
        }
        while i < n {
            if bytes[i] == UInt8(ascii: "\\") && i + 1 < n {
                let c = bytes[i + 1]
                if c == UInt8(ascii: "@") {
                    out.append(contentsOf: String(counter).utf8)
                    i += 2
                    continue
                }
                if i + 2 < n && c == UInt8(ascii: "(") && bytes[i + 2] == UInt8(ascii: ")") {
                    i += 3
                    continue
                }
                if isMacroNameByte(c) {
                    var j = i + 1
                    while j < n && isMacroNameByte(bytes[j]) { j += 1 }
                    if let value = bindings[String(decoding: bytes[(i + 1)..<j], as: UTF8.self)] {
                        out.append(contentsOf: value.utf8)
                        i = j
                        if isEmptyGroup(i) { i += 3 }
                        continue
                    }
                }
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Numeric local labels

    private static func rewriteNumericLocalLabels(_ stmts: [AsmStatement]) -> [AsmStatement] {
        // First pass: split out any inline labels (`1: in %dx, %al`) into separate label statements.
        var normalized: [AsmStatement] = []
        normalized.reserveCapacity(stmts.count + 16)

        for stmt in stmts {
            var text = stmt.text
            while let (lbl, rest) = extractLeadingLabel(text) {
                normalized.append(AsmStatement(text: "\(lbl):", loc: stmt.loc))
                text = rest
            }
            if !text.isEmpty && !text.hasSuffix(":") {
                normalized.append(AsmStatement(text: text, loc: stmt.loc))
            }
        }

        // Second pass: assign instance numbers to each numeric label definition `N:`.
        // `currentInstance[N]` = number of definitions of `N` seen so far (1..k), so at statement `i`,
        // `Nb` refers to `.L_local_N_<currentInstance[N]>` and `Nf` to `.L_local_N_<currentInstance[N] + 1>`.
        var currentInstance: [Int: Int] = [:]
        var out: [AsmStatement] = []
        out.reserveCapacity(normalized.count)

        for stmt in normalized {
            let text = stmt.text
            if text.hasSuffix(":") {
                let lblName = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                if let num = Int(lblName), lblName.allSatisfy({ $0.isNumber }) {
                    let nextInst = (currentInstance[num] ?? 0) + 1
                    currentInstance[num] = nextInst
                    out.append(AsmStatement(text: ".L_local_\(num)_\(nextInst):", loc: stmt.loc))
                    continue
                }
            }
            out.append(AsmStatement(text: rewriteNumericRefsInLine(text, currentInstance: currentInstance), loc: stmt.loc))
        }
        return out
    }

    private static func rewriteNumericRefsInLine(_ line: String, currentInstance: [Int: Int]) -> String {
        // Don't rewrite inside string literals
        var out = ""
        let chars = Array(line)
        let n = chars.count
        var i = 0
        var inString = false

        while i < n {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\" && i + 1 < n {
                    i += 1
                    out.append(chars[i])
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i += 1
                continue
            }

            // Check if a numeric token starts at `i` (not preceded by identifier/number/hex prefix)
            let prevIsIdent: Bool = {
                guard i > 0 else { return false }
                let p = chars[i - 1]
                return p.isLetter || p.isNumber || p == "_" || p == "." || p == "%" || p == "$"
            }()

            // Note: on x86 AT&T, `$1b` could be immediate label ref, wait: `$1` is integer, so `prevIsIdent` for `$` should NOT block `1b` if needed, though branches never use `$`.
            if !prevIsIdent && c.isNumber {
                var j = i
                while j < n && chars[j].isNumber {
                    j += 1
                }
                if j < n && (chars[j] == "b" || chars[j] == "B" || chars[j] == "f" || chars[j] == "F") {
                    let nextIsIdent: Bool = (j + 1 < n) && (chars[j + 1].isLetter || chars[j + 1].isNumber || chars[j + 1] == "_")
                    // Make sure `0b1010` binary literal is NOT treated as local label `0b`!
                    if !nextIsIdent {
                        let numStr = String(chars[i..<j])
                        if let num = Int(numStr) {
                            let dir = chars[j]
                            let cur = currentInstance[num] ?? 0
                            let targetInst = (dir == "b" || dir == "B") ? cur : (cur + 1)
                            out.append(".L_local_\(num)_\(targetInst)")
                            i = j + 1
                            continue
                        }
                    }
                }
            }

            out.append(c)
            i += 1
        }
        return out
    }
}

// MARK: - 4. Parsing Helpers (Shared across `Asm/`)

/// Splits `str` into `(firstToken, remainder)` separated by whitespace.
public func splitFirstWord(_ str: String) -> (String, String) {
    let trimmed = str.trimmingCharacters(in: .whitespaces)
    guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }) else {
        return (trimmed, "")
    }
    let first = String(trimmed[..<spaceIdx])
    let rest = String(trimmed[spaceIdx...]).trimmingCharacters(in: .whitespaces)
    return (first, rest)
}

/// Extracts a leading `label:` from `str` if present (ignoring `:lo12:` or `%fs:0` colons inside operands).
public func extractLeadingLabel(_ str: String) -> (label: String, remainder: String)? {
    let trimmed = str.trimmingCharacters(in: .whitespaces)
    guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
    let candidate = String(trimmed[..<colonIdx])
    guard !candidate.isEmpty else { return nil }
    // A valid label has no whitespace, quotes, commas, or `%`/`[`/`(` characters
    for ch in candidate {
        if !(ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "$") {
            return nil
        }
    }
    let rest = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
    return (candidate, rest)
}

/// Splits an operand list by top-level commas, respecting `(...)`, `[...]`, `{...}`, and `"..."`.
public func splitCommaSeparated(_ str: String) -> [String] {
    let trimmed = str.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }

    var result: [String] = []
    var current = ""
    var parenDepth = 0
    var bracketDepth = 0
    var braceDepth = 0
    var inString = false
    let chars = Array(trimmed)
    var i = 0

    while i < chars.count {
        let c = chars[i]
        if inString {
            current.append(c)
            if c == "\\" && i + 1 < chars.count {
                i += 1
                current.append(chars[i])
            } else if c == "\"" {
                inString = false
            }
            i += 1
            continue
        }
        switch c {
        case "\"":
            inString = true
            current.append(c)
        case "(":
            parenDepth += 1
            current.append(c)
        case ")":
            parenDepth = max(0, parenDepth - 1)
            current.append(c)
        case "[":
            bracketDepth += 1
            current.append(c)
        case "]":
            bracketDepth = max(0, bracketDepth - 1)
            current.append(c)
        case "{":
            braceDepth += 1
            current.append(c)
        case "}":
            braceDepth = max(0, braceDepth - 1)
            current.append(c)
        case "," where parenDepth == 0 && bracketDepth == 0 && braceDepth == 0:
            result.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        default:
            current.append(c)
        }
        i += 1
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty || !result.isEmpty {
        result.append(last)
    }
    return result
}

/// Unescapes a C/GNU `as` string literal `"..."` into raw UTF-8 bytes.
public func parseAsmStringLiteral(_ raw: String) -> [UInt8]? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
    let inner = Array(trimmed.dropFirst().dropLast().utf8)
    var out: [UInt8] = []
    out.reserveCapacity(inner.count)
    var i = 0
    while i < inner.count {
        let b = inner[i]
        if b == UInt8(ascii: "\\") && i + 1 < inner.count {
            i += 1
            let esc = inner[i]
            switch esc {
            case UInt8(ascii: "n"): out.append(10); i += 1
            case UInt8(ascii: "r"): out.append(13); i += 1
            case UInt8(ascii: "t"): out.append(9);  i += 1
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var val: UInt8 = esc - UInt8(ascii: "0")
                i += 1
                var count = 1
                while count < 3 && i < inner.count && inner[i] >= UInt8(ascii: "0") && inner[i] <= UInt8(ascii: "7") {
                    val = (val &* 8) &+ (inner[i] - UInt8(ascii: "0"))
                    i += 1
                    count += 1
                }
                out.append(val)
            case UInt8(ascii: "x"):
                i += 1
                var hexStr = ""
                while hexStr.count < 2 && i < inner.count {
                    let hc = inner[i]
                    if (hc >= UInt8(ascii: "0") && hc <= UInt8(ascii: "9")) ||
                       (hc >= UInt8(ascii: "a") && hc <= UInt8(ascii: "f")) ||
                       (hc >= UInt8(ascii: "A") && hc <= UInt8(ascii: "F")) {
                        hexStr.append(Character(UnicodeScalar(hc)))
                        i += 1
                    } else {
                        break
                    }
                }
                if let hv = UInt8(hexStr, radix: 16) {
                    out.append(hv)
                }
            default:
                out.append(esc)
                i += 1
            }
        } else {
            out.append(b)
            i += 1
        }
    }
    return out
}

// MARK: - 5. Section Fragments & Relaxation Model (`05-assembler.md` §4.5)

/// A symbolic fixup or relocation emitted inside an instruction fragment.
public struct AsmInstFixup: Sendable {
    public let offsetInInst: Int
    public let kind: RelocKind
    public let symbol: String
    public let minusSymbol: String?
    public let addend: Int64
    public let width: Int
    /// True if a same-section target can be resolved at assembly time without emitting an ELF relocation.
    public let resolveIfSameSection: Bool

    public init(
        offsetInInst: Int,
        kind: RelocKind,
        symbol: String,
        minusSymbol: String? = nil,
        addend: Int64,
        width: Int = 4,
        resolveIfSameSection: Bool = false
    ) {
        self.offsetInInst = offsetInInst
        self.kind = kind
        self.symbol = symbol
        self.minusSymbol = minusSymbol
        self.addend = addend
        self.width = width
        self.resolveIfSameSection = resolveIfSameSection
    }
}

/// Relaxable branch instruction whose short vs long encoding is chosen during the layout fixpoint loop.
public enum AsmRelaxableBranch: Sendable {
    /// x86-64 `jmp` (`isConditional == false`, `condCode == 0`) or `jcc` (`isConditional == true`, `condCode == 0x0..0xF`).
    /// Short form: 2 bytes (`EB rel8` or `70+cc rel8`); Long form: 5 bytes (`E9 rel32`) or 6 bytes (`0F 80+cc rel32`).
    case x86Branch(isConditional: Bool, condCode: UInt8, targetSymbol: String, addend: Int64)

    /// AArch64 conditional branch (`b.cond`, `cbz`/`cbnz`, `tbz`/`tbnz`) or unconditional `b`/`bl`.
    case a64Branch(baseInst: A64Instruction, targetSymbol: String, addend: Int64)

    /// RV64 branch or jump (`c.j`/`jal` or `c.beqz`/`c.bnez`/`beq`/`bne`/`blt`/`bge`/`bltu`/`bgeu`).
    case rvBranch(baseInst: RV64Instruction, rvcAllowed: Bool, targetSymbol: String, addend: Int64)
}

/// Fragment inside an assembling section (`05-assembler.md` §4.5).
public enum AsmFragment: Sendable {
    /// Fixed encoded bytes with zero or more symbolic fixups/relocations.
    case inst(bytes: [UInt8], fixups: [AsmInstFixup], loc: AsmLoc)
    /// Label definition at the current position in the section.
    case label(name: String)
    /// Relaxable branch instruction (`form` grows monotonically; see `AsmSession.relaxableSize`).
    case relaxable(branch: AsmRelaxableBranch, form: Int, loc: AsmLoc)
    /// Alignment directive (`.balign`, `.p2align`, `.align`).
    case align(alignBytes: Int, fillByte: UInt8?, maxBytes: Int)
    /// Data expression (`.byte`, `.short`, `.long`, `.quad`).
    case dataExpr(width: Int, expr: String, loc: AsmLoc)
    /// Zero or byte fill (`.zero`, `.space`, `.skip`, `.fill`).
    case fill(countExpr: String, unitSize: Int, fillValue: Int64, loc: AsmLoc)
}

/// State of a single section during assembly.
public final class AsmSectionBuilder {
    public let name: String
    public var kind: SectionKind
    public var flags: SectionFlags
    public var alignLog2: UInt8
    public var fragments: [AsmFragment] = []
    /// Literal pool entries for AArch64 `ldr xN, =expr` (`(labelName, exprString)`).
    public var literalPool: [(label: String, expr: String)] = []

    public init(name: String, kind: SectionKind, flags: SectionFlags, alignLog2: UInt8) {
        self.name = name
        self.kind = kind
        self.flags = flags
        self.alignLog2 = alignLog2
    }

    public func emitBytes(_ bytes: [UInt8], fixups: [AsmInstFixup] = [], loc: AsmLoc = .unknown) {
        fragments.append(.inst(bytes: bytes, fixups: fixups, loc: loc))
    }

    public func emitRelaxable(_ branch: AsmRelaxableBranch, loc: AsmLoc = .unknown) {
        fragments.append(.relaxable(branch: branch, form: 0, loc: loc))
    }

    public func recordAlignment(alignBytes: Int) {
        guard alignBytes > 1 else { return }
        let log2 = UInt8(alignBytes.trailingZeroBitCount)
        if log2 > alignLog2 {
            alignLog2 = log2
        }
    }
}

// MARK: - 6. CFI & `.eh_frame` Builder (`05-assembler.md` §4.9)

/// Tracks `.cfi_*` directives and synthesizes `.eh_frame` CIE + FDE records byte-identical to LLVM MC
/// (`MCDwarf.cpp` `FrameEmitterImpl`): each directive's DWARF CFA instruction is placed after a
/// `DW_CFA_advance_loc{,1,2,4}` from the previous directive's address (resolved after layout); FDEs are
/// stable-sorted by CIE key and each group is preceded by its CIE, so FDEs with different CIEs are not in source
/// order (GNU `as` keeps source order and shares CIEs by content; 05-assembler.md §4.11); records are padded with
/// `DW_CFA_nop` to 4 bytes, the last FDE so the section size is a multiple of 8.
public final class AsmCFIBuilder {
    /// CIE-level properties (LLVM MC `CIEKey`); FDEs with equal keys share one CIE, and FDEs are ordered by key.
    struct CIEKey: Hashable, Comparable {
        var signalFrame = false
        /// `.cfi_startproc simple`: no default initial instructions.
        var simple = false
        /// `.cfi_return_column`, or nil for the target default. An explicit column is a different key even when
        /// it equals the default, and sorts before it (LLVM MC compares it with `INT_MAX` for "unset").
        var returnColumn: UInt64? = nil

        static func < (a: CIEKey, b: CIEKey) -> Bool {
            func rank(_ k: CIEKey) -> (Int, Int, UInt64) {
                (k.signalFrame ? 1 : 0, k.simple ? 1 : 0, k.returnColumn ?? UInt64(Int32.max))
            }
            return rank(a) < rank(b)
        }
    }

    /// One DWARF CFA instruction, emitted at the address of `label`.
    struct Op {
        let label: String
        let bytes: [UInt8]
    }

    struct ProcedureCFI {
        let sectionIndex: Int
        let startLabel: String
        var endLabel: String = ""
        var key: CIEKey
        var ops: [Op] = []
    }

    private let arch: AssemblerArch
    private(set) var procedures: [ProcedureCFI] = []
    private var activeProcIndex: Int? = nil
    private var labelCounter: Int = 0
    /// Assembler-tracked CFA (for `.cfi_adjust_cfa_offset` / `.cfi_rel_offset`) and its remember/restore stack.
    private var cfaRegister: UInt64 = 0
    private var cfaOffset: Int64 = 0
    private var stateStack: [(UInt64, Int64)] = []
    /// `.cfi_sections` without `.eh_frame` suppresses `.eh_frame` output.
    private(set) var emitEhFrame = true

    init(arch: AssemblerArch) {
        self.arch = arch
    }

    var hasActiveProcedure: Bool {
        activeProcIndex != nil
    }

    // MARK: Target conventions (identical in GNU `as` and LLVM MC)

    var dataAlignmentFactor: Int64 {
        switch arch {
        case .x86_64, .riscv64: return -8
        case .aarch64:          return -4
        }
    }

    var defaultReturnColumn: UInt64 {
        switch arch {
        case .x86_64:  return 16   // %rip
        case .aarch64: return 30   // x30 (lr)
        case .riscv64: return 1    // ra
        }
    }

    /// Initial CFA rule: `rsp + 8` on x86-64 (the call pushed the return address), `sp + 0` elsewhere.
    private var initialCFA: (register: UInt64, offset: Int64) {
        switch arch {
        case .x86_64:  return (7, 8)
        case .aarch64: return (31, 0)
        case .riscv64: return (2, 0)
        }
    }

    // MARK: Directives

    private func makeLabel(in section: AsmSectionBuilder, prefix: String) -> String {
        labelCounter += 1
        let name = ".Lcfi_\(prefix)\(labelCounter)"
        section.fragments.append(.label(name: name))
        return name
    }

    func startProc(in section: AsmSectionBuilder, sectionIndex: Int, args: String) {
        let start = makeLabel(in: section, prefix: "start")
        let simple = args.trimmingCharacters(in: .whitespaces).lowercased() == "simple"
        procedures.append(ProcedureCFI(
            sectionIndex: sectionIndex,
            startLabel: start,
            key: CIEKey(simple: simple)
        ))
        activeProcIndex = procedures.count - 1
        (cfaRegister, cfaOffset) = initialCFA
        stateStack.removeAll()
    }

    func endProc(in section: AsmSectionBuilder) {
        guard let idx = activeProcIndex else { return }
        procedures[idx].endLabel = makeLabel(in: section, prefix: "end")
        activeProcIndex = nil
    }

    /// Handles a `.cfi_*` directive other than `startproc`/`endproc`. Returns false for an unknown or
    /// unsupported directive or malformed operands (the caller reports it).
    func handleDirective(_ directive: String, args: String, in section: AsmSectionBuilder, constants: [String: Int64]) -> Bool {
        if directive == ".cfi_sections" {
            emitEhFrame = splitCommaSeparated(args).contains { $0.trimmingCharacters(in: .whitespaces) == ".eh_frame" }
            return true
        }
        guard let idx = activeProcIndex else { return false }  // the caller diagnoses CFI outside a procedure
        let parts = splitCommaSeparated(args)
        func value(_ i: Int) -> Int64? {
            guard i < parts.count else { return nil }
            return AsmExprEvaluator.evaluate(parts[i], constants: constants)?.constantValue
        }
        func reg(_ i: Int) -> UInt64? {
            guard i < parts.count else { return nil }
            return parseDwarfReg(parts[i])
        }
        var bytes: [UInt8] = []

        switch directive {
        case ".cfi_signal_frame":
            procedures[idx].key.signalFrame = true
            return true
        case ".cfi_return_column":
            guard let r = reg(0) else { return false }
            procedures[idx].key.returnColumn = r
            return true
        case ".cfi_personality", ".cfi_lsda":
            // Encoding 0xff (DW_EH_PE_omit) means "none"; real personality/LSDA augmentation is unsupported.
            return value(0) == 0xFF
        case ".cfi_def_cfa":
            guard parts.count == 2, let r = reg(0), let off = value(1) else { return false }
            (cfaRegister, cfaOffset) = (r, off)
            encodeDefCFA(r, off, into: &bytes)
        case ".cfi_def_cfa_offset":
            guard parts.count == 1, let off = value(0) else { return false }
            cfaOffset = off
            encodeDefCFAOffset(off, into: &bytes)
        case ".cfi_adjust_cfa_offset":
            guard parts.count == 1, let delta = value(0) else { return false }
            cfaOffset &+= delta
            encodeDefCFAOffset(cfaOffset, into: &bytes)
        case ".cfi_def_cfa_register":
            guard parts.count == 1, let r = reg(0) else { return false }
            cfaRegister = r
            bytes.append(0x0D)
            appendULEB128(r, to: &bytes)
        case ".cfi_offset", ".cfi_rel_offset":
            guard parts.count == 2, let r = reg(0), var off = value(1) else { return false }
            if directive == ".cfi_rel_offset" { off &-= cfaOffset }
            let factored = off / dataAlignmentFactor
            if factored >= 0 && r < 64 {
                bytes.append(0x80 | UInt8(r))                // DW_CFA_offset
                appendULEB128(UInt64(factored), to: &bytes)
            } else if factored >= 0 {
                bytes.append(0x05)                           // DW_CFA_offset_extended
                appendULEB128(r, to: &bytes)
                appendULEB128(UInt64(factored), to: &bytes)
            } else {
                bytes.append(0x11)                           // DW_CFA_offset_extended_sf
                appendULEB128(r, to: &bytes)
                appendSLEB128(factored, to: &bytes)
            }
        case ".cfi_val_offset":
            guard parts.count == 2, let r = reg(0), let off = value(1) else { return false }
            let factored = off / dataAlignmentFactor
            bytes.append(factored >= 0 ? 0x14 : 0x15)        // DW_CFA_val_offset{,_sf}
            appendULEB128(r, to: &bytes)
            if factored >= 0 { appendULEB128(UInt64(factored), to: &bytes) } else { appendSLEB128(factored, to: &bytes) }
        case ".cfi_restore":
            guard parts.count == 1, let r = reg(0) else { return false }
            if r < 64 {
                bytes.append(0xC0 | UInt8(r))                // DW_CFA_restore
            } else {
                bytes.append(0x06)                           // DW_CFA_restore_extended
                appendULEB128(r, to: &bytes)
            }
        case ".cfi_undefined", ".cfi_same_value":
            guard parts.count == 1, let r = reg(0) else { return false }
            bytes.append(directive == ".cfi_undefined" ? 0x07 : 0x08)
            appendULEB128(r, to: &bytes)
        case ".cfi_register":
            guard parts.count == 2, let r1 = reg(0), let r2 = reg(1) else { return false }
            bytes.append(0x09)                               // DW_CFA_register
            appendULEB128(r1, to: &bytes)
            appendULEB128(r2, to: &bytes)
        case ".cfi_remember_state":
            stateStack.append((cfaRegister, cfaOffset))
            bytes.append(0x0A)
        case ".cfi_restore_state":
            if let saved = stateStack.popLast() { (cfaRegister, cfaOffset) = saved }
            bytes.append(0x0B)
        case ".cfi_window_save", ".cfi_negate_ra_state":
            bytes.append(0x2D)                               // DW_CFA_GNU_window_save / AARCH64_negate_ra_state
        case ".cfi_escape":
            for i in parts.indices {
                guard let b = value(i) else { return false }
                bytes.append(UInt8(truncatingIfNeeded: b))
            }
        default:
            return false
        }

        // Reuse the label of an immediately preceding CFI directive at the same address
        let label: String
        if case .label(let name)? = section.fragments.last, name.hasPrefix(".Lcfi_") {
            label = name
        } else {
            label = makeLabel(in: section, prefix: "")
        }
        procedures[idx].ops.append(Op(label: label, bytes: bytes))
        return true
    }

    private func encodeDefCFA(_ r: UInt64, _ off: Int64, into bytes: inout [UInt8]) {
        if off >= 0 {
            bytes.append(0x0C)                               // DW_CFA_def_cfa
            appendULEB128(r, to: &bytes)
            appendULEB128(UInt64(off), to: &bytes)
        } else {
            bytes.append(0x12)                               // DW_CFA_def_cfa_sf
            appendULEB128(r, to: &bytes)
            appendSLEB128(off / dataAlignmentFactor, to: &bytes)
        }
    }

    private func encodeDefCFAOffset(_ off: Int64, into bytes: inout [UInt8]) {
        if off >= 0 {
            bytes.append(0x0E)                               // DW_CFA_def_cfa_offset
            appendULEB128(UInt64(off), to: &bytes)
        } else {
            bytes.append(0x13)                               // DW_CFA_def_cfa_offset_sf
            appendSLEB128(off / dataAlignmentFactor, to: &bytes)
        }
    }

    /// DWARF register number of `raw` (a register name or a plain number).
    private func parseDwarfReg(_ raw: String) -> UInt64? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("%") { s.removeFirst() }
        if let num = UInt64(s) { return num }
        func indexed(_ prefixes: [String], max: UInt64) -> UInt64? {
            for p in prefixes where s.hasPrefix(p) {
                if let n = UInt64(s.dropFirst(p.count)), n <= max { return n }
            }
            return nil
        }
        switch arch {
        case .x86_64:
            let gprs = ["rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp"]
            if let i = gprs.firstIndex(of: s) { return UInt64(i) }
            if s == "rip" { return 16 }
            if let n = indexed(["r"], max: 15), n >= 8 { return n }
            if let n = indexed(["xmm"], max: 15) { return 17 + n }
            if let n = indexed(["st"], max: 7) { return 33 + n }
            if let n = indexed(["mm"], max: 7) { return 41 + n }
            return nil
        case .aarch64:
            switch s {
            case "sp", "wsp": return 31
            case "lr":        return 30
            case "fp":        return 29
            default: break
            }
            if let n = indexed(["x", "w"], max: 30) { return n }
            if let n = indexed(["v", "q", "d", "s", "h", "b"], max: 31) { return 64 + n }
            return nil
        case .riscv64:
            if let gpr = RVGPR(name: s) { return UInt64(gpr.rawValue) }
            if let fpr = RVFPR(name: s) { return 32 + UInt64(fpr.rawValue) }
            return nil
        }
    }

    // MARK: `.eh_frame` synthesis (after layout)

    /// One `.eh_frame` record (CIE or FDE) plus the offset of its `pc_begin` field and target label, if any.
    struct Record {
        let bytes: [UInt8]
        let pcBeginLabel: String?
    }

    /// Builds the `.eh_frame` records. `labelOffset` gives a label's (section index, offset) after layout.
    func buildEhFrame(labelOffset: (String) -> (Int, Int64)?) -> [Record] {
        let procs = procedures.filter { !$0.endLabel.isEmpty }
        guard emitEhFrame, !procs.isEmpty else { return [] }

        // Stable sort by CIE key, so each CIE is emitted once, right before its group of FDEs
        let sorted = procs.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element)
        var records: [Record] = []
        var size = 0
        var cieOffset = 0
        var lastKey: CIEKey? = nil

        for (procIdx, proc) in sorted.enumerated() {
            guard let start = labelOffset(proc.startLabel), let end = labelOffset(proc.endLabel) else { continue }
            let isLast = procIdx == sorted.count - 1

            if proc.key != lastKey {
                lastKey = proc.key
                cieOffset = size
                let cie = padded(cieBody(proc.key), alignment: 4, at: size)
                records.append(Record(bytes: cie, pcBeginLabel: nil))
                size += cie.count
            }

            var body: [UInt8] = []
            appendLE(UInt64(size + 4 - cieOffset), width: 4, to: &body)              // CIE_pointer (relative)
            appendLE(0, width: 4, to: &body)                                         // pc_begin (relocated)
            appendLE(UInt64(max(0, end.1 - start.1)), width: 4, to: &body)           // pc_range
            body.append(0)                                                           // augmentation data length
            var location = start.1
            for op in proc.ops {
                if let (sec, target) = labelOffset(op.label), sec == start.0, target > location {
                    appendAdvance(UInt64(target - location), to: &body)
                    location = target
                }
                body.append(contentsOf: op.bytes)
            }
            let fde = padded(body, alignment: isLast ? 8 : 4, at: size)
            records.append(Record(bytes: fde, pcBeginLabel: proc.startLabel))
            size += fde.count
        }
        return records
    }

    private func cieBody(_ key: CIEKey) -> [UInt8] {
        var body: [UInt8] = [0, 0, 0, 0, 1]                   // CIE_id = 0 (.eh_frame), version 1
        body.append(contentsOf: Array((key.signalFrame ? "zRS" : "zR").utf8))
        body.append(0)
        appendULEB128(1, to: &body)                           // code_alignment_factor
        appendSLEB128(dataAlignmentFactor, to: &body)         // data_alignment_factor
        appendULEB128(key.returnColumn ?? defaultReturnColumn, to: &body)  // return_address_register
        body.append(1)                                        // augmentation data length
        body.append(0x1B)                                     // FDE encoding: DW_EH_PE_pcrel | DW_EH_PE_sdata4
        if !key.simple {
            let cfa = initialCFA
            encodeDefCFA(cfa.register, cfa.offset, into: &body)
            if arch == .x86_64 {
                body.append(contentsOf: [0x80 | 16, 1])       // DW_CFA_offset %rip, cfa-8
            }
        }
        return body
    }

    /// Prefixes the 4-byte length and pads the record (starting at section offset `offset`) with `DW_CFA_nop`
    /// so that it ends on a multiple of `alignment`.
    private func padded(_ body: [UInt8], alignment: Int, at offset: Int) -> [UInt8] {
        var b = body
        while (offset + b.count + 4) % alignment != 0 { b.append(0) }
        var out: [UInt8] = []
        appendLE(UInt64(b.count), width: 4, to: &out)
        return out + b
    }

    private func appendAdvance(_ delta: UInt64, to bytes: inout [UInt8]) {
        if delta < 64 {
            bytes.append(0x40 | UInt8(delta))                 // DW_CFA_advance_loc
        } else if delta <= 0xFF {
            bytes.append(0x02)                                // DW_CFA_advance_loc1
            appendLE(delta, width: 1, to: &bytes)
        } else if delta <= 0xFFFF {
            bytes.append(0x03)                                // DW_CFA_advance_loc2
            appendLE(delta, width: 2, to: &bytes)
        } else {
            bytes.append(0x04)                                // DW_CFA_advance_loc4
            appendLE(delta, width: 4, to: &bytes)
        }
    }

    private func appendLE(_ value: UInt64, width: Int, to buf: inout [UInt8]) {
        for i in 0..<width { buf.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) }
    }

    private func appendULEB128(_ value: UInt64, to buf: inout [UInt8]) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            buf.append(byte)
        } while v != 0
    }

    private func appendSLEB128(_ value: Int64, to buf: inout [UInt8]) {
        var v = value
        while true {
            let byte = UInt8(truncatingIfNeeded: v & 0x7F)
            v >>= 7
            if (v == 0 && byte & 0x40 == 0) || (v == -1 && byte & 0x40 != 0) {
                buf.append(byte)
                return
            }
            buf.append(byte | 0x80)
        }
    }
}

// MARK: - 7. Top-Level Assembler (`Assembler`, `05-assembler.md`)

/// Top-level native assembler for x86-64, AArch64, and RV64 (RVA23).
public enum Assembler {

    /// Assembles a `.s` or `.S` file from disk into a `RelocatableObject`. Diagnostic locations refer to
    /// `sourceManager` (pass one to render them).
    public static func assembleFile(
        path: String,
        arch: AssemblerArch,
        includePaths: [String] = [],
        defines: [(name: String, value: String)] = [],
        riscvOptions: RVAsmOptions = RVAsmOptions(),
        sourceManager: SourceManager? = nil,
        diagnostics: inout DiagnosticBag
    ) throws -> RelocatableObject {
        let sm = sourceManager ?? SourceManager()
        let fileId = try sm.loadFile(path: path)
        let sourceMap = AsmSourceMap(sourceManager: sm)
        sourceMap.register(fileId)
        if path.hasSuffix(".S") {
            let text = preprocess(fileId: fileId, sourceManager: sm, arch: arch, includePaths: includePaths, defines: defines, diagnostics: &diagnostics)
            return assembleText(text, physicalFile: nil, arch: arch, sourceMap: sourceMap, includePaths: includePaths, riscvOptions: riscvOptions, diagnostics: &diagnostics)
        }
        let text = String(decoding: sourceMap.bytes(of: fileId), as: UTF8.self)
        return assembleText(text, physicalFile: fileId, arch: arch, sourceMap: sourceMap, includePaths: includePaths, riscvOptions: riscvOptions, diagnostics: &diagnostics)
    }

    /// Runs the `assembler-with-cpp` preprocessor: target-architecture predefined macros replace the host
    /// defaults, then user `-D` definitions are applied so they can override them. The output carries
    /// `# <line> "<file>"` markers, so assembler diagnostics point into the original `.S` and headers.
    private static func preprocess(
        fileId: FileId,
        sourceManager sm: SourceManager,
        arch: AssemblerArch,
        includePaths: [String],
        defines: [(name: String, value: String)],
        diagnostics: inout DiagnosticBag
    ) -> String {
        let pp = CPreprocessor(sourceManager: sm)
        pp.enableAssemblerMode(arch: arch.description)
        pp.includePaths.append(contentsOf: includePaths)
        for def in defines {
            pp.defineMacro(def.name, replacement: def.value)
        }
        let text = pp.preprocessToText(fileId: fileId)
        diagnostics.absorb(pp.diagnostics)
        return text
    }

    /// Assembles in-memory assembly source text into a `RelocatableObject`. The text is registered in
    /// `sourceManager` as `fileName` so diagnostics carry `file:line:col` locations.
    public static func assemble(
        source: String,
        arch: AssemblerArch,
        fileName: String = "<asm>",
        preprocess runPreprocessor: Bool = false,
        includePaths: [String] = [],
        defines: [(name: String, value: String)] = [],
        riscvOptions: RVAsmOptions = RVAsmOptions(),
        sourceManager: SourceManager? = nil,
        diagnostics: inout DiagnosticBag
    ) -> RelocatableObject {
        let sm = sourceManager ?? SourceManager()
        let fileId = sm.addBuffer(bytes: Array(source.utf8), path: fileName)
        let sourceMap = AsmSourceMap(sourceManager: sm)
        sourceMap.register(fileId)
        if runPreprocessor {
            let text = preprocess(fileId: fileId, sourceManager: sm, arch: arch, includePaths: includePaths, defines: defines, diagnostics: &diagnostics)
            return assembleText(text, physicalFile: nil, arch: arch, sourceMap: sourceMap, includePaths: includePaths, riscvOptions: riscvOptions, diagnostics: &diagnostics)
        }
        return assembleText(source, physicalFile: fileId, arch: arch, sourceMap: sourceMap, includePaths: includePaths, riscvOptions: riscvOptions, diagnostics: &diagnostics)
    }

    private static func assembleText(
        _ text: String,
        physicalFile: FileId?,
        arch: AssemblerArch,
        sourceMap: AsmSourceMap,
        includePaths: [String],
        riscvOptions: RVAsmOptions,
        diagnostics: inout DiagnosticBag
    ) -> RelocatableObject {
        let statements = AsmMacroEngine.expandStatements(
            text: text,
            physicalFile: physicalFile,
            arch: arch,
            sourceMap: sourceMap,
            includePaths: includePaths,
            diagnostics: &diagnostics
        )
        let session = AsmSession(arch: arch, sourceMap: sourceMap, includePaths: includePaths)
        session.rvOptions = riscvOptions
        session.processStatements(statements, diagnostics: &diagnostics)
        return session.buildRelocatableObject(diagnostics: &diagnostics)
    }
}

// MARK: - 8. Assembler Session (Directives, Layout, Relaxation & Object Emission)

internal struct AsmSymbolAttrs {
    var binding: SymbolBinding = .local
    var visibility: SymbolVisibility = .defaultVisibility
    var kind: SymbolKind = .notype
    var sizeExpr: String? = nil
    var sizeLoc: AsmLoc = .unknown
}

internal final class AsmSession {
    let arch: AssemblerArch

    // Ordered sections (always starting with default `.text`)
    var sections: [AsmSectionBuilder] = []
    var sectionByName: [String: Int] = [:]
    var currentSectionIndex: Int = 0
    var sectionStack: [Int] = []
    var previousSectionIndex: Int = 0

    // Constants (`.equ` / `.set` / `=`) known at parse time, plus label-dependent assignments
    // (`.equ len, end - start`, forward references) that are resolved after layout.
    var constants: [String: Int64] = [:]
    var deferredAssignments: [String: (expr: String, loc: AsmLoc)] = [:]
    /// Assignments that resolved to an undefined symbol plus addend (`.set alias, extern + 4`).
    var externalAliases: [String: (symbol: String, addend: Int64)] = [:]

    let sourceMap: AsmSourceMap?
    let includePaths: [String]

    // Symbol attributes & order of first mention/definition
    var symbolAttrs: [String: AsmSymbolAttrs] = [:]
    var symbolMentionOrder: [String] = []
    var symbolMentionSet: Set<String> = []
    var definedLabels: [String: (sectionIndex: Int, offset: Int64)] = [:]

    // Per-architecture mutable state
    var x86CodeMode: X86CodeMode = .mode64
    var rvOptions = RVAsmOptions()
    var rvOptionStack: [RVAsmOptions] = []
    var pcrelHiCounter: Int = 0
    var literalPoolCounter: Int = 0

    // CFI state
    let cfiBuilder: AsmCFIBuilder

    init(arch: AssemblerArch, sourceMap: AsmSourceMap? = nil, includePaths: [String] = []) {
        self.arch = arch
        self.sourceMap = sourceMap
        self.includePaths = includePaths
        self.cfiBuilder = AsmCFIBuilder(arch: arch)
        // GNU `as` / LLVM MC always creates `.text` as the initial section
        _ = getOrCreateSection(
            name: ".text",
            kind: .text,
            flags: [.alloc, .execInstr],
            alignLog2: arch.defaultTextAlignLog2
        )
    }

    var currentSection: AsmSectionBuilder {
        sections[currentSectionIndex]
    }

    func noteSymbol(_ name: String) {
        guard !name.isEmpty, name != "." else { return }
        if !symbolMentionSet.contains(name) {
            symbolMentionSet.insert(name)
            symbolMentionOrder.append(name)
        }
        if symbolAttrs[name] == nil {
            symbolAttrs[name] = AsmSymbolAttrs()
        }
    }

    @discardableResult
    func getOrCreateSection(
        name: String,
        kind: SectionKind,
        flags: SectionFlags,
        alignLog2: UInt8
    ) -> Int {
        if let existing = sectionByName[name] {
            return existing
        }
        let idx = sections.count
        let sec = AsmSectionBuilder(name: name, kind: kind, flags: flags, alignLog2: alignLog2)
        sections.append(sec)
        sectionByName[name] = idx
        return idx
    }

    func switchSection(to idx: Int) {
        previousSectionIndex = currentSectionIndex
        currentSectionIndex = idx
    }

    func flushLiteralPoolIfNeeded(in sec: AsmSectionBuilder) {
        guard !sec.literalPool.isEmpty else { return }
        let entries = sec.literalPool
        sec.literalPool.removeAll()
        sec.fragments.append(.align(alignBytes: 8, fillByte: 0, maxBytes: 0))
        sec.recordAlignment(alignBytes: 8)
        for entry in entries {
            sec.fragments.append(.label(name: entry.label))
            sec.fragments.append(.dataExpr(width: 8, expr: entry.expr, loc: .unknown))
        }
    }

    // MARK: Statement Processing

    func processStatements(_ statements: [AsmStatement], diagnostics: inout DiagnosticBag) {
        for stmt in statements {
            processOneStatement(stmt, diagnostics: &diagnostics)
        }
        for sec in sections {
            flushLiteralPoolIfNeeded(in: sec)
        }
    }

    private func processOneStatement(_ stmt: AsmStatement, diagnostics: inout DiagnosticBag) {
        let text = stmt.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        // 1. Label definition `foo:`
        if text.hasSuffix(":") && !text.contains(" ") && !text.contains("\t") {
            let lbl = String(text.dropLast())
            noteSymbol(lbl)
            currentSection.fragments.append(.label(name: lbl))
            return
        }

        // 2. Direct symbol assignment `SYM = EXPR` (not `==`)
        if let eqIdx = text.firstIndex(of: "="), !text.hasPrefix("."),
           text[text.index(after: eqIdx)...].first != "=" {
            let lhs = String(text[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let rhs = String(text[text.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            if !lhs.isEmpty && lhs.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }) {
                assignSymbol(lhs, rhs, loc: stmt.loc, diagnostics: &diagnostics)
                return
            }
        }

        let (mnemonic, args) = splitFirstWord(text)

        // 3. Assembler directive `.foo`
        if mnemonic.hasPrefix(".") {
            handleDirective(mnemonic.lowercased(), args: args, loc: stmt.loc, diagnostics: &diagnostics)
            return
        }

        // 4. Architecture-specific instruction dispatch (closed enum switch per 05-assembler.md §4.3)
        let sectionBefore = currentSectionIndex
        let fragmentsBefore = currentSection.fragments.count
        let errorsBefore = diagnostics.errorCount
        defer {
            // Every instruction emits at least one fragment. An instruction parser that neither emitted
            // anything nor reported an error rejected the operands (e.g. an encoder range check failed),
            // so report it here rather than silently dropping the statement.
            if currentSectionIndex == sectionBefore,
               currentSection.fragments.count == fragmentsBefore,
               diagnostics.errorCount == errorsBefore {
                diagnostics.report(.asmInvalidOperands, at: stmt.loc, args: [mnemonic])
            }
        }
        switch arch {
        case .x86_64:
            X86Asm.parseInstruction(mnemonic: mnemonic, args: args, loc: stmt.loc, session: self, diagnostics: &diagnostics)
        case .aarch64:
            A64Asm.parseInstruction(mnemonic: mnemonic, args: args, loc: stmt.loc, session: self, diagnostics: &diagnostics)
        case .riscv64:
            RVAsm.parseInstruction(mnemonic: mnemonic, args: args, loc: stmt.loc, session: self, diagnostics: &diagnostics)
        }
    }

    private func handleDirective(_ dir: String, args: String, loc: AsmLoc, diagnostics: inout DiagnosticBag) {
        switch dir {
        case ".text":
            let idx = getOrCreateSection(name: ".text", kind: .text, flags: [.alloc, .execInstr], alignLog2: arch.defaultTextAlignLog2)
            switchSection(to: idx)

        case ".data":
            let idx = getOrCreateSection(name: ".data", kind: .data, flags: [.alloc, .write], alignLog2: 0)
            switchSection(to: idx)

        case ".bss":
            let idx = getOrCreateSection(name: ".bss", kind: .bss, flags: [.alloc, .write], alignLog2: 0)
            switchSection(to: idx)

        case ".rodata":
            let idx = getOrCreateSection(name: ".rodata", kind: .rodata, flags: [.alloc], alignLog2: 0)
            switchSection(to: idx)

        case ".section", ".pushsection":
            if dir == ".pushsection" {
                sectionStack.append(currentSectionIndex)
            }
            let parts = splitCommaSeparated(args)
            guard let rawName = parts.first else { return }
            let secName = rawName.trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            let (kind, flags, alignLog2) = inferSectionProperties(name: secName, parts: parts)
            let idx = getOrCreateSection(name: secName, kind: kind, flags: flags, alignLog2: alignLog2)
            switchSection(to: idx)

        case ".popsection":
            if let prev = sectionStack.popLast() {
                currentSectionIndex = prev
            }

        case ".previous":
            let tmp = currentSectionIndex
            currentSectionIndex = previousSectionIndex
            previousSectionIndex = tmp

        case ".globl", ".global":
            for sym in splitCommaSeparated(args) where !sym.isEmpty {
                noteSymbol(sym)
                symbolAttrs[sym, default: AsmSymbolAttrs()].binding = .global
            }

        case ".weak":
            for sym in splitCommaSeparated(args) where !sym.isEmpty {
                noteSymbol(sym)
                symbolAttrs[sym, default: AsmSymbolAttrs()].binding = .weak
            }

        case ".local":
            for sym in splitCommaSeparated(args) where !sym.isEmpty {
                noteSymbol(sym)
                symbolAttrs[sym, default: AsmSymbolAttrs()].binding = .local
            }

        case ".hidden":
            for sym in splitCommaSeparated(args) where !sym.isEmpty {
                noteSymbol(sym)
                symbolAttrs[sym, default: AsmSymbolAttrs()].visibility = .hidden
            }

        case ".protected":
            for sym in splitCommaSeparated(args) where !sym.isEmpty {
                noteSymbol(sym)
                symbolAttrs[sym, default: AsmSymbolAttrs()].visibility = .protected
            }

        case ".internal":
            for sym in splitCommaSeparated(args) where !sym.isEmpty {
                noteSymbol(sym)
                symbolAttrs[sym, default: AsmSymbolAttrs()].visibility = .internalVisibility
            }

        case ".type":
            let parts = splitCommaSeparated(args)
            if parts.count >= 2 {
                let sym = parts[0]
                let typeStr = parts[1].lowercased()
                noteSymbol(sym)
                if typeStr.contains("function") {
                    symbolAttrs[sym, default: AsmSymbolAttrs()].kind = .funcSymbol
                } else if typeStr.contains("object") {
                    symbolAttrs[sym, default: AsmSymbolAttrs()].kind = .object
                } else if typeStr.contains("tls_object") {
                    symbolAttrs[sym, default: AsmSymbolAttrs()].kind = .tls
                }
            }

        case ".size":
            let parts = splitCommaSeparated(args)
            if parts.count == 2 {
                let sym = parts[0]
                noteSymbol(sym)
                // The expression is evaluated after layout, so pin `.` to a temporary label here.
                symbolAttrs[sym, default: AsmSymbolAttrs()].sizeExpr = bindLocationCounter(in: parts[1])
                symbolAttrs[sym, default: AsmSymbolAttrs()].sizeLoc = loc
            }

        case ".equ", ".set", ".equiv", ".eqv":
            let parts = splitCommaSeparated(args)
            guard parts.count == 2 else {
                diagnostics.report(.asmInvalidExpression, at: loc, args: [args])
                return
            }
            assignSymbol(parts[0], parts[1], loc: loc, diagnostics: &diagnostics)

        case ".balign":
            let parts = splitCommaSeparated(args)
            if let first = parts.first,
               let alignBytes = AsmExprEvaluator.evaluate(first, constants: constants)?.constantValue,
               alignBytes > 0 {
                let fill: UInt8? = (parts.count >= 2) ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue.map { UInt8(truncatingIfNeeded: $0) } : nil
                let maxB: Int = (parts.count >= 3) ? Int(AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                appendAlignment(alignBytes: Int(alignBytes), fillByte: fill, maxBytes: maxB)
            }

        case ".p2align":
            let parts = splitCommaSeparated(args)
            if let first = parts.first,
               let pow2 = AsmExprEvaluator.evaluate(first, constants: constants)?.constantValue,
               pow2 >= 0 && pow2 <= 30 {
                let alignBytes = 1 << Int(pow2)
                let fill: UInt8? = (parts.count >= 2 && !parts[1].isEmpty) ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue.map { UInt8(truncatingIfNeeded: $0) } : nil
                let maxB: Int = (parts.count >= 3) ? Int(AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                appendAlignment(alignBytes: alignBytes, fillByte: fill, maxBytes: maxB)
            }

        case ".align":
            let parts = splitCommaSeparated(args)
            if let first = parts.first,
               let val = AsmExprEvaluator.evaluate(first, constants: constants)?.constantValue,
               val >= 0 {
                let alignBytes = arch.alignDirectiveIsBytes ? max(1, Int(val)) : (1 << Int(val))
                let fill: UInt8? = (parts.count >= 2 && !parts[1].isEmpty) ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue.map { UInt8(truncatingIfNeeded: $0) } : nil
                let maxB: Int = (parts.count >= 3) ? Int(AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                appendAlignment(alignBytes: alignBytes, fillByte: fill, maxBytes: maxB)
            }

        case ".byte", ".1byte":
            emitData(args, width: 1, loc: loc)

        case ".short", ".hword", ".value", ".2byte":
            emitData(args, width: 2, loc: loc)

        case ".word":
            emitData(args, width: (arch == .x86_64) ? 2 : 4, loc: loc)

        case ".long", ".int", ".4byte":
            emitData(args, width: 4, loc: loc)

        case ".quad", ".dword", ".8byte":
            emitData(args, width: 8, loc: loc)

        case ".incbin":
            emitIncbin(args, loc: loc, diagnostics: &diagnostics)

        case ".ascii":
            for item in splitCommaSeparated(args) {
                if let bytes = parseAsmStringLiteral(item) {
                    currentSection.emitBytes(bytes, loc: loc)
                }
            }

        case ".asciz", ".string":
            for item in splitCommaSeparated(args) {
                if var bytes = parseAsmStringLiteral(item) {
                    bytes.append(0)
                    currentSection.emitBytes(bytes, loc: loc)
                }
            }

        case ".zero", ".space", ".skip":
            let parts = splitCommaSeparated(args)
            if let countExpr = parts.first {
                let fillVal: Int64 = (parts.count >= 2) ? (AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.fill(countExpr: countExpr, unitSize: 1, fillValue: fillVal, loc: loc))
            }

        case ".fill":
            let parts = splitCommaSeparated(args)
            if let repeatExpr = parts.first {
                let unitSize = (parts.count >= 2) ? Int(AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue ?? 1) : 1
                let fillVal: Int64 = (parts.count >= 3) ? (AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.fill(countExpr: repeatExpr, unitSize: max(1, unitSize), fillValue: fillVal, loc: loc))
            }

        case ".ltorg", ".pool":
            flushLiteralPoolIfNeeded(in: currentSection)

        case ".code16":
            x86CodeMode = .mode16
        case ".code32":
            x86CodeMode = .mode32
        case ".code64":
            x86CodeMode = .mode64

        case ".option":
            let opt = args.trimmingCharacters(in: .whitespaces).lowercased()
            switch opt {
            case "push":
                rvOptionStack.append(rvOptions)
            case "pop":
                if let prev = rvOptionStack.popLast() {
                    rvOptions = prev
                }
            case "rvc":
                rvOptions.rvcEnabled = true
            case "norvc":
                rvOptions.rvcEnabled = false
            case "relax":
                rvOptions.relaxEnabled = true
            case "norelax":
                rvOptions.relaxEnabled = false
            case "pic":
                rvOptions.picEnabled = true
            case "nopic":
                rvOptions.picEnabled = false
            default:
                break
            }

        case ".cfi_startproc":
            if cfiBuilder.hasActiveProcedure {
                diagnostics.report(.asmCFIError, at: loc, args: ["starting new .cfi frame before finishing the previous one"])
            } else {
                cfiBuilder.startProc(in: currentSection, sectionIndex: currentSectionIndex, args: args)
            }
        case _ where dir.hasPrefix(".cfi_") && dir != ".cfi_sections" && !cfiBuilder.hasActiveProcedure:
            // LLVM MC (and GNU `as`) reject CFI outside a `.cfi_startproc`/`.cfi_endproc` region
            diagnostics.report(.asmCFIError, at: loc, args: ["this directive must appear between .cfi_startproc and .cfi_endproc directives"])
        case ".cfi_endproc":
            cfiBuilder.endProc(in: currentSection)
        case _ where dir.hasPrefix(".cfi_"):
            if !cfiBuilder.handleDirective(dir, args: args, in: currentSection, constants: constants) {
                diagnostics.report(.asmUnsupportedDirective, at: loc, args: ["\(dir) \(args)"])
            }

        case ".inst":
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: 4, expr: expr, loc: loc))
            }

        case ".arch", ".arch_extension", ".cpu", ".fpu", ".file", ".loc", ".ident", ".addrsig", ".addrsig_sym", ".attribute", ".insn":
            // Metadata / target attribute directives accepted as no-ops in v1 (`.insn` for RV64 is handled in `RVAsm` if needed)
            if dir == ".insn" && arch == .riscv64 {
                RVAsm.parseInsnDirective(args: args, loc: loc, session: self, diagnostics: &diagnostics)
            }

        default:
            diagnostics.report(.asmUnknownDirective, at: loc, args: [dir])
        }
    }

    /// Emits `.byte`/`.short`/`.long`/`.quad` operands. Values already constant are encoded now, as LLVM MC
    /// inlines an absolute `.set` symbol at its use (so a later `.set` of the same symbol does not change them); the rest are resolved after layout.
    private func emitData(_ args: String, width: Int, loc: AsmLoc) {
        for expr in splitCommaSeparated(args) {
            if let v = AsmExprEvaluator.evaluate(expr, constants: constants)?.constantValue {
                var bytes: [UInt8] = []
                appendLittleEndian(v, width: width, to: &bytes)
                currentSection.emitBytes(bytes, loc: loc)
            } else {
                currentSection.fragments.append(.dataExpr(width: width, expr: expr, loc: loc))
            }
        }
    }

    /// `.incbin "file"[, skip[, count]]`, searched like `.include`.
    private func emitIncbin(_ args: String, loc: AsmLoc, diagnostics: inout DiagnosticBag) {
        let parts = splitCommaSeparated(args)
        guard let first = parts.first, let nameBytes = parseAsmStringLiteral(first) else {
            diagnostics.report(.asmInvalidExpression, at: loc, args: [args])
            return
        }
        let name = String(decoding: nameBytes, as: UTF8.self)
        let path = sourceMap?.resolve(name, from: loc.location, includePaths: includePaths)
            ?? (FileManager.default.fileExists(atPath: name) ? name : nil)
        guard let path, let data = FileManager.default.contents(atPath: path) else {
            diagnostics.report(.asmFileNotFound, at: loc, args: [name])
            return
        }
        let skip = parts.count >= 2 ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue : 0
        let count = parts.count >= 3 ? AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue : Int64(data.count)
        guard let skip, let count, skip >= 0, count >= 0, skip <= Int64(data.count) else {
            diagnostics.report(.asmInvalidExpression, at: loc, args: [args])
            return
        }
        let end = Int(min(Int64(data.count), skip + count))
        currentSection.emitBytes([UInt8](data[Int(skip)..<end]), loc: loc)
    }

    /// `.equ`/`.set`/`=`. A value known now becomes a constant for the statements that follow (as in LLVM MC);
    /// one that depends on label positions not yet final (a forward reference, `. - msg` across an alignment)
    /// is resolved after layout. As in LLVM MC, an assigned constant is a local `SHN_ABS` symbol.
    private func assignSymbol(_ rawSym: String, _ rawExpr: String, loc: AsmLoc, diagnostics: inout DiagnosticBag) {
        let sym = rawSym.trimmingCharacters(in: .whitespaces)
        noteSymbol(sym)
        let expr = bindLocationCounter(in: rawExpr)
        if let v = evaluateWithFixedLayout(expr) {
            constants[sym] = v
            deferredAssignments[sym] = nil
        } else if AsmExprEvaluator.evaluate(expr, constants: constants) != nil {
            constants[sym] = nil
            deferredAssignments[sym] = (expr, loc)
        } else {
            diagnostics.report(.asmInvalidExpression, at: loc, args: [rawExpr])
        }
    }

    /// Evaluates `expr` to a constant using label offsets that are already final: within a run of fixed-size
    /// fragments of one section (no alignment or relaxable branch in between) label differences cannot change,
    /// which is when LLVM MC (and GNU `as`) fold them at once, whichever section is current.
    private func evaluateWithFixedLayout(_ expr: String) -> Int64? {
        if let v = AsmExprEvaluator.evaluate(expr, constants: constants)?.constantValue { return v }
        var runs: [[String: Int64]] = []
        var offset: Int64 = 0
        for section in sections {
            // Each section starts a new run
            runs.append([:])
            offset = 0
            for frag in section.fragments {
                switch frag {
                case .label(let name):
                    runs[runs.count - 1][name] = offset
                case .inst(let bytes, _, _):
                    offset += Int64(bytes.count)
                case .dataExpr(let width, _, _):
                    offset += Int64(width)
                case .fill(let countExpr, let unitSize, _, _):
                    if let c = AsmExprEvaluator.evaluate(countExpr, constants: constants)?.constantValue {
                        offset += max(0, c) * Int64(unitSize)
                    } else {
                        runs.append([:])
                        offset = 0
                    }
                case .align, .relaxable:
                    runs.append([:])
                    offset = 0
                }
            }
        }
        for labels in runs.reversed() where !labels.isEmpty {
            if let v = AsmExprEvaluator.evaluate(expr, constants: constants, currentSectionSymbols: labels)?.constantValue {
                return v
            }
        }
        return nil
    }

    /// Replaces each standalone `.` (the location counter) in `expr` with a temporary label defined at the
    /// current position, so the expression can be evaluated after layout without losing where `.` was.
    func bindLocationCounter(in expr: String) -> String {
        let chars = Array(expr.utf8)
        func isIdentByte(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2E || c == 0x24
        }
        var out: [UInt8] = []
        var label: String? = nil
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == 0x2E,
               i == 0 || !isIdentByte(chars[i - 1]),
               i + 1 == chars.count || !isIdentByte(chars[i + 1]) {
                if label == nil {
                    literalPoolCounter += 1
                    let name = ".Lloc_\(literalPoolCounter)"
                    currentSection.fragments.append(.label(name: name))
                    label = name
                }
                out.append(contentsOf: label!.utf8)
            } else if isIdentByte(c) {
                // Copy a whole identifier/number so dots inside names (e.g. `.Lfoo`, `a.b`) are untouched
                while i < chars.count && isIdentByte(chars[i]) {
                    out.append(chars[i])
                    i += 1
                }
                continue
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func inferSectionProperties(name: String, parts: [String]) -> (SectionKind, SectionFlags, UInt8) {
        var flags: SectionFlags = []
        if parts.count >= 2 {
            let flagStr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")).lowercased()
            for ch in flagStr {
                switch ch {
                case "a": flags.insert(.alloc)
                case "w": flags.insert(.write)
                case "x": flags.insert(.execInstr)
                case "m": flags.insert(.merge)
                case "s": flags.insert(.strings)
                case "t": flags.insert(.tls)
                case "g": flags.insert(.group)
                default: break
                }
            }
        } else {
            if name.hasPrefix(".text") { flags = [.alloc, .execInstr] }
            else if name.hasPrefix(".data") || name.hasPrefix(".sdata") || name.hasPrefix(".bss") || name.hasPrefix(".sbss") { flags = [.alloc, .write] }
            else if name.hasPrefix(".rodata") { flags = [.alloc] }
        }

        var isNobits = name == ".bss" || name.hasPrefix(".bss.") || name == ".sbss" || name.hasPrefix(".sbss.") || name == ".tbss" || name.hasPrefix(".tbss.")
        if parts.count >= 3 {
            let typeStr = parts[2].lowercased()
            if typeStr.contains("nobits") {
                isNobits = true
            } else if typeStr.contains("progbits") {
                isNobits = false
            }
        }

        let kind: SectionKind
        if isNobits {
            kind = flags.contains(.tls) ? .tbss : .bss
        } else if flags.contains(.execInstr) || name.hasPrefix(".text") {
            kind = .text
        } else if flags.contains(.tls) {
            kind = .tdata
        } else if flags.contains(.write) {
            kind = .data
        } else if name.hasPrefix(".rodata") {
            kind = .rodata
        } else if name == ".eh_frame" {
            kind = .ehFrame
        } else {
            kind = .customProgbits
        }

        let defaultAlignLog2: UInt8
        if name == ".text" {
            defaultAlignLog2 = arch.defaultTextAlignLog2
        } else if kind == .text {
            defaultAlignLog2 = arch.defaultSubsectionTextAlignLog2
        } else {
            defaultAlignLog2 = 0
        }

        return (kind, flags, defaultAlignLog2)
    }

    /// Appends an alignment directive. RISC-V code alignment under linker relaxation (no fill value, an executable
    /// section) is LLVM MC's `shouldInsertExtraNopBytesForCodeAlign`: the worst-case padding, `align` minus the
    /// smallest instruction, as NOPs plus an `R_RISCV_ALIGN` whose addend is that size, so the linker can trim it
    /// after relaxing. The padding is emitted even where the offset is already aligned.
    func appendAlignment(alignBytes: Int, fillByte: UInt8?, maxBytes: Int) {
        let sec = currentSection
        sec.recordAlignment(alignBytes: alignBytes)
        let minNop = rvOptions.rvcEnabled ? 2 : 4
        if arch == .riscv64 && rvOptions.relaxEnabled && fillByte == nil && sec.flags.contains(.execInstr) && alignBytes > minNop {
            let pad = alignBytes - minNop
            var nops: [UInt8] = []
            appendRISCVNops(&nops, count: pad, rvc: rvOptions.rvcEnabled)
            sec.emitBytes(nops, fixups: [AsmInstFixup(offsetInInst: 0, kind: .riscv_align, symbol: "", addend: Int64(pad), width: 0)])
            return
        }
        sec.fragments.append(.align(alignBytes: alignBytes, fillByte: fillByte, maxBytes: maxBytes))
    }

    /// RISC-V NOP padding as LLVM MC writes it (`RISCVAsmBackend::writeNopData`): a zero byte to reach an even
    /// offset, then one `c.nop` (two zero bytes without C) if the count is 2 mod 4, then 4-byte `nop`s.
    func appendRISCVNops(_ bytes: inout [UInt8], count: Int, rvc: Bool) {
        var rem = count
        if (rem & 1) != 0 {
            bytes.append(0)
            rem -= 1
        }
        if rem % 4 == 2 {
            bytes.append(contentsOf: rvc ? [0x01, 0x00] : [0x00, 0x00])
            rem -= 2
        }
        while rem >= 4 {
            bytes.append(contentsOf: [0x13, 0x00, 0x00, 0x00])
            rem -= 4
        }
    }

    /// Fragment indices of RISC-V linker-relaxation barriers in `sec`: instructions with an `R_RISCV_RELAX` marker
    /// and relaxed code alignments. A PC-relative difference spanning one cannot be folded at assembly time (LLVM
    /// MC `attemptToFoldSymbolOffsetDifference`), since the linker may change the distance.
    func relaxBarriers(_ sec: AsmSectionBuilder) -> [Int] {
        guard arch == .riscv64 else { return [] }
        var out: [Int] = []
        for (i, frag) in sec.fragments.enumerated() {
            if case .inst(_, let fixups, _) = frag, fixups.contains(where: { $0.kind == .riscv_relax || $0.kind == .riscv_align }) {
                out.append(i)
            }
        }
        return out
    }

    // MARK: - 9. Fixpoint Layout, Branch Relaxation & `RelocatableObject` Construction (`05-assembler.md` §4.5)

    func buildRelocatableObject(diagnostics: inout DiagnosticBag) -> RelocatableObject {
        // 1. Run fixpoint layout and branch relaxation per section (05-assembler.md §4.5). `.fill`/`.space`
        //    counts may refer to labels further down or to label-dependent assignments; those are evaluated
        //    against the previous iteration's layout, so iteration continues until the labels are stable.
        var sectionSymbolOffsets: [[String: Int64]] = Array(repeating: [:], count: sections.count)
        var sectionTotalSizes: [Int] = Array(repeating: 0, count: sections.count)

        for secIdx in 0..<sections.count {
            let sec = sections[secIdx]
            var previousLabels: [String: Int64] = [:]
            var iteration = 0
            while true {
                iteration += 1
                let layoutConstants = deferredAssignments.isEmpty ? constants : constantsResolvingDeferred(labels: previousLabels)
                func fillCount(_ expr: String, at offset: Int, labels: [String: Int64]) -> Int {
                    let known = previousLabels.merging(labels) { _, new in new }
                    return Int(AsmExprEvaluator.evaluate(expr, constants: layoutConstants, currentSectionSymbols: known, dotOffset: Int64(offset))?.constantValue ?? 0)
                }
                var changed = false
                var offset = 0
                var localLabels: [String: Int64] = [:]

                // Pass A: compute current label offsets
                for frag in sec.fragments {
                    switch frag {
                    case .label(let name):
                        localLabels[name] = Int64(offset)
                    case .inst(let bytes, _, _):
                        offset += bytes.count
                    case .relaxable(let branch, let form, _):
                        offset += relaxableSize(branch: branch, form: form)
                    case .align(let alignBytes, _, let maxBytes):
                        offset += computeAlignPadding(currentOffset: offset, alignBytes: alignBytes, maxBytes: maxBytes)
                    case .dataExpr(let width, _, _):
                        offset += width
                    case .fill(let countExpr, let unitSize, _, _):
                        offset += max(0, fillCount(countExpr, at: offset, labels: localLabels)) * unitSize
                    }
                }

                // Pass B: check if any short relaxable branch needs to grow (monotonic: never shrinks)
                var checkOffset = 0
                var partialLabels: [String: Int64] = [:]
                for fIdx in 0..<sec.fragments.count {
                    switch sec.fragments[fIdx] {
                    case .label(let name):
                        partialLabels[name] = Int64(checkOffset)
                    case .inst(let bytes, _, _):
                        checkOffset += bytes.count
                    case .relaxable(let branch, let form, let loc):
                        let curSize = relaxableSize(branch: branch, form: form)
                        if let next = grownForm(branch: branch, form: form, instOffset: Int64(checkOffset), localLabels: localLabels) {
                            sec.fragments[fIdx] = .relaxable(branch: branch, form: next, loc: loc)
                            changed = true
                        }
                        checkOffset += curSize
                    case .align(let alignBytes, _, let maxBytes):
                        checkOffset += computeAlignPadding(currentOffset: checkOffset, alignBytes: alignBytes, maxBytes: maxBytes)
                    case .dataExpr(let width, _, _):
                        checkOffset += width
                    case .fill(let countExpr, let unitSize, _, _):
                        checkOffset += max(0, fillCount(countExpr, at: checkOffset, labels: partialLabels)) * unitSize
                    }
                }

                if !changed && (localLabels == previousLabels || iteration >= 64) {
                    sectionSymbolOffsets[secIdx] = localLabels
                    sectionTotalSizes[secIdx] = offset
                    break
                }
                previousLabels = localLabels
            }

            // Record global label lookup table
            for (lbl, off) in sectionSymbolOffsets[secIdx] {
                definedLabels[lbl] = (sectionIndex: secIdx, offset: off)
            }
        }

        resolveDeferredAssignments(sectionSymbolOffsets: sectionSymbolOffsets, diagnostics: &diagnostics)

        // Synthesize `.eh_frame` if any `.cfi_startproc` procedures were recorded
        synthesizeEhFrameIfNeeded(sectionSymbolOffsets: &sectionSymbolOffsets, sectionTotalSizes: &sectionTotalSizes)

        // 2. Initialize `RelocatableObject` and create all sections
        var obj = RelocatableObject(origin: .assembler, arch: arch.objectArch)
        var objSectionIndices: [SectionIndex] = []
        for secIdx in 0..<sections.count {
            let sec = sections[secIdx]
            let sHandle = obj.addSection(
                name: sec.name,
                kind: sec.kind,
                flags: sec.flags,
                alignLog2: sec.alignLog2
            )
            objSectionIndices.append(sHandle)
        }

        // 3. Emit section bytes and collect pending relocations
        struct PendingReloc {
            let sectionIndex: Int
            let offset: UInt64
            let kind: RelocKind
            let symbol: String
            let addend: Int64
        }
        var pendingRelocs: [PendingReloc] = []

        // RISC-V linker relaxation: per section, the barrier fragments and the fragment index of each label.
        let barriersBySection = sections.map { relaxBarriers($0) }
        let labelIndexBySection: [[String: Int]] = sections.indices.map { i in
            guard !barriersBySection[i].isEmpty else { return [:] }
            var out: [String: Int] = [:]
            for (fi, frag) in sections[i].fragments.enumerated() {
                if case .label(let name) = frag { out[name] = fi }
            }
            return out
        }
        /// True when a RISC-V relaxation barrier lies between fragment positions `a` and `b` of `section`.
        func spansRelaxBarrier(_ section: Int, _ a: Int?, _ b: Int?) -> Bool {
            guard let a, let b, !barriersBySection[section].isEmpty else { return false }
            let lo = min(a, b), hi = max(a, b)
            return barriersBySection[section].contains { $0 > lo && $0 < hi }
        }

        for secIdx in 0..<sections.count {
            let sec = sections[secIdx]
            let localLabels = sectionSymbolOffsets[secIdx]
            let sHandle = objSectionIndices[secIdx]
            let labelIndex = labelIndexBySection[secIdx]

            if sec.kind.isNobits {
                obj.setNobitsSectionSize(sHandle, size: UInt32(sectionTotalSizes[secIdx]))
                continue
            }

            var bytes: [UInt8] = []
            bytes.reserveCapacity(sectionTotalSizes[secIdx])

            for (fragIndex, frag) in sec.fragments.enumerated() {
                let fragOffset = bytes.count
                switch frag {
                case .label:
                    break

                case .inst(let instBytes, let fixups, _):
                    var patched = instBytes
                    var resolvedPCRelHi20 = false
                    for fix in fixups {
                        if fix.kind == .riscv_relax {
                            // Follows the relocation it marks; nothing to mark if that fixup was folded.
                            let at = UInt64(fragOffset + fix.offsetInInst)
                            if let last = pendingRelocs.last, last.sectionIndex == secIdx, last.offset == at, last.kind != .riscv_relax {
                                pendingRelocs.append(PendingReloc(sectionIndex: secIdx, offset: at, kind: .riscv_relax, symbol: "", addend: 0))
                            }
                            continue
                        }
                        if fix.kind == .riscv_align {
                            pendingRelocs.append(PendingReloc(sectionIndex: secIdx, offset: UInt64(fragOffset), kind: .riscv_align, symbol: "", addend: fix.addend))
                            continue
                        }
                        if let minusSym = fix.minusSymbol,
                           let pDef = definedLabels[fix.symbol],
                           let mDef = definedLabels[minusSym],
                           pDef.sectionIndex == mDef.sectionIndex {
                            let val = (pDef.offset - mDef.offset) + fix.addend
                            switch arch {
                            case .x86_64:
                                let u = UInt64(bitPattern: val)
                                let off = fix.offsetInInst
                                for bIdx in 0..<fix.width where (off + bIdx) < patched.count {
                                    patched[off + bIdx] = UInt8(truncatingIfNeeded: u >> (bIdx * 8))
                                }
                            case .aarch64:
                                if patched.count >= 4 {
                                    var word = UInt32(patched[0]) | (UInt32(patched[1]) << 8) | (UInt32(patched[2]) << 16) | (UInt32(patched[3]) << 24)
                                    word = (word & ~(0xFFFF << 5)) | ((UInt32(truncatingIfNeeded: UInt64(bitPattern: val)) & 0xFFFF) << 5)
                                    patched[0] = UInt8(truncatingIfNeeded: word)
                                    patched[1] = UInt8(truncatingIfNeeded: word >> 8)
                                    patched[2] = UInt8(truncatingIfNeeded: word >> 16)
                                    patched[3] = UInt8(truncatingIfNeeded: word >> 24)
                                }
                            case .riscv64:
                                if patched.count >= 4 {
                                    var word = UInt32(patched[0]) | (UInt32(patched[1]) << 8) | (UInt32(patched[2]) << 16) | (UInt32(patched[3]) << 24)
                                    word = (word & 0x000F_FFFF) | ((UInt32(truncatingIfNeeded: UInt64(bitPattern: val)) & 0xFFF) << 20)
                                    patched[0] = UInt8(truncatingIfNeeded: word)
                                    patched[1] = UInt8(truncatingIfNeeded: word >> 8)
                                    patched[2] = UInt8(truncatingIfNeeded: word >> 16)
                                    patched[3] = UInt8(truncatingIfNeeded: word >> 24)
                                }
                            }
                        } else if fix.kind == .riscv_pcrel_lo12_i && fix.resolveIfSameSection {
                            if resolvedPCRelHi20 {
                                // Already patched into bytes[4..<8] when resolving the companion `.riscv_pcrel_hi20`
                                continue
                            }
                            noteSymbol(fix.symbol)
                            pendingRelocs.append(
                                PendingReloc(
                                    sectionIndex: secIdx,
                                    offset: UInt64(fragOffset + fix.offsetInInst),
                                    kind: fix.kind,
                                    symbol: fix.symbol,
                                    addend: fix.addend
                                )
                            )
                        } else if fix.resolveIfSameSection,
                           let targetOff = localLabels[fix.symbol],
                           (symbolAttrs[fix.symbol]?.binding ?? .local) == .local {
                            let disp = targetOff + fix.addend - Int64(fragOffset)
                            patchSameSectionFixup(&patched, fixup: fix, displacementFromInstStart: disp, instLength: patched.count)
                            if fix.kind == .riscv_pcrel_hi20 {
                                resolvedPCRelHi20 = true
                            }
                        } else if fix.minusSymbol == nil, let value = constants[fix.symbol], let width = absoluteFixupWidth(fix.kind) {
                            let u = UInt64(bitPattern: value &+ fix.addend)
                            for bIdx in 0..<width where fix.offsetInInst + bIdx < patched.count {
                                patched[fix.offsetInInst + bIdx] = UInt8(truncatingIfNeeded: u >> (8 * UInt64(bIdx)))
                            }
                        } else {
                            noteSymbol(fix.symbol)
                            pendingRelocs.append(
                                PendingReloc(
                                    sectionIndex: secIdx,
                                    offset: UInt64(fragOffset + fix.offsetInInst),
                                    kind: fix.kind,
                                    symbol: fix.symbol,
                                    addend: fix.addend
                                )
                            )
                        }
                    }
                    bytes.append(contentsOf: patched)

                case .relaxable(let branch, let form, let loc):
                    if case .rvBranch(let baseInst, _, let targetSym, let addend) = branch,
                       spansRelaxBarrier(secIdx, fragIndex, labelIndex[targetSym]) {
                        // The linker may change the distance: keep the form chosen by distance, with a relocation.
                        let (instBytes, r) = encodeUnresolvedRVBranch(baseInst: baseInst, form: form, targetSymbol: targetSym, addend: addend)
                        noteSymbol(targetSym)
                        pendingRelocs.append(PendingReloc(sectionIndex: secIdx, offset: UInt64(fragOffset + r.offsetInInst), kind: r.kind, symbol: targetSym, addend: addend))
                        bytes.append(contentsOf: instBytes)
                        break
                    }
                    var outOfRange = false
                    let (instBytes, relocOpt) = encodeRelaxedBranch(
                        branch: branch,
                        form: form,
                        instOffset: Int64(fragOffset),
                        localLabels: localLabels,
                        outOfRange: &outOfRange
                    )
                    if outOfRange {
                        diagnostics.report(.asmBranchOutOfRange, at: loc)
                    }
                    if let r = relocOpt {
                        noteSymbol(r.symbol)
                        pendingRelocs.append(
                            PendingReloc(
                                sectionIndex: secIdx,
                                offset: UInt64(fragOffset + r.offsetInInst),
                                kind: r.kind,
                                symbol: r.symbol,
                                addend: r.addend
                            )
                        )
                    }
                    bytes.append(contentsOf: instBytes)

                case .align(let alignBytes, let fillByte, let maxBytes):
                    let padCount = computeAlignPadding(currentOffset: fragOffset, alignBytes: alignBytes, maxBytes: maxBytes)
                    if padCount > 0 {
                        appendAlignmentPadding(&bytes, count: padCount, fillByte: fillByte, isExec: sec.flags.contains(.execInstr))
                    }

                case .dataExpr(let width, let exprStr, let loc):
                    // `.` stays symbolic (it is a location, not a constant) so that `sym - .` becomes a
                    // PC-relative relocation; differences against same-section labels still fold.
                    var dotLabels = localLabels
                    dotLabels["."] = Int64(fragOffset)
                    var valOpt = AsmExprEvaluator.evaluate(
                        exprStr,
                        constants: constants,
                        currentSectionSymbols: dotLabels
                    )
                    // Under RISC-V linker relaxation a label difference folds only if no barrier lies between
                    // the labels: keep it symbolic so the `.symbolDiff` case below decides.
                    if case .constant = valOpt, barriersBySection.contains(where: { !$0.isEmpty }),
                       case .symbolDiff? = AsmExprEvaluator.evaluate(exprStr, constants: constants) {
                        valOpt = AsmExprEvaluator.evaluate(exprStr, constants: constants)
                    }
                    func dotLabel() -> String {
                        let name = ".Ldot_\(secIdx)_\(fragOffset)"
                        noteSymbol(name)
                        definedLabels[name] = (sectionIndex: secIdx, offset: Int64(fragOffset))
                        return name
                    }
                    func addReloc(_ kind: RelocKind, _ sym: String, _ addend: Int64) {
                        noteSymbol(sym)
                        pendingRelocs.append(PendingReloc(sectionIndex: secIdx, offset: UInt64(fragOffset), kind: kind, symbol: sym, addend: addend))
                    }
                    func reportInvalid() {
                        diagnostics.report(.asmInvalidExpression, at: loc, args: [exprStr])
                    }
                    switch valOpt {
                    case .constant(let v):
                        appendLittleEndian(v, width: width, to: &bytes)
                    case .symbolOffset(let sym, let addend, _):
                        if let kind = dataRelocKind(width: width, isPCRel: false) {
                            addReloc(kind, sym == "." ? dotLabel() : sym, addend)
                        } else {
                            reportInvalid()
                        }
                        appendLittleEndian(0, width: width, to: &bytes)
                    case .symbolDiff(let plusSym, let minusSym, let addend):
                        if let pDef = definedLabels[plusSym],
                           let mDef = (minusSym == "." ? (sectionIndex: secIdx, offset: Int64(fragOffset)) : definedLabels[minusSym]),
                           pDef.sectionIndex == mDef.sectionIndex,
                           !spansRelaxBarrier(pDef.sectionIndex, labelIndexBySection[pDef.sectionIndex][plusSym],
                                              minusSym == "." ? fragIndex : labelIndexBySection[mDef.sectionIndex][minusSym]) {
                            appendLittleEndian((pDef.offset - mDef.offset) + addend, width: width, to: &bytes)
                        } else if arch == .riscv64, let addKind = riscvPairKinds(width: width) {
                            // RISC-V encodes symbol differences as an ADD/SUB relocation pair (as GNU `as`/LLVM do).
                            addReloc(addKind.add, plusSym, addend)
                            addReloc(addKind.sub, minusSym == "." ? dotLabel() : minusSym, 0)
                            appendLittleEndian(0, width: width, to: &bytes)
                        } else if minusSym == ".", let kind = dataRelocKind(width: width, isPCRel: true) {
                            addReloc(kind, plusSym, addend)
                            appendLittleEndian(0, width: width, to: &bytes)
                        } else if let mDef = definedLabels[minusSym], mDef.sectionIndex == secIdx,
                                  let kind = dataRelocKind(width: width, isPCRel: true) {
                            // `A - B` with `B` in this section is `A - P + (P - B)`: LLVM MC emits a PC-relative
                            // relocation against `A` with `P - B` folded into the addend (e.g. the vDSO header's
                            // `.long <entry point> - vdso_header` in VectraOS user/vdso/header.S).
                            addReloc(kind, plusSym, addend + Int64(fragOffset) - mDef.offset)
                            appendLittleEndian(0, width: width, to: &bytes)
                        } else {
                            reportInvalid()
                            appendLittleEndian(0, width: width, to: &bytes)
                        }
                    case nil:
                        reportInvalid()
                        appendLittleEndian(0, width: width, to: &bytes)
                    }

                case .fill(let countExpr, let unitSize, let fillValue, _):
                    let cnt = Int(AsmExprEvaluator.evaluate(countExpr, constants: constants, currentSectionSymbols: localLabels, dotOffset: Int64(fragOffset))?.constantValue ?? 0)
                    if cnt > 0 {
                        for _ in 0..<cnt {
                            appendLittleEndian(fillValue, width: min(8, unitSize), to: &bytes)
                            if unitSize > 8 {
                                bytes.append(contentsOf: repeatElement(UInt8(0), count: unitSize - 8))
                            }
                        }
                    }
                }
            }

            obj.appendSectionBytes(sHandle, bytes)
        }

        // Relocations against `.set alias, extern + c` refer to `extern` with the addend folded in
        if !externalAliases.isEmpty {
            pendingRelocs = pendingRelocs.map { r in
                guard let alias = externalAliases[r.symbol] else { return r }
                noteSymbol(alias.symbol)
                return PendingReloc(sectionIndex: r.sectionIndex, offset: r.offset, kind: r.kind, symbol: alias.symbol, addend: r.addend &+ alias.addend)
            }
        }

        // 4. Populate Symbol Table
        // Note: temporary `.L*` labels are omitted from `.symtab` UNLESS they are referenced by a relocation
        // (such as `.Lpcrel_hi0` on RV64!).
        let relocReferencedSymbols = Set(pendingRelocs.map { $0.symbol })
        var symHandleByName: [String: SymbolIndex] = [:]

        // If any relocation references a local symbol in another section (like `.bss.no_percpu` or `boot_stack`),
        // make sure it's in `symbolMentionOrder`.
        for symName in symbolMentionOrder {
            let attrs = symbolAttrs[symName] ?? AsmSymbolAttrs()
            let isDefined = definedLabels[symName] != nil || constants[symName] != nil
            let isReferenced = relocReferencedSymbols.contains(symName)
            let isTempLabel = symName.hasPrefix(".L")

            if isTempLabel && !isReferenced && attrs.binding == .local {
                continue
            }
            if !isDefined && !isReferenced && attrs.binding == .local {
                continue
            }

            let symSec: SectionIndex
            let symVal: UInt64
            if let def = definedLabels[symName] {
                symSec = objSectionIndices[def.sectionIndex]
                symVal = UInt64(bitPattern: def.offset)
            } else if let cVal = constants[symName] {
                symSec = .absolute
                symVal = UInt64(bitPattern: cVal)
            } else {
                symSec = .undefined
                symVal = 0
            }

            // Undeclared external symbols referenced by relocations default to `.global`
            let effectiveBinding: SymbolBinding
            if symSec == .undefined && attrs.binding == .local {
                effectiveBinding = .global
            } else {
                effectiveBinding = attrs.binding
            }

            var symSize: UInt64 = 0
            if let sizeExpr = attrs.sizeExpr {
                let secLabels = definedLabels[symName].map { sectionSymbolOffsets[$0.sectionIndex] } ?? [:]
                if let c = AsmExprEvaluator.evaluate(sizeExpr, constants: constants, currentSectionSymbols: secLabels)?.constantValue {
                    symSize = UInt64(bitPattern: c)
                } else {
                    diagnostics.report(.asmInvalidExpression, at: attrs.sizeLoc, args: [".size \(symName), \(sizeExpr)"])
                }
            }

            let handle = obj.addSymbol(
                name: symName,
                section: symSec,
                value: symVal,
                size: symSize,
                binding: effectiveBinding,
                visibility: attrs.visibility,
                kind: attrs.kind
            )
            symHandleByName[symName] = handle
        }

        // 5. Attach Relocations to Sections (`R_RISCV_RELAX`/`R_RISCV_ALIGN` have no symbol)
        for pr in pendingRelocs {
            guard let symHandle = pr.symbol.isEmpty ? SymbolIndex.nilId : symHandleByName[pr.symbol] else { continue }
            let sHandle = objSectionIndices[pr.sectionIndex]
            obj.addRelocation(
                to: sHandle,
                offset: pr.offset,
                symbol: symHandle,
                kind: pr.kind,
                addend: pr.addend
            )
        }

        return obj
    }

    // MARK: - Deferred `.equ`/`.set` Resolution

    /// `constants` plus each label-dependent assignment that `labels` (one section's layout) resolves.
    private func constantsResolvingDeferred(labels: [String: Int64]) -> [String: Int64] {
        var result = constants
        for _ in 0..<2 {   // a second round resolves assignments that refer to other assignments
            for (sym, entry) in deferredAssignments where result[sym] == nil {
                if let v = AsmExprEvaluator.evaluate(entry.expr, constants: result, currentSectionSymbols: labels)?.constantValue {
                    result[sym] = v
                }
            }
        }
        return result
    }

    /// Resolves label-dependent assignments after layout: to a constant (`SHN_ABS` symbol, as in LLVM MC), to a
    /// label plus offset in a section (an alias defined there), or to an undefined symbol plus addend (references
    /// are redirected to that symbol). Anything else is an invalid expression.
    private func resolveDeferredAssignments(sectionSymbolOffsets: [[String: Int64]], diagnostics: inout DiagnosticBag) {
        var pending = deferredAssignments
        var progress = true
        while progress && !pending.isEmpty {
            progress = false
            for sym in pending.keys.sorted() {
                guard let entry = pending[sym] else { continue }
                var value: AsmExprValue? = AsmExprEvaluator.evaluate(entry.expr, constants: constants)
                for labels in sectionSymbolOffsets {
                    if case .constant = value { break }
                    if case .constant(let c)? = AsmExprEvaluator.evaluate(entry.expr, constants: constants, currentSectionSymbols: labels) {
                        value = .constant(c)
                    }
                }
                switch value {
                case .constant(let c)?:
                    constants[sym] = c
                case .symbolOffset(let target, let addend, .none)?:
                    if pending[target] != nil && target != sym { continue }
                    if let def = definedLabels[target] {
                        definedLabels[sym] = (sectionIndex: def.sectionIndex, offset: def.offset + addend)
                    } else if let alias = externalAliases[target] {
                        externalAliases[sym] = (alias.symbol, alias.addend + addend)
                    } else {
                        externalAliases[sym] = (target, addend)
                    }
                default:
                    continue
                }
                pending[sym] = nil
                progress = true
            }
        }
        for sym in pending.keys.sorted() {
            if let entry = pending[sym] {
                diagnostics.report(.asmInvalidExpression, at: entry.loc, args: [entry.expr])
            }
        }
        deferredAssignments = [:]
    }

    /// Width of an absolute x86-64 fixup that can be patched in place when its symbol is an assembly-time
    /// constant (e.g. `movl $len, %eax` before `.equ len, end - start`); nil for every other kind.
    private func absoluteFixupWidth(_ kind: RelocKind) -> Int? {
        switch kind {
        case .x86_64_64:              return 8
        case .x86_64_32, .x86_64_32s: return 4
        case .x86_64_16:              return 2
        case .x86_64_8:               return 1
        default:                      return nil
        }
    }

    // MARK: - Relaxation & Patching Helpers

    private func computeAlignPadding(currentOffset: Int, alignBytes: Int, maxBytes: Int) -> Int {
        guard alignBytes > 1 else { return 0 }
        let rem = currentOffset % alignBytes
        guard rem != 0 else { return 0 }
        let pad = alignBytes - rem
        if maxBytes > 0 && pad > maxBytes {
            return 0
        }
        return pad
    }

    private func appendAlignmentPadding(_ bytes: inout [UInt8], count: Int, fillByte: UInt8?, isExec: Bool) {
        if let fill = fillByte {
            bytes.append(contentsOf: repeatElement(fill, count: count))
            return
        }
        if !isExec {
            bytes.append(contentsOf: repeatElement(UInt8(0), count: count))
            return
        }
        switch arch {
        case .x86_64:
            if x86CodeMode != .mode64 {
                bytes.append(contentsOf: repeatElement(UInt8(0x90), count: count))
                return
            }
            var rem = count
            while rem > 0 {
                let chunk = min(rem, 9)
                switch chunk {
                case 1: bytes.append(0x90)
                case 2: bytes.append(contentsOf: [0x66, 0x90])
                case 3: bytes.append(contentsOf: [0x0F, 0x1F, 0x00])
                case 4: bytes.append(contentsOf: [0x0F, 0x1F, 0x40, 0x00])
                case 5: bytes.append(contentsOf: [0x0F, 0x1F, 0x44, 0x00, 0x00])
                case 6: bytes.append(contentsOf: [0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00])
                case 7: bytes.append(contentsOf: [0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00])
                case 8: bytes.append(contentsOf: [0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00])
                default: bytes.append(contentsOf: [0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00])
                }
                rem -= chunk
            }
        case .aarch64:
            var rem = count
            while rem >= 4 {
                // A64 NOP = 0xD503201F
                bytes.append(contentsOf: [0x1F, 0x20, 0x03, 0xD5])
                rem -= 4
            }
            if rem > 0 {
                bytes.append(contentsOf: repeatElement(UInt8(0), count: rem))
            }
        case .riscv64:
            appendRISCVNops(&bytes, count: count, rvc: rvOptions.rvcEnabled)
        }
    }

    /// Encoded size of a relaxable branch in a given form (`05-assembler.md` §4.5).
    /// Forms only ever grow: x86 `rel8` → `rel32`; A64 short → inverted branch over `B`;
    /// RV64 compressed → 32-bit → inverted branch over `jal`.
    private func relaxableSize(branch: AsmRelaxableBranch, form: Int) -> Int {
        switch branch {
        case .x86Branch(let isCond, _, _, _):
            if form == 0 { return 2 }
            return isCond ? 6 : 5
        case .a64Branch:
            return form == 0 ? 4 : 8
        case .rvBranch:
            switch form {
            case 0: return 2
            case 1: return 4
            default: return 8
            }
        }
    }

    /// Returns the next larger form if the branch does not fit its current form, or nil if it fits
    /// (or no larger form exists, in which case `encodeRelaxedBranch` reports the range error).
    private func grownForm(
        branch: AsmRelaxableBranch,
        form: Int,
        instOffset: Int64,
        localLabels: [String: Int64]
    ) -> Int? {
        switch branch {
        case .x86Branch(_, _, let targetSym, let addend):
            guard form == 0 else { return nil }
            // External or cross-section symbols always use the long form
            guard let targetOff = localLabels[targetSym] else { return 1 }
            let disp = (targetOff + addend) - (instOffset + 2)
            return (disp < -128 || disp > 127) ? 1 : nil

        case .a64Branch(let baseInst, let targetSym, let addend):
            guard form == 0, let targetOff = localLabels[targetSym] else { return nil }
            let disp = (targetOff + addend) - instOffset
            switch A64InstructionTable.descriptor(for: baseInst.opcode).format {
            case .testBranch14:
                return A64Encoder.pcRelInRange(disp, bits: 14) ? nil : 1
            case .branchCond19, .compareBranch19:
                return A64Encoder.pcRelInRange(disp, bits: 19) ? nil : 1
            default:
                return nil
            }

        case .rvBranch(let baseInst, _, let targetSym, let addend):
            guard let targetOff = localLabels[targetSym] else {
                // External targets use the 32-bit form with a relocation
                return form == 0 ? 1 : nil
            }
            let disp = (targetOff + addend) - instOffset
            let isJump = (baseInst.opcode == .c_j || baseInst.opcode == .jal)
            switch form {
            case 0:
                let limit: Int64 = isJump ? 2048 : 256
                return (disp < -limit || disp >= limit || (disp & 1) != 0) ? 1 : nil
            case 1:
                if isJump { return nil }
                return (disp < -4096 || disp >= 4096 || (disp & 1) != 0) ? 2 : nil
            default:
                return nil
            }
        }
    }

    private static func rvUncompressed(_ inst: RV64Instruction) -> RV64Instruction {
        switch inst.opcode {
        case .c_j:    return RV64Instruction(opcode: .jal, rd: RVGPR.zero.rawValue)
        case .c_beqz: return RV64Instruction(opcode: .beq, rs1: inst.rs1, rs2: RVGPR.zero.rawValue)
        case .c_bnez: return RV64Instruction(opcode: .bne, rs1: inst.rs1, rs2: RVGPR.zero.rawValue)
        default:      return inst
        }
    }

    private static func rvInvertedBranch(_ op: RV64Opcode) -> RV64Opcode {
        switch op {
        case .beq:  return .bne
        case .bne:  return .beq
        case .blt:  return .bge
        case .bge:  return .blt
        case .bltu: return .bgeu
        default:    return .bltu
        }
    }

    /// Encodes a relaxable branch in its final form. `outOfRange` is set when the target does not fit
    /// even the largest form; the caller reports a diagnostic instead of emitting a truncated displacement.
    private func encodeRelaxedBranch(
        branch: AsmRelaxableBranch,
        form: Int,
        instOffset: Int64,
        localLabels: [String: Int64],
        outOfRange: inout Bool
    ) -> ([UInt8], AsmInstFixup?) {
        switch branch {
        case .x86Branch(let isCond, let cc, let targetSym, let addend):
            let size = relaxableSize(branch: branch, form: form)
            if let targetOff = localLabels[targetSym] {
                let disp = (targetOff + addend) - (instOffset + Int64(size))
                if form == 0 {
                    let opcode: UInt8 = isCond ? (0x70 + (cc & 0x0F)) : 0xEB
                    return ([opcode, UInt8(bitPattern: Int8(truncatingIfNeeded: disp))], nil)
                }
                if disp < Int64(Int32.min) || disp > Int64(Int32.max) { outOfRange = true }
                var out: [UInt8] = isCond ? [0x0F, 0x80 + (cc & 0x0F)] : [0xE9]
                appendLittleEndian(disp, width: 4, to: &out)
                return (out, nil)
            }
            // External or cross-section branch -> emit 32-bit PLT32 relocation
            let out: [UInt8] = isCond ? [0x0F, 0x80 + (cc & 0x0F), 0, 0, 0, 0] : [0xE9, 0, 0, 0, 0]
            let fixup = AsmInstFixup(
                offsetInInst: isCond ? 2 : 1,
                kind: .x86_64_plt32,
                symbol: targetSym,
                addend: addend - 4
            )
            return (out, fixup)

        case .a64Branch(var baseInst, let targetSym, let addend):
            if let targetOff = localLabels[targetSym],
               (baseInst.opcode != .bl || (symbolAttrs[targetSym]?.binding ?? .local) == .local) {
                let disp = (targetOff + addend) - instOffset
                if form == 0 {
                    baseInst.imm = disp
                    if let bytes = A64Encoder.encodeBytes(baseInst) { return (bytes, nil) }
                    outOfRange = true
                    return ([0, 0, 0, 0], nil)
                }
                // Inverted conditional branch skipping over an unconditional `B` to the target
                var skip = baseInst
                switch baseInst.opcode {
                case .bCond: skip.cond = baseInst.cond.inverted
                case .cbz:   skip.opcode = .cbnz
                case .cbnz:  skip.opcode = .cbz
                case .tbz:   skip.opcode = .tbnz
                default:     skip.opcode = .tbz
                }
                skip.imm = 8
                let far = A64Instruction(opcode: .b, imm: disp - 4)
                guard let b0 = A64Encoder.encodeBytes(skip), let b1 = A64Encoder.encodeBytes(far) else {
                    outOfRange = true
                    return ([UInt8](repeating: 0, count: 8), nil)
                }
                return (b0 + b1, nil)
            }
            // External symbol -> encode with imm=0 and attach relocation
            baseInst.imm = 0
            let bytes = A64Encoder.encodeBytes(baseInst) ?? [0, 0, 0, 0]
            let rKind: RelocKind
            switch A64InstructionTable.descriptor(for: baseInst.opcode).format {
            case .branchImm26:
                rKind = (baseInst.opcode == .bl) ? .aarch64_call26 : .aarch64_jump26
            case .branchCond19, .compareBranch19:
                rKind = .aarch64_condbr19
            case .testBranch14:
                rKind = .aarch64_tstbr14
            default:
                rKind = .aarch64_jump26
            }
            return (bytes, AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: targetSym, addend: addend))

        case .rvBranch(let baseInst, _, let targetSym, let addend):
            if let targetOff = localLabels[targetSym] {
                let disp = (targetOff + addend) - instOffset
                switch form {
                case 0:
                    var inst = baseInst
                    inst.imm = disp
                    return (RV64Encoder.encode(inst, rvcEnabled: true), nil)
                case 1:
                    var inst = Self.rvUncompressed(baseInst)
                    inst.imm = disp
                    let limit: Int64 = (inst.opcode == .jal) ? (1 << 20) : (1 << 12)
                    if disp < -limit || disp >= limit || (disp & 1) != 0 { outOfRange = true }
                    return (RV64Encoder.encode(inst, rvcEnabled: false), nil)
                default:
                    // Inverted branch over `jal x0, target`
                    let wide = Self.rvUncompressed(baseInst)
                    let skip = RV64Instruction(opcode: Self.rvInvertedBranch(wide.opcode), rs1: wide.rs1, rs2: wide.rs2, imm: 8)
                    let jalDisp = disp - 4
                    if jalDisp < -(1 << 20) || jalDisp >= (1 << 20) || (jalDisp & 1) != 0 { outOfRange = true }
                    let jal = RV64Instruction(opcode: .jal, rd: RVGPR.zero.rawValue, imm: jalDisp)
                    return (RV64Encoder.encode(skip, rvcEnabled: false) + RV64Encoder.encode(jal, rvcEnabled: false), nil)
                }
            }
            // External symbol -> emit 32-bit branch/jump with relocation
            var extInst = Self.rvUncompressed(baseInst)
            extInst.imm = 0
            let bytes = RV64Encoder.encode(extInst, rvcEnabled: false)
            let rKind: RelocKind = (extInst.opcode == .jal) ? .riscv_jal : .riscv_branch
            return (bytes, AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: targetSym, addend: addend))
        }
    }

    /// A RISC-V branch or jump whose target is in the same section but across a linker-relaxation barrier: the
    /// form already chosen by distance (LLVM MC keeps `c.j`/`c.beqz` with `R_RISCV_RVC_*`), with a zero immediate.
    private func encodeUnresolvedRVBranch(baseInst: RV64Instruction, form: Int, targetSymbol: String, addend: Int64) -> ([UInt8], AsmInstFixup) {
        switch form {
        case 0:
            var inst = baseInst
            inst.imm = 0
            let kind: RelocKind = inst.opcode == .c_j ? .riscv_rvc_jump : .riscv_rvc_branch
            return (RV64Encoder.encode(inst, rvcEnabled: true), AsmInstFixup(offsetInInst: 0, kind: kind, symbol: targetSymbol, addend: addend))
        case 1:
            var inst = Self.rvUncompressed(baseInst)
            inst.imm = 0
            let kind: RelocKind = inst.opcode == .jal ? .riscv_jal : .riscv_branch
            return (RV64Encoder.encode(inst, rvcEnabled: false), AsmInstFixup(offsetInInst: 0, kind: kind, symbol: targetSymbol, addend: addend))
        default:
            let wide = Self.rvUncompressed(baseInst)
            let skip = RV64Instruction(opcode: Self.rvInvertedBranch(wide.opcode), rs1: wide.rs1, rs2: wide.rs2, imm: 8)
            let jal = RV64Instruction(opcode: .jal, rd: RVGPR.zero.rawValue, imm: 0)
            return (RV64Encoder.encode(skip, rvcEnabled: false) + RV64Encoder.encode(jal, rvcEnabled: false),
                    AsmInstFixup(offsetInInst: 4, kind: .riscv_jal, symbol: targetSymbol, addend: addend))
        }
    }

    private func patchSameSectionFixup(
        _ bytes: inout [UInt8],
        fixup: AsmInstFixup,
        displacementFromInstStart disp: Int64,
        instLength: Int
    ) {
        switch fixup.kind {
        case .x86_64_pc32, .x86_64_plt32:
            // Note: X86TableEncoder subtracted `(instLength - offsetInInst)` into `fixup.addend`,
            // so subtracting `fixup.offsetInInst` yields `targetOff + rawAddend - (fragOffset + instLength)`.
            let rel32 = disp - Int64(fixup.offsetInInst)
            let v32 = UInt32(bitPattern: Int32(truncatingIfNeeded: rel32))
            let off = fixup.offsetInInst
            if off + 4 <= bytes.count {
                bytes[off]     = UInt8(truncatingIfNeeded: v32)
                bytes[off + 1] = UInt8(truncatingIfNeeded: v32 >> 8)
                bytes[off + 2] = UInt8(truncatingIfNeeded: v32 >> 16)
                bytes[off + 3] = UInt8(truncatingIfNeeded: v32 >> 24)
            }
        case .aarch64_adr_prel_lo21:
            if bytes.count >= 4 {
                var word = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
                let u21 = UInt32(bitPattern: Int32(truncatingIfNeeded: disp)) & 0x1F_FFFF
                let immlo = u21 & 0x3
                let immhi = (u21 >> 2) & 0x7_FFFF
                word &= ~((0x3 << 29) | (0x7_FFFF << 5))
                word |= (immlo << 29) | (immhi << 5)
                bytes[0] = UInt8(truncatingIfNeeded: word)
                bytes[1] = UInt8(truncatingIfNeeded: word >> 8)
                bytes[2] = UInt8(truncatingIfNeeded: word >> 16)
                bytes[3] = UInt8(truncatingIfNeeded: word >> 24)
            }
        case .aarch64_ld_prel_lo19:
            if bytes.count >= 4 {
                var word = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
                let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: disp >> 2)) & 0x7_FFFF
                word &= ~(0x7_FFFF << 5)
                word |= (imm19 << 5)
                bytes[0] = UInt8(truncatingIfNeeded: word)
                bytes[1] = UInt8(truncatingIfNeeded: word >> 8)
                bytes[2] = UInt8(truncatingIfNeeded: word >> 16)
                bytes[3] = UInt8(truncatingIfNeeded: word >> 24)
            }
        case .riscv_pcrel_hi20:
            // Patch `auipc` at bytes[0..<4] with `hi20 = (disp + 0x800) >> 12`,
            // and if bytes.count >= 8 (`lla` / `la` pair), also patch `addi`/`ld` at bytes[4..<8] with `lo12 = disp & 0xFFF`.
            if bytes.count >= 4 {
                var word0 = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
                let hi20 = UInt32(bitPattern: Int32(truncatingIfNeeded: (disp + 0x800) >> 12)) & 0xF_FFFF
                word0 = (word0 & 0x0000_0FFF) | (hi20 << 12)
                bytes[0] = UInt8(truncatingIfNeeded: word0)
                bytes[1] = UInt8(truncatingIfNeeded: word0 >> 8)
                bytes[2] = UInt8(truncatingIfNeeded: word0 >> 16)
                bytes[3] = UInt8(truncatingIfNeeded: word0 >> 24)
            }
            if bytes.count >= 8 {
                var word1 = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
                let lo12 = UInt32(bitPattern: Int32(truncatingIfNeeded: disp)) & 0xFFF
                word1 = (word1 & 0x000F_FFFF) | (lo12 << 20)
                bytes[4] = UInt8(truncatingIfNeeded: word1)
                bytes[5] = UInt8(truncatingIfNeeded: word1 >> 8)
                bytes[6] = UInt8(truncatingIfNeeded: word1 >> 16)
                bytes[7] = UInt8(truncatingIfNeeded: word1 >> 24)
            }
        default:
            break
        }
    }

    private func dataRelocKind(width: Int, isPCRel: Bool) -> RelocKind? {
        switch (arch, isPCRel, width) {
        case (.x86_64, false, 8):  return .x86_64_64
        case (.x86_64, false, 4):  return .x86_64_32
        case (.x86_64, false, 2):  return .x86_64_16
        case (.x86_64, false, 1):  return .x86_64_8
        case (.x86_64, true, 8):   return .x86_64_pc64
        case (.x86_64, true, 4):   return .x86_64_pc32
        case (.x86_64, true, 2):   return .x86_64_pc16
        case (.x86_64, true, 1):   return .x86_64_pc8
        case (.aarch64, false, 8): return .aarch64_abs64
        case (.aarch64, false, 4): return .aarch64_abs32
        case (.aarch64, false, 2): return .aarch64_abs16
        case (.aarch64, true, 8):  return .aarch64_prel64
        case (.aarch64, true, 4):  return .aarch64_prel32
        case (.aarch64, true, 2):  return .aarch64_prel16
        case (.riscv64, false, 8): return .riscv_64
        case (.riscv64, false, 4): return .riscv_32
        case (.riscv64, true, 4):  return .riscv_32_pcrel
        default:                   return nil
        }
    }

    private func riscvPairKinds(width: Int) -> (add: RelocKind, sub: RelocKind)? {
        switch width {
        case 1: return (.riscv_add8, .riscv_sub8)
        case 2: return (.riscv_add16, .riscv_sub16)
        case 4: return (.riscv_add32, .riscv_sub32)
        case 8: return (.riscv_add64, .riscv_sub64)
        default: return nil
        }
    }

    private func appendLittleEndian(_ value: Int64, width: Int, to bytes: inout [UInt8]) {
        let u = UInt64(bitPattern: value)
        for i in 0..<width {
            bytes.append(UInt8(truncatingIfNeeded: u >> (i * 8)))
        }
    }

    private func synthesizeEhFrameIfNeeded(
        sectionSymbolOffsets: inout [[String: Int64]],
        sectionTotalSizes: inout [Int]
    ) {
        let records = cfiBuilder.buildEhFrame { label in
            self.definedLabels[label].map { ($0.sectionIndex, $0.offset) }
        }
        guard !records.isEmpty else { return }

        let ehIdx = getOrCreateSection(name: ".eh_frame", kind: .ehFrame, flags: [.alloc], alignLog2: 3)
        let ehSec = sections[ehIdx]
        let pcRel32: RelocKind
        switch arch {
        case .x86_64:  pcRel32 = .x86_64_pc32
        case .aarch64: pcRel32 = .aarch64_prel32
        case .riscv64: pcRel32 = .riscv_32_pcrel
        }
        var size = 0
        for record in records {
            // FDE `pc_begin` (after the length and CIE_pointer words) is a PC-relative reference to the function
            let fixups = record.pcBeginLabel.map { [AsmInstFixup(offsetInInst: 8, kind: pcRel32, symbol: $0, addend: 0)] } ?? []
            ehSec.emitBytes(record.bytes, fixups: fixups)
            size += record.bytes.count
        }

        if ehIdx >= sectionSymbolOffsets.count {
            sectionSymbolOffsets.append([:])
            sectionTotalSizes.append(size)
        } else {
            sectionTotalSizes[ehIdx] += size
        }
    }
}

/// Mutable options state for RV64 `.option` directives, and the initial state a driver sets from the target
/// (`-march`, `-fPIC`/`-fPIE`, `-mrelax`/`-mno-relax`). The default is Swift-Stack's RVA23 baseline without
/// linker relaxation; clang's default enables relaxation.
public struct RVAsmOptions: Sendable {
    public var rvcEnabled: Bool = true
    /// Linker relaxation (`.option relax`): relaxable relocations get an `R_RISCV_RELAX` companion, code alignment
    /// emits worst-case NOPs plus `R_RISCV_ALIGN`, and PC-relative differences that span either stay relocations.
    public var relaxEnabled: Bool = false
    public var picEnabled: Bool = false
    /// Zbs is available, so `li` may materialize a single high bit with `bseti` (LLVM `RISCVMatInt`).
    public var zbsEnabled: Bool = true

    public init() {}

    /// Options for `-march=<isa>` (e.g. `rv64imac_zicsr_zifencei`, `rv64gc`, `rv64gcb_zbs`): the C extension enables
    /// compression and Zbs (or B) enables `bseti` in `li`. `pic` and `relax` give the initial `.option` state.
    public init(march: String, pic: Bool = false, relax: Bool = false) {
        let isa = march.lowercased()
        var parts = isa.split(separator: "_").map(String.init)
        let base = parts.isEmpty ? "" : parts.removeFirst()
        // Single-letter extensions follow `rv64`; `g` is `imafd_zicsr_zifencei`.
        let letters = base.hasPrefix("rv64") ? Set(base.dropFirst(4)) : []
        rvcEnabled = letters.contains("c") || parts.contains("zca")
        zbsEnabled = letters.contains("b") || parts.contains("zbs")
        picEnabled = pic
        relaxEnabled = relax
    }
}
