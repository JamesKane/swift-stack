// Sources/SwiftStack/Parse/CParser.swift
import Foundation

/// A high-performance non-backtracking recursive descent & Pratt precedence parser for ISO C23 (01-frontend.md §4.6-4.7).
/// Generates a flat postorder `ParseTree` with explicit recursion bounding and scoped typedef disambiguation.
public struct CParser: ~Copyable {
    private let tokens: UnsafePointer<TokenBuffer>
    private let sourceBuffer: UnsafePointer<UInt8>
    private let sourceLength: Int
    private let sourceManager: SourceManager?
    private var cursor: Int = 1
    private var parseTree: ParseTree

    // Scoped typedef names for C disambiguation (T * x vs x * y)
    private var typedefScopes: [Set<String>] = []

    // Stack depth protection (Principle: G3)
    private var currentDepth: Int = 0
    private let maxDepth: Int = 1024

    public init(tokens: UnsafePointer<TokenBuffer>, sourceBuffer: UnsafePointer<UInt8>, sourceLength: Int, sourceManager: SourceManager? = nil) {
        self.tokens = tokens
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
        self.sourceManager = sourceManager
        self.parseTree = ParseTree()

        // Initialize global scope with standard POSIX / C23 typedefs
        let globalTypedefs: Set<String> = [
            "int8_t", "int16_t", "int32_t", "int64_t",
            "uint8_t", "uint16_t", "uint32_t", "uint64_t",
            "int_least8_t", "int_least16_t", "int_least32_t", "int_least64_t",
            "uint_least8_t", "uint_least16_t", "uint_least32_t", "uint_least64_t",
            "int_fast8_t", "int_fast16_t", "int_fast32_t", "int_fast64_t",
            "uint_fast8_t", "uint_fast16_t", "uint_fast32_t", "uint_fast64_t",
            "intptr_t", "uintptr_t", "intmax_t", "uintmax_t",
            "size_t", "ssize_t", "ptrdiff_t", "max_align_t", "nullptr_t",
            "wchar_t", "char8_t", "char16_t", "char32_t",
            "time_t", "clock_t", "pid_t", "off_t", "mode_t", "uid_t", "gid_t",
            "FILE", "fpos_t", "va_list", "__builtin_va_list",
            "Component_1_t", "Component_2_t"
        ]
        self.typedefScopes = [globalTypedefs]
    }

    // MARK: - Scopes

    private mutating func pushScope() {
        typedefScopes.append([])
    }

    private mutating func popScope() {
        if typedefScopes.count > 1 {
            typedefScopes.removeLast()
        }
    }

    private mutating func registerTypedef(_ name: String) {
        if !typedefScopes.isEmpty {
            typedefScopes[typedefScopes.count - 1].insert(name)
        }
    }

    private func isTypedefName(_ name: String) -> Bool {
        for scope in typedefScopes.reversed() {
            if scope.contains(name) { return true }
        }
        return false
    }

    // MARK: - Token Inspection

    var isAtEnd: Bool {
        cursor >= tokens.pointee.count || currentKind == .eof || currentKind == .nilToken
    }

    var currentTokenId: TokenId {
        guard cursor < tokens.pointee.count else { return .nilId }
        return TokenId(UInt32(cursor))
    }

    var currentKind: CTokenKind {
        guard cursor < tokens.pointee.count else { return .eof }
        let raw = tokens.pointee.kind(of: TokenId(UInt32(cursor)))
        return CTokenKind(rawValue: raw) ?? .errorToken
    }

    func peekKind(offset: Int = 1) -> CTokenKind {
        let idx = cursor + offset
        guard idx < tokens.pointee.count else { return .eof }
        let raw = tokens.pointee.kind(of: TokenId(UInt32(idx)))
        return CTokenKind(rawValue: raw) ?? .errorToken
    }

    @discardableResult
    mutating func advance() -> TokenId {
        let tok = currentTokenId
        if cursor < tokens.pointee.count {
            cursor += 1
        }
        return tok
    }

    mutating func match(_ kind: CTokenKind) -> Bool {
        if currentKind == kind {
            advance()
            return true
        }
        return false
    }

    @discardableResult
    mutating func expect(_ kind: CTokenKind) -> TokenId {
        if currentKind == kind {
            return advance()
        }
        let errTok = currentTokenId
        if !isAtEnd { advance() }
        return errTok
    }

    public func tokenSpelling(of id: TokenId) -> String {
        guard id.isValid else { return "" }
        let s = tokens.pointee.start(of: id)
        let e = tokens.pointee.end(of: id)
        let len = Int(e.rawValue - s.rawValue)
        guard len >= 0 else { return "" }

        if let sm = sourceManager {
            if let (file, off) = sm.file(containing: s) {
                guard let base = file.buffer.baseAddress, Int(off) + len <= file.length else { return "" }
                return String(decoding: UnsafeBufferPointer(start: base + Int(off), count: len), as: UTF8.self)
            }
        }
        let sRaw = Int(s.rawValue)
        guard sRaw >= 0, sRaw + len <= sourceLength else { return "" }
        return String(decoding: UnsafeBufferPointer(start: sourceBuffer + sRaw, count: len), as: UTF8.self)
    }

    // MARK: - Public Entry Point

    public consuming func parse() -> ParseTree {
        let start = parseTree.count
        var hasError = false

        while !isAtEnd {
            // Semicolons at top level (e.g. extra semicolons in header files)
            if currentKind == .semicolon {
                advance()
                continue
            }

            // Skip top-level extension attributes / keywords
            if currentKind == .identifier {
                let sp = tokenSpelling(of: currentTokenId)
                if sp == "__extension__" {
                    advance()
                    continue
                }
            }

            let prevCursor = cursor
            let decl = parseExternalDeclaration()
            if decl.isNil {
                hasError = true
                parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
                // Synchronize on semicolon or brace
                while !isAtEnd && currentKind != .semicolon && currentKind != .rBrace {
                    advance()
                }
                if !isAtEnd && (currentKind == .semicolon || currentKind == .rBrace || cursor == prevCursor) {
                    advance()
                }
            }
        }

        let totalSize = parseTree.count - start + 1
        let rootTok = tokens.pointee.count > 1 ? TokenId(1) : .nilId
        parseTree.append(kind: .translationUnit, token: rootTok, subtreeSize: totalSize, hasError: hasError)
        return consume parseTree
    }

    // MARK: - Attributes & Modifiers

    /// Consumes attributes: C23 `[[...]]`, `alignas(...)`, GNU `__attribute__((...))`, `__declspec(...)`, `__asm__("...")`.
    private mutating func parseAttributes() {
        while !isAtEnd {
            if currentKind == .lBracket && peekKind() == .lBracket {
                // C23 [[attribute]]
                let start = parseTree.count
                let anchor = advance() // [
                advance() // [
                var depth = 2
                while !isAtEnd && depth > 0 {
                    if currentKind == .lBracket { depth += 1 }
                    else if currentKind == .rBracket {
                        depth -= 1
                        if depth == 0 { advance(); break }
                    }
                    advance()
                }
                let subSize = parseTree.count - start + 1
                parseTree.append(kind: .attributeSpec, token: anchor, subtreeSize: subSize)
            } else if currentKind == .kwAlignas {
                let anchor = advance()
                if currentKind == .lParen {
                    advance()
                    var depth = 1
                    while !isAtEnd && depth > 0 {
                        if currentKind == .lParen { depth += 1 }
                        else if currentKind == .rParen {
                            depth -= 1
                            if depth == 0 { advance(); break }
                        }
                        advance()
                    }
                }
                parseTree.appendLeaf(kind: .attributeSpec, token: anchor)
            } else if currentKind == .identifier {
                let sp = tokenSpelling(of: currentTokenId)
                if sp == "__attribute__" || sp == "__attribute" || sp == "__declspec" {
                    let start = parseTree.count
                    let anchor = advance()
                    if currentKind == .lParen {
                        advance()
                        var depth = 1
                        while !isAtEnd && depth > 0 {
                            if currentKind == .lParen { depth += 1 }
                            else if currentKind == .rParen {
                                depth -= 1
                                if depth == 0 { advance(); break }
                            }
                            advance()
                        }
                    }
                    let subSize = parseTree.count - start + 1
                    parseTree.append(kind: .attributeSpec, token: anchor, subtreeSize: subSize)
                } else if sp == "__asm__" || sp == "__asm" || sp == "asm" {
                    let anchor = advance()
                    if currentKind == .lParen {
                        advance()
                        var depth = 1
                        while !isAtEnd && depth > 0 {
                            if currentKind == .lParen { depth += 1 }
                            else if currentKind == .rParen {
                                depth -= 1
                                if depth == 0 { advance(); break }
                            }
                            advance()
                        }
                    }
                    parseTree.appendLeaf(kind: .attributeSpec, token: anchor)
                } else if sp == "__extension__" || sp == "__inline" || sp == "__inline__" ||
                          sp == "__restrict" || sp == "__restrict__" || sp == "_Noreturn" {
                    advance()
                } else {
                    break
                }
            } else {
                break
            }
        }
    }

    // MARK: - Declarations

    private func isBuiltinExtendedTypeName(_ sp: String) -> Bool {
        switch sp {
        case "__builtin_va_list", "__gnuc_va_list",
             "__int128", "__int128_t", "__uint128_t",
             "__float128", "__float80", "__ibm128",
             "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128",
             "_Decimal32", "_Decimal64", "_Decimal128",
             "_Complex", "__complex__", "__complex", "_Imaginary":
            return true
        default:
            return false
        }
    }

    private mutating func isTypeStart() -> Bool {
        switch currentKind {
        case .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble,
             .kwSigned, .kwUnsigned, .kwBool, .kwAtomic, .kwStruct, .kwUnion, .kwEnum,
             .kwTypeof, .kwTypeofUnqual, .kwNullptr,
             .kwConst, .kwVolatile, .kwRestrict, .kwAlignas,
             .kwStatic, .kwExtern, .kwAuto, .kwRegister, .kwThreadLocal, .kwConstexpr, .kwInline:
            return true
        case .kwTypedef:
            return true
        case .identifier:
            let sp = tokenSpelling(of: currentTokenId)
            return isTypedefName(sp) || sp == "_BitInt" || sp == "__typeof__" || sp == "__typeof" ||
                   isBuiltinExtendedTypeName(sp)
        default:
            return false
        }
    }

    private mutating func parseExternalDeclaration() -> NodeId {
        parseAttributes()
        guard !isAtEnd else { return .nilId }

        if currentKind == .kwStaticAssert {
            return parseStaticAssert()
        }

        if currentKind == .kwTypedef {
            return parseTypedefDeclaration()
        }

        return parseDeclarationOrFunction()
    }

    private mutating func parseStaticAssert() -> NodeId {
        let start = parseTree.count
        let anchor = advance() // static_assert
        expect(.lParen)
        _ = parseExpression()
        if currentKind == .comma {
            advance()
            _ = parseExpression()
        }
        expect(.rParen)
        expect(.semicolon)
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .staticAssertDecl, token: anchor, subtreeSize: subSize)
    }

    private mutating func parseTypedefDeclaration() -> NodeId {
        let start = parseTree.count
        let anchor = advance() // typedef
        parseAttributes()
        _ = parseType()
        parseAttributes()

        var lastNameTok = anchor

        // Parse declarators
        while !isAtEnd && currentKind != .semicolon {
            let prevCursor = cursor
            parseAttributes()
            while currentKind == .star || isQualifierOrStorage(currentKind) {
                if currentKind == .star {
                    let star = advance()
                    let subSize = parseTree.count - start + 1
                    parseTree.append(kind: .pointerType, token: star, subtreeSize: subSize)
                } else {
                    advance()
                }
                parseAttributes()
            }
            if currentKind == .lParen {
                // Function pointer or parenthesized declarator: `typedef void (*name)(int)`
                advance()
                parseAttributes()
                while currentKind == .star || isQualifierOrStorage(currentKind) {
                    advance()
                    parseAttributes()
                }
                if currentKind == .identifier {
                    let nameTok = advance()
                    let name = tokenSpelling(of: nameTok)
                    registerTypedef(name)
                    lastNameTok = nameTok
                }
                var pDepth = 1
                while !isAtEnd && pDepth > 0 {
                    if currentKind == .lParen { pDepth += 1 }
                    else if currentKind == .rParen {
                        pDepth -= 1
                        if pDepth == 0 { advance(); break }
                    }
                    advance()
                }
            } else if currentKind == .identifier {
                let nameTok = advance()
                let name = tokenSpelling(of: nameTok)
                registerTypedef(name)
                lastNameTok = nameTok
            }
            parseAttributes()
            // Array or function suffixes
            while currentKind == .lBracket || currentKind == .lParen {
                advance()
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if currentKind == .lBracket || currentKind == .lParen { depth += 1 }
                    else if currentKind == .rBracket || currentKind == .rParen {
                        depth -= 1
                        if depth == 0 { advance(); break }
                    }
                    advance()
                }
                parseAttributes()
            }
            if currentKind == .comma {
                advance()
            } else if cursor == prevCursor {
                advance()
            } else {
                break
            }
        }
        expect(.semicolon)

        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .typedefDecl, token: lastNameTok, subtreeSize: subSize)
    }

    /// Parses a declaration (variable, struct/union/enum tag, or function definition).
    private mutating func parseDeclarationOrFunction() -> NodeId {
        let start = parseTree.count
        parseAttributes()

        if currentKind == .semicolon {
            let semi = advance()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .varDecl, token: semi, subtreeSize: subSize)
        }
        if currentKind == .kwStaticAssert {
            return parseStaticAssert()
        }
        if currentKind == .kwTypedef {
            return parseTypedefDeclaration()
        }

        // Parse declaration specifiers (storage class, qualifiers, type)
        guard isTypeStart() else { return .nilId }
        _ = parseType()

        // Tag declarations without declarators: `struct Foo { ... };` or `enum E { ... };`
        if currentKind == .semicolon {
            let semi = advance()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .varDecl, token: semi, subtreeSize: subSize)
        }

        // Anonymous bitfield `int : 0;`
        if currentKind == .colon {
            let colonTok = advance()
            _ = parseAssignmentExpression()
            expect(.semicolon)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .varDecl, token: colonTok, subtreeSize: subSize)
        }

        parseAttributes()

        // Parse pointers and qualifiers if any: `* const restrict`
        while currentKind == .star || isQualifierOrStorage(currentKind) {
            if currentKind == .star {
                let star = advance()
                parseAttributes()
                let subSize = parseTree.count - start + 1
                parseTree.append(kind: .pointerType, token: star, subtreeSize: subSize)
            } else {
                advance()
                parseAttributes()
            }
        }

        var nameTok: TokenId = currentTokenId
        var hasParenDeclarator = false
        var hasInnerParamList = false
        if currentKind == .lParen {
            hasParenDeclarator = true
            // Function pointer declarator: `void (*fn)(int)`, `int (*fn(int))(int)`, or `void (*(*x)(void*))(void)`
            var outerParens = 0
            while currentKind == .lParen || currentKind == .star || isQualifierOrStorage(currentKind) {
                if currentKind == .lParen {
                    outerParens += 1
                    advance()
                } else if currentKind == .star {
                    let star = advance()
                    let subSize = parseTree.count - start + 1
                    parseTree.append(kind: .pointerType, token: star, subtreeSize: subSize)
                } else {
                    advance()
                }
                parseAttributes()
            }
            if currentKind == .identifier {
                nameTok = advance()
            }
            parseAttributes()
            if outerParens == 1 && currentKind == .lParen {
                hasInnerParamList = true
                advance()
                _ = parseParameterList()
                expect(.rParen)
                parseAttributes()
            }
            var pDepth = outerParens
            while !isAtEnd && pDepth > 0 {
                if currentKind == .lParen { pDepth += 1 }
                else if currentKind == .rParen {
                    pDepth -= 1
                    if pDepth == 0 { advance(); break }
                }
                advance()
            }
            // Consume parameter list(s) following `(*fn)`
            while currentKind == .lParen || currentKind == .lBracket {
                advance()
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if currentKind == .lParen || currentKind == .lBracket { depth += 1 }
                    else if currentKind == .rParen || currentKind == .rBracket {
                        depth -= 1
                        if depth == 0 { advance(); break }
                    }
                    advance()
                }
                parseAttributes()
            }
        } else if currentKind == .identifier {
            nameTok = advance()
        } else {
            return .nilId
        }
        parseAttributes()

        if hasParenDeclarator && (hasInnerParamList || currentKind == .lBrace) {
            if currentKind == .lBrace {
                _ = parseCompoundStatement()
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .functionDecl, token: nameTok, subtreeSize: subSize)
            } else if hasInnerParamList && currentKind == .semicolon {
                advance()
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .functionDecl, token: nameTok, subtreeSize: subSize)
            }
        }

        // Function definition or declaration
        if currentKind == .lParen {
            advance()
            _ = parseParameterList()
            expect(.rParen)
            parseAttributes()

            if currentKind == .lBrace {
                // Function definition with body
                _ = parseCompoundStatement()
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .functionDecl, token: nameTok, subtreeSize: subSize)
            } else {
                // Function prototype declaration
                expect(.semicolon)
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .functionDecl, token: nameTok, subtreeSize: subSize)
            }
        }

        // Variable or array declaration
        while currentKind == .lBracket {
            let lBrk = advance()
            while isQualifierOrStorage(currentKind) { advance() }
            if currentKind != .rBracket {
                _ = parseExpression()
            }
            expect(.rBracket)
            let subSize = parseTree.count - start + 1
            parseTree.append(kind: .arrayType, token: lBrk, subtreeSize: subSize)
        }
        parseAttributes()

        // Bitfield width: `: expr`
        if currentKind == .colon {
            advance()
            _ = parseAssignmentExpression()
        }

        // Initializer: `=`
        if currentKind == .equal {
            advance()
            _ = parseInitializer()
        }

        // Additional declarators in the same statement: `int a, b = 2;` or `Expr *pE, sEAlt;`
        while currentKind == .comma {
            advance()
            let extraStart = parseTree.count
            var extraNameTok: TokenId = .nilId
            parseAttributes()
            while currentKind == .star || isQualifierOrStorage(currentKind) {
                if currentKind == .star {
                    let star = advance()
                    parseTree.appendLeaf(kind: .pointerType, token: star)
                } else {
                    advance()
                }
                parseAttributes()
            }
            if currentKind == .lParen {
                let lPar = advance()
                parseTree.appendLeaf(kind: .pointerType, token: lPar)
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if currentKind == .lParen { depth += 1 }
                    else if currentKind == .rParen {
                        depth -= 1
                        if depth == 0 { advance(); break }
                    }
                    if currentKind == .identifier && extraNameTok.isNil {
                        extraNameTok = currentTokenId
                    }
                    advance()
                }
                while currentKind == .lParen || currentKind == .lBracket {
                    advance()
                    var d2 = 1
                    while !isAtEnd && d2 > 0 {
                        if currentKind == .lParen || currentKind == .lBracket { d2 += 1 }
                        else if currentKind == .rParen || currentKind == .rBracket {
                            d2 -= 1
                            if d2 == 0 { advance(); break }
                        }
                        advance()
                    }
                }
            } else if currentKind == .identifier {
                extraNameTok = advance()
                while currentKind == .lBracket {
                    let arrStart = parseTree.count
                    let lBrk = advance()
                    while isQualifierOrStorage(currentKind) { advance() }
                    if currentKind != .rBracket { _ = parseExpression() }
                    expect(.rBracket)
                    let arrSize = parseTree.count - arrStart + 1
                    parseTree.append(kind: .arrayType, token: lBrk, subtreeSize: arrSize)
                }
            }
            parseAttributes()
            if currentKind == .colon {
                advance()
                _ = parseAssignmentExpression()
            }
            if currentKind == .equal {
                advance()
                _ = parseInitializer()
            }
            if extraNameTok.isValid {
                let extraSize = parseTree.count - extraStart + 1
                parseTree.append(kind: .fieldDecl, token: extraNameTok, subtreeSize: extraSize)
            }
        }

        expect(.semicolon)
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .varDecl, token: nameTok, subtreeSize: subSize)
    }

    // MARK: - Types

    /// Parses type specifiers, qualifiers, and tags.
    @discardableResult
    private mutating func parseType() -> NodeId {
        let start = parseTree.count
        var anchorTok = currentTokenId

        var hasStorage = false
        var lastStorageTok = currentTokenId
        // Consume leading qualifiers / storage specifiers: `const`, `static`, `inline`, `auto`, etc.
        while isQualifierOrStorage(currentKind) {
            hasStorage = true
            lastStorageTok = advance()
            if lastStorageTok != .nilId && tokens.pointee.kind(of: lastStorageTok) == CTokenKind.kwAtomic.rawValue && currentKind == .lParen {
                // _Atomic(type)
                advance()
                _ = parseType()
                while currentKind == .star { advance() }
                expect(.rParen)
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .typeSpec, token: lastStorageTok, subtreeSize: subSize)
            }
            parseAttributes()
        }

        // C23 auto type inference: if storage/qualifier was seen and no type specifier follows
        if hasStorage && !isTypeStart() {
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .typeSpec, token: lastStorageTok, subtreeSize: subSize)
        }

        switch currentKind {
        case .kwStruct, .kwUnion:
            let isUnion = (currentKind == .kwUnion)
            anchorTok = advance()
            parseAttributes()

            // Optional tag name
            if currentKind == .identifier {
                anchorTok = advance()
                parseAttributes()
            }

            // Member specification `{ ... }`
            if currentKind == .lBrace {
                advance()
                while !isAtEnd && currentKind != .rBrace {
                    let prevCursor = cursor
                    parseAttributes()
                    if currentKind == .rBrace { break }
                    if isTypeStart() {
                        _ = parseDeclarationOrFunction()
                    } else if currentKind == .semicolon {
                        advance()
                    } else {
                        advance()
                    }
                    if cursor == prevCursor && !isAtEnd {
                        advance()
                    }
                }
                expect(.rBrace)
                parseAttributes()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: isUnion ? .unionType : .structType, token: anchorTok, subtreeSize: subSize)

        case .kwEnum:
            anchorTok = advance()
            parseAttributes()
            if currentKind == .identifier {
                anchorTok = advance()
                parseAttributes()
            }
            // C23 underlying type specification: `enum E : unsigned char`
            if currentKind == .colon {
                advance()
                _ = parseType()
            }
            if currentKind == .lBrace {
                advance()
                while !isAtEnd && currentKind != .rBrace {
                    let prevCursor = cursor
                    if currentKind == .identifier {
                        let enumStart = parseTree.count
                        let enumName = advance()
                        parseAttributes()
                        if currentKind == .equal {
                            advance()
                            _ = parseAssignmentExpression()
                        }
                        let enumSub = parseTree.count - enumStart + 1
                        parseTree.append(kind: .enumeratorDecl, token: enumName, subtreeSize: enumSub)
                    }
                    if currentKind == .comma {
                        advance()
                    } else if cursor == prevCursor && !isAtEnd && currentKind != .rBrace {
                        advance()
                    } else {
                        break
                    }
                }
                expect(.rBrace)
                parseAttributes()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .enumType, token: anchorTok, subtreeSize: subSize)

        case .kwTypeof, .kwTypeofUnqual:
            let isUnqual = (currentKind == .kwTypeofUnqual)
            anchorTok = advance()
            expect(.lParen)
            if isTypeStart() {
                _ = parseTypeNameInParens()
            } else {
                _ = parseExpression()
            }
            expect(.rParen)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: isUnqual ? .typeofUnqualType : .typeofType, token: anchorTok, subtreeSize: subSize)

        case .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble,
             .kwSigned, .kwUnsigned, .kwBool, .kwNullptr:
            anchorTok = advance()
            // Consume multiple specifiers: `unsigned long long`, `signed char`, `double _Complex`, etc.
            while isPrimitiveTypeSpecifier(currentKind) || isQualifierOrStorage(currentKind) ||
                  (currentKind == .identifier && isBuiltinExtendedTypeName(tokenSpelling(of: currentTokenId))) {
                advance()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .typeSpec, token: anchorTok, subtreeSize: subSize)

        case .identifier:
            let sp = tokenSpelling(of: currentTokenId)
            if sp == "_BitInt" {
                anchorTok = advance()
                if currentKind == .lParen {
                    advance()
                    _ = parseExpression()
                    expect(.rParen)
                }
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .typeSpec, token: anchorTok, subtreeSize: subSize)
            } else if isTypedefName(sp) || isBuiltinExtendedTypeName(sp) {
                anchorTok = advance()
                while isQualifierOrStorage(currentKind) || isPrimitiveTypeSpecifier(currentKind) ||
                      (currentKind == .identifier && isBuiltinExtendedTypeName(tokenSpelling(of: currentTokenId))) {
                    advance()
                }
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .typeSpec, token: anchorTok, subtreeSize: subSize)
            } else {
                return parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
            }

        default:
            return parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
        }
    }

    private func isQualifierOrStorage(_ kind: CTokenKind) -> Bool {
        switch kind {
        case .kwConst, .kwVolatile, .kwRestrict, .kwAtomic,
             .kwStatic, .kwExtern, .kwAuto, .kwRegister, .kwThreadLocal, .kwConstexpr, .kwInline:
            return true
        default:
            return false
        }
    }

    private func isPrimitiveTypeSpecifier(_ kind: CTokenKind) -> Bool {
        switch kind {
        case .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble,
             .kwSigned, .kwUnsigned, .kwBool:
            return true
        default:
            return false
        }
    }

    private mutating func parseParameterList() -> NodeId {
        let start = parseTree.count
        var paramCount = 0

        if currentKind == .rParen {
            // f() in C23 means f(void)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .paramList, token: currentTokenId, subtreeSize: subSize)
        }

        while !isAtEnd && currentKind != .rParen {
            let prevCursor = cursor
            parseAttributes()
            if currentKind == .ellipsis {
                let elTok = advance()
                parseTree.appendLeaf(kind: .paramDecl, token: elTok)
                paramCount += 1
                break
            }

            let pStart = parseTree.count
            _ = parseType()
            parseAttributes()
            while currentKind == .star || isQualifierOrStorage(currentKind) {
                if currentKind == .star {
                    let star = advance()
                    let subSize = parseTree.count - pStart + 1
                    parseTree.append(kind: .pointerType, token: star, subtreeSize: subSize)
                } else {
                    advance()
                }
                parseAttributes()
            }
            var nameTok = currentTokenId
            if currentKind == .lParen {
                // Function pointer parameter: `int (*cmp)(const void *, const void *)`
                advance()
                parseAttributes()
                while currentKind == .star || isQualifierOrStorage(currentKind) {
                    advance()
                    parseAttributes()
                }
                if currentKind == .identifier {
                    nameTok = advance()
                }
                var pDepth = 1
                while !isAtEnd && pDepth > 0 {
                    if currentKind == .lParen { pDepth += 1 }
                    else if currentKind == .rParen {
                        pDepth -= 1
                        if pDepth == 0 { advance(); break }
                    }
                    advance()
                }
                while currentKind == .lParen || currentKind == .lBracket {
                    advance()
                    var depth = 1
                    while !isAtEnd && depth > 0 {
                        if currentKind == .lParen || currentKind == .lBracket { depth += 1 }
                        else if currentKind == .rParen || currentKind == .rBracket {
                            depth -= 1
                            if depth == 0 { advance(); break }
                        }
                        advance()
                    }
                }
            } else if currentKind == .identifier {
                nameTok = advance()
            }
            parseAttributes()
            while currentKind == .lBracket {
                advance()
                while isQualifierOrStorage(currentKind) { advance() }
                if currentKind != .rBracket { _ = parseExpression() }
                expect(.rBracket)
            }
            parseAttributes()
            let pSize = parseTree.count - pStart + 1
            parseTree.append(kind: .paramDecl, token: nameTok, subtreeSize: pSize)
            paramCount += 1

            if currentKind == .comma {
                advance()
            } else if cursor == prevCursor && !isAtEnd && currentKind != .rParen {
                advance()
            } else {
                break
            }
        }

        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .paramList, token: currentTokenId, subtreeSize: subSize)
    }

    // MARK: - Initializers

    private mutating func parseInitializer() -> NodeId {
        if currentKind == .lBrace {
            // Braced initializer list `{ ... }`
            let start = parseTree.count
            let anchor = advance() // {

            while !isAtEnd && currentKind != .rBrace {
                if currentKind == .period {
                    // Designated member: `.field = val`
                    let dStart = parseTree.count
                    _ = advance()
                    let field = expect(.identifier)
                    expect(.equal)
                    _ = parseInitializer()
                    let dSize = parseTree.count - dStart + 1
                    parseTree.append(kind: .designatedInit, token: field, subtreeSize: dSize)
                } else if currentKind == .lBracket {
                    // Designated array index: `[index] = val`
                    let dStart = parseTree.count
                    let lBrk = advance()
                    _ = parseExpression()
                    expect(.rBracket)
                    expect(.equal)
                    _ = parseInitializer()
                    let dSize = parseTree.count - dStart + 1
                    parseTree.append(kind: .designatedInit, token: lBrk, subtreeSize: dSize)
                } else {
                    _ = parseInitializer()
                }

                if currentKind == .comma {
                    advance()
                } else {
                    break
                }
            }
            expect(.rBrace)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .initList, token: anchor, subtreeSize: subSize)
        } else {
            return parseAssignmentExpression()
        }
    }

    // MARK: - Statements

    private mutating func parseStatement() -> NodeId {
        guard currentDepth < maxDepth else {
            return parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
        }
        currentDepth += 1
        defer { currentDepth -= 1 }

        switch currentKind {
        case .lBrace:
            return parseCompoundStatement()

        case .kwReturn:
            let start = parseTree.count
            let anchor = advance()
            if currentKind != .semicolon {
                _ = parseExpression()
            }
            expect(.semicolon)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .returnStmt, token: anchor, subtreeSize: subSize)

        case .kwIf:
            let start = parseTree.count
            let anchor = advance()
            if currentKind == .kwConstexpr {
                _ = advance()
            }
            expect(.lParen)
            _ = parseExpression()
            expect(.rParen)
            _ = parseStatement()
            if currentKind == .kwElse {
                advance()
                _ = parseStatement()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .ifStmt, token: anchor, subtreeSize: subSize)

        case .kwSwitch:
            let start = parseTree.count
            let anchor = advance()
            expect(.lParen)
            _ = parseExpression()
            expect(.rParen)
            _ = parseStatement()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .switchStmt, token: anchor, subtreeSize: subSize)

        case .kwCase:
            let start = parseTree.count
            let anchor = advance()
            _ = parseExpression()
            expect(.colon)
            if currentKind != .rBrace && currentKind != .kwCase && currentKind != .kwDefault {
                _ = parseStatement()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .caseStmt, token: anchor, subtreeSize: subSize)

        case .kwDefault:
            let start = parseTree.count
            let anchor = advance()
            expect(.colon)
            if currentKind != .rBrace && currentKind != .kwCase && currentKind != .kwDefault {
                _ = parseStatement()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .defaultStmt, token: anchor, subtreeSize: subSize)

        case .kwWhile:
            let start = parseTree.count
            let anchor = advance()
            expect(.lParen)
            _ = parseExpression()
            expect(.rParen)
            _ = parseStatement()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .whileStmt, token: anchor, subtreeSize: subSize)

        case .kwDo:
            let start = parseTree.count
            let anchor = advance()
            _ = parseStatement()
            expect(.kwWhile)
            expect(.lParen)
            _ = parseExpression()
            expect(.rParen)
            expect(.semicolon)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .doWhileStmt, token: anchor, subtreeSize: subSize)

        case .kwFor:
            let start = parseTree.count
            let anchor = advance()
            expect(.lParen)
            pushScope()
            if currentKind == .semicolon {
                advance()
            } else if isTypeStart() {
                _ = parseDeclarationOrFunction()
            } else {
                _ = parseExpression()
                expect(.semicolon)
            }
            if currentKind != .semicolon {
                _ = parseExpression()
            }
            expect(.semicolon)
            if currentKind != .rParen {
                _ = parseExpression()
            }
            expect(.rParen)
            _ = parseStatement()
            popScope()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .forStmt, token: anchor, subtreeSize: subSize)

        case .kwGoto:
            let start = parseTree.count
            let anchor = advance()
            if currentKind == .star {
                advance()
                _ = parseExpression()
            } else {
                _ = expect(.identifier)
            }
            expect(.semicolon)
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .gotoStmt, token: anchor, subtreeSize: subSize)

        case .kwContinue:
            let anchor = advance()
            expect(.semicolon)
            return parseTree.appendLeaf(kind: .continueStmt, token: anchor)

        case .kwBreak:
            let anchor = advance()
            expect(.semicolon)
            return parseTree.appendLeaf(kind: .breakStmt, token: anchor)

        case .semicolon:
            let anchor = advance()
            return parseTree.appendLeaf(kind: .exprStmt, token: anchor)

        case .identifier:
            // Check for labeled statement: `label:`
            if peekKind() == .colon {
                let start = parseTree.count
                let label = advance()
                advance() // :
                _ = parseStatement()
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .labelStmt, token: label, subtreeSize: subSize)
            }
            fallthrough

        default:
            // Declaration or expression statement
            if isTypeStart() {
                return parseDeclarationOrFunction()
            } else {
                let start = parseTree.count
                let anchor = currentTokenId
                _ = parseExpression()
                expect(.semicolon)
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .exprStmt, token: anchor, subtreeSize: subSize)
            }
        }
    }

    private mutating func parseCompoundStatement() -> NodeId {
        let start = parseTree.count
        let anchor = advance() // {
        pushScope()

        while !isAtEnd && currentKind != .rBrace {
            while currentKind == .identifier && tokenSpelling(of: currentTokenId) == "__extension__" {
                advance()
            }
            if currentKind == .rBrace { break }
            if isTypeStart() {
                _ = parseDeclarationOrFunction()
            } else {
                _ = parseStatement()
            }
        }
        expect(.rBrace)
        popScope()

        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .compoundStmt, token: anchor, subtreeSize: subSize)
    }

    // MARK: - Expressions (Pratt Precedence Climbing)

    private mutating func parseExpression() -> NodeId {
        let start = parseTree.count
        var left = parseAssignmentExpression()

        // Comma operator `,`
        while currentKind == .comma {
            let comma = advance()
            _ = parseAssignmentExpression()
            let subSize = parseTree.count - start + 1
            left = parseTree.append(kind: .commaExpr, token: comma, subtreeSize: subSize)
        }
        return left
    }

    private mutating func parseAssignmentExpression() -> NodeId {
        let start = parseTree.count
        let left = parseConditionalExpression()

        if isAssignmentOperator(currentKind) {
            let opTok = advance()
            _ = parseAssignmentExpression() // right-associative
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .assignExpr, token: opTok, subtreeSize: subSize)
        }
        return left
    }

    private mutating func parseConditionalExpression() -> NodeId {
        let start = parseTree.count
        var left = parseBinaryExpression(minPrec: 0)

        // Ternary `? :`
        if currentKind == .question {
            let qTok = advance()
            _ = parseExpression()
            expect(.colon)
            _ = parseConditionalExpression()
            let subSize = parseTree.count - start + 1
            left = parseTree.append(kind: .conditionalExpr, token: qTok, subtreeSize: subSize)
        }
        return left
    }

    private mutating func parseBinaryExpression(minPrec: Int) -> NodeId {
        let start = parseTree.count
        var left = parseCastOrUnaryExpression()

        while true {
            let prec = operatorPrecedence(currentKind)
            if prec < minPrec { break }

            let opTok = advance()
            let nextMinPrec = prec + 1
            _ = parseBinaryExpression(minPrec: nextMinPrec)

            let subSize = parseTree.count - start + 1
            left = parseTree.append(kind: .binaryExpr, token: opTok, subtreeSize: subSize)
        }

        return left
    }

    private mutating func parseTypeNameInParens() -> NodeId {
        let typeStart = parseTree.count
        var lastNode = parseType()
        parseAttributes()
        while currentKind == .star || isQualifierOrStorage(currentKind) {
            if currentKind == .star {
                let star = advance()
                let pSub = parseTree.count - typeStart + 1
                lastNode = parseTree.append(kind: .pointerType, token: star, subtreeSize: pSub)
            } else {
                advance()
            }
            parseAttributes()
        }
        // Abstract function pointer or array declarator in type name: `void (*)(int)` or `int [4]`
        while currentKind == .lParen || currentKind == .lBracket {
            if currentKind == .lBracket {
                let lBrk = advance()
                if currentKind != .rBracket { _ = parseExpression() }
                expect(.rBracket)
                let aSub = parseTree.count - typeStart + 1
                lastNode = parseTree.append(kind: .arrayType, token: lBrk, subtreeSize: aSub)
            } else {
                let lPar = advance()
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if currentKind == .lParen { depth += 1 }
                    else if currentKind == .rParen {
                        depth -= 1
                        if depth == 0 { advance(); break }
                    }
                    advance()
                }
                let pSub = parseTree.count - typeStart + 1
                lastNode = parseTree.append(kind: .pointerType, token: lPar, subtreeSize: pSub)
            }
        }
        return lastNode
    }

    private mutating func parseCastOrUnaryExpression() -> NodeId {
        while currentKind == .identifier && tokenSpelling(of: currentTokenId) == "__extension__" {
            advance()
        }
        // Cast expression or compound literal: `(type)expr` or `(type){ ... }`
        if currentKind == .lParen && isTypeSpecifierInParenthesis() {
            let start = parseTree.count
            let lParen = advance()
            _ = parseTypeNameInParens()
            expect(.rParen)
            if currentKind == .lBrace {
                _ = parseInitializer()
                let subSize = parseTree.count - start + 1
                let compLit = parseTree.append(kind: .castExpr, token: lParen, subtreeSize: subSize)
                return parsePostfixTail(start: start, base: compLit)
            } else {
                _ = parseCastOrUnaryExpression()
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .castExpr, token: lParen, subtreeSize: subSize)
            }
        }

        // Unary operators
        if isUnaryOperator(currentKind) {
            let start = parseTree.count
            let opTok = advance()
            _ = parseCastOrUnaryExpression()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .unaryExpr, token: opTok, subtreeSize: subSize)
        }

        if currentKind == .kwSizeof || currentKind == .kwAlignof {
            let start = parseTree.count
            let opTok = advance()
            if currentKind == .lParen && isTypeSpecifierInParenthesis() {
                advance()
                _ = parseTypeNameInParens()
                expect(.rParen)
            } else {
                _ = parseCastOrUnaryExpression()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .unaryExpr, token: opTok, subtreeSize: subSize)
        }

        return parsePostfixExpression()
    }

    private mutating func isTypeSpecifierInParenthesis() -> Bool {
        let next = peekKind(offset: 1)
        switch next {
        case .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble,
             .kwSigned, .kwUnsigned, .kwBool, .kwStruct, .kwUnion, .kwEnum,
             .kwConst, .kwVolatile, .kwRestrict, .kwAtomic, .kwTypeof, .kwTypeofUnqual, .kwAlignas:
            return true
        case .identifier:
            let idx = cursor + 1
            guard idx < tokens.pointee.count else { return false }
            let sp = tokenSpelling(of: TokenId(UInt32(idx)))
            return isTypedefName(sp) || isBuiltinExtendedTypeName(sp) || sp == "_BitInt" || sp == "__typeof__" || sp == "__typeof"
        default:
            return false
        }
    }

    private mutating func parsePostfixExpression() -> NodeId {
        let start = parseTree.count
        let expr = parsePrimaryExpression()
        return parsePostfixTail(start: start, base: expr)
    }

    private mutating func parsePostfixTail(start: UInt32, base: NodeId) -> NodeId {
        var expr = base
        while true {
            switch currentKind {
            case .lBracket:
                // Array subscript `a[b]`
                let lBrk = advance()
                _ = parseExpression()
                expect(.rBracket)
                let subSize = parseTree.count - start + 1
                expr = parseTree.append(kind: .subscriptExpr, token: lBrk, subtreeSize: subSize)

            case .lParen:
                // Call `f(...)`
                let lParen = advance()
                _ = parseArgumentList()
                expect(.rParen)
                let subSize = parseTree.count - start + 1
                expr = parseTree.append(kind: .callExpr, token: lParen, subtreeSize: subSize)

            case .period, .arrow:
                // Member access `a.b` or `a->b`
                let opTok = advance()
                let fieldTok = expect(.identifier)
                parseTree.appendLeaf(kind: .identExpr, token: fieldTok)
                let subSize = parseTree.count - start + 1
                expr = parseTree.append(kind: .memberExpr, token: opTok, subtreeSize: subSize)

            case .plusPlus, .minusMinus:
                // Postfix increment / decrement
                let opTok = advance()
                let subSize = parseTree.count - start + 1
                expr = parseTree.append(kind: .unaryExpr, token: opTok, subtreeSize: subSize)

            default:
                return expr
            }
        }
    }

    private mutating func parseArgumentList() -> NodeId {
        let start = parseTree.count
        while !isAtEnd && currentKind != .rParen {
            let prevCursor = cursor
            if isTypeStart() {
                _ = parseTypeNameInParens()
            } else {
                _ = parseAssignmentExpression()
            }
            if currentKind == .comma {
                advance()
            } else if cursor == prevCursor && !isAtEnd && currentKind != .rParen {
                advance()
            } else {
                break
            }
        }
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .argList, token: currentTokenId, subtreeSize: subSize)
    }

    private mutating func parsePrimaryExpression() -> NodeId {
        let tok = currentTokenId
        switch currentKind {
        case .identifier:
            if tokenSpelling(of: tok) == "_Generic" {
                let gStart = parseTree.count
                let gTok = advance()
                expect(.lParen)
                _ = parseAssignmentExpression()
                while currentKind == .comma {
                    advance()
                    let assocStart = parseTree.count
                    let assocTok = currentTokenId
                    if currentKind == .kwDefault {
                        advance()
                        expect(.colon)
                        _ = parseAssignmentExpression()
                    } else {
                        _ = parseTypeNameInParens()
                        expect(.colon)
                        _ = parseAssignmentExpression()
                    }
                    let assocSub = parseTree.count - assocStart + 1
                    parseTree.append(kind: .genericAssoc, token: assocTok, subtreeSize: assocSub)
                }
                expect(.rParen)
                let gSub = parseTree.count - gStart + 1
                return parseTree.append(kind: .genericExpr, token: gTok, subtreeSize: gSub)
            }
            advance()
            return parseTree.appendLeaf(kind: .identExpr, token: tok)

        case .intLiteral:
            advance()
            return parseTree.appendLeaf(kind: .intLiteral, token: tok)

        case .floatLiteral:
            advance()
            return parseTree.appendLeaf(kind: .floatLiteral, token: tok)

        case .charLiteral:
            advance()
            return parseTree.appendLeaf(kind: .charLiteral, token: tok)

        case .stringLiteral:
            advance()
            // Support adjacent string literal concatenation: `"a" "b"`
            while currentKind == .stringLiteral {
                advance()
            }
            return parseTree.appendLeaf(kind: .stringLiteral, token: tok)

        case .kwTrue, .kwFalse:
            advance()
            return parseTree.appendLeaf(kind: .boolLiteral, token: tok)

        case .kwNullptr:
            advance()
            return parseTree.appendLeaf(kind: .nullptrLiteral, token: tok)

        case .embedAsset:
            advance()
            return parseTree.appendLeaf(kind: .embedSequence, token: tok)

        case .lParen:
            advance()
            if currentKind == .lBrace {
                // GNU statement expression `({ ... })`
                let stmtExpr = parseCompoundStatement()
                expect(.rParen)
                return stmtExpr
            }
            let expr = parseExpression()
            expect(.rParen)
            return expr

        default:
            let errTok = advance()
            return parseTree.appendLeaf(kind: .errorNode, token: errTok, hasError: true)
        }
    }

    // MARK: - Operator Precedence

    private func isAssignmentOperator(_ kind: CTokenKind) -> Bool {
        switch kind {
        case .equal, .plusEqual, .minusEqual, .starEqual, .slashEqual, .percentEqual,
             .lessLessEqual, .greaterGreaterEqual, .ampEqual, .caretEqual, .pipeEqual:
            return true
        default:
            return false
        }
    }

    private func isUnaryOperator(_ kind: CTokenKind) -> Bool {
        switch kind {
        case .plusPlus, .minusMinus, .amp, .ampAmp, .star, .plus, .minus, .tilde, .exclaim:
            return true
        default:
            return false
        }
    }

    private func operatorPrecedence(_ kind: CTokenKind) -> Int {
        switch kind {
        case .pipePipe:                             return 1  // Logical OR
        case .ampAmp:                               return 2  // Logical AND
        case .pipe:                                 return 3  // Bitwise OR
        case .caret:                                return 4  // Bitwise XOR
        case .amp:                                  return 5  // Bitwise AND
        case .equalEqual, .exclaimEqual:            return 6  // Equality
        case .less, .lessEqual, .greater, .greaterEqual: return 7 // Relational
        case .lessLess, .greaterGreater:            return 8  // Shift
        case .plus, .minus:                         return 9  // Additive
        case .star, .slash, .percent:               return 10 // Multiplicative
        default:                                    return -1
        }
    }
}
