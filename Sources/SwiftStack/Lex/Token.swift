// Sources/SwiftStack/Lex/Token.swift

/// Trivia and adjacency flags for tokens (01-frontend.md §4.4).
@frozen
public struct TokenFlags: OptionSet, Sendable, BitwiseCopyable {
    public let rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let maskLeadingSpace: UInt8   = 1 << 0
    public static let maskLeadingNewline: UInt8 = 1 << 1
    public static let maskTrailingSpace: UInt8  = 1 << 2
    public static let maskMacroExpanded: UInt8  = 1 << 5
    public static let maskNeedsCleaning: UInt8  = 1 << 6
    public static let maskHasError: UInt8       = 1 << 7

    /// Bit 0: Horizontal whitespace or a comment precedes the token on the same line.
    public static let leadingSpace   = TokenFlags(rawValue: maskLeadingSpace)
    /// Bit 1: At least one line break precedes the token.
    public static let leadingNewline = TokenFlags(rawValue: maskLeadingNewline)
    /// Bit 2: Whitespace, a comment, or EOF follows the token.
    public static let trailingSpace  = TokenFlags(rawValue: maskTrailingSpace)

    /// Bits 3–4: Operator fixity mask
    @usableFromInline
    internal static let fixityMask: UInt8 = 0x18
    public static let fixityNone: UInt8    = 0 << 3
    public static let fixityBinary: UInt8  = 1 << 3
    public static let fixityPrefix: UInt8  = 2 << 3
    public static let fixityPostfix: UInt8 = 3 << 3

    /// Bit 5: Token produced by macro expansion (C).
    public static let macroExpanded  = TokenFlags(rawValue: maskMacroExpanded)
    /// Bit 6: Token contains line splices or UCNs needing cleaning.
    public static let needsCleaning  = TokenFlags(rawValue: maskNeedsCleaning)
    /// Bit 7: Malformed token (diagnostic already emitted).
    public static let hasError       = TokenFlags(rawValue: maskHasError)

    @inlinable
    public var fixity: OperatorFixity {
        switch (rawValue & Self.fixityMask) {
        case Self.fixityBinary:  return .binary
        case Self.fixityPrefix:  return .prefix
        case Self.fixityPostfix: return .postfix
        default:                 return .none
        }
    }

    @inlinable
    public func withFixity(_ fixity: OperatorFixity) -> TokenFlags {
        let cleared = rawValue & ~Self.fixityMask
        let val: UInt8
        switch fixity {
        case .none:    val = Self.fixityNone
        case .binary:  val = Self.fixityBinary
        case .prefix:  val = Self.fixityPrefix
        case .postfix: val = Self.fixityPostfix
        }
        return TokenFlags(rawValue: cleared | val)
    }
}

/// Swift operator fixity inferred from left-bound and right-bound whitespace rules.
@frozen
public enum OperatorFixity: UInt8, Sendable, BitwiseCopyable {
    case none = 0
    case binary = 1
    case prefix = 2
    case postfix = 3
}

/// Token kinds for the Swift frontend.
@frozen
public enum SwiftTokenKind: UInt8, Sendable, BitwiseCopyable, CustomStringConvertible {
    case nilToken = 0

    // Identifiers & literals
    case identifier = 1
    case dollarIdentifier = 2
    case integerLiteral = 3
    case floatingLiteral = 4
    case stringLiteral = 5
    case regexLiteral = 6

    // Keywords
    case kwFunc = 10
    case kwLet = 11
    case kwVar = 12
    case kwIf = 13
    case kwElse = 14
    case kwWhile = 15
    case kwFor = 16
    case kwIn = 17
    case kwReturn = 18
    case kwStruct = 19
    case kwClass = 20
    case kwEnum = 21
    case kwProtocol = 22
    case kwExtension = 23
    case kwInit = 24
    case kwDeinit = 25
    case kwTypealias = 26
    case kwImport = 27
    case kwGuard = 28
    case kwDefer = 29
    case kwSwitch = 30
    case kwCase = 31
    case kwDefault = 32
    case kwBreak = 33
    case kwContinue = 34
    case kwFallthrough = 35
    case kwThrow = 36
    case kwThrows = 37
    case kwRethrows = 38
    case kwTry = 39
    case kwCatch = 40
    case kwDo = 41
    case kwAs = 42
    case kwIs = 43
    case kwNil = 44
    case kwTrue = 45
    case kwFalse = 46
    case kwSelf = 47
    case kwSelfCapital = 48
    case kwSuper = 49
    case kwRepeat = 50
    case kwWhere = 51
    case kwSubscript = 52
    case kwOperator = 53
    case kwPrecedencegroup = 54
    case kwMacro = 55
    case kwStatic = 56

    // Punctuators & Delimiters
    case lParen = 70
    case rParen = 71
    case lBrace = 72
    case rBrace = 73
    case lBracket = 74
    case rBracket = 75
    case period = 76
    case comma = 77
    case colon = 78
    case semicolon = 79
    case arrow = 80
    case equal = 81
    case at = 82
    case pound = 83
    case question = 84
    case exclamation = 85
    case binaryOperator = 86
    case prefixOperator = 87
    case postfixOperator = 88

    // Special
    case eof = 254
    case errorToken = 255

    public var description: String {
        switch self {
        case .nilToken: return "nil"
        case .identifier: return "identifier"
        case .dollarIdentifier: return "dollarIdentifier"
        case .integerLiteral: return "integerLiteral"
        case .floatingLiteral: return "floatingLiteral"
        case .stringLiteral: return "stringLiteral"
        case .regexLiteral: return "regexLiteral"
        case .eof: return "<eof>"
        case .errorToken: return "<error>"
        default: return "\(self)"
        }
    }
}

/// Token kinds for the C23 frontend.
@frozen
public enum CTokenKind: UInt8, Sendable, BitwiseCopyable, CustomStringConvertible {
    case nilToken = 0

    // Identifiers & literals
    case identifier = 1
    case intLiteral = 2
    case floatLiteral = 3
    case charLiteral = 4
    case stringLiteral = 5

    // C23 Keywords
    case kwAuto = 10
    case kwBreak = 11
    case kwCase = 12
    case kwChar = 13
    case kwConst = 14
    case kwContinue = 15
    case kwDefault = 16
    case kwDo = 17
    case kwDouble = 18
    case kwElse = 19
    case kwEnum = 20
    case kwExtern = 21
    case kwFloat = 22
    case kwFor = 23
    case kwGoto = 24
    case kwIf = 25
    case kwInline = 26
    case kwInt = 27
    case kwLong = 28
    case kwRegister = 29
    case kwRestrict = 30
    case kwReturn = 31
    case kwShort = 32
    case kwSigned = 33
    case kwSizeof = 34
    case kwStatic = 35
    case kwStruct = 36
    case kwSwitch = 37
    case kwTypedef = 38
    case kwUnion = 39
    case kwUnsigned = 40
    case kwVoid = 41
    case kwVolatile = 42
    case kwWhile = 43
    case kwAlignas = 44
    case kwAlignof = 45
    case kwAtomic = 46
    case kwBool = 47
    case kwConstexpr = 48
    case kwFalse = 49
    case kwTrue = 50
    case kwNullptr = 51
    case kwStaticAssert = 52
    case kwThreadLocal = 53
    case kwTypeof = 54
    case kwTypeofUnqual = 55

    // Delimiters & Operators
    case lParen = 60
    case rParen = 61
    case lBrace = 62
    case rBrace = 63
    case lBracket = 64
    case rBracket = 65
    case semicolon = 66
    case comma = 67
    case colon = 68
    case period = 69
    case arrow = 70
    case plus = 71
    case minus = 72
    case star = 73
    case slash = 74
    case percent = 75
    case amp = 76
    case pipe = 77
    case caret = 78
    case tilde = 79
    case exclaim = 80
    case equal = 81
    case less = 82
    case greater = 83
    case plusPlus = 84
    case minusMinus = 85
    case lessLess = 86
    case greaterGreater = 87
    case lessEqual = 88
    case greaterEqual = 89
    case equalEqual = 90
    case exclaimEqual = 91
    case ampAmp = 92
    case pipePipe = 93
    case question = 94
    case ellipsis = 95
    case hash = 96
    case hashHash = 97
    case embedAsset = 98

    // Special
    case eof = 254
    case errorToken = 255

    public var description: String {
        switch self {
        case .nilToken: return "nil"
        case .identifier: return "identifier"
        case .intLiteral: return "intLiteral"
        case .floatLiteral: return "floatLiteral"
        case .charLiteral: return "charLiteral"
        case .stringLiteral: return "stringLiteral"
        case .eof: return "<eof>"
        case .errorToken: return "<error>"
        default: return "\(self)"
        }
    }
}
