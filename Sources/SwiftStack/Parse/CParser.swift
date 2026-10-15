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

    // Scoped ordinary-identifier namespace for C disambiguation (`T * x` vs `x * y`): each name maps to its
    // bindings, innermost last, recording whether it is a typedef name in that scope, so an inner variable
    // named `T` hides an outer typedef `T`. `scopeNames` lists the names bound in each open scope.
    private var nameBindings: [String: [(depth: Int, isTypedef: Bool)]] = [:]
    private var scopeNames: [[String]] = [[]]
    /// The source file of the last token whose bytes were read (consecutive tokens share a file).
    private let fileCache = FileCache()
    // Struct/union member names live in their own namespace and never hide typedef names.
    private var memberDeclarationDepth: Int = 0

    // Stack depth protection (Principle: G3)
    private var currentDepth: Int = 0
    private let maxDepth: Int = 1024

    /// Typedef names that a raw (unpreprocessed) parse can assume, as `<stdint.h>`/`<stddef.h>` would declare
    /// them. Only the `--bench` parser kernel uses this; normal compilation declares every typedef in source.
    public static let benchmarkPredeclaredTypedefs: Set<String> = [
        "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
        "intptr_t", "uintptr_t", "intmax_t", "uintmax_t", "size_t", "ssize_t", "ptrdiff_t",
    ]

    public init(
        tokens: UnsafePointer<TokenBuffer>,
        sourceBuffer: UnsafePointer<UInt8>,
        sourceLength: Int,
        sourceManager: SourceManager? = nil,
        predeclaredTypedefs: Set<String> = []
    ) {
        self.tokens = tokens
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
        self.sourceManager = sourceManager
        self.parseTree = ParseTree()

        // `__builtin_va_list` is the only typedef name the compiler itself provides (used by <stdarg.h>)
        bind("__builtin_va_list", isTypedef: true)
        for name in predeclaredTypedefs { bind(name, isTypedef: true) }
    }

    // MARK: - Scopes

    private mutating func pushScope() {
        scopeNames.append([])
    }

    private mutating func popScope() {
        guard scopeNames.count > 1 else { return }
        for name in scopeNames.removeLast() {
            nameBindings[name]?.removeLast()
            if nameBindings[name]?.isEmpty == true { nameBindings[name] = nil }
        }
    }

    private mutating func bind(_ name: String, isTypedef: Bool) {
        let depth = scopeNames.count
        if let last = nameBindings[name]?.last, last.depth == depth {
            nameBindings[name]![nameBindings[name]!.count - 1].isTypedef = isTypedef
        } else {
            nameBindings[name, default: []].append((depth, isTypedef))
            scopeNames[depth - 1].append(name)
        }
    }

    private mutating func registerTypedef(_ name: String) {
        bind(name, isTypedef: true)
    }

    /// Records an ordinary identifier (variable, parameter) declared in the current scope.
    private mutating func registerOrdinaryName(_ tok: TokenId) {
        guard memberDeclarationDepth == 0, tok.isValid, CTokenKind(rawValue: tokens.pointee.kind(of: tok)) == .identifier else { return }
        let name = tokenSpelling(of: tok)
        if isTypedefName(name) {
            bind(name, isTypedef: false)
        }
    }

    private func isTypedefName(_ name: String) -> Bool {
        nameBindings[name]?.last?.isTypedef ?? false
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
        // Missing token: record the syntax error (the tree is rejected), then skip one token so callers
        // that loop on `expect` always make progress.
        let errTok = currentTokenId
        parseTree.appendLeaf(kind: .errorNode, token: errTok, hasError: true)
        if !isAtEnd { advance() }
        return errTok
    }

    public func tokenSpelling(of id: TokenId) -> String {
        String(decoding: tokenBytes(of: id), as: UTF8.self)
    }

    final class FileCache {
        var start: UInt32 = 1
        var end: UInt32 = 0
        var base: UnsafePointer<UInt8>? = nil
    }

    /// The source bytes of a token, without allocating.
    private func tokenBytes(of id: TokenId) -> UnsafeBufferPointer<UInt8> {
        guard id.isValid else { return UnsafeBufferPointer(start: nil, count: 0) }
        let s = tokens.pointee.start(of: id).rawValue
        let e = tokens.pointee.end(of: id).rawValue
        guard e >= s else { return UnsafeBufferPointer(start: nil, count: 0) }
        let len = Int(e - s)
        if s >= fileCache.start && e <= fileCache.end, let base = fileCache.base {
            return UnsafeBufferPointer(start: base + Int(s - fileCache.start), count: len)
        }
        if let sm = sourceManager {
            if let (file, off) = sm.file(containing: SourceLocation(s)) {
                guard let base = file.buffer.baseAddress, Int(off) + len <= file.length else { return UnsafeBufferPointer(start: nil, count: 0) }
                fileCache.start = s - off
                fileCache.end = fileCache.start + UInt32(file.length)
                fileCache.base = UnsafePointer(base)
                return UnsafeBufferPointer(start: base + Int(off), count: len)
            }
        }
        guard Int(s) + len <= sourceLength else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: sourceBuffer + Int(s), count: len)
    }

    /// Whether a token is spelled `word`, without allocating.
    private func token(_ id: TokenId, is word: StaticString) -> Bool {
        let bytes = tokenBytes(of: id)
        guard bytes.count == word.utf8CodeUnitCount, let p = bytes.baseAddress else { return false }
        return memcmp(p, word.utf8Start, bytes.count) == 0
    }

    /// Whether an identifier token is reserved (starts with `_`) or `asm`: the GNU keywords and builtin type
    /// names this parser recognizes all are, so other identifiers skip those comparisons.
    private func isReservedOrAsm(_ id: TokenId) -> Bool {
        let bytes = tokenBytes(of: id)
        guard let first = bytes.first else { return false }
        return first == UInt8(ascii: "_") || (bytes.count == 3 && first == UInt8(ascii: "a"))
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
            if currentKind == .identifier && token(currentTokenId, is: "__extension__") {
                advance()
                continue
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
    /// Each becomes an `attributeSpec` node unless `emit` is false (attributes of a statement, which has one node).
    private mutating func parseAttributes(emit: Bool = true) {
        while !isAtEnd {
            if currentKind == .lBracket && peekKind() == .lBracket {
                // C23 [[attribute]]
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
                if emit { parseTree.appendLeaf(kind: .attributeSpec, token: anchor) }
            } else if currentKind == .kwAlignas {
                // `alignas ( type-name )` or `alignas ( constant-expression )`: the operand is the node's child
                let start = parseTree.count
                let anchor = advance()
                guard emit, currentKind == .lParen else {
                    skipBalancedParens()
                    if emit { parseTree.appendLeaf(kind: .attributeSpec, token: anchor) }
                    continue
                }
                advance()
                if isTypeStart() { _ = parseTypeName() } else { _ = parseConditionalExpression() }
                expect(.rParen)
                parseTree.append(kind: .attributeSpec, token: anchor, subtreeSize: parseTree.count - start + 1)
            } else if currentKind == .identifier && isReservedOrAsm(currentTokenId) {
                let tok = currentTokenId
                if emit && (token(tok, is: "__attribute__") || token(tok, is: "__attribute")) {
                    parseGNUAttribute()
                } else if token(tok, is: "__attribute__") || token(tok, is: "__attribute") || token(tok, is: "__declspec") ||
                   token(tok, is: "__asm__") || token(tok, is: "__asm") || token(tok, is: "asm") {
                    let anchor = advance()
                    skipBalancedParens()
                    if emit { parseTree.appendLeaf(kind: .attributeSpec, token: anchor) }
                } else if token(tok, is: "__extension__") || token(tok, is: "_Noreturn") {
                    advance()
                } else {
                    break
                }
            } else {
                break
            }
        }
    }

    /// `__attribute__((a, b(args), ...))`: one `attributeSpec` node anchored at `__attribute__`. The argument of an
    /// `aligned` attribute is parsed as the node's child (a constant expression), so that sema can evaluate it;
    /// other arguments are skipped.
    private mutating func parseGNUAttribute() {
        let start = parseTree.count
        let anchor = advance()
        guard currentKind == .lParen, peekKind() == .lParen else {
            skipBalancedParens()
            parseTree.appendLeaf(kind: .attributeSpec, token: anchor)
            return
        }
        advance()
        advance()
        while !isAtEnd && currentKind != .rParen {
            let name = currentTokenId
            advance()
            if currentKind == .lParen {
                if token(name, is: "aligned") || token(name, is: "__aligned__") {
                    advance()
                    _ = parseConditionalExpression()
                    expect(.rParen)
                } else {
                    skipBalancedParens()
                }
            }
            guard currentKind == .comma else { break }
            advance()
        }
        expect(.rParen)
        expect(.rParen)
        parseTree.append(kind: .attributeSpec, token: anchor, subtreeSize: parseTree.count - start + 1)
    }

    /// Skips a parenthesized group `( ... )` if one starts at the cursor.
    private mutating func skipBalancedParens() {
        guard currentKind == .lParen else { return }
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

    private func isAttributeStart() -> Bool {
        switch currentKind {
        case .lBracket: return peekKind() == .lBracket
        case .kwAlignas: return true
        case .identifier:
            let tok = currentTokenId
            guard isReservedOrAsm(tok) else { return false }
            return token(tok, is: "__attribute__") || token(tok, is: "__attribute") || token(tok, is: "__declspec") ||
                token(tok, is: "__asm__") || token(tok, is: "__asm") || token(tok, is: "asm") || token(tok, is: "__extension__") ||
                token(tok, is: "_Noreturn")
        default: return false
        }
    }

    // MARK: - Declarations

    private func isBuiltinExtendedTypeName(_ sp: String) -> Bool {
        switch sp {
        case "__builtin_va_list", "__gnuc_va_list", "__auto_type",
             "__int128", "__int128_t", "__uint128_t",
             "__float128", "__float80", "__ibm128", "__bf16",
             "_Float16", "_Float32", "_Float32x", "_Float64", "_Float64x", "_Float128",
             "_Decimal32", "_Decimal64", "_Decimal128",
             "_Complex", "__complex__", "__complex", "_Imaginary":
            return true
        default:
            return false
        }
    }

    /// Whether the token `offset` tokens ahead can begin declaration specifiers (C23 6.7).
    private func isTypeStart(offset: Int = 0) -> Bool {
        switch peekKind(offset: offset) {
        case .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble,
             .kwSigned, .kwUnsigned, .kwBool, .kwAtomic, .kwStruct, .kwUnion, .kwEnum,
             .kwTypeof, .kwTypeofUnqual,
             .kwConst, .kwVolatile, .kwRestrict, .kwAlignas, .kwTypedef,
             .kwStatic, .kwExtern, .kwAuto, .kwRegister, .kwThreadLocal, .kwConstexpr, .kwInline:
            return true
        case .identifier:
            let idx = cursor + offset
            guard idx < tokens.pointee.count else { return false }
            let tok = TokenId(UInt32(idx))
            let sp = tokenSpelling(of: tok)
            if isTypedefName(sp) { return true }
            return isReservedOrAsm(tok) && (sp == "_BitInt" || sp == "__typeof__" || sp == "__typeof" || isBuiltinExtendedTypeName(sp))
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
        return parseDeclaration(allowFunctionDefinition: true)
    }

    private mutating func parseStaticAssert() -> NodeId {
        let start = parseTree.count
        let anchor = advance() // static_assert
        expect(.lParen)
        // static_assert ( constant-expression , string-literal ) -- the condition is not a comma expression
        _ = parseAssignmentExpression()
        if currentKind == .comma {
            advance()
            _ = parseAssignmentExpression()
        }
        expect(.rParen)
        expect(.semicolon)
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .staticAssertDecl, token: anchor, subtreeSize: subSize)
    }

    /// Parses a declaration (C23 6.7) or, at file scope, a function definition (6.9.1).
    ///
    /// Tree shape: `varDecl`/`typedefDecl` (token: first declarator's name) with children `declSpecs`, then each
    /// `declarator` followed by its initializer, if any. A definition is a `functionDecl` with children `declSpecs`,
    /// `declarator`, and the body's `compoundStmt`. A declaration without declarators (`struct S { ... };`) is a
    /// `varDecl` whose token is the `;`.
    private mutating func parseDeclaration(allowFunctionDefinition: Bool = false) -> NodeId {
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
        guard isTypeStart() else { return .nilId }
        let isTypedef = parseDeclarationSpecifiers()

        // Tag declarations without declarators: `struct Foo { ... };` or `enum E { ... };`
        if currentKind == .semicolon {
            let semi = advance()
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .varDecl, token: semi, subtreeSize: subSize)
        }

        var firstName: TokenId = .nilId
        var isFirst = true
        while true {
            let prevCursor = cursor
            let d = parseDeclarator(.named)
            if isTypedef {
                if d.name.isValid { registerTypedef(tokenSpelling(of: d.name)) }
            } else {
                registerOrdinaryName(d.name)
            }
            if isFirst { firstName = d.name }
            parseAttributes()
            if isFirst && allowFunctionDefinition && !isTypedef && d.shape == .function && currentKind == .lBrace {
                // The parameters are in scope in the body, hiding typedef names they reuse
                pushScope()
                for p in d.params { registerOrdinaryName(p) }
                _ = parseCompoundStatement()
                popScope()
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .functionDecl, token: d.name, subtreeSize: subSize)
            }
            isFirst = false
            if currentKind == .equal {
                advance()
                _ = parseInitializer()
            }
            if currentKind == .comma && cursor != prevCursor {
                advance()
                continue
            }
            break
        }
        expect(.semicolon)
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: isTypedef ? .typedefDecl : .varDecl, token: firstName, subtreeSize: subSize)
    }

    /// Parses declaration specifiers (C23 6.7.1-6.7.5) into a `declSpecs` node: a `specifier` leaf per keyword,
    /// typedef name or builtin type name; nodes for struct/union/enum, `typeof`, `_Atomic(T)` and `_BitInt(N)`
    /// specifiers; and attribute nodes. Returns whether `typedef` was among them.
    @discardableResult
    private mutating func parseDeclarationSpecifiers() -> Bool {
        let start = parseTree.count
        let anchor = currentTokenId
        var sawTypeSpecifier = false
        var isTypedef = false
        loop: while !isAtEnd {
            switch currentKind {
            case .kwTypedef:
                isTypedef = true
                parseTree.appendLeaf(kind: .specifier, token: advance())
            case .kwConst, .kwVolatile, .kwRestrict, .kwStatic, .kwExtern, .kwAuto, .kwRegister, .kwThreadLocal,
                 .kwConstexpr, .kwInline:
                parseTree.appendLeaf(kind: .specifier, token: advance())
            case .kwAtomic:
                if peekKind() == .lParen {
                    // `_Atomic ( type-name )` is a type specifier; plain `_Atomic` is a qualifier
                    let aStart = parseTree.count
                    let anchorTok = advance()
                    advance()
                    _ = parseTypeName()
                    expect(.rParen)
                    parseTree.append(kind: .atomicType, token: anchorTok, subtreeSize: parseTree.count - aStart + 1)
                    sawTypeSpecifier = true
                } else {
                    parseTree.appendLeaf(kind: .specifier, token: advance())
                }
            case .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble, .kwSigned, .kwUnsigned, .kwBool:
                parseTree.appendLeaf(kind: .specifier, token: advance())
                sawTypeSpecifier = true
            case .kwStruct, .kwUnion:
                _ = parseStructOrUnionSpecifier()
                sawTypeSpecifier = true
            case .kwEnum:
                _ = parseEnumSpecifier()
                sawTypeSpecifier = true
            case .kwTypeof, .kwTypeofUnqual:
                _ = parseTypeofSpecifier(isUnqual: currentKind == .kwTypeofUnqual)
                sawTypeSpecifier = true
            case .kwAlignas, .lBracket:
                guard isAttributeStart() else { break loop }
                parseAttributes()
            case .identifier:
                let sp = tokenSpelling(of: currentTokenId)
                if sp == "__typeof__" || sp == "__typeof" {
                    _ = parseTypeofSpecifier(isUnqual: false)
                    sawTypeSpecifier = true
                } else if sp == "_BitInt" {
                    let bStart = parseTree.count
                    let anchorTok = advance()
                    expect(.lParen)
                    _ = parseAssignmentExpression()
                    expect(.rParen)
                    parseTree.append(kind: .bitIntType, token: anchorTok, subtreeSize: parseTree.count - bStart + 1)
                    sawTypeSpecifier = true
                } else if isBuiltinExtendedTypeName(sp) || (!sawTypeSpecifier && isTypedefName(sp)) {
                    // A typedef name is a type specifier only if no other one has been seen: in `T T;` or
                    // `unsigned T;` the second name is the declarator's identifier
                    parseTree.appendLeaf(kind: .specifier, token: advance())
                    sawTypeSpecifier = true
                } else if isAttributeStart() {
                    parseAttributes()
                } else {
                    break loop
                }
            default:
                break loop
            }
        }
        if parseTree.count == start {
            parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
        }
        parseTree.append(kind: .declSpecs, token: anchor, subtreeSize: parseTree.count - start + 1)
        return isTypedef
    }

    /// `struct`/`union` specifier (C23 6.7.2.1). Members are `fieldDecl` nodes; the node's token is the tag name
    /// (or the keyword for an anonymous type).
    private mutating func parseStructOrUnionSpecifier() -> NodeId {
        let start = parseTree.count
        let isUnion = (currentKind == .kwUnion)
        var anchorTok = advance()
        parseAttributes()
        if currentKind == .identifier {
            anchorTok = advance()
            parseAttributes()
        }
        if currentKind == .lBrace {
            advance()
            memberDeclarationDepth += 1
            defer { memberDeclarationDepth -= 1 }
            while !isAtEnd && currentKind != .rBrace {
                let prevCursor = cursor
                parseAttributes()
                if currentKind == .rBrace { break }
                if currentKind == .kwStaticAssert {
                    _ = parseStaticAssert()
                } else if currentKind == .semicolon {
                    advance()
                } else if isTypeStart() {
                    _ = parseMemberDeclaration()
                } else {
                    // Not a member declaration: record the syntax error instead of skipping the token
                    parseTree.appendLeaf(kind: .errorNode, token: advance(), hasError: true)
                }
                if cursor == prevCursor && !isAtEnd {
                    parseTree.appendLeaf(kind: .errorNode, token: advance(), hasError: true)
                }
            }
            expect(.rBrace)
            parseAttributes()
        }
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: isUnion ? .unionType : .structType, token: anchorTok, subtreeSize: subSize)
    }

    /// A member declaration (C23 6.7.2.1): `fieldDecl` with children `declSpecs`, then each `declarator`
    /// followed by its bit-field width, if any. An unnamed bit-field has an empty declarator whose token is the `:`.
    private mutating func parseMemberDeclaration() -> NodeId {
        let start = parseTree.count
        parseDeclarationSpecifiers()
        var firstName = currentTokenId
        var isFirst = true
        while currentKind != .semicolon {
            let prevCursor = cursor
            var name: TokenId
            if currentKind == .colon {
                name = currentTokenId
                parseTree.appendLeaf(kind: .declarator, token: name)
            } else {
                name = parseDeclarator(.named).name
                parseAttributes()
            }
            if currentKind == .colon {
                advance()
                _ = parseConditionalExpression()
                parseAttributes()
            }
            if isFirst { firstName = name }
            isFirst = false
            guard currentKind == .comma, cursor != prevCursor else { break }
            advance()
        }
        expect(.semicolon)
        return parseTree.append(kind: .fieldDecl, token: firstName, subtreeSize: parseTree.count - start + 1)
    }

    /// `enum` specifier (C23 6.7.2.2): children are the fixed underlying type's `declSpecs` (if any) and the
    /// `enumeratorDecl` nodes. `enum E : T` is a fixed underlying type unless the `:` starts a bit-field width.
    private mutating func parseEnumSpecifier() -> NodeId {
        let start = parseTree.count
        var anchorTok = advance()
        parseAttributes()
        if currentKind == .identifier {
            anchorTok = advance()
            parseAttributes()
        }
        if currentKind == .colon && isTypeStart(offset: 1) {
            advance()
            parseDeclarationSpecifiers()
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
                        _ = parseConditionalExpression()
                    }
                    let enumSub = parseTree.count - enumStart + 1
                    parseTree.append(kind: .enumeratorDecl, token: enumName, subtreeSize: enumSub)
                }
                if currentKind == .comma {
                    advance()
                } else if cursor == prevCursor && !isAtEnd && currentKind != .rBrace {
                    parseTree.appendLeaf(kind: .errorNode, token: advance(), hasError: true)
                } else {
                    break
                }
            }
            expect(.rBrace)
            parseAttributes()
        }
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: .enumType, token: anchorTok, subtreeSize: subSize)
    }

    /// `typeof ( expression )` / `typeof ( type-name )` (C23 6.7.2.5), also GNU `__typeof__`.
    private mutating func parseTypeofSpecifier(isUnqual: Bool) -> NodeId {
        let start = parseTree.count
        let anchorTok = advance()
        expect(.lParen)
        if isTypeStart() {
            _ = parseTypeName()
        } else {
            _ = parseExpression()
        }
        expect(.rParen)
        let subSize = parseTree.count - start + 1
        return parseTree.append(kind: isUnqual ? .typeofUnqualType : .typeofType, token: anchorTok, subtreeSize: subSize)
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

    private func isTypeQualifier(_ kind: CTokenKind) -> Bool {
        kind == .kwConst || kind == .kwVolatile || kind == .kwRestrict || kind == .kwAtomic
    }

    // MARK: - Declarators

    enum DeclaratorMode {
        /// A declarator in a declaration: it declares an identifier.
        case named
        /// An abstract declarator, in a type name (C23 6.7.8).
        case abstract
        /// A parameter declarator, which may be either.
        case either
    }

    /// What a declarator makes its identifier: decides whether `{` may follow as a function body.
    enum DeclaratorShape {
        case plain, pointer, array, function
    }

    /// Parses a declarator (C23 6.7.7) into a `declarator` node whose token is the declared identifier (`nilId` if
    /// abstract). Its children, in source order: a `pointerType` leaf per `*`, each followed by `specifier` leaves for
    /// its qualifiers; the nested `declarator` of a parenthesized one; then an `arrayType` (child: the size
    /// expression) or `functionType` (child: the `paramList`) node per suffix. Semantic analysis derives the type.
    /// Returns the identifier, the declarator's shape, and the parameter names of the function suffix that makes
    /// the identifier a function, if any.
    private mutating func parseDeclarator(_ mode: DeclaratorMode) -> (name: TokenId, shape: DeclaratorShape, params: [TokenId]) {
        let start = parseTree.count
        guard currentDepth < maxDepth else {
            parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
            return (.nilId, .plain, [])
        }
        currentDepth += 1
        defer { currentDepth -= 1 }

        parseAttributes()
        var hasPointer = false
        while currentKind == .star {
            parseTree.appendLeaf(kind: .pointerType, token: advance())
            hasPointer = true
            while isTypeQualifier(currentKind) || isAttributeStart() {
                if isTypeQualifier(currentKind) {
                    parseTree.appendLeaf(kind: .specifier, token: advance())
                } else {
                    parseAttributes()
                }
            }
        }

        var name: TokenId = .nilId
        var inner: (shape: DeclaratorShape, params: [TokenId]) = (.plain, [])
        if currentKind == .identifier && mode != .abstract && !isAttributeStart() {
            name = advance()
        } else if currentKind == .lParen && (mode == .named || startsNestedDeclarator()) {
            advance()
            let nested = parseDeclarator(mode)
            expect(.rParen)
            name = nested.name
            inner = (nested.shape, nested.params)
        } else if mode == .named {
            // A declarator must declare an identifier
            parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
        }
        parseAttributes()

        var firstSuffix: DeclaratorShape? = nil
        var firstParams: [TokenId] = []
        while (currentKind == .lBracket && peekKind() != .lBracket) || currentKind == .lParen {
            let suffixStart = parseTree.count
            if currentKind == .lBracket {
                let lBrk = advance()
                // `[static N]`, `[const N]`, `[*]` (C23 6.7.7.3)
                while isQualifierOrStorage(currentKind) {
                    parseTree.appendLeaf(kind: .specifier, token: advance())
                }
                if currentKind == .star && peekKind() == .rBracket {
                    advance()
                } else if currentKind != .rBracket {
                    _ = parseAssignmentExpression()
                }
                expect(.rBracket)
                parseTree.append(kind: .arrayType, token: lBrk, subtreeSize: parseTree.count - suffixStart + 1)
                if firstSuffix == nil { firstSuffix = .array }
            } else {
                let lPar = advance()
                let names = parseParameterList()
                expect(.rParen)
                parseTree.append(kind: .functionType, token: lPar, subtreeSize: parseTree.count - suffixStart + 1)
                if firstSuffix == nil {
                    firstSuffix = .function
                    firstParams = names
                }
            }
            parseAttributes()
        }

        let shape: (DeclaratorShape, [TokenId])
        if inner.shape != .plain {
            shape = inner
        } else if let s = firstSuffix {
            shape = (s, firstParams)
        } else {
            shape = (hasPointer ? .pointer : .plain, [])
        }
        parseTree.append(kind: .declarator, token: name, subtreeSize: parseTree.count - start + 1)
        return (name, shape.0, shape.1)
    }

    /// In an abstract or parameter declarator, whether `(` opens a nested declarator (`(*)`, `(*name)`) rather
    /// than a parameter list (`()`, `(int)`, `(T x)`).
    private func startsNestedDeclarator() -> Bool {
        switch peekKind() {
        case .rParen, .ellipsis:
            return false
        case .star, .caret, .lParen:
            return true
        case .lBracket:
            return peekKind(offset: 2) != .lBracket
        case .identifier:
            let sp = tokenSpelling(of: TokenId(UInt32(cursor + 1)))
            if sp == "__attribute__" || sp == "__attribute" || sp == "__declspec" { return true }
            return !isTypeStart(offset: 1)
        default:
            return !isTypeStart(offset: 1)
        }
    }

    /// Parses a parameter type list (C23 6.7.7.4) into a `paramList` node of `paramDecl` nodes (children:
    /// `declSpecs`, `declarator`), with a `paramDecl` leaf for `...`. Returns the parameter names.
    private mutating func parseParameterList() -> [TokenId] {
        let start = parseTree.count
        var names: [TokenId] = []

        while !isAtEnd && currentKind != .rParen {
            let prevCursor = cursor
            parseAttributes()
            if currentKind == .ellipsis {
                parseTree.appendLeaf(kind: .paramDecl, token: advance())
                break
            }
            let pStart = parseTree.count
            let pTok = currentTokenId
            if isTypeStart() {
                parseDeclarationSpecifiers()
            } else {
                // C23 has no identifier lists or implicit `int`
                parseTree.appendLeaf(kind: .errorNode, token: pTok, hasError: true)
            }
            let d = parseDeclarator(.either)
            parseAttributes()
            names.append(d.name)
            parseTree.append(kind: .paramDecl, token: d.name.isValid ? d.name : pTok, subtreeSize: parseTree.count - pStart + 1)

            if currentKind == .comma {
                advance()
            } else if cursor == prevCursor && !isAtEnd && currentKind != .rParen {
                advance()
            } else {
                break
            }
        }

        let subSize = parseTree.count - start + 1
        parseTree.append(kind: .paramList, token: currentTokenId, subtreeSize: subSize)
        return names
    }

    /// A type name (C23 6.7.8): `typeName` node with children `declSpecs` and, if present, an abstract `declarator`.
    private mutating func parseTypeName() -> NodeId {
        let start = parseTree.count
        let anchor = currentTokenId
        parseAttributes()
        parseDeclarationSpecifiers()
        if currentKind == .star || currentKind == .lParen || (currentKind == .lBracket && peekKind() != .lBracket) || isAttributeStart() {
            _ = parseDeclarator(.abstract)
        }
        return parseTree.append(kind: .typeName, token: anchor, subtreeSize: parseTree.count - start + 1)
    }

    // MARK: - Initializers

    private mutating func parseInitializer() -> NodeId {
        if currentKind == .lBrace {
            // Braced initializer list `{ ... }`
            let start = parseTree.count
            let anchor = advance() // {

            while !isAtEnd && currentKind != .rBrace {
                if currentKind == .period || currentKind == .lBracket {
                    // Designation (C23 6.7.10): a designator list such as `.a.b[2] = v`, including the GNU
                    // range form `[lo ... hi] = v`. The node's token is the first designator's.
                    let dStart = parseTree.count
                    var anchorTok = currentTokenId
                    var first = true
                    while currentKind == .period || currentKind == .lBracket {
                        if currentKind == .period {
                            advance()
                            let field = expect(.identifier)
                            if first { anchorTok = field }
                        } else {
                            let lBrk = advance()
                            if first { anchorTok = lBrk }
                            _ = parseAssignmentExpression()
                            if currentKind == .ellipsis {
                                advance()
                                _ = parseAssignmentExpression()
                            }
                            expect(.rBracket)
                        }
                        first = false
                    }
                    expect(.equal)
                    _ = parseInitializer()
                    let dSize = parseTree.count - dStart + 1
                    parseTree.append(kind: .designatedInit, token: anchorTok, subtreeSize: dSize)
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

        // Attributes of a statement: `[[fallthrough]];`, `__attribute__((fallthrough));`, `[[maybe_unused]] int x;`
        if (currentKind == .lBracket && peekKind() == .lBracket) || (currentKind == .identifier &&
            (token(currentTokenId, is: "__attribute__") || token(currentTokenId, is: "__attribute"))) {
            // An attribute declaration `[[fallthrough]];` is a null statement anchored at its first attribute
            let attrTok = currentTokenId
            parseAttributes(emit: false)
            if currentKind == .semicolon {
                advance()
                return parseTree.appendLeaf(kind: .exprStmt, token: attrTok)
            }
            return parseStatement()
        }

        switch currentKind {
        case .lBrace:
            return parseCompoundStatement()

        case .kwStaticAssert:
            return parseStaticAssert()

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
                _ = parseDeclaration()
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
            // GNU asm statement: `__asm__ [volatile|inline|goto] ( template : outputs : inputs : clobbers ) ;`
            if token(currentTokenId, is: "__asm__") || token(currentTokenId, is: "__asm") || token(currentTokenId, is: "asm") {
                let start = parseTree.count
                let anchor = advance()
                while isQualifierOrStorage(currentKind) || currentKind == .kwGoto ||
                      (currentKind == .identifier && ["__volatile__", "__volatile", "__inline__", "__inline"].contains(tokenSpelling(of: currentTokenId))) {
                    advance()
                }
                if currentKind == .lParen {
                    advance()
                    var depth = 1
                    while !isAtEnd && depth > 0 {
                        if currentKind == .lParen { depth += 1 }
                        else if currentKind == .rParen { depth -= 1 }
                        advance()
                    }
                } else {
                    expect(.lParen)
                }
                expect(.semicolon)
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .asmStmt, token: anchor, subtreeSize: subSize)
            }
            // Check for labeled statement: `label:`
            if peekKind() == .colon {
                let start = parseTree.count
                let label = advance()
                advance() // :
                // C23 6.8.2: a label may end a compound statement
                if currentKind != .rBrace {
                    _ = parseStatement()
                }
                let subSize = parseTree.count - start + 1
                return parseTree.append(kind: .labelStmt, token: label, subtreeSize: subSize)
            }
            fallthrough

        default:
            // Declaration or expression statement
            if isTypeStart() {
                return parseDeclaration()
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
            while currentKind == .identifier && token(currentTokenId, is: "__extension__") {
                advance()
            }
            if currentKind == .rBrace { break }
            if isTypeStart() {
                _ = parseDeclaration()
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
            // GNU `a ?: b` omits the middle operand (it is `a`, evaluated once): the node has two children
            if currentKind != .colon {
                _ = parseExpression()
            }
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

    private mutating func parseCastOrUnaryExpression() -> NodeId {
        while currentKind == .identifier && token(currentTokenId, is: "__extension__") {
            advance()
        }
        // Cast expression or compound literal: `(type)expr` or `(type){ ... }`
        if currentKind == .lParen && isTypeSpecifierInParenthesis() {
            let start = parseTree.count
            let lParen = advance()
            _ = parseTypeName()
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
                _ = parseTypeName()
                expect(.rParen)
            } else {
                _ = parseCastOrUnaryExpression()
            }
            let subSize = parseTree.count - start + 1
            return parseTree.append(kind: .unaryExpr, token: opTok, subtreeSize: subSize)
        }

        return parsePostfixExpression()
    }

    private func isTypeSpecifierInParenthesis() -> Bool {
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
            // A type name may start with a GNU attribute: `(__attribute__((noinline)) int (*)(void))`
            return isTypedefName(sp) || isBuiltinExtendedTypeName(sp) || sp == "_BitInt" || sp == "__typeof__" ||
                   sp == "__typeof" || sp == "__attribute__" || sp == "__attribute"
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
                _ = parseTypeName()
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
            if token(tok, is: "_Generic") {
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
                        _ = parseTypeName()
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
