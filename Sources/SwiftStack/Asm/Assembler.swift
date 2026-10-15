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

/// Evaluates GNU `as` integer and symbolic expressions with full C/GNU operator precedence.
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

        var tokens = tokenizeExpr(trimmed)
        var pos = 0
        guard let result = parseLogicalOr(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
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

    // Recursive descent parser

    private static func parseLogicalOr(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseLogicalAnd(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count, tokens[pos] == .op("||") {
            pos += 1
            guard let rhs = parseLogicalAnd(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                  let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
            lhs = .constant((l != 0 || r != 0) ? 1 : 0)
        }
        return lhs
    }

    private static func parseLogicalAnd(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseBitwiseOr(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count, tokens[pos] == .op("&&") {
            pos += 1
            guard let rhs = parseBitwiseOr(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                  let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
            lhs = .constant((l != 0 && r != 0) ? 1 : 0)
        }
        return lhs
    }

    private static func parseBitwiseOr(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseBitwiseXor(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count, tokens[pos] == .op("|") {
            pos += 1
            guard let rhs = parseBitwiseXor(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                  let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
            lhs = .constant(l | r)
        }
        return lhs
    }

    private static func parseBitwiseXor(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseBitwiseAnd(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count, tokens[pos] == .op("^") {
            pos += 1
            guard let rhs = parseBitwiseAnd(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                  let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
            lhs = .constant(l ^ r)
        }
        return lhs
    }

    private static func parseBitwiseAnd(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseEquality(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count, tokens[pos] == .op("&") {
            pos += 1
            guard let rhs = parseEquality(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                  let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
            lhs = .constant(l & r)
        }
        return lhs
    }

    private static func parseEquality(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseRelational(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count {
            if tokens[pos] == .op("==") || tokens[pos] == .op("!=") {
                let isEq = (tokens[pos] == .op("=="))
                pos += 1
                guard let rhs = parseRelational(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                      let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
                lhs = .constant((isEq ? (l == r) : (l != r)) ? 1 : 0)
            } else {
                break
            }
        }
        return lhs
    }

    private static func parseRelational(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseShift(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count {
            if case .op(let op) = tokens[pos], op == "<" || op == "<=" || op == ">" || op == ">=" {
                pos += 1
                guard let rhs = parseShift(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                      let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
                let b: Bool
                switch op {
                case "<":  b = l < r
                case "<=": b = l <= r
                case ">":  b = l > r
                default:   b = l >= r
                }
                lhs = .constant(b ? 1 : 0)
            } else {
                break
            }
        }
        return lhs
    }

    private static func parseShift(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseAdditive(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count {
            if tokens[pos] == .op("<<") || tokens[pos] == .op(">>") {
                let isLeft = (tokens[pos] == .op("<<"))
                pos += 1
                guard let rhs = parseAdditive(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                      let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
                if isLeft {
                    lhs = .constant(Int64(bitPattern: UInt64(bitPattern: l) << UInt64(r & 63)))
                } else {
                    lhs = .constant(Int64(bitPattern: UInt64(bitPattern: l) >> UInt64(r & 63)))
                }
            } else {
                break
            }
        }
        return lhs
    }

    private static func parseAdditive(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseMultiplicative(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count {
            if tokens[pos] == .op("+") || tokens[pos] == .op("-") {
                let isPlus = (tokens[pos] == .op("+"))
                pos += 1
                guard let rhs = parseMultiplicative(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
                if isPlus {
                    switch (lhs, rhs) {
                    case (.constant(let a), .constant(let b)):
                        lhs = .constant(a &+ b)
                    case (.symbolOffset(let s, let a, let m), .constant(let b)):
                        lhs = .symbolOffset(symbol: s, addend: a &+ b, modifier: m)
                    case (.constant(let a), .symbolOffset(let s, let b, let m)):
                        lhs = .symbolOffset(symbol: s, addend: a &+ b, modifier: m)
                    case (.symbolDiff(let p, let m, let a), .constant(let b)):
                        lhs = .symbolDiff(plusSymbol: p, minusSymbol: m, addend: a &+ b)
                    case (.constant(let a), .symbolDiff(let p, let m, let b)):
                        lhs = .symbolDiff(plusSymbol: p, minusSymbol: m, addend: a &+ b)
                    default:
                        return nil
                    }
                } else {
                    switch (lhs, rhs) {
                    case (.constant(let a), .constant(let b)):
                        lhs = .constant(a &- b)
                    case (.symbolOffset(let s, let a, let m), .constant(let b)):
                        lhs = .symbolOffset(symbol: s, addend: a &- b, modifier: m)
                    case (.symbolDiff(let p, let m, let a), .constant(let b)):
                        lhs = .symbolDiff(plusSymbol: p, minusSymbol: m, addend: a &- b)
                    case (.symbolOffset(let s1, let a1, .none), .symbolOffset(let s2, let a2, .none)):
                        if s1 == s2 {
                            lhs = .constant(a1 &- a2)
                        } else if let v1 = currentSectionSymbols[s1], let v2 = currentSectionSymbols[s2] {
                            lhs = .constant((v1 &- v2) &+ (a1 &- a2))
                        } else {
                            lhs = .symbolDiff(plusSymbol: s1, minusSymbol: s2, addend: a1 &- a2)
                        }
                    default:
                        return nil
                    }
                }
            } else {
                break
            }
        }
        return lhs
    }

    private static func parseMultiplicative(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard var lhs = parseUnary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset) else { return nil }
        while pos < tokens.count {
            if case .op(let op) = tokens[pos], op == "*" || op == "/" || op == "%" {
                pos += 1
                guard let rhs = parseUnary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                      let l = lhs.constantValue, let r = rhs.constantValue else { return nil }
                switch op {
                case "*": lhs = .constant(l &* r)
                case "/":
                    guard r != 0 else { return nil }
                    lhs = .constant(l / r)
                default:
                    guard r != 0 else { return nil }
                    lhs = .constant(l % r)
                }
            } else {
                break
            }
        }
        return lhs
    }

    private static func parseUnary(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard pos < tokens.count else { return nil }
        if case .op(let op) = tokens[pos] {
            if op == "+" {
                pos += 1
                return parseUnary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)
            } else if op == "-" {
                pos += 1
                guard let v = parseUnary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)?.constantValue else { return nil }
                return .constant(0 &- v)
            } else if op == "~" {
                pos += 1
                guard let v = parseUnary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)?.constantValue else { return nil }
                return .constant(~v)
            } else if op == "!" {
                pos += 1
                guard let v = parseUnary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)?.constantValue else { return nil }
                return .constant(v == 0 ? 1 : 0)
            }
        }
        return parsePrimary(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset)
    }

    private static func parsePrimary(
        _ tokens: inout [ExprToken],
        _ pos: inout Int,
        constants: [String: Int64],
        currentSectionSymbols: [String: Int64],
        dotOffset: Int64?
    ) -> AsmExprValue? {
        guard pos < tokens.count else { return nil }
        switch tokens[pos] {
        case .int(let v):
            pos += 1
            return .constant(v)
        case .symbol(let sym, let mod):
            pos += 1
            if sym == "." {
                if let dot = dotOffset {
                    return .constant(dot)
                }
                return .symbolOffset(symbol: ".", addend: 0, modifier: .none)
            }
            if mod == .none, let c = constants[sym] {
                return .constant(c)
            }
            return .symbolOffset(symbol: sym, addend: 0, modifier: mod)
        case .lparen:
            pos += 1
            guard let inner = parseLogicalOr(&tokens, &pos, constants: constants, currentSectionSymbols: currentSectionSymbols, dotOffset: dotOffset),
                  pos < tokens.count, tokens[pos] == .rparen else { return nil }
            pos += 1
            return inner
        default:
            return nil
        }
    }
}

// MARK: - 3. Statement Lexing, Macros, Conditionals, and Local Labels (`05-assembler.md` §4.4)

/// A parsed line/statement of assembly after comment stripping and macro expansion.
public struct AsmStatement: Sendable {
    public let text: String
    public let lineNumber: Int

    public init(text: String, lineNumber: Int) {
        self.text = text
        self.lineNumber = lineNumber
    }
}

/// Macro definition for `.macro name params...` / `.endm`.
private struct AsmMacroDef {
    let name: String
    let params: [(name: String, defaultValue: String?)]
    let bodyLines: [(String, Int)]
}

/// Expands comments, multi-statement `;` lines, `.macro`/`.endm`, `.rept`/`.endr`, `.irp`/`.endr`,
/// `.if`/`.ifdef`/`.ifndef`/`.else`/`.endif`, and numeric local labels (`1:`, `1b`, `1f`).
public enum AsmMacroEngine {

    /// Strips comments according to `arch`, splits statements, expands macros/conditionals/rept,
    /// and rewrites numeric local labels (`0:`..`99:`, `0b`..`99b`, `0f`..`99f`) into unique synthetic labels.
    public static func expandStatements(
        source: String,
        arch: AssemblerArch,
        initialConstants: [String: Int64] = [:]
    ) -> [AsmStatement] {
        let rawLines = source.components(separatedBy: "\n")
        var cleanedStatements: [AsmStatement] = []
        cleanedStatements.reserveCapacity(rawLines.count)

        var inBlockComment = false
        for (idx, var line) in rawLines.enumerated() {
            let lineNum = idx + 1
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            let subStatements = stripCommentsAndSplit(line: line, arch: arch, inBlockComment: &inBlockComment)
            for s in subStatements {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    cleanedStatements.append(AsmStatement(text: trimmed, lineNumber: lineNum))
                }
            }
        }

        // Expand macros, .rept, .irp, and .if conditionals
        var macros: [String: AsmMacroDef] = [:]
        var constants = initialConstants
        var definedSymbols: Set<String> = Set(initialConstants.keys)
        var macroInvocationCounter = 0

        let expanded = expandBlock(
            cleanedStatements,
            arch: arch,
            macros: &macros,
            constants: &constants,
            definedSymbols: &definedSymbols,
            macroCounter: &macroInvocationCounter
        )

        // Rewrite numeric local labels (`1:`, `1b`, `1f`)
        return rewriteNumericLocalLabels(expanded)
    }

    private static func stripCommentsAndSplit(
        line: String,
        arch: AssemblerArch,
        inBlockComment: inout Bool
    ) -> [String] {
        var statements: [String] = []
        var current = ""
        let chars = Array(line)
        let n = chars.count
        var i = 0
        var inString = false

        while i < n {
            let c = chars[i]
            if inBlockComment {
                if c == "*" && i + 1 < n && chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    i += 1
                }
                continue
            }

            if inString {
                current.append(c)
                if c == "\\" && i + 1 < n {
                    i += 1
                    current.append(chars[i])
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            if c == "\"" {
                inString = true
                current.append(c)
                i += 1
                continue
            }

            // C-style block comment /* ... */
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                inBlockComment = true
                i += 2
                continue
            }

            // C++-style line comment // ...
            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                break
            }

            // Architecture-specific comment & statement separator
            if c == "#" {
                if arch == .x86_64 || arch == .riscv64 {
                    break
                }
                // On AArch64, `#` is immediate prefix unless at very start of line
                let trimmedSoFar = current.trimmingCharacters(in: .whitespaces)
                if trimmedSoFar.isEmpty {
                    break
                }
            }

            if c == ";" {
                // In GNU as for x86-64, AArch64, and RV64, `;` separates statements on the same line
                // (e.g. `1: wfe; b 1b` in croi/kernel/arch/arm64/smp.S)
                statements.append(current)
                current = ""
                i += 1
                continue
            }

            current.append(c)
            i += 1
        }

        if !current.isEmpty {
            statements.append(current)
        }
        return statements
    }

    private static func expandBlock(
        _ stmts: [AsmStatement],
        arch: AssemblerArch,
        macros: inout [String: AsmMacroDef],
        constants: inout [String: Int64],
        definedSymbols: inout Set<String>,
        macroCounter: inout Int
    ) -> [AsmStatement] {
        var out: [AsmStatement] = []
        var i = 0
        while i < stmts.count {
            let rawStmt = stmts[i]
            var lineAfterLabels = rawStmt.text
            while let (label, remainder) = extractLeadingLabel(lineAfterLabels) {
                if !label.allSatisfy({ $0.isNumber }) {
                    definedSymbols.insert(label)
                }
                out.append(AsmStatement(text: "\(label):", lineNumber: rawStmt.lineNumber))
                lineAfterLabels = remainder
            }
            if lineAfterLabels.isEmpty {
                i += 1
                continue
            }
            let stmt = (lineAfterLabels == rawStmt.text)
                ? rawStmt
                : AsmStatement(text: lineAfterLabels, lineNumber: rawStmt.lineNumber)
            let text = stmt.text
            let (firstWord, restText) = splitFirstWord(text)
            let lowerFirst = firstWord.lowercased()

            // 1. `.macro` definition
            if lowerFirst == ".macro" {
                let (mName, params) = parseMacroHeader(restText)
                var body: [(String, Int)] = []
                i += 1
                var depth = 1
                while i < stmts.count {
                    let bFirst = splitFirstWord(stmts[i].text).0.lowercased()
                    if bFirst == ".macro" {
                        depth += 1
                    } else if bFirst == ".endm" {
                        depth -= 1
                        if depth == 0 {
                            i += 1
                            break
                        }
                    }
                    body.append((stmts[i].text, stmts[i].lineNumber))
                    i += 1
                }
                if !mName.isEmpty {
                    macros[mName] = AsmMacroDef(name: mName, params: params, bodyLines: body)
                }
                continue
            }

            // 2. `.rept count` ... `.endr`
            if lowerFirst == ".rept" {
                let countVal = Int(AsmExprEvaluator.evaluate(restText, constants: constants)?.constantValue ?? 0)
                var body: [AsmStatement] = []
                i += 1
                var depth = 1
                while i < stmts.count {
                    let bFirst = splitFirstWord(stmts[i].text).0.lowercased()
                    if bFirst == ".rept" || bFirst == ".irp" || bFirst == ".irpc" {
                        depth += 1
                    } else if bFirst == ".endr" {
                        depth -= 1
                        if depth == 0 {
                            i += 1
                            break
                        }
                    }
                    body.append(stmts[i])
                    i += 1
                }
                if countVal > 0 {
                    for _ in 0..<countVal {
                        let expandedBody = expandBlock(body, arch: arch, macros: &macros, constants: &constants, definedSymbols: &definedSymbols, macroCounter: &macroCounter)
                        out.append(contentsOf: expandedBody)
                    }
                }
                continue
            }

            // 3. `.irp param, val1, val2, ...` ... `.endr`
            if lowerFirst == ".irp" {
                let parts = splitCommaSeparated(restText)
                let paramName = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let values = parts.count > 1 ? Array(parts.dropFirst()) : []
                var body: [AsmStatement] = []
                i += 1
                var depth = 1
                while i < stmts.count {
                    let bFirst = splitFirstWord(stmts[i].text).0.lowercased()
                    if bFirst == ".rept" || bFirst == ".irp" || bFirst == ".irpc" {
                        depth += 1
                    } else if bFirst == ".endr" {
                        depth -= 1
                        if depth == 0 {
                            i += 1
                            break
                        }
                    }
                    body.append(stmts[i])
                    i += 1
                }
                for val in values {
                    let substituted = body.map { s in
                        AsmStatement(
                            text: substituteMacroParams(in: s.text, bindings: [paramName: val], counter: macroCounter),
                            lineNumber: s.lineNumber
                        )
                    }
                    let expandedBody = expandBlock(substituted, arch: arch, macros: &macros, constants: &constants, definedSymbols: &definedSymbols, macroCounter: &macroCounter)
                    out.append(contentsOf: expandedBody)
                }
                continue
            }

            // 4. `.if`, `.ifdef`, `.ifndef`, `.ifeq`, `.ifne` ... `.else` / `.elseif` / `.endif`
            if lowerFirst == ".if" || lowerFirst == ".ifdef" || lowerFirst == ".ifndef" ||
               lowerFirst == ".ifeq" || lowerFirst == ".ifne" || lowerFirst == ".ifc" || lowerFirst == ".ifnc" {
                var branches: [(condKind: String, condArg: String, body: [AsmStatement])] = []
                var currentCondKind = lowerFirst
                var currentCondArg = restText
                var currentBody: [AsmStatement] = []
                i += 1
                var depth = 1
                while i < stmts.count {
                    let (bFirstRaw, bRest) = splitFirstWord(stmts[i].text)
                    let bFirst = bFirstRaw.lowercased()
                    if bFirst.hasPrefix(".if") {
                        depth += 1
                        currentBody.append(stmts[i])
                    } else if bFirst == ".endif" {
                        depth -= 1
                        if depth == 0 {
                            branches.append((currentCondKind, currentCondArg, currentBody))
                            i += 1
                            break
                        } else {
                            currentBody.append(stmts[i])
                        }
                    } else if depth == 1 && (bFirst == ".else" || bFirst == ".elseif") {
                        branches.append((currentCondKind, currentCondArg, currentBody))
                        currentCondKind = bFirst == ".else" ? ".else" : ".if"
                        currentCondArg = bRest
                        currentBody = []
                    } else {
                        currentBody.append(stmts[i])
                    }
                    i += 1
                }

                for branch in branches {
                    if evaluateConditional(kind: branch.condKind, arg: branch.condArg, constants: constants, definedSymbols: definedSymbols) {
                        let expandedBranch = expandBlock(branch.body, arch: arch, macros: &macros, constants: &constants, definedSymbols: &definedSymbols, macroCounter: &macroCounter)
                        out.append(contentsOf: expandedBranch)
                        break
                    }
                }
                continue
            }

            // Track `.equ` / `.set` constants so macros and `.rept` / `.if` can reference them
            if lowerFirst == ".equ" || lowerFirst == ".set" {
                let parts = splitCommaSeparated(restText)
                if parts.count == 2 {
                    let sym = parts[0].trimmingCharacters(in: .whitespaces)
                    if let val = AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue {
                        constants[sym] = val
                        definedSymbols.insert(sym)
                    }
                }
            }

            // Check if `firstWord` is a macro invocation
            if let macro = macros[firstWord] {
                macroCounter += 1
                let myCount = macroCounter
                let expandedMacro = instantiateMacro(macro, arch: arch, argsText: restText, counter: myCount, lineNumber: stmt.lineNumber)
                let recursive = expandBlock(expandedMacro, arch: arch, macros: &macros, constants: &constants, definedSymbols: &definedSymbols, macroCounter: &macroCounter)
                out.append(contentsOf: recursive)
                i += 1
                continue
            }

            out.append(stmt)
            i += 1
        }
        return out
    }

    private static func evaluateConditional(
        kind: String,
        arg: String,
        constants: [String: Int64],
        definedSymbols: Set<String>
    ) -> Bool {
        switch kind {
        case ".else":
            return true
        case ".ifdef":
            return definedSymbols.contains(arg.trimmingCharacters(in: .whitespaces))
        case ".ifndef":
            return !definedSymbols.contains(arg.trimmingCharacters(in: .whitespaces))
        case ".ifeq":
            guard let v = AsmExprEvaluator.evaluate(arg, constants: constants)?.constantValue else { return false }
            return v == 0
        case ".ifne":
            guard let v = AsmExprEvaluator.evaluate(arg, constants: constants)?.constantValue else { return false }
            return v != 0
        case ".ifc", ".ifnc":
            let parts = splitCommaSeparated(arg)
            guard parts.count == 2 else { return false }
            let eq = parts[0].trimmingCharacters(in: .whitespaces) == parts[1].trimmingCharacters(in: .whitespaces)
            return kind == ".ifc" ? eq : !eq
        default:
            guard let v = AsmExprEvaluator.evaluate(arg, constants: constants)?.constantValue else { return false }
            return v != 0
        }
    }

    private static func parseMacroHeader(_ header: String) -> (String, [(name: String, defaultValue: String?)]) {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let (name, argsPart) = splitFirstWord(trimmed)
        guard !argsPart.isEmpty else { return (name, []) }

        // Macro parameters in GNU as can be comma-separated or whitespace-separated
        let rawTokens: [String]
        if argsPart.contains(",") {
            rawTokens = splitCommaSeparated(argsPart)
        } else {
            rawTokens = argsPart.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        var params: [(name: String, defaultValue: String?)] = []
        for tok in rawTokens {
            var p = tok.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var defVal: String? = nil
            if let eqIdx = p.firstIndex(of: "=") {
                defVal = String(p[p.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                p = String(p[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            }
            if let colonIdx = p.firstIndex(of: ":") {
                p = String(p[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            }
            params.append((name: p, defaultValue: defVal))
        }
        return (name, params)
    }

    private static func instantiateMacro(
        _ macro: AsmMacroDef,
        arch: AssemblerArch,
        argsText: String,
        counter: Int,
        lineNumber: Int
    ) -> [AsmStatement] {
        let trimmedArgs = argsText.trimmingCharacters(in: .whitespaces)
        let supplied: [String]
        if trimmedArgs.isEmpty {
            supplied = []
        } else if trimmedArgs.contains(",") {
            supplied = splitCommaSeparated(trimmedArgs)
        } else {
            supplied = trimmedArgs.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        var bindings: [String: String] = [:]
        for (idx, param) in macro.params.enumerated() {
            if idx < supplied.count {
                bindings[param.name] = supplied[idx].trimmingCharacters(in: .whitespaces)
            } else if let def = param.defaultValue {
                bindings[param.name] = def
            } else {
                bindings[param.name] = ""
            }
        }

        var result: [AsmStatement] = []
        for (line, bodyLineNum) in macro.bodyLines {
            if splitFirstWord(line).0.lowercased() == ".exitm" {
                break
            }
            let sub = substituteMacroParams(in: line, bindings: bindings, counter: counter)
            // Split on `;` if macro expansion introduced multiple statements
            var dummyBlock = false
            let subStmts = stripCommentsAndSplit(line: sub, arch: arch, inBlockComment: &dummyBlock)
            for s in subStmts {
                let t = s.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    result.append(AsmStatement(text: t, lineNumber: bodyLineNum > 0 ? bodyLineNum : lineNumber))
                }
            }
        }
        return result
    }

    private static func substituteMacroParams(
        in line: String,
        bindings: [String: String],
        counter: Int
    ) -> String {
        var s = line.replacingOccurrences(of: "\\@", with: "\(counter)")
        // Sort parameter names longest-first so `\vector` doesn't partially match `\vec`
        let sortedKeys = bindings.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            let val = bindings[key] ?? ""
            s = s.replacingOccurrences(of: "\\\(key)\\()", with: val)
            s = s.replacingOccurrences(of: "\\\(key)", with: val)
        }
        s = s.replacingOccurrences(of: "\\()", with: "")
        return s
    }

    private static func rewriteNumericLocalLabels(_ stmts: [AsmStatement]) -> [AsmStatement] {
        // First pass: split out any inline labels (`1: in %dx, %al`) into separate label statements,
        // and count how many times each numeric label `N` is defined.
        var normalized: [AsmStatement] = []
        normalized.reserveCapacity(stmts.count + 16)

        for stmt in stmts {
            var text = stmt.text
            while let (lbl, rest) = extractLeadingLabel(text) {
                normalized.append(AsmStatement(text: "\(lbl):", lineNumber: stmt.lineNumber))
                text = rest
            }
            if !text.isEmpty && !text.hasSuffix(":") {
                normalized.append(AsmStatement(text: text, lineNumber: stmt.lineNumber))
            } else if text == stmt.text && text.hasSuffix(":") {
                // Already handled by extractLeadingLabel when rest is empty
            }
        }

        // Second pass: assign instance numbers to each numeric label definition `N:`
        // `currentInstance[N]` = number of definitions of `N` seen so far (1..k).
        // Therefore:
        // - at statement index `i`, `Nb` refers to `.L_local_\(N)_\(currentInstance[N])`
        // - at statement index `i`, `Nf` refers to `.L_local_\(N)_\(currentInstance[N] + 1)`
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
                    out.append(AsmStatement(text: ".L_local_\(num)_\(nextInst):", lineNumber: stmt.lineNumber))
                    continue
                }
            }
            let rewritten = rewriteNumericRefsInLine(text, currentInstance: currentInstance)
            out.append(AsmStatement(text: rewritten, lineNumber: stmt.lineNumber))
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
    case inst(bytes: [UInt8], fixups: [AsmInstFixup], lineNumber: Int)
    /// Label definition at the current position in the section.
    case label(name: String)
    /// Relaxable branch instruction (`form` grows monotonically; see `AsmSession.relaxableSize`).
    case relaxable(branch: AsmRelaxableBranch, form: Int, lineNumber: Int)
    /// Alignment directive (`.balign`, `.p2align`, `.align`).
    case align(alignBytes: Int, fillByte: UInt8?, maxBytes: Int)
    /// Data expression (`.byte`, `.short`, `.long`, `.quad`).
    case dataExpr(width: Int, expr: String, lineNumber: Int)
    /// Zero or byte fill (`.zero`, `.space`, `.skip`, `.fill`).
    case fill(countExpr: String, unitSize: Int, fillValue: Int64, lineNumber: Int)
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

    public func emitBytes(_ bytes: [UInt8], fixups: [AsmInstFixup] = [], lineNumber: Int = 0) {
        fragments.append(.inst(bytes: bytes, fixups: fixups, lineNumber: lineNumber))
    }

    public func emitRelaxable(_ branch: AsmRelaxableBranch, lineNumber: Int = 0) {
        fragments.append(.relaxable(branch: branch, form: 0, lineNumber: lineNumber))
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

/// Tracks `.cfi_*` directives and synthesizes `.eh_frame` CIE + FDE records.
public final class AsmCFIBuilder {
    public struct ProcedureCFI {
        public let sectionName: String
        public let startLabel: String
        public var endLabel: String = ""
        public var isSignalFrame: Bool = false
        public var cfaReg: UInt8 = 7 // RSP on x86-64, SP(31) on AArch64, SP(2) on RV64
        public var cfaOffset: Int32 = 8
        public var instructions: [UInt8] = []
    }

    private let arch: AssemblerArch
    public private(set) var procedures: [ProcedureCFI] = []
    private var activeProcIndex: Int? = nil
    private var labelCounter: Int = 0

    public init(arch: AssemblerArch) {
        self.arch = arch
    }

    public var hasActiveProcedure: Bool {
        activeProcIndex != nil
    }

    public func startProc(in section: AsmSectionBuilder) {
        labelCounter += 1
        let startLbl = ".Lcfi_start_\(labelCounter)"
        section.fragments.append(.label(name: startLbl))
        let defaultReg: UInt8 = (arch == .x86_64) ? 7 : ((arch == .aarch64) ? 31 : 2)
        let defaultOff: Int32 = (arch == .x86_64) ? 8 : 0
        let proc = ProcedureCFI(
            sectionName: section.name,
            startLabel: startLbl,
            cfaReg: defaultReg,
            cfaOffset: defaultOff
        )
        procedures.append(proc)
        activeProcIndex = procedures.count - 1
    }

    public func endProc(in section: AsmSectionBuilder) {
        guard let idx = activeProcIndex else { return }
        let endLbl = ".Lcfi_end_\(labelCounter)"
        section.fragments.append(.label(name: endLbl))
        procedures[idx].endLabel = endLbl
        activeProcIndex = nil
    }

    public func handleDirective(_ directive: String, args: String) {
        guard let idx = activeProcIndex else { return }
        let parts = splitCommaSeparated(args)
        switch directive {
        case ".cfi_signal_frame":
            procedures[idx].isSignalFrame = true
        case ".cfi_def_cfa":
            if parts.count == 2,
               let reg = parseDwarfReg(parts[0]),
               let off = Int32(parts[1].trimmingCharacters(in: .whitespaces)) {
                procedures[idx].cfaReg = reg
                procedures[idx].cfaOffset = off
                procedures[idx].instructions.append(0x0C) // DW_CFA_def_cfa
                appendULEB128(UInt64(reg), to: &procedures[idx].instructions)
                appendULEB128(UInt64(max(0, off)), to: &procedures[idx].instructions)
            }
        case ".cfi_def_cfa_offset":
            if let off = Int32( args.trimmingCharacters(in: .whitespaces) ) {
                procedures[idx].cfaOffset = off
                procedures[idx].instructions.append(0x0E) // DW_CFA_def_cfa_offset
                appendULEB128(UInt64(max(0, off)), to: &procedures[idx].instructions)
            }
        case ".cfi_adjust_cfa_offset":
            if let delta = Int32(args.trimmingCharacters(in: .whitespaces)) {
                procedures[idx].cfaOffset += delta
                procedures[idx].instructions.append(0x0E) // DW_CFA_def_cfa_offset
                appendULEB128(UInt64(max(0, procedures[idx].cfaOffset)), to: &procedures[idx].instructions)
            }
        case ".cfi_def_cfa_register":
            if let reg = parseDwarfReg(args) {
                procedures[idx].cfaReg = reg
                procedures[idx].instructions.append(0x0D) // DW_CFA_def_cfa_register
                appendULEB128(UInt64(reg), to: &procedures[idx].instructions)
            }
        case ".cfi_offset":
            if parts.count == 2,
               let reg = parseDwarfReg(parts[0]),
               let off = Int32(parts[1].trimmingCharacters(in: .whitespaces)) {
                let factored = UInt64(abs(off) / 8)
                if reg < 64 {
                    procedures[idx].instructions.append(0x80 | reg) // DW_CFA_offset
                } else {
                    procedures[idx].instructions.append(0x05) // DW_CFA_offset_extended
                    appendULEB128(UInt64(reg), to: &procedures[idx].instructions)
                }
                appendULEB128(factored, to: &procedures[idx].instructions)
            }
        case ".cfi_undefined":
            if let reg = parseDwarfReg(args) {
                procedures[idx].instructions.append(0x07) // DW_CFA_undefined
                appendULEB128(UInt64(reg), to: &procedures[idx].instructions)
            }
        case ".cfi_restore":
            if let reg = parseDwarfReg(args) {
                if reg < 64 {
                    procedures[idx].instructions.append(0xC0 | reg) // DW_CFA_restore
                } else {
                    procedures[idx].instructions.append(0x06) // DW_CFA_restore_extended
                    appendULEB128(UInt64(reg), to: &procedures[idx].instructions)
                }
            }
        case ".cfi_remember_state":
            procedures[idx].instructions.append(0x0A) // DW_CFA_remember_state
        case ".cfi_restore_state":
            procedures[idx].instructions.append(0x0B) // DW_CFA_restore_state
        default:
            break
        }
    }

    private func parseDwarfReg(_ raw: String) -> UInt8? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("%") { s.removeFirst() }
        if let num = UInt8(s) { return num }
        switch arch {
        case .x86_64:
            let map: [String: UInt8] = [
                "rax": 0, "rdx": 1, "rcx": 2, "rbx": 3, "rsi": 4, "rdi": 5, "rbp": 6, "rsp": 7,
                "r8": 8, "r9": 9, "r10": 10, "r11": 11, "r12": 12, "r13": 13, "r14": 14, "r15": 15, "rip": 16,
            ]
            return map[s]
        case .aarch64:
            if s == "sp" { return 31 }
            if s == "lr" { return 30 }
            if s == "fp" { return 29 }
            if (s.hasPrefix("x") || s.hasPrefix("w")), let n = UInt8(s.dropFirst()), n <= 30 {
                return n
            }
            return nil
        case .riscv64:
            if let gpr = RVGPR(name: s) { return gpr.rawValue }
            return nil
        }
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
}

// MARK: - 7. Top-Level Assembler (`Assembler`, `05-assembler.md`)

/// Top-level native assembler for x86-64, AArch64, and RV64 (RVA23).
public enum Assembler {

    /// Assembles a `.s` or `.S` file from disk into a `RelocatableObject`.
    public static func assembleFile(
        path: String,
        arch: AssemblerArch,
        includePaths: [String] = [],
        defines: [(name: String, value: String)] = [],
        sourceManager: SourceManager? = nil,
        diagnostics: inout DiagnosticBag
    ) throws -> RelocatableObject {
        let sm = sourceManager ?? SourceManager()
        let fileId = try sm.loadFile(path: path)
        let shouldPreprocess = path.hasSuffix(".S")

        if shouldPreprocess {
            let pp = makeAssemblerPreprocessor(sourceManager: sm, arch: arch, includePaths: includePaths, defines: defines)
            let expandedText = pp.preprocessToText(fileId: fileId)
            return assemble(
                source: expandedText,
                arch: arch,
                fileName: URL(fileURLWithPath: path).lastPathComponent,
                preprocess: false,
                includePaths: includePaths,
                defines: defines,
                sourceManager: sm,
                diagnostics: &diagnostics
            )
        } else {
            let sf = sm[fileId]
            let rawText: String
            if let base = sf.buffer.baseAddress {
                let slice = UnsafeBufferPointer(start: base, count: sf.length)
                rawText = String(decoding: slice, as: UTF8.self)
            } else {
                rawText = ""
            }
            return assemble(
                source: rawText,
                arch: arch,
                fileName: URL(fileURLWithPath: path).lastPathComponent,
                preprocess: false,
                includePaths: includePaths,
                defines: defines,
                sourceManager: sm,
                diagnostics: &diagnostics
            )
        }
    }

    /// Creates the `assembler-with-cpp` preprocessor for `.S` input: target-architecture predefined macros
    /// replace the host defaults, then user `-D` definitions are applied so they can override them.
    private static func makeAssemblerPreprocessor(
        sourceManager sm: SourceManager,
        arch: AssemblerArch,
        includePaths: [String],
        defines: [(name: String, value: String)]
    ) -> CPreprocessor {
        let pp = CPreprocessor(sourceManager: sm)
        pp.enableAssemblerMode(arch: arch.description)
        pp.includePaths.append(contentsOf: includePaths)
        for def in defines {
            pp.defineMacro(def.name, replacement: def.value)
        }
        return pp
    }

    /// Assembles in-memory assembly source text into a `RelocatableObject`.
    public static func assemble(
        source: String,
        arch: AssemblerArch,
        fileName: String = "<asm>",
        preprocess: Bool = false,
        includePaths: [String] = [],
        defines: [(name: String, value: String)] = [],
        sourceManager: SourceManager? = nil,
        diagnostics: inout DiagnosticBag
    ) -> RelocatableObject {
        let effectiveSource: String
        if preprocess {
            let sm = sourceManager ?? SourceManager()
            let fileId = sm.addBuffer(bytes: Array(source.utf8), path: fileName)
            let pp = makeAssemblerPreprocessor(sourceManager: sm, arch: arch, includePaths: includePaths, defines: defines)
            effectiveSource = pp.preprocessToText(fileId: fileId)
        } else {
            effectiveSource = source
        }

        let statements = AsmMacroEngine.expandStatements(source: effectiveSource, arch: arch)
        let session = AsmSession(arch: arch)
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
}

internal final class AsmSession {
    let arch: AssemblerArch

    // Ordered sections (always starting with default `.text`)
    var sections: [AsmSectionBuilder] = []
    var sectionByName: [String: Int] = [:]
    var currentSectionIndex: Int = 0
    var sectionStack: [Int] = []
    var previousSectionIndex: Int = 0

    // Constants (`.equ` / `.set` / `=`)
    var constants: [String: Int64] = [:]

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

    init(arch: AssemblerArch) {
        self.arch = arch
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
            sec.fragments.append(.dataExpr(width: 8, expr: entry.expr, lineNumber: 0))
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

        // 2. Direct symbol assignment `SYM = EXPR`
        if let eqIdx = text.firstIndex(of: "="), !text.hasPrefix(".") {
            let lhs = String(text[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let rhs = String(text[text.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            if !lhs.isEmpty && lhs.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }) {
                if let val = AsmExprEvaluator.evaluate(rhs, constants: constants)?.constantValue {
                    constants[lhs] = val
                    noteSymbol(lhs)
                    return
                }
            }
        }

        let (mnemonic, args) = splitFirstWord(text)

        // 3. Assembler directive `.foo`
        if mnemonic.hasPrefix(".") {
            handleDirective(mnemonic.lowercased(), args: args, lineNumber: stmt.lineNumber, diagnostics: &diagnostics)
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
                diagnostics.report(.asmInvalidOperands, at: SourceLocation(rawValue: UInt32(max(1, stmt.lineNumber))), args: [mnemonic])
            }
        }
        switch arch {
        case .x86_64:
            X86Asm.parseInstruction(mnemonic: mnemonic, args: args, lineNumber: stmt.lineNumber, session: self, diagnostics: &diagnostics)
        case .aarch64:
            A64Asm.parseInstruction(mnemonic: mnemonic, args: args, lineNumber: stmt.lineNumber, session: self, diagnostics: &diagnostics)
        case .riscv64:
            RVAsm.parseInstruction(mnemonic: mnemonic, args: args, lineNumber: stmt.lineNumber, session: self, diagnostics: &diagnostics)
        }
    }

    private func handleDirective(_ dir: String, args: String, lineNumber: Int, diagnostics: inout DiagnosticBag) {
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
            }

        case ".equ", ".set":
            let parts = splitCommaSeparated(args)
            if parts.count == 2 {
                let sym = parts[0]
                if let val = AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue {
                    constants[sym] = val
                    // Like GNU `as`/LLVM MC, an assigned symbol is emitted as a local `SHN_ABS` symbol.
                    noteSymbol(sym)
                }
            }

        case ".balign":
            let parts = splitCommaSeparated(args)
            if let first = parts.first,
               let alignBytes = AsmExprEvaluator.evaluate(first, constants: constants)?.constantValue,
               alignBytes > 0 {
                let fill: UInt8? = (parts.count >= 2) ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue.map { UInt8(truncatingIfNeeded: $0) } : nil
                let maxB: Int = (parts.count >= 3) ? Int(AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.align(alignBytes: Int(alignBytes), fillByte: fill, maxBytes: maxB))
                currentSection.recordAlignment(alignBytes: Int(alignBytes))
            }

        case ".p2align":
            let parts = splitCommaSeparated(args)
            if let first = parts.first,
               let pow2 = AsmExprEvaluator.evaluate(first, constants: constants)?.constantValue,
               pow2 >= 0 && pow2 <= 30 {
                let alignBytes = 1 << Int(pow2)
                let fill: UInt8? = (parts.count >= 2 && !parts[1].isEmpty) ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue.map { UInt8(truncatingIfNeeded: $0) } : nil
                let maxB: Int = (parts.count >= 3) ? Int(AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.align(alignBytes: alignBytes, fillByte: fill, maxBytes: maxB))
                currentSection.recordAlignment(alignBytes: alignBytes)
            }

        case ".align":
            let parts = splitCommaSeparated(args)
            if let first = parts.first,
               let val = AsmExprEvaluator.evaluate(first, constants: constants)?.constantValue,
               val >= 0 {
                let alignBytes = arch.alignDirectiveIsBytes ? max(1, Int(val)) : (1 << Int(val))
                let fill: UInt8? = (parts.count >= 2 && !parts[1].isEmpty) ? AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue.map { UInt8(truncatingIfNeeded: $0) } : nil
                let maxB: Int = (parts.count >= 3) ? Int(AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.align(alignBytes: alignBytes, fillByte: fill, maxBytes: maxB))
                currentSection.recordAlignment(alignBytes: alignBytes)
            }

        case ".byte", ".1byte":
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: 1, expr: expr, lineNumber: lineNumber))
            }

        case ".short", ".hword", ".value", ".2byte":
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: 2, expr: expr, lineNumber: lineNumber))
            }

        case ".word":
            let w = (arch == .x86_64) ? 2 : 4
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: w, expr: expr, lineNumber: lineNumber))
            }

        case ".long", ".int", ".4byte":
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: 4, expr: expr, lineNumber: lineNumber))
            }

        case ".quad", ".dword", ".8byte":
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: 8, expr: expr, lineNumber: lineNumber))
            }

        case ".ascii":
            for item in splitCommaSeparated(args) {
                if let bytes = parseAsmStringLiteral(item) {
                    currentSection.emitBytes(bytes, lineNumber: lineNumber)
                }
            }

        case ".asciz", ".string":
            for item in splitCommaSeparated(args) {
                if var bytes = parseAsmStringLiteral(item) {
                    bytes.append(0)
                    currentSection.emitBytes(bytes, lineNumber: lineNumber)
                }
            }

        case ".zero", ".space", ".skip":
            let parts = splitCommaSeparated(args)
            if let countExpr = parts.first {
                let fillVal: Int64 = (parts.count >= 2) ? (AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.fill(countExpr: countExpr, unitSize: 1, fillValue: fillVal, lineNumber: lineNumber))
            }

        case ".fill":
            let parts = splitCommaSeparated(args)
            if let repeatExpr = parts.first {
                let unitSize = (parts.count >= 2) ? Int(AsmExprEvaluator.evaluate(parts[1], constants: constants)?.constantValue ?? 1) : 1
                let fillVal: Int64 = (parts.count >= 3) ? (AsmExprEvaluator.evaluate(parts[2], constants: constants)?.constantValue ?? 0) : 0
                currentSection.fragments.append(.fill(countExpr: repeatExpr, unitSize: max(1, unitSize), fillValue: fillVal, lineNumber: lineNumber))
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
            cfiBuilder.startProc(in: currentSection)
        case ".cfi_endproc":
            cfiBuilder.endProc(in: currentSection)
        case _ where dir.hasPrefix(".cfi_"):
            cfiBuilder.handleDirective(dir, args: args)

        case ".inst":
            for expr in splitCommaSeparated(args) {
                currentSection.fragments.append(.dataExpr(width: 4, expr: expr, lineNumber: lineNumber))
            }

        case ".arch", ".arch_extension", ".cpu", ".fpu", ".file", ".loc", ".ident", ".addrsig", ".addrsig_sym", ".attribute", ".insn":
            // Metadata / target attribute directives accepted as no-ops in v1 (`.insn` for RV64 is handled in `RVAsm` if needed)
            if dir == ".insn" && arch == .riscv64 {
                RVAsm.parseInsnDirective(args: args, lineNumber: lineNumber, session: self, diagnostics: &diagnostics)
            }

        default:
            diagnostics.report(.asmUnknownDirective, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [dir])
        }
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

    // MARK: - 9. Fixpoint Layout, Branch Relaxation & `RelocatableObject` Construction (`05-assembler.md` §4.5)

    func buildRelocatableObject(diagnostics: inout DiagnosticBag) -> RelocatableObject {
        // 1. Run fixpoint layout and branch relaxation per section (05-assembler.md §4.5)
        var sectionSymbolOffsets: [[String: Int64]] = Array(repeating: [:], count: sections.count)
        var sectionTotalSizes: [Int] = Array(repeating: 0, count: sections.count)

        for secIdx in 0..<sections.count {
            let sec = sections[secIdx]
            var changed = true
            while changed {
                changed = false
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
                        let cnt = Int(AsmExprEvaluator.evaluate(countExpr, constants: constants, currentSectionSymbols: localLabels, dotOffset: Int64(offset))?.constantValue ?? 0)
                        offset += max(0, cnt) * unitSize
                    }
                }

                // Pass B: check if any short relaxable branch needs to grow (monotonic: never shrinks)
                var checkOffset = 0
                for fIdx in 0..<sec.fragments.count {
                    switch sec.fragments[fIdx] {
                    case .label:
                        break
                    case .inst(let bytes, _, _):
                        checkOffset += bytes.count
                    case .relaxable(let branch, let form, let lineNum):
                        let curSize = relaxableSize(branch: branch, form: form)
                        if let next = grownForm(branch: branch, form: form, instOffset: Int64(checkOffset), localLabels: localLabels) {
                            sec.fragments[fIdx] = .relaxable(branch: branch, form: next, lineNumber: lineNum)
                            changed = true
                        }
                        checkOffset += curSize
                    case .align(let alignBytes, _, let maxBytes):
                        checkOffset += computeAlignPadding(currentOffset: checkOffset, alignBytes: alignBytes, maxBytes: maxBytes)
                    case .dataExpr(let width, _, _):
                        checkOffset += width
                    case .fill(let countExpr, let unitSize, _, _):
                        let cnt = Int(AsmExprEvaluator.evaluate(countExpr, constants: constants, currentSectionSymbols: localLabels, dotOffset: Int64(checkOffset))?.constantValue ?? 0)
                        checkOffset += max(0, cnt) * unitSize
                    }
                }

                if !changed {
                    sectionSymbolOffsets[secIdx] = localLabels
                    sectionTotalSizes[secIdx] = offset
                }
            }

            // Record global label lookup table
            for (lbl, off) in sectionSymbolOffsets[secIdx] {
                definedLabels[lbl] = (sectionIndex: secIdx, offset: off)
            }
        }

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

        for secIdx in 0..<sections.count {
            let sec = sections[secIdx]
            let localLabels = sectionSymbolOffsets[secIdx]
            let sHandle = objSectionIndices[secIdx]

            if sec.kind.isNobits {
                obj.setNobitsSectionSize(sHandle, size: UInt32(sectionTotalSizes[secIdx]))
                continue
            }

            var bytes: [UInt8] = []
            bytes.reserveCapacity(sectionTotalSizes[secIdx])

            for frag in sec.fragments {
                let fragOffset = bytes.count
                switch frag {
                case .label:
                    break

                case .inst(let instBytes, let fixups, _):
                    var patched = instBytes
                    var resolvedPCRelHi20 = false
                    for fix in fixups {
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

                case .relaxable(let branch, let form, let lineNum):
                    var outOfRange = false
                    let (instBytes, relocOpt) = encodeRelaxedBranch(
                        branch: branch,
                        form: form,
                        instOffset: Int64(fragOffset),
                        localLabels: localLabels,
                        outOfRange: &outOfRange
                    )
                    if outOfRange {
                        diagnostics.report(.asmBranchOutOfRange, at: SourceLocation(rawValue: UInt32(max(1, lineNum))), args: [])
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

                case .dataExpr(let width, let exprStr, let lineNum):
                    // `.` stays symbolic (it is a location, not a constant) so that `sym - .` becomes a
                    // PC-relative relocation; differences against same-section labels still fold.
                    var dotLabels = localLabels
                    dotLabels["."] = Int64(fragOffset)
                    let valOpt = AsmExprEvaluator.evaluate(
                        exprStr,
                        constants: constants,
                        currentSectionSymbols: dotLabels
                    )
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
                        diagnostics.report(.asmInvalidExpression, at: SourceLocation(rawValue: UInt32(max(1, lineNum))), args: [exprStr])
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
                           pDef.sectionIndex == mDef.sectionIndex {
                            appendLittleEndian((pDef.offset - mDef.offset) + addend, width: width, to: &bytes)
                        } else if arch == .riscv64, let addKind = riscvPairKinds(width: width) {
                            // RISC-V encodes symbol differences as an ADD/SUB relocation pair (as GNU `as`/LLVM do).
                            addReloc(addKind.add, plusSym, addend)
                            addReloc(addKind.sub, minusSym == "." ? dotLabel() : minusSym, 0)
                            appendLittleEndian(0, width: width, to: &bytes)
                        } else if minusSym == ".", let kind = dataRelocKind(width: width, isPCRel: true) {
                            addReloc(kind, plusSym, addend)
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
                    diagnostics.report(.asmInvalidExpression, at: SourceLocation(rawValue: 1), args: [".size \(symName), \(sizeExpr)"])
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

        // 5. Attach Relocations to Sections
        for pr in pendingRelocs {
            guard let symHandle = symHandleByName[pr.symbol] else { continue }
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
            var rem = count
            if (rem & 1) != 0 {
                bytes.append(0)
                rem -= 1
            }
            while rem >= 4 {
                // RV64 ADDI x0, x0, 0 = 0x00000013
                bytes.append(contentsOf: [0x13, 0x00, 0x00, 0x00])
                rem -= 4
            }
            while rem >= 2 {
                // RVC c.nop = 0x0001
                bytes.append(contentsOf: [0x01, 0x00])
                rem -= 2
            }
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
        let procs = cfiBuilder.procedures.filter { !$0.endLabel.isEmpty }
        guard !procs.isEmpty else { return }

        let ehIdx = getOrCreateSection(name: ".eh_frame", kind: .ehFrame, flags: [.alloc], alignLog2: 3)
        let ehSec = sections[ehIdx]

        // Build standard 64-bit DWARF CIE with "zR" augmentation (PC-relative 32-bit FDE encoding = 0x1B)
        var cieBody: [UInt8] = [
            0, 0, 0, 0,             // CIE_id = 0 for .eh_frame
            1,                      // version = 1
            0x7A, 0x52, 0x00,       // augmentation string "zR\0"
            1,                      // code_alignment_factor = 1 (ULEB128)
            0x78,                   // data_alignment_factor = -8 (SLEB128)
            arch == .x86_64 ? 16 : (arch == .aarch64 ? 30 : 1), // return_address_register
            1,                      // augmentation data length = 1
            0x1B,                   // FDE pointer encoding: DW_EH_PE_pcrel | DW_EH_PE_sdata4
        ]
        // Initial instructions: DW_CFA_def_cfa (rsp/sp, 8/0)
        if arch == .x86_64 {
            cieBody.append(contentsOf: [0x0C, 7, 8])
        } else if arch == .aarch64 {
            cieBody.append(contentsOf: [0x0C, 31, 0])
        } else {
            cieBody.append(contentsOf: [0x0C, 2, 0])
        }
        while (cieBody.count + 4) % 8 != 0 {
            cieBody.append(0) // DW_CFA_nop
        }

        var ehBytes: [UInt8] = []
        appendLittleEndian(Int64(cieBody.count), width: 4, to: &ehBytes)
        ehBytes.append(contentsOf: cieBody)

        for proc in procs {
            guard let startDef = definedLabels[proc.startLabel],
                  let endDef = definedLabels[proc.endLabel] else { continue }
            let rangeLen = max(0, endDef.offset - startDef.offset)
            let fdeStartOffset = ehBytes.count
            let ciePointer = UInt32(fdeStartOffset + 4) // offset from FDE's CIE_pointer field back to CIE at 0

            var fdeBody: [UInt8] = []
            appendLittleEndian(Int64(ciePointer), width: 4, to: &fdeBody)
            appendLittleEndian(0, width: 4, to: &fdeBody) // pc_begin placeholder
            appendLittleEndian(rangeLen, width: 4, to: &fdeBody) // pc_range
            fdeBody.append(0) // augmentation data length = 0
            fdeBody.append(contentsOf: proc.instructions)
            while (fdeBody.count + 4) % 8 != 0 {
                fdeBody.append(0)
            }

            var fdeRecord: [UInt8] = []
            appendLittleEndian(Int64(fdeBody.count), width: 4, to: &fdeRecord)
            fdeRecord.append(contentsOf: fdeBody)

            let fixup = AsmInstFixup(
                offsetInInst: 8, // 4 (length) + 4 (CIE_pointer)
                kind: arch == .x86_64 ? .x86_64_pc32 : (arch == .aarch64 ? .aarch64_prel32 : .riscv_32_pcrel),
                symbol: proc.startLabel,
                addend: 0
            )
            ehSec.emitBytes(fdeRecord, fixups: [fixup])
            ehBytes.append(contentsOf: fdeRecord)
        }

        // Emit header CIE at start of .eh_frame
        var cieHeader: [UInt8] = []
        appendLittleEndian(Int64(cieBody.count), width: 4, to: &cieHeader)
        cieHeader.append(contentsOf: cieBody)
        ehSec.fragments.insert(.inst(bytes: cieHeader, fixups: [], lineNumber: 0), at: 0)

        if ehIdx >= sectionSymbolOffsets.count {
            sectionSymbolOffsets.append([:])
            sectionTotalSizes.append(ehBytes.count)
        } else {
            sectionTotalSizes[ehIdx] = ehBytes.count
        }
    }
}

/// Mutable options state for RV64 `.option` directives.
public struct RVAsmOptions: Sendable {
    public var rvcEnabled: Bool = true
    public var relaxEnabled: Bool = false
    public var picEnabled: Bool = false

    public init() {}
}
