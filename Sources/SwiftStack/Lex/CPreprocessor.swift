// Sources/SwiftStack/Lex/CPreprocessor.swift
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Token representation used internally during preprocessing.
public struct PPToken: Sendable, Equatable {
    public var kind: CTokenKind
    public var flags: TokenFlags
    public var location: SourceLocation
    public var endLocation: SourceLocation
    public var spelling: String

    public init(kind: CTokenKind, flags: TokenFlags, location: SourceLocation, endLocation: SourceLocation, spelling: String) {
        self.kind = kind
        self.flags = flags
        self.location = location
        self.endLocation = endLocation
        self.spelling = spelling
    }

    public var isLeadingNewline: Bool {
        (flags.rawValue & TokenFlags.maskLeadingNewline) != 0
    }

    public var isLeadingSpace: Bool {
        (flags.rawValue & TokenFlags.maskLeadingSpace) != 0
    }
}

/// Definition of a preprocessor macro.
public struct PPMacro: Sendable {
    public let name: String
    public let isFunctionLike: Bool
    public let parameters: [String]
    public let isVariadic: Bool
    public let variadicParamName: String?
    public let replacementTokens: [PPToken]
    public let location: SourceLocation

    public init(
        name: String,
        isFunctionLike: Bool,
        parameters: [String] = [],
        isVariadic: Bool = false,
        variadicParamName: String? = nil,
        replacementTokens: [PPToken] = [],
        location: SourceLocation = .zero
    ) {
        self.name = name
        self.isFunctionLike = isFunctionLike
        self.parameters = parameters
        self.isVariadic = isVariadic
        self.variadicParamName = variadicParamName
        self.replacementTokens = replacementTokens
        self.location = location
    }
}

/// State of an active or inactive conditional block (#if / #ifdef / #elif / #else).
private struct CondBranch {
    let isParentActive: Bool
    var hasMetCondition: Bool
    var isBranchActive: Bool
    let directiveLocation: SourceLocation
}

/// ISO C23 Preprocessor supporting macro expansion, directives, #embed, and host headers (01-frontend.md §4.5, D7).
public final class CPreprocessor {
    public let sourceManager: SourceManager
    public var diagnostics: DiagnosticBag
    public var includePaths: [String] = []
    public var systemIncludePaths: [String] = []

    private var macros: [String: PPMacro] = [:]
    private var pragmaOnceFiles: Set<String> = []
    private var includeGuards: [String: String] = [:] // filePath -> guardMacroName
    private var counterValue: UInt32 = 0
    private var activeInclusions: [String] = [] // Call stack of included files for #include_next

    public init(sourceManager: SourceManager, diagnostics: consuming DiagnosticBag = DiagnosticBag()) {
        self.sourceManager = sourceManager
        self.diagnostics = diagnostics
        setupDefaultIncludePaths()
        setupPredefinedMacros()
    }

    private func setupDefaultIncludePaths() {
        // Standard Linux include search paths
        let standardPaths = [
            "/usr/local/include",
            "/usr/include/x86_64-linux-gnu",
            "/usr/include",
            "/usr/lib/gcc/x86_64-redhat-linux/16/include",
            "/usr/lib/gcc/x86_64-linux-gnu/14/include",
            "/usr/lib/gcc/x86_64-linux-gnu/13/include"
        ]
        for p in standardPaths {
            if FileManager.default.fileExists(atPath: p) {
                systemIncludePaths.append(p)
            }
        }
    }

    private func setupPredefinedMacros() {
        // ISO C23 Standards
        defineMacro("__STDC__", replacement: "1")
        defineMacro("__STDC_VERSION__", replacement: "202311L")
        defineMacro("__STDC_HOSTED__", replacement: "1")
        defineMacro("__STDC_UTF_16__", replacement: "1")
        defineMacro("__STDC_UTF_32__", replacement: "1")

        // Target Architecture (x86-64 LP64)
        defineMacro("__x86_64__", replacement: "1")
        defineMacro("__x86_64", replacement: "1")
        defineMacro("__amd64__", replacement: "1")
        defineMacro("__amd64", replacement: "1")
        defineMacro("__LP64__", replacement: "1")
        defineMacro("_LP64", replacement: "1")

        // OS
        defineMacro("__linux__", replacement: "1")
        defineMacro("__linux", replacement: "1")
        defineMacro("__gnu_linux__", replacement: "1")
        defineMacro("__unix__", replacement: "1")
        defineMacro("__unix", replacement: "1")
        defineMacro("__ELF__", replacement: "1")

        // Compiler Sizes & ABI
        defineMacro("__SIZEOF_INT__", replacement: "4")
        defineMacro("__SIZEOF_LONG__", replacement: "8")
        defineMacro("__SIZEOF_LONG_LONG__", replacement: "8")
        defineMacro("__SIZEOF_SHORT__", replacement: "2")
        defineMacro("__SIZEOF_FLOAT__", replacement: "4")
        defineMacro("__SIZEOF_DOUBLE__", replacement: "8")
        defineMacro("__SIZEOF_LONG_DOUBLE__", replacement: "16")
        defineMacro("__SIZEOF_SIZE_T__", replacement: "8")
        defineMacro("__SIZEOF_POINTER__", replacement: "8")
        defineMacro("__SIZEOF_PTRDIFF_T__", replacement: "8")
        defineMacro("__BYTE_ORDER__", replacement: "1234")
        defineMacro("__ORDER_LITTLE_ENDIAN__", replacement: "1234")
        defineMacro("__ORDER_BIG_ENDIAN__", replacement: "4321")
        defineMacro("__FLOAT_WORD_ORDER__", replacement: "1234")
        defineMacro("__CHAR_BIT__", replacement: "8")

        // Integer Limits
        defineMacro("__INT_MAX__", replacement: "2147483647")
        defineMacro("__LONG_MAX__", replacement: "9223372036854775807L")
        defineMacro("__LONG_LONG_MAX__", replacement: "9223372036854775807LL")
        defineMacro("__SCHAR_MAX__", replacement: "127")
        defineMacro("__SHRT_MAX__", replacement: "32767")
        defineMacro("__SIZE_MAX__", replacement: "18446744073709551615UL")
        defineMacro("__PTRDIFF_MAX__", replacement: "9223372036854775807L")
        defineMacro("__INTPTR_MAX__", replacement: "9223372036854775807L")
        defineMacro("__UINTPTR_MAX__", replacement: "18446744073709551615UL")

        // Host Compatibility Profile (D7)
        defineMacro("_GNU_SOURCE", replacement: "1")
        defineMacro("__USER_LABEL_PREFIX__", replacement: "")
        defineMacro("__GNUC__", replacement: "14")
        defineMacro("__GNUC_MINOR__", replacement: "2")
        defineMacro("__GNUC_PATCHLEVEL__", replacement: "1")
        defineMacro("__clang__", replacement: "1")
        defineMacro("__clang_major__", replacement: "19")
        defineMacro("__clang_minor__", replacement: "1")
        defineMacro("__clang_patchlevel__", replacement: "0")
        defineMacro("__clang_version__", replacement: "\"19.1.0 (Swift-Stack C23)\"")
        defineMacro("__VERSION__", replacement: "\"14.2.1 (Swift-Stack C23 compatible)\"")

        // Atomic memory order & floating point mantissa digits
        defineMacro("__ATOMIC_RELAXED", replacement: "0")
        defineMacro("__ATOMIC_CONSUME", replacement: "1")
        defineMacro("__ATOMIC_ACQUIRE", replacement: "2")
        defineMacro("__ATOMIC_RELEASE", replacement: "3")
        defineMacro("__ATOMIC_ACQ_REL", replacement: "4")
        defineMacro("__ATOMIC_SEQ_CST", replacement: "5")
        defineMacro("__GCC_ATOMIC_BOOL_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_CHAR_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_CHAR8_T_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_CHAR16_T_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_CHAR32_T_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_WCHAR_T_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_SHORT_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_INT_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_LONG_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_LLONG_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_POINTER_LOCK_FREE", replacement: "2")
        defineMacro("__GCC_ATOMIC_TEST_AND_SET_TRUEVAL", replacement: "1")

        // Predefined standard integer typedef macros (<stdatomic.h>, <stdint.h>, <stddef.h>)
        defineMacro("__SIZE_TYPE__", replacement: "unsigned long")
        defineMacro("__PTRDIFF_TYPE__", replacement: "long")
        defineMacro("__WCHAR_TYPE__", replacement: "int")
        defineMacro("__WINT_TYPE__", replacement: "unsigned int")
        defineMacro("__INTMAX_TYPE__", replacement: "long")
        defineMacro("__UINTMAX_TYPE__", replacement: "unsigned long")
        defineMacro("__INTPTR_TYPE__", replacement: "long")
        defineMacro("__UINTPTR_TYPE__", replacement: "unsigned long")
        defineMacro("__CHAR8_TYPE__", replacement: "unsigned char")
        defineMacro("__CHAR16_TYPE__", replacement: "unsigned short")
        defineMacro("__CHAR32_TYPE__", replacement: "unsigned int")
        defineMacro("__INT8_TYPE__", replacement: "signed char")
        defineMacro("__INT16_TYPE__", replacement: "short")
        defineMacro("__INT32_TYPE__", replacement: "int")
        defineMacro("__INT64_TYPE__", replacement: "long")
        defineMacro("__UINT8_TYPE__", replacement: "unsigned char")
        defineMacro("__UINT16_TYPE__", replacement: "unsigned short")
        defineMacro("__UINT32_TYPE__", replacement: "unsigned int")
        defineMacro("__UINT64_TYPE__", replacement: "unsigned long")
        defineMacro("__INT_LEAST8_TYPE__", replacement: "signed char")
        defineMacro("__INT_LEAST16_TYPE__", replacement: "short")
        defineMacro("__INT_LEAST32_TYPE__", replacement: "int")
        defineMacro("__INT_LEAST64_TYPE__", replacement: "long")
        defineMacro("__UINT_LEAST8_TYPE__", replacement: "unsigned char")
        defineMacro("__UINT_LEAST16_TYPE__", replacement: "unsigned short")
        defineMacro("__UINT_LEAST32_TYPE__", replacement: "unsigned int")
        defineMacro("__UINT_LEAST64_TYPE__", replacement: "unsigned long")
        defineMacro("__INT_FAST8_TYPE__", replacement: "signed char")
        defineMacro("__INT_FAST16_TYPE__", replacement: "long")
        defineMacro("__INT_FAST32_TYPE__", replacement: "long")
        defineMacro("__INT_FAST64_TYPE__", replacement: "long")
        defineMacro("__UINT_FAST8_TYPE__", replacement: "unsigned char")
        defineMacro("__UINT_FAST16_TYPE__", replacement: "unsigned long")
        defineMacro("__UINT_FAST32_TYPE__", replacement: "unsigned long")
        defineMacro("__UINT_FAST64_TYPE__", replacement: "unsigned long")

        // Floating point limits (<float.h>) and IEC 60559 extensions
        defineMacro("__STDC_WANT_IEC_60559_TYPES_EXT__", replacement: "1")
        defineMacro("__FLT_RADIX__", replacement: "2")
        defineMacro("__FLT_MANT_DIG__", replacement: "24")
        defineMacro("__DBL_MANT_DIG__", replacement: "53")
        defineMacro("__LDBL_MANT_DIG__", replacement: "64")
        defineMacro("__FLT_DIG__", replacement: "6")
        defineMacro("__DBL_DIG__", replacement: "15")
        defineMacro("__LDBL_DIG__", replacement: "18")
        defineMacro("__FLT_MIN_EXP__", replacement: "(-125)")
        defineMacro("__DBL_MIN_EXP__", replacement: "(-1021)")
        defineMacro("__LDBL_MIN_EXP__", replacement: "(-16381)")
        defineMacro("__FLT_MIN_10_EXP__", replacement: "(-37)")
        defineMacro("__DBL_MIN_10_EXP__", replacement: "(-307)")
        defineMacro("__LDBL_MIN_10_EXP__", replacement: "(-4931)")
        defineMacro("__FLT_MAX_EXP__", replacement: "128")
        defineMacro("__DBL_MAX_EXP__", replacement: "1024")
        defineMacro("__LDBL_MAX_EXP__", replacement: "16384")
        defineMacro("__FLT_MAX_10_EXP__", replacement: "38")
        defineMacro("__DBL_MAX_10_EXP__", replacement: "308")
        defineMacro("__LDBL_MAX_10_EXP__", replacement: "4932")
        defineMacro("__FLT_MAX__", replacement: "3.40282347e+38F")
        defineMacro("__DBL_MAX__", replacement: "1.7976931348623157e+308")
        defineMacro("__LDBL_MAX__", replacement: "1.18973149535723176502e+4932L")
        defineMacro("__FLT_EPSILON__", replacement: "1.19209290e-7F")
        defineMacro("__DBL_EPSILON__", replacement: "2.2204460492503131e-16")
        defineMacro("__LDBL_EPSILON__", replacement: "1.08420217248550443401e-19L")
        defineMacro("__FLT_MIN__", replacement: "1.17549435e-38F")
        defineMacro("__DBL_MIN__", replacement: "2.2250738585072014e-308")
        defineMacro("__LDBL_MIN__", replacement: "3.36210314311209350626e-4932L")
        defineMacro("__FLT_DENORM_MIN__", replacement: "1.40129846e-45F")
        defineMacro("__DBL_DENORM_MIN__", replacement: "4.9406564584124654e-324")
        defineMacro("__LDBL_DENORM_MIN__", replacement: "3.64519953188247460253e-4951L")
        defineMacro("__FLT_DECIMAL_DIG__", replacement: "9")
        defineMacro("__DBL_DECIMAL_DIG__", replacement: "17")
        defineMacro("__LDBL_DECIMAL_DIG__", replacement: "21")
        defineMacro("__DECIMAL_DIG__", replacement: "21")
        defineMacro("__FLT_EVAL_METHOD__", replacement: "0")
        defineMacro("__FLT_HAS_DENORM__", replacement: "1")
        defineMacro("__DBL_HAS_DENORM__", replacement: "1")
        defineMacro("__LDBL_HAS_DENORM__", replacement: "1")

        // C23 #embed status constants & dynamic macros
        defineMacro("__STDC_EMBED_NOT_FOUND__", replacement: "0")
        defineMacro("__STDC_EMBED_FOUND__", replacement: "1")
        defineMacro("__STDC_EMBED_EMPTY__", replacement: "2")
        defineMacro("__LINE__", replacement: "1")
        defineMacro("__FILE__", replacement: "\"<input>\"")
        defineMacro("__COUNTER__", replacement: "0")
    }

    /// Helper to define an object-like macro from a string expression.
    public func defineMacro(_ name: String, replacement: String) {
        let dummyFileId = sourceManager.addBuffer(bytes: Array(replacement.utf8), path: "<predefined>")
        let sf = sourceManager[dummyFileId]
        var tb = TokenBuffer()
        let lexer = CLexer(fileId: dummyFileId, buffer: sf.buffer, length: sf.length, baseLocation: sf.baseLocation)
        lexer.lexInto(&tb)

        var tokens: [PPToken] = []
        for i in 1..<Int(tb.count) {
            let tid = TokenId(UInt32(i))
            let k = CTokenKind(rawValue: tb.kind(of: tid)) ?? .errorToken
            if k == .eof { break }
            let f = TokenFlags(rawValue: tb.flag(of: tid))
            let s = tb.start(of: tid)
            let e = tb.end(of: tid)
            let txt = String(decoding: UnsafeBufferPointer(start: sf.buffer.baseAddress! + Int(s.rawValue - sf.baseLocation.rawValue), count: Int(e.rawValue - s.rawValue)), as: UTF8.self)
            tokens.append(PPToken(kind: k, flags: f, location: s, endLocation: e, spelling: txt))
        }

        macros[name] = PPMacro(name: name, isFunctionLike: false, replacementTokens: tokens, location: .zero)
    }

    /// Undefines a macro.
    public func undefMacro(_ name: String) {
        macros.removeValue(forKey: name)
    }

    public func isMacroDefined(_ name: String) -> Bool {
        macros[name] != nil
    }

    // MARK: - Main Preprocessing Entry Point

    /// Preprocesses a given file into a target `TokenBuffer`.
    public func preprocess(fileId: FileId, into output: inout TokenBuffer) {
        let sf = sourceManager[fileId]
        activeInclusions.append(sf.path)
        defer { activeInclusions.removeLast() }

        var rawTB = TokenBuffer()
        let lexer = CLexer(fileId: fileId, buffer: sf.buffer, length: sf.length, baseLocation: sf.baseLocation)
        lexer.lexInto(&rawTB)

        var rawTokens: [PPToken] = []
        rawTokens.reserveCapacity(Int(rawTB.count))
        for i in 1..<Int(rawTB.count) {
            let tid = TokenId(UInt32(i))
            let k = CTokenKind(rawValue: rawTB.kind(of: tid)) ?? .errorToken
            if k == .eof { break }
            let f = TokenFlags(rawValue: rawTB.flag(of: tid))
            let s = rawTB.start(of: tid)
            let e = rawTB.end(of: tid)
            let off = Int(s.rawValue - sf.baseLocation.rawValue)
            let len = Int(e.rawValue - s.rawValue)
            let txt = (off >= 0 && len >= 0 && off + len <= sf.length) ?
                String(decoding: UnsafeBufferPointer(start: sf.buffer.baseAddress! + off, count: len), as: UTF8.self) : ""
            rawTokens.append(PPToken(kind: k, flags: f, location: s, endLocation: e, spelling: txt))
        }

        var processedTokens: [PPToken] = []
        processTokenStream(rawTokens, currentFilePath: sf.path, into: &processedTokens)

        // Write processed tokens into output TokenBuffer
        let startCount = output.count
        let neededCap = Int(startCount) + processedTokens.count + 1
        output.reserveCapacity(neededCap)

        for tok in processedTokens {
            _ = output.append(
                cKind: tok.kind,
                flags: tok.flags,
                start: tok.location,
                end: tok.endLocation
            )
        }
    }

    // MARK: - Directive Processing & Macro Expansion

    private func processTokenStream(
        _ input: [PPToken],
        currentFilePath: String,
        into output: inout [PPToken]
    ) {
        var cursor = 0
        var condStack: [CondBranch] = []

        func isCurrentActive() -> Bool {
            condStack.allSatisfy { $0.isBranchActive }
        }

        while cursor < input.count {
            let tok = input[cursor]

            // Check if this token starts a preprocessor directive (# at line start)
            let isAtLineStart = (cursor == 0) || tok.isLeadingNewline
            if isAtLineStart && tok.kind == .hash {
                cursor += 1
                // Collect all tokens belonging to this directive line
                var directiveTokens: [PPToken] = []
                while cursor < input.count && !input[cursor].isLeadingNewline {
                    directiveTokens.append(input[cursor])
                    cursor += 1
                }
                handleDirective(
                    directiveTokens,
                    currentFilePath: currentFilePath,
                    condStack: &condStack,
                    into: &output
                )
                continue
            }

            // Normal token: only emit if in active conditional branch
            if isCurrentActive() {
                // Check for macro expansion
                if isIdentifierOrKeyword(tok.kind), macros[tok.spelling] != nil {
                    var expanded: [PPToken] = []
                    cursor = expandMacro(
                        macroName: tok.spelling,
                        tokens: input,
                        index: cursor,
                        disabled: [],
                        into: &expanded
                    )
                    // Macro expansion tokens might themselves contain macros to expand
                    var disabledSet: Set<String> = [tok.spelling]
                    var fullyExpanded: [PPToken] = []
                    expandAllMacros(expanded, disabled: disabledSet, into: &fullyExpanded)
                    while let last = fullyExpanded.last,
                          isIdentifierOrKeyword(last.kind),
                          let m = macros[last.spelling],
                          m.isFunctionLike,
                          !disabledSet.contains(last.spelling),
                          cursor < input.count,
                          input[cursor].kind == .lParen {
                        var depth = 0
                        while cursor < input.count {
                            let argTok = input[cursor]
                            fullyExpanded.append(argTok)
                            cursor += 1
                            if argTok.kind == .lParen {
                                depth += 1
                            } else if argTok.kind == .rParen {
                                depth -= 1
                                if depth == 0 { break }
                            }
                        }
                        var reExpanded: [PPToken] = []
                        expandAllMacros(fullyExpanded, disabled: disabledSet, into: &reExpanded)
                        disabledSet.insert(last.spelling)
                        fullyExpanded = reExpanded
                    }
                    output.append(contentsOf: fullyExpanded)
                    continue
                } else {
                    output.append(tok)
                }
            }

            cursor += 1
        }
    }

    private func isIdentifierOrKeyword(_ kind: CTokenKind) -> Bool {
        kind == .identifier || (kind.rawValue >= 10 && kind.rawValue <= 55)
    }

    private func makeSyntheticToken(kind: CTokenKind, flags: TokenFlags, spelling: String) -> PPToken {
        let fid = sourceManager.addBuffer(bytes: Array(spelling.utf8), path: "<scratch>")
        let sf = sourceManager[fid]
        let start = sf.baseLocation
        let end = SourceLocation(sf.baseLocation.rawValue + UInt32(sf.length))
        return PPToken(kind: kind, flags: flags, location: start, endLocation: end, spelling: spelling)
    }

    private func handleDirective(
        _ tokens: [PPToken],
        currentFilePath: String,
        condStack: inout [CondBranch],
        into output: inout [PPToken]
    ) {
        guard let first = tokens.first else {
            // Null directive '#' does nothing
            return
        }

        let isParentActive = condStack.isEmpty || condStack.last!.isBranchActive

        switch first.spelling {
        case "if":
            let active = isParentActive && evaluateCondition(Array(tokens.dropFirst()))
            condStack.append(CondBranch(isParentActive: isParentActive, hasMetCondition: active, isBranchActive: active, directiveLocation: first.location))

        case "ifdef":
            guard tokens.count >= 2 else {
                diagnostics.report(.ppInvalidDirective, at: first.location, args: ["ifdef"])
                return
            }
            let name = tokens[1].spelling
            let defined = isMacroDefined(name)
            let active = isParentActive && defined
            condStack.append(CondBranch(isParentActive: isParentActive, hasMetCondition: active, isBranchActive: active, directiveLocation: first.location))

        case "ifndef":
            guard tokens.count >= 2 else {
                diagnostics.report(.ppInvalidDirective, at: first.location, args: ["ifndef"])
                return
            }
            let name = tokens[1].spelling
            let defined = isMacroDefined(name)
            let active = isParentActive && !defined
            condStack.append(CondBranch(isParentActive: isParentActive, hasMetCondition: active, isBranchActive: active, directiveLocation: first.location))

        case "elif", "elifdef", "elifndef":
            guard let top = condStack.last else {
                diagnostics.report(.ppInvalidDirective, at: first.location, args: [first.spelling])
                return
            }
            condStack.removeLast()
            if top.hasMetCondition || !top.isParentActive {
                condStack.append(CondBranch(isParentActive: top.isParentActive, hasMetCondition: true, isBranchActive: false, directiveLocation: first.location))
            } else {
                let active: Bool
                if first.spelling == "elif" {
                    active = evaluateCondition(Array(tokens.dropFirst()))
                } else if first.spelling == "elifdef" {
                    active = tokens.count >= 2 && isMacroDefined(tokens[1].spelling)
                } else { // elifndef
                    active = tokens.count >= 2 && !isMacroDefined(tokens[1].spelling)
                }
                condStack.append(CondBranch(isParentActive: top.isParentActive, hasMetCondition: active, isBranchActive: active, directiveLocation: first.location))
            }

        case "else":
            guard let top = condStack.last else {
                diagnostics.report(.ppInvalidDirective, at: first.location, args: ["else"])
                return
            }
            condStack.removeLast()
            let active = top.isParentActive && !top.hasMetCondition
            condStack.append(CondBranch(isParentActive: top.isParentActive, hasMetCondition: true, isBranchActive: active, directiveLocation: first.location))

        case "endif":
            guard !condStack.isEmpty else {
                diagnostics.report(.ppInvalidDirective, at: first.location, args: ["endif without #if"])
                return
            }
            condStack.removeLast()

        default:
            // Non-conditional directives: only execute if current block is active!
            guard condStack.allSatisfy({ $0.isBranchActive }) else { return }

            switch first.spelling {
            case "define":
                handleDefine(Array(tokens.dropFirst()), location: first.location)
            case "undef":
                if tokens.count >= 2 {
                    undefMacro(tokens[1].spelling)
                }
            case "include", "include_next":
                let isNext = (first.spelling == "include_next")
                handleInclude(Array(tokens.dropFirst()), currentFilePath: currentFilePath, isNext: isNext, location: first.location, into: &output)
            case "embed":
                handleEmbed(Array(tokens.dropFirst()), currentFilePath: currentFilePath, location: first.location, into: &output)
            case "pragma":
                handlePragma(Array(tokens.dropFirst()), currentFilePath: currentFilePath)
            case "error":
                let msg = tokens.dropFirst().map { $0.spelling }.joined(separator: " ")
                diagnostics.report(.ppUserError, at: first.location, args: [msg])
            case "warning":
                let msg = tokens.dropFirst().map { $0.spelling }.joined(separator: " ")
                diagnostics.report(.ppUserWarning, at: first.location, args: [msg])
            case "line":
                break // Ignored for now
            default:
                diagnostics.report(.ppInvalidDirective, at: first.location, args: [first.spelling])
            }
        }
    }

    private func handleDefine(_ tokens: [PPToken], location: SourceLocation) {
        guard let nameTok = tokens.first, isIdentifierOrKeyword(nameTok.kind) else {
            diagnostics.report(.ppInvalidDirective, at: location, args: ["define"])
            return
        }

        let name = nameTok.spelling
        if tokens.count == 1 {
            // Empty object-like macro `#define FOO`
            macros[name] = PPMacro(name: name, isFunctionLike: false, replacementTokens: [], location: location)
            return
        }

        let second = tokens[1]
        // In C, a function-like macro MUST have '(' immediately following the macro name with NO whitespace!
        if second.kind == .lParen && !second.isLeadingSpace {
            // Function-like macro: #define FOO(a, b, ...)
            var params: [String] = []
            var isVariadic = false
            var variadicName: String? = nil
            var idx = 2

            while idx < tokens.count && tokens[idx].kind != .rParen {
                let pTok = tokens[idx]
                if pTok.kind == .ellipsis {
                    isVariadic = true
                    variadicName = "__VA_ARGS__"
                    idx += 1
                    break
                } else if isIdentifierOrKeyword(pTok.kind) {
                    // Check for named variadic `args...` (GNU extension)
                    if idx + 1 < tokens.count && tokens[idx + 1].kind == .ellipsis {
                        isVariadic = true
                        variadicName = pTok.spelling
                        idx += 2
                        break
                    } else {
                        params.append(pTok.spelling)
                        idx += 1
                    }
                } else if pTok.kind == .comma {
                    idx += 1
                } else {
                    idx += 1
                }
            }

            if idx < tokens.count && tokens[idx].kind == .rParen {
                idx += 1
            }

            let replacements = Array(tokens[idx...])
            macros[name] = PPMacro(
                name: name,
                isFunctionLike: true,
                parameters: params,
                isVariadic: isVariadic,
                variadicParamName: variadicName,
                replacementTokens: replacements,
                location: location
            )
        } else {
            // Object-like macro: #define FOO replacement...
            let replacements = Array(tokens.dropFirst())
            macros[name] = PPMacro(
                name: name,
                isFunctionLike: false,
                replacementTokens: replacements,
                location: location
            )
        }
    }

    private func handleInclude(
        _ tokens: [PPToken],
        currentFilePath: String,
        isNext: Bool,
        location: SourceLocation,
        into output: inout [PPToken]
    ) {
        // Expand macros if line contains computed include e.g. #include HEADER_VAR
        var resolvedTokens: [PPToken] = []
        expandAllMacros(tokens, disabled: [], into: &resolvedTokens)

        guard let first = resolvedTokens.first else {
            diagnostics.report(.ppInvalidDirective, at: location, args: ["include"])
            return
        }

        var headerPath = ""
        var isAngled = false

        if first.kind == .stringLiteral {
            headerPath = first.spelling.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            isAngled = false
        } else if first.kind == .less {
            // Angle bracket include <foo/bar.h>
            isAngled = true
            var parts: [String] = []
            for t in resolvedTokens.dropFirst() {
                if t.kind == .greater { break }
                parts.append(t.spelling)
            }
            headerPath = parts.joined()
        } else {
            headerPath = first.spelling
        }

        guard let targetFile = resolveHeader(headerPath, currentFile: currentFilePath, isAngled: isAngled, isNext: isNext) else {
            diagnostics.report(.ppFileNotFound, at: location, args: [headerPath])
            return
        }

        // Check #pragma once or include guard
        if pragmaOnceFiles.contains(targetFile) {
            return
        }
        if let guardMacro = includeGuards[targetFile], isMacroDefined(guardMacro) {
            return
        }

        do {
            let fid = try sourceManager.loadFile(path: targetFile)
            let sf = sourceManager[fid]
            activeInclusions.append(sf.path)
            defer { activeInclusions.removeLast() }

            var rawTB = TokenBuffer()
            let lexer = CLexer(fileId: fid, buffer: sf.buffer, length: sf.length, baseLocation: sf.baseLocation)
            lexer.lexInto(&rawTB)

            var rawTokens: [PPToken] = []
            rawTokens.reserveCapacity(Int(rawTB.count))
            for i in 1..<Int(rawTB.count) {
                let tid = TokenId(UInt32(i))
                let k = CTokenKind(rawValue: rawTB.kind(of: tid)) ?? .errorToken
                if k == .eof { break }
                let f = TokenFlags(rawValue: rawTB.flag(of: tid))
                let s = rawTB.start(of: tid)
                let e = rawTB.end(of: tid)
                let off = Int(s.rawValue - sf.baseLocation.rawValue)
                let len = Int(e.rawValue - s.rawValue)
                let txt = (off >= 0 && len >= 0 && off + len <= sf.length) ?
                    String(decoding: UnsafeBufferPointer(start: sf.buffer.baseAddress! + off, count: len), as: UTF8.self) : ""
                rawTokens.append(PPToken(kind: k, flags: f, location: s, endLocation: e, spelling: txt))
            }

            var includedTokens: [PPToken] = []
            processTokenStream(rawTokens, currentFilePath: sf.path, into: &includedTokens)
            output.append(contentsOf: includedTokens)
        } catch {
            diagnostics.report(.ppFileNotFound, at: location, args: [targetFile])
        }
    }

    /// Resolves an include file path searching current directory, -I paths, and system include paths.
    public func resolveHeader(_ name: String, currentFile: String, isAngled: Bool, isNext: Bool) -> String? {
        let fm = FileManager.default
        let currentDir = (currentFile as NSString).deletingLastPathComponent

        var searchDirs: [String] = []
        if !isAngled && !isNext {
            searchDirs.append(currentDir)
        }
        searchDirs.append(contentsOf: includePaths)

        var fallbackRelDirs: [String] = []
        if !isNext && !currentDir.isEmpty && !currentDir.hasPrefix("/usr/include") && !currentDir.hasPrefix("/usr/lib") {
            let relDirs = [
                currentDir,
                (currentDir as NSString).appendingPathComponent("include"),
                (currentDir as NSString).appendingPathComponent("../include"),
                (currentDir as NSString).appendingPathComponent("../../include"),
                (currentDir as NSString).appendingPathComponent("../../c/include")
            ]
            for rd in relDirs {
                let stdRd = (rd as NSString).standardizingPath
                if fm.fileExists(atPath: stdRd) && !fallbackRelDirs.contains(stdRd) {
                    fallbackRelDirs.append(stdRd)
                }
            }
        }

        if !isAngled {
            for rd in fallbackRelDirs where !searchDirs.contains(rd) {
                searchDirs.append(rd)
            }
        }
        searchDirs.append(contentsOf: systemIncludePaths)
        if isAngled {
            for rd in fallbackRelDirs where !searchDirs.contains(rd) {
                searchDirs.append(rd)
            }
        }

        if isNext {
            // Find search directory containing currentFile and start after it
            if let idx = searchDirs.firstIndex(where: { currentFile == $0 || currentFile.hasPrefix($0 + "/") }) {
                searchDirs = Array(searchDirs.dropFirst(idx + 1))
            }
        }

        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: candidate) {
                return (candidate as NSString).standardizingPath
            }
        }

        return nil
    }

    private func handlePragma(_ tokens: [PPToken], currentFilePath: String) {
        if tokens.first?.spelling == "once" {
            pragmaOnceFiles.insert(currentFilePath)
        }
    }

    // MARK: - C23 #embed Directive Handling

    private func handleEmbed(
        _ tokens: [PPToken],
        currentFilePath: String,
        location: SourceLocation,
        into output: inout [PPToken]
    ) {
        guard let first = tokens.first else {
            diagnostics.report(.ppInvalidDirective, at: location, args: ["embed"])
            return
        }

        var resourcePath = ""
        var isAngled = false
        var paramStart = 1

        if first.kind == .stringLiteral {
            resourcePath = first.spelling.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            isAngled = false
        } else if first.kind == .less {
            isAngled = true
            var parts: [String] = []
            paramStart = 1
            for t in tokens.dropFirst() {
                paramStart += 1
                if t.kind == .greater { break }
                parts.append(t.spelling)
            }
            resourcePath = parts.joined()
        }

        guard let resolvedPath = resolveHeader(resourcePath, currentFile: currentFilePath, isAngled: isAngled, isNext: false) else {
            diagnostics.report(.ppEmbedNotFound, at: location, args: [resourcePath])
            return
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedPath)) else {
            diagnostics.report(.ppEmbedNotFound, at: location, args: [resolvedPath])
            return
        }

        // Parse optional parameters: limit(N), prefix(...), suffix(...), if_empty(...)
        var limitVal: Int? = nil
        var prefixTokens: [PPToken] = []
        var suffixTokens: [PPToken] = []
        var ifEmptyTokens: [PPToken] = []

        var pIdx = paramStart
        while pIdx < tokens.count {
            let pName = tokens[pIdx].spelling
            pIdx += 1
            if pIdx < tokens.count && tokens[pIdx].kind == .lParen {
                pIdx += 1
                var paramContent: [PPToken] = []
                var depth = 1
                while pIdx < tokens.count && depth > 0 {
                    if tokens[pIdx].kind == .lParen { depth += 1 }
                    else if tokens[pIdx].kind == .rParen { depth -= 1; if depth == 0 { pIdx += 1; break } }
                    paramContent.append(tokens[pIdx])
                    pIdx += 1
                }

                switch pName {
                case "limit":
                    if let firstInt = paramContent.first, let num = Int(firstInt.spelling) {
                        limitVal = num
                    }
                case "prefix":
                    prefixTokens = paramContent
                case "suffix":
                    suffixTokens = paramContent
                case "if_empty":
                    ifEmptyTokens = paramContent
                default:
                    diagnostics.report(.ppEmbedInvalidParam, at: location, args: [pName])
                }
            }
        }

        if data.isEmpty {
            output.append(contentsOf: ifEmptyTokens)
            return
        }

        var finalData = data
        if let lim = limitVal, lim < finalData.count {
            finalData = finalData.prefix(lim)
        }

        let assetId = BinaryAssetPool.shared.intern(path: resolvedPath, data: finalData)
        let sliceIdx = BinaryAssetPool.shared.registerSlice(assetId: assetId, offset: 0, count: UInt32(finalData.count))

        output.append(contentsOf: prefixTokens)

        // Single embedAsset token
        let embedTok = makeSyntheticToken(
            kind: .embedAsset,
            flags: TokenFlags(rawValue: 0),
            spelling: String(sliceIdx)
        )
        output.append(embedTok)

        output.append(contentsOf: suffixTokens)
    }

    // MARK: - Macro Expansion Algorithm

    private func expandAllMacros(_ input: [PPToken], disabled: Set<String>, into output: inout [PPToken]) {
        var i = 0
        while i < input.count {
            let tok = input[i]
            if isIdentifierOrKeyword(tok.kind), macros[tok.spelling] != nil, !disabled.contains(tok.spelling) {
                var nextExpanded: [PPToken] = []
                i = expandMacro(macroName: tok.spelling, tokens: input, index: i, disabled: disabled, into: &nextExpanded)
                var subDisabled = disabled.union([tok.spelling])
                var subOutput: [PPToken] = []
                expandAllMacros(nextExpanded, disabled: subDisabled, into: &subOutput)
                while let last = subOutput.last,
                      isIdentifierOrKeyword(last.kind),
                      let m = macros[last.spelling],
                      m.isFunctionLike,
                      !subDisabled.contains(last.spelling),
                      i < input.count,
                      input[i].kind == .lParen {
                    var depth = 0
                    while i < input.count {
                        let argTok = input[i]
                        subOutput.append(argTok)
                        i += 1
                        if argTok.kind == .lParen {
                            depth += 1
                        } else if argTok.kind == .rParen {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                    var reExpanded: [PPToken] = []
                    expandAllMacros(subOutput, disabled: subDisabled, into: &reExpanded)
                    subDisabled.insert(last.spelling)
                    subOutput = reExpanded
                }
                output.append(contentsOf: subOutput)
            } else {
                output.append(tok)
                i += 1
            }
        }
    }

    private func expandMacro(
        macroName: String,
        tokens: [PPToken],
        index: Int,
        disabled: Set<String>,
        into output: inout [PPToken]
    ) -> Int {
        guard let macro = macros[macroName] else {
            output.append(tokens[index])
            return index + 1
        }

        // Special dynamic macros
        if macroName == "__LINE__" {
            let lineNum = 1 // approximated or resolved via LineTable
            output.append(makeSyntheticToken(kind: .intLiteral, flags: tokens[index].flags, spelling: "\(lineNum)"))
            return index + 1
        } else if macroName == "__FILE__" {
            let path = activeInclusions.last ?? "<input>"
            output.append(makeSyntheticToken(kind: .stringLiteral, flags: tokens[index].flags, spelling: "\"\(path)\""))
            return index + 1
        } else if macroName == "__COUNTER__" {
            let val = counterValue
            counterValue += 1
            output.append(makeSyntheticToken(kind: .intLiteral, flags: tokens[index].flags, spelling: "\(val)"))
            return index + 1
        }

        if !macro.isFunctionLike {
            // Object-like macro: substitute replacement tokens directly, preserving their SourceLocations
            for rep in macro.replacementTokens {
                output.append(rep)
            }
            return index + 1
        }

        // Function-like macro: requires '(' as next non-whitespace token
        var nextIdx = index + 1
        guard nextIdx < tokens.count && tokens[nextIdx].kind == .lParen else {
            // Not a function call; do not expand
            output.append(tokens[index])
            return index + 1
        }

        nextIdx += 1 // skip '('
        var args: [[PPToken]] = []
        var currentArg: [PPToken] = []
        var depth = 1

        while nextIdx < tokens.count && depth > 0 {
            let t = tokens[nextIdx]
            if t.kind == .lParen {
                depth += 1
                currentArg.append(t)
            } else if t.kind == .rParen {
                depth -= 1
                if depth == 0 {
                    args.append(currentArg)
                    nextIdx += 1
                    break
                } else {
                    currentArg.append(t)
                }
            } else if t.kind == .comma && depth == 1 {
                // If variadic and we've gathered all named parameters, the rest belongs to __VA_ARGS__
                if macro.isVariadic && args.count >= macro.parameters.count {
                    currentArg.append(t)
                } else {
                    args.append(currentArg)
                    currentArg = []
                }
            } else {
                currentArg.append(t)
            }
            nextIdx += 1
        }

        // Match parameters to arguments
        var paramToArg: [String: [PPToken]] = [:]
        for (pIdx, paramName) in macro.parameters.enumerated() {
            if pIdx < args.count {
                paramToArg[paramName] = args[pIdx]
            } else {
                paramToArg[paramName] = []
            }
        }

        if macro.isVariadic {
            let vName = macro.variadicParamName ?? "__VA_ARGS__"
            if args.count > macro.parameters.count {
                let vArgs = args[macro.parameters.count...]
                var merged: [PPToken] = []
                for (vi, v) in vArgs.enumerated() {
                    if vi > 0 {
                        merged.append(makeSyntheticToken(kind: .comma, flags: TokenFlags(rawValue: 0), spelling: ","))
                    }
                    merged.append(contentsOf: v)
                }
                paramToArg[vName] = merged
            } else {
                paramToArg[vName] = []
            }
        }

        // Substitute replacement tokens
        var subst: [PPToken] = []
        var repIdx = 0
        while repIdx < macro.replacementTokens.count {
            let rep = macro.replacementTokens[repIdx]

            // C23 __VA_OPT__(...)
            if rep.spelling == "__VA_OPT__" && repIdx + 1 < macro.replacementTokens.count && macro.replacementTokens[repIdx + 1].kind == .lParen {
                repIdx += 2
                var optTokens: [PPToken] = []
                var optDepth = 1
                while repIdx < macro.replacementTokens.count && optDepth > 0 {
                    let ot = macro.replacementTokens[repIdx]
                    if ot.kind == .lParen { optDepth += 1; optTokens.append(ot) }
                    else if ot.kind == .rParen { optDepth -= 1; if optDepth == 0 { break } else { optTokens.append(ot) } }
                    else { optTokens.append(ot) }
                    repIdx += 1
                }
                repIdx += 1 // skip closing ')'

                let vaName = macro.variadicParamName ?? "__VA_ARGS__"
                let hasVarArgs = !(paramToArg[vaName]?.isEmpty ?? true)
                if hasVarArgs {
                    subst.append(contentsOf: optTokens)
                }
                continue
            }

            // Stringizing '#'
            if rep.kind == .hash && repIdx + 1 < macro.replacementTokens.count {
                let nextRep = macro.replacementTokens[repIdx + 1]
                if let arg = paramToArg[nextRep.spelling] {
                    let strContent = arg.map { $0.spelling }.joined(separator: " ")
                    let escaped = "\"" + strContent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                    subst.append(makeSyntheticToken(kind: .stringLiteral, flags: rep.flags, spelling: escaped))
                    repIdx += 2
                    continue
                }
            }

            // Token pasting '##'
            if rep.kind == .hashHash {
                // Combine last token with next
                if !subst.isEmpty && repIdx + 1 < macro.replacementTokens.count {
                    let prev = subst.removeLast()
                    let nextRep = macro.replacementTokens[repIdx + 1]
                    if let arg = paramToArg[nextRep.spelling] {
                        if let firstArg = arg.first {
                            let pastedSpelling = prev.spelling + firstArg.spelling
                            let pastedKind = classifyPastedToken(pastedSpelling)
                            subst.append(makeSyntheticToken(kind: pastedKind, flags: prev.flags, spelling: pastedSpelling))
                            if arg.count > 1 {
                                subst.append(contentsOf: arg.dropFirst())
                            }
                        } else {
                            subst.append(prev)
                        }
                    } else {
                        let pastedSpelling = prev.spelling + nextRep.spelling
                        let pastedKind = classifyPastedToken(pastedSpelling)
                        subst.append(makeSyntheticToken(kind: pastedKind, flags: prev.flags, spelling: pastedSpelling))
                    }
                    repIdx += 2
                    continue
                }
            }

            // Normal parameter substitution (pre-expanded)
            if let arg = paramToArg[rep.spelling] {
                // If adjacent to ##, parameter is not pre-expanded
                let isAdjacentToPaste = (repIdx + 1 < macro.replacementTokens.count && macro.replacementTokens[repIdx + 1].kind == .hashHash) ||
                                        (repIdx > 0 && macro.replacementTokens[repIdx - 1].kind == .hashHash)
                if isAdjacentToPaste {
                    subst.append(contentsOf: arg)
                } else {
                    var preExpandedArg: [PPToken] = []
                    expandAllMacros(arg, disabled: disabled, into: &preExpandedArg)
                    subst.append(contentsOf: preExpandedArg)
                }
            } else {
                subst.append(rep)
            }

            repIdx += 1
        }

        output.append(contentsOf: subst)
        return nextIdx
    }

    private func classifyPastedToken(_ s: String) -> CTokenKind {
        guard let first = s.utf8.first else { return .identifier }
        if first >= 0x30 && first <= 0x39 {
            return s.contains(".") ? .floatLiteral : .intLiteral
        }
        if first == 0x22 { return .stringLiteral }
        if first == 0x27 { return .charLiteral }
        let utf8 = Array(s.utf8)
        let rawKind = utf8.withUnsafeBufferPointer { buf in
            CLexer.matchCKeyword(ptr: buf.baseAddress!, length: buf.count)
        }
        return CTokenKind(rawValue: rawKind) ?? .identifier
    }

    // MARK: - Constant Expression Evaluation (#if / #elif)

    private func replaceDefinedAndQueries(_ tokens: [PPToken]) -> [PPToken] {
        var result: [PPToken] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.spelling == "defined" {
                i += 1
                var name = ""
                if i < tokens.count && tokens[i].kind == .lParen {
                    i += 1
                    if i < tokens.count && isIdentifierOrKeyword(tokens[i].kind) {
                        name = tokens[i].spelling
                        i += 1
                    }
                    if i < tokens.count && tokens[i].kind == .rParen {
                        i += 1
                    }
                } else if i < tokens.count && isIdentifierOrKeyword(tokens[i].kind) {
                    name = tokens[i].spelling
                    i += 1
                }
                let val = isMacroDefined(name) ? "1" : "0"
                result.append(makeSyntheticToken(kind: .intLiteral, flags: t.flags, spelling: val))
                continue
            }

            // Builtin queries: __has_include, __has_embed, __has_c_attribute, __has_builtin, __has_feature, __has_extension
            if (t.spelling == "__has_include" || t.spelling == "__has_embed" || t.spelling == "__has_c_attribute" ||
                t.spelling == "__has_builtin" || t.spelling == "__has_feature" || t.spelling == "__has_extension") &&
                i + 1 < tokens.count && tokens[i + 1].kind == .lParen {
                let query = t.spelling
                i += 2
                var queryArg = ""
                while i < tokens.count && tokens[i].kind != .rParen {
                    queryArg += tokens[i].spelling
                    i += 1
                }
                if i < tokens.count && tokens[i].kind == .rParen { i += 1 }

                let qVal = evaluateQuery(query, arg: queryArg)
                result.append(makeSyntheticToken(kind: .intLiteral, flags: t.flags, spelling: "\(qVal)"))
                continue
            }

            result.append(t)
            i += 1
        }
        return result
    }

    public func evaluateCondition(_ tokens: [PPToken]) -> Bool {
        // Step 1: Replace direct defined(X) and builtin queries
        let step1 = replaceDefinedAndQueries(tokens)

        // Step 2: Expand remaining macros, then replace any defined(X) produced by macro expansion
        var expanded: [PPToken] = []
        expandAllMacros(step1, disabled: [], into: &expanded)
        let step2 = replaceDefinedAndQueries(expanded)

        // Step 3: Any remaining identifiers/keywords become 0 (except 'true' -> 1)
        var step3: [PPToken] = []
        for t in step2 {
            if t.kind == .kwTrue {
                step3.append(makeSyntheticToken(kind: .intLiteral, flags: t.flags, spelling: "1"))
            } else if t.kind == .kwFalse {
                step3.append(makeSyntheticToken(kind: .intLiteral, flags: t.flags, spelling: "0"))
            } else if isIdentifierOrKeyword(t.kind) {
                let val = (t.spelling == "true" || t.spelling == "__true") ? "1" : "0"
                step3.append(makeSyntheticToken(kind: .intLiteral, flags: t.flags, spelling: val))
            } else {
                step3.append(t)
            }
        }

        // Step 4: Evaluate integer expression with Pratt parser
        var pCursor = 0
        let val = parseConditionalExpr(step3, cursor: &pCursor, minPrec: 0)
        return val != 0
    }

    private func evaluateQuery(_ query: String, arg: String) -> Int64 {
        let cleanArg = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"<>"))
        switch query {
        case "__has_include":
            return resolveHeader(cleanArg, currentFile: "", isAngled: arg.hasPrefix("<"), isNext: false) != nil ? 1 : 0
        case "__has_embed":
            return resolveHeader(cleanArg, currentFile: "", isAngled: arg.hasPrefix("<"), isNext: false) != nil ? 1 : 0
        case "__has_c_attribute":
            switch cleanArg {
            case "nodiscard", "maybe_unused", "deprecated", "fallthrough", "noreturn", "_Noreturn", "reproducible", "unsequenced":
                return 202311
            default:
                return 0
            }
        case "__has_builtin":
            let builtins: Set<String> = [
                "__builtin_expect", "__builtin_trap", "__builtin_unreachable", "__builtin_constant_p",
                "__builtin_types_compatible_p", "__builtin_va_start", "__builtin_va_end", "__builtin_va_copy",
                "__builtin_offsetof", "__builtin_memcpy", "__builtin_memset", "__builtin_memmove",
                "__builtin_alloca", "__builtin_clz", "__builtin_ctz", "__builtin_popcount",
                "__builtin_bswap16", "__builtin_bswap32", "__builtin_bswap64", "__builtin_add_overflow",
                "__builtin_sub_overflow", "__builtin_mul_overflow"
            ]
            return builtins.contains(cleanArg) ? 1 : 0
        case "__has_feature", "__has_extension":
            let features: Set<String> = [
                "c_alignas", "c_alignof", "c_atomic", "c_generic_selections", "c_static_assert", "c_thread_local"
            ]
            return features.contains(cleanArg) ? 1 : 0
        default:
            return 0
        }
    }

    private func parseConditionalExpr(_ tokens: [PPToken], cursor: inout Int, minPrec: Int) -> Int64 {
        guard cursor < tokens.count else { return 0 }

        // Primary prefix expression
        var left = parseConditionalPrimary(tokens, cursor: &cursor)

        while cursor < tokens.count {
            let op = tokens[cursor]
            let prec = binaryPrecedence(op.kind)
            if prec < minPrec { break }

            cursor += 1

            if op.kind == .question {
                // Ternary conditional expr: cond ? then : else
                let thenVal = parseConditionalExpr(tokens, cursor: &cursor, minPrec: 0)
                var elseVal: Int64 = 0
                if cursor < tokens.count && tokens[cursor].kind == .colon {
                    cursor += 1
                    elseVal = parseConditionalExpr(tokens, cursor: &cursor, minPrec: 0)
                }
                left = (left != 0) ? thenVal : elseVal
                continue
            }

            let nextMinPrec = prec + 1
            let right = parseConditionalExpr(tokens, cursor: &cursor, minPrec: nextMinPrec)

            switch op.kind {
            case .pipePipe:           left = ((left != 0) || (right != 0)) ? 1 : 0
            case .ampAmp:             left = ((left != 0) && (right != 0)) ? 1 : 0
            case .pipe:               left = left | right
            case .caret:              left = left ^ right
            case .amp:                left = left & right
            case .equalEqual:         left = (left == right) ? 1 : 0
            case .exclaimEqual:       left = (left != right) ? 1 : 0
            case .less:               left = (left < right) ? 1 : 0
            case .lessEqual:          left = (left <= right) ? 1 : 0
            case .greater:            left = (left > right) ? 1 : 0
            case .greaterEqual:       left = (left >= right) ? 1 : 0
            case .lessLess:           left = left << right
            case .greaterGreater:     left = left >> right
            case .plus:               left = left &+ right
            case .minus:              left = left &- right
            case .star:               left = left &* right
            case .slash:              left = right != 0 ? left / right : 0
            case .percent:            left = right != 0 ? left % right : 0
            default: break
            }
        }

        return left
    }

    private func parseConditionalPrimary(_ tokens: [PPToken], cursor: inout Int) -> Int64 {
        guard cursor < tokens.count else { return 0 }
        let t = tokens[cursor]
        cursor += 1

        switch t.kind {
        case .plus:
            return parseConditionalPrimary(tokens, cursor: &cursor)
        case .minus:
            return -parseConditionalPrimary(tokens, cursor: &cursor)
        case .tilde:
            return ~parseConditionalPrimary(tokens, cursor: &cursor)
        case .exclaim:
            return (parseConditionalPrimary(tokens, cursor: &cursor) == 0) ? 1 : 0
        case .lParen:
            let val = parseConditionalExpr(tokens, cursor: &cursor, minPrec: 0)
            if cursor < tokens.count && tokens[cursor].kind == .rParen {
                cursor += 1
            }
            return val
        case .intLiteral:
            var s = t.spelling.lowercased().filter { $0 != "'" }
            while let last = s.last, last == "u" || last == "l" || last == "z" {
                s.removeLast()
            }
            if s.hasPrefix("0x") {
                if let u = UInt64(s.dropFirst(2), radix: 16) { return Int64(bitPattern: u) }
                return 0
            } else if s.hasPrefix("0b") {
                if let u = UInt64(s.dropFirst(2), radix: 2) { return Int64(bitPattern: u) }
                return 0
            } else if s.hasPrefix("0") && s.count > 1 {
                if let u = UInt64(s.dropFirst(1), radix: 8) { return Int64(bitPattern: u) }
                return 0
            } else {
                let digits = s.prefix(while: { $0 >= "0" && $0 <= "9" })
                if let u = UInt64(digits) { return Int64(bitPattern: u) }
                return 0
            }
        case .charLiteral:
            if let c = t.spelling.dropFirst().first {
                return Int64(c.asciiValue ?? 0)
            }
            return 0
        default:
            return 0
        }
    }

    private func binaryPrecedence(_ kind: CTokenKind) -> Int {
        switch kind {
        case .question:                             return 1
        case .pipePipe:                             return 2
        case .ampAmp:                               return 3
        case .pipe:                                 return 4
        case .caret:                                return 5
        case .amp:                                  return 6
        case .equalEqual, .exclaimEqual:            return 7
        case .less, .lessEqual, .greater, .greaterEqual: return 8
        case .lessLess, .greaterGreater:            return 9
        case .plus, .minus:                         return 10
        case .star, .slash, .percent:               return 11
        default:                                    return -1
        }
    }
}
