// Sources/SwiftStack/Lex/CharacterClass.swift

/// 256-entry character classification for single-byte dispatch (01-frontend.md §4.4).
@frozen
public enum CharClass: UInt8, Sendable, BitwiseCopyable {
    case other = 0
    case whitespace = 1
    case newline = 2
    case identStart = 3
    case digit = 4
    case dollar = 5
    case quote = 6
    case singleQuote = 7
    case slash = 8
    case operatorChar = 9
    case lParen = 10
    case rParen = 11
    case lBrace = 12
    case rBrace = 13
    case lBracket = 14
    case rBracket = 15
    case semicolon = 16
    case comma = 17
    case colon = 18
    case period = 19
    case at = 20
    case pound = 21
    case backslash = 22
    case nul = 23
    case utf8Lead = 24
}

public enum CharacterTable {
    @_noAllocation
    @inline(__always)
    public static func classify(_ byte: UInt8) -> CharClass {
        switch byte {
        case 0:
            return .nul
        case 9, 13, 32:
            return .whitespace
        case 10:
            return .newline
        case 0x30...0x39: // '0'...'9'
            return .digit
        case 0x41...0x5A, 0x61...0x7A, 0x5F: // 'A'...'Z', 'a'...'z', '_'
            return .identStart
        case 0x24: // '$'
            return .dollar
        case 0x22: // '"'
            return .quote
        case 0x27: // '\''
            return .singleQuote
        case 0x2F: // '/'
            return .slash
        case 0x5C: // '\\'
            return .backslash
        case 0x28: // '('
            return .lParen
        case 0x29: // ')'
            return .rParen
        case 0x7B: // '{'
            return .lBrace
        case 0x7D: // '}'
            return .rBrace
        case 0x5B: // '['
            return .lBracket
        case 0x5D: // ']'
            return .rBracket
        case 0x3B: // ';'
            return .semicolon
        case 0x2C: // ','
            return .comma
        case 0x3A: // ':'
            return .colon
        case 0x2E: // '.'
            return .period
        case 0x40: // '@'
            return .at
        case 0x23: // '#'
            return .pound
        case 0x2B, 0x2D, 0x2A, 0x25, 0x3C, 0x3E, 0x3D, 0x21, 0x26, 0x7C, 0x5E, 0x7E, 0x3F: // +-*%<>=!&|^~?
            return .operatorChar
        case 0x80...0xFF:
            return .utf8Lead
        default:
            return .other
        }
    }
}
