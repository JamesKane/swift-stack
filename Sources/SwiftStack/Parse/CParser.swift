// Sources/SwiftStack/Parse/CParser.swift
import Foundation

/// A non-backtracking recursive descent / Pratt parser for the C subset defined in M0.5.
/// Emits nodes into a postorder `ParseTree` (01-frontend.md §4.6).
public struct CParser: ~Copyable {
    private let tokens: UnsafePointer<TokenBuffer>
    private let sourceBuffer: UnsafePointer<UInt8>
    private let sourceLength: Int
    private var cursor: Int = 1
    private var parseTree: ParseTree

    public init(tokens: UnsafePointer<TokenBuffer>, sourceBuffer: UnsafePointer<UInt8>, sourceLength: Int) {
        self.tokens = tokens
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
        self.parseTree = ParseTree()
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
        // Emit error and advance
        let errTok = currentTokenId
        advance()
        return errTok
    }

    public func tokenSpelling(of id: TokenId) -> String {
        guard id.isValid else { return "" }
        let s = Int(tokens.pointee.start(of: id).rawValue)
        let e = Int(tokens.pointee.end(of: id).rawValue)
        guard s >= 0, e >= s, e <= sourceLength else { return "" }
        return String(decoding: UnsafeBufferPointer(start: sourceBuffer + s, count: e - s), as: UTF8.self)
    }

    // MARK: - Public Entry Point

    public consuming func parse() -> ParseTree {
        let start = parseTree.count
        var hasError = false

        while !isAtEnd {
            if currentKind == .semicolon {
                advance()
                continue
            }
            let decl = parseDeclaration()
            if decl.isNil {
                hasError = true
                advance()
            }
        }

        let totalSize = parseTree.count - start + 1
        let rootTok = tokens.pointee.count > 1 ? TokenId(1) : .nilId
        parseTree.append(kind: .translationUnit, token: rootTok, subtreeSize: totalSize, hasError: hasError)
        return consume parseTree
    }

    // MARK: - Declarations

    private mutating func isTypeSpecifier(_ kind: CTokenKind) -> Bool {
        switch kind {
        case .kwInt, .kwLong, .kwChar, .kwVoid:
            return true
        default:
            return false
        }
    }

    /// Parses a type specification, e.g. `int`, `long`, `char *`, `int **`.
    @discardableResult
    private mutating func parseType() -> NodeId {
        let start = parseTree.count
        guard isTypeSpecifier(currentKind) else {
            return parseTree.appendLeaf(kind: .errorNode, token: currentTokenId, hasError: true)
        }
        let typeTok = advance()
        parseTree.appendLeaf(kind: .typeSpec, token: typeTok)

        // Parse pointer stars: `*`
        while currentKind == .star {
            let starTok = advance()
            let subSize = parseTree.count - start + 1
            parseTree.append(kind: .pointerType, token: starTok, subtreeSize: subSize)
        }
        return NodeId(parseTree.count - 1)
    }

    /// Parses a top-level declaration (function or global variable).
    private mutating func parseDeclaration() -> NodeId {
        let start = parseTree.count
        guard isTypeSpecifier(currentKind) else {
            return .nilId
        }

        // Return / variable type
        _ = parseType()

        guard currentKind == .identifier else {
            return .nilId
        }
        let nameTok = advance()

        if currentKind == .lParen {
            // Function declaration or definition
            advance() // '('

            let paramStart = parseTree.count
            // Parse parameter list
            if currentKind != .rParen {
                if currentKind == .kwVoid && peekKind(offset: 1) == .rParen {
                    advance() // void
                } else {
                    parseParameter()
                    while match(.comma) {
                        parseParameter()
                    }
                }
            }
            expect(.rParen)
            let paramListSize = parseTree.count - paramStart + 1
            parseTree.append(kind: .paramList, token: nameTok, subtreeSize: paramListSize)

            if currentKind == .lBrace {
                // Function definition with body
                _ = parseCompoundStatement()
            } else {
                // Function prototype / declaration
                expect(.semicolon)
            }

            let fnSize = parseTree.count - start + 1
            return parseTree.append(kind: .functionDecl, token: nameTok, subtreeSize: fnSize)
        } else {
            // Global variable declaration
            if match(.equal) {
                parseExpression()
            }
            expect(.semicolon)
            let varSize = parseTree.count - start + 1
            return parseTree.append(kind: .varDecl, token: nameTok, subtreeSize: varSize)
        }
    }

    private mutating func parseParameter() {
        let start = parseTree.count
        parseType()
        let nameTok = currentKind == .identifier ? advance() : .nilId
        let size = parseTree.count - start + 1
        parseTree.append(kind: .paramDecl, token: nameTok, subtreeSize: size)
    }

    // MARK: - Statements

    @discardableResult
    private mutating func parseStatement() -> NodeId {
        switch currentKind {
        case .lBrace:
            return parseCompoundStatement()
        case .kwReturn:
            return parseReturnStatement()
        case .kwIf:
            return parseIfStatement()
        case .kwWhile:
            return parseWhileStatement()
        case .semicolon:
            let tok = advance()
            return parseTree.appendLeaf(kind: .exprStmt, token: tok)
        default:
            if isTypeSpecifier(currentKind) {
                return parseVarDeclStatement()
            } else {
                return parseExpressionStatement()
            }
        }
    }

    private mutating func parseCompoundStatement() -> NodeId {
        let start = parseTree.count
        let lBraceTok = expect(.lBrace)

        while currentKind != .rBrace && !isAtEnd {
            parseStatement()
        }
        expect(.rBrace)

        let size = parseTree.count - start + 1
        return parseTree.append(kind: .compoundStmt, token: lBraceTok, subtreeSize: size)
    }

    private mutating func parseReturnStatement() -> NodeId {
        let start = parseTree.count
        let retTok = expect(.kwReturn)
        if currentKind != .semicolon {
            parseExpression()
        }
        expect(.semicolon)
        let size = parseTree.count - start + 1
        return parseTree.append(kind: .returnStmt, token: retTok, subtreeSize: size)
    }

    private mutating func parseIfStatement() -> NodeId {
        let start = parseTree.count
        let ifTok = expect(.kwIf)
        expect(.lParen)
        parseExpression()
        expect(.rParen)
        parseStatement() // then branch

        if match(.kwElse) {
            parseStatement() // else branch
        }

        let size = parseTree.count - start + 1
        return parseTree.append(kind: .ifStmt, token: ifTok, subtreeSize: size)
    }

    private mutating func parseWhileStatement() -> NodeId {
        let start = parseTree.count
        let whileTok = expect(.kwWhile)
        expect(.lParen)
        parseExpression()
        expect(.rParen)
        parseStatement()

        let size = parseTree.count - start + 1
        return parseTree.append(kind: .whileStmt, token: whileTok, subtreeSize: size)
    }

    private mutating func parseVarDeclStatement() -> NodeId {
        let start = parseTree.count
        parseType()
        let nameTok = expect(.identifier)
        if match(.equal) {
            parseExpression()
        }
        expect(.semicolon)
        let size = parseTree.count - start + 1
        return parseTree.append(kind: .varDecl, token: nameTok, subtreeSize: size)
    }

    private mutating func parseExpressionStatement() -> NodeId {
        let start = parseTree.count
        let exprNode = parseExpression()
        expect(.semicolon)
        let size = parseTree.count - start + 1
        return parseTree.append(kind: .exprStmt, token: parseTree.token(of: exprNode), subtreeSize: size)
    }

    // MARK: - Expressions (Pratt Precedence Climbing)

    @discardableResult
    private mutating func parseExpression() -> NodeId {
        parseBinaryExpression(minPrecedence: 1)
    }

    private func binaryPrecedence(_ kind: CTokenKind) -> (prec: Int, isRightAssoc: Bool)? {
        switch kind {
        case .equal:
            return (1, true)
        case .pipePipe:
            return (2, false)
        case .ampAmp:
            return (3, false)
        case .pipe:
            return (4, false)
        case .caret:
            return (5, false)
        case .amp:
            return (6, false)
        case .equalEqual, .exclaimEqual:
            return (7, false)
        case .less, .lessEqual, .greater, .greaterEqual:
            return (8, false)
        case .lessLess, .greaterGreater:
            return (9, false)
        case .plus, .minus:
            return (10, false)
        case .star, .slash, .percent:
            return (11, false)
        default:
            return nil
        }
    }

    private mutating func parseBinaryExpression(minPrecedence: Int) -> NodeId {
        let exprStart = parseTree.count
        var lhs = parseUnaryExpression()

        while let (prec, rightAssoc) = binaryPrecedence(currentKind), prec >= minPrecedence {
            let opTok = advance()
            let nextMinPrec = rightAssoc ? prec : prec + 1
            _ = parseBinaryExpression(minPrecedence: nextMinPrec)

            let kind: CNodeKind = (opTokKind(opTok) == .equal) ? .assignExpr : .binaryExpr
            let size = parseTree.count - exprStart + 1
            lhs = parseTree.append(kind: kind, token: opTok, subtreeSize: size)
        }

        return lhs
    }

    private func opTokKind(_ tok: TokenId) -> CTokenKind {
        CTokenKind(rawValue: tokens.pointee.kind(of: tok)) ?? .errorToken
    }

    private mutating func parseUnaryExpression() -> NodeId {
        let start = parseTree.count
        switch currentKind {
        case .minus, .plus, .exclaim, .tilde, .star, .amp:
            let opTok = advance()
            _ = parseUnaryExpression()
            let size = parseTree.count - start + 1
            return parseTree.append(kind: .unaryExpr, token: opTok, subtreeSize: size)
        default:
            return parsePostfixExpression()
        }
    }

    private mutating func parsePostfixExpression() -> NodeId {
        var base = parsePrimaryExpression()

        while true {
            if currentKind == .lParen {
                // Function call
                let callStart = base.rawIndex - parseTree.subtreeSize(of: base) + 1
                let lParenTok = advance()
                let argStart = parseTree.count

                if currentKind != .rParen {
                    parseExpression()
                    while match(.comma) {
                        parseExpression()
                    }
                }
                expect(.rParen)

                let argListSize = parseTree.count - argStart + 1
                parseTree.append(kind: .argList, token: lParenTok, subtreeSize: argListSize)

                let callSize = parseTree.count - callStart + 1
                base = parseTree.append(kind: .callExpr, token: lParenTok, subtreeSize: callSize)
            } else {
                break
            }
        }

        return base
    }

    private mutating func parsePrimaryExpression() -> NodeId {
        switch currentKind {
        case .identifier:
            let tok = advance()
            return parseTree.appendLeaf(kind: .identExpr, token: tok)

        case .intLiteral:
            let tok = advance()
            return parseTree.appendLeaf(kind: .intLiteral, token: tok)

        case .stringLiteral:
            let tok = advance()
            return parseTree.appendLeaf(kind: .stringLiteral, token: tok)

        case .charLiteral:
            let tok = advance()
            return parseTree.appendLeaf(kind: .charLiteral, token: tok)

        case .lParen:
            advance() // '('
            let inner = parseExpression()
            expect(.rParen)
            return inner

        default:
            let errTok = currentTokenId
            advance()
            return parseTree.appendLeaf(kind: .errorNode, token: errTok, hasError: true)
        }
    }
}
