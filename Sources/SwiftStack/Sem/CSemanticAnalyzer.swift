// Sources/SwiftStack/Sem/CSemanticAnalyzer.swift
import Foundation

public enum CSymbolStorage: Equatable {
    case global(name: String)
    case function(name: String)
    case param(index: Int, offset: Int32)
    case local(offset: Int32)
}

public struct CSymbol: Equatable {
    public let name: String
    public let type: TypeId
    public let storage: CSymbolStorage

    public init(name: String, type: TypeId, storage: CSymbolStorage) {
        self.name = name
        self.type = type
        self.storage = storage
    }
}

public final class CScope {
    public let parent: CScope?
    private var symbols: [String: CSymbol] = [:]

    public init(parent: CScope? = nil) {
        self.parent = parent
    }

    public func insert(symbol: CSymbol) {
        symbols[symbol.name] = symbol
    }

    public func lookup(_ name: String) -> CSymbol? {
        if let sym = symbols[name] {
            return sym
        }
        return parent?.lookup(name)
    }

    public func lookupLocal(_ name: String) -> CSymbol? {
        symbols[name]
    }
}

public struct FunctionSignature {
    public let name: String
    public let returnType: TypeId
    public let paramNames: [String]
    public let paramTypes: [TypeId]
    public let bodyNode: NodeId // compoundStmt node
    public let stackFrameSize: Int32
}

public struct SemResult {
    public let nodeTypes: [NodeId: TypeId]
    public let symbolRefs: [NodeId: CSymbol]
    public let functions: [String: FunctionSignature]
    public let functionOrder: [String]
    public let stringLiterals: [String: Int] // string content -> index
    public let diagnostics: [String]
}

/// Semantic analyzer and minimal type checker for C23 M0.5 slice.
public struct CSemanticAnalyzer {
    public let typePool: TypePool
    private let sourceBuffer: UnsafePointer<UInt8>
    private let sourceLength: Int
    private var nodeTypes: [NodeId: TypeId] = [:]
    private var symbolRefs: [NodeId: CSymbol] = [:]
    private var functions: [String: FunctionSignature] = [:]
    private var functionOrder: [String] = []
    private var stringLiterals: [String: Int] = [:]
    private var stringCounter: Int = 0
    private var diagnostics: [String] = []

    // Scope & frame tracking
    private var currentScope: CScope
    private var currentStackOffset: Int32 = 0
    private var currentReturnType: TypeId = .void

    public init(typePool: TypePool, sourceBuffer: UnsafePointer<UInt8>, sourceLength: Int) {
        self.typePool = typePool
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
        self.currentScope = CScope()

        // Pre-declare standard library syscall stubs
        // long write(int fd, const void *buf, unsigned long count)
        let writeType = typePool.functionType(returnType: .long, paramTypes: [.int, .pointer, .long])
        self.currentScope.insert(symbol: CSymbol(name: "write", type: writeType, storage: .function(name: "write")))

        // void exit(int status)
        let exitType = typePool.functionType(returnType: .void, paramTypes: [.int])
        self.currentScope.insert(symbol: CSymbol(name: "exit", type: exitType, storage: .function(name: "exit")))
    }

    private func spelling(of tok: TokenId, in tokens: borrowing TokenBuffer) -> String {
        guard tok.isValid else { return "" }
        let s = Int(tokens.start(of: tok).rawValue)
        let e = Int(tokens.end(of: tok).rawValue)
        guard s >= 0, e >= s, e <= sourceLength else { return "" }
        return String(decoding: UnsafeBufferPointer(start: sourceBuffer + s, count: e - s), as: UTF8.self)
    }

    public mutating func analyze(tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemResult {
        let root = NodeId(tree.count - 1)
        guard root.isValid, tree.kind(of: root) == .translationUnit else {
            return SemResult(nodeTypes: [:], symbolRefs: [:], functions: [:], functionOrder: [], stringLiterals: [:], diagnostics: ["Empty or invalid translation unit"])
        }

        // Walk top-level declarations
        let decls = tree.children(of: root)
        for decl in decls {
            let k = tree.kind(of: decl)
            if k == .functionDecl {
                analyzeFunction(decl, tree: tree, tokens: tokens)
            } else if k == .varDecl {
                analyzeGlobalVar(decl, tree: tree, tokens: tokens)
            }
        }

        return SemResult(
            nodeTypes: nodeTypes,
            symbolRefs: symbolRefs,
            functions: functions,
            functionOrder: functionOrder,
            stringLiterals: stringLiterals,
            diagnostics: diagnostics
        )
    }

    private mutating func resolveType(from typeNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> TypeId {
        let kind = tree.kind(of: typeNode)
        if kind == .typeSpec {
            let tok = tree.token(of: typeNode)
            let txt = spelling(of: tok, in: tokens)
            switch txt {
            case "int": return .int
            case "long": return .long
            case "char": return .char
            case "void": return .void
            default: return .int
            }
        } else if kind == .pointerType {
            let child = tree.children(of: typeNode).first ?? .nilId
            let pointee = resolveType(from: child, tree: tree, tokens: tokens)
            return typePool.pointerTo(pointee)
        }
        return .int
    }

    private mutating func analyzeFunction(_ fnNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: fnNode)
        guard children.count >= 2 else { return }

        let retTypeNode = children[0]
        let returnType = resolveType(from: retTypeNode, tree: tree, tokens: tokens)
        self.currentReturnType = returnType

        let fnTok = tree.token(of: fnNode)
        let fnName = spelling(of: fnTok, in: tokens)

        let paramListNode = children[1]
        let paramNodes = tree.children(of: paramListNode)

        var paramNames: [String] = []
        var paramTypes: [TypeId] = []

        for pNode in paramNodes {
            let pChildren = tree.children(of: pNode)
            if let pTypeNode = pChildren.first {
                let pType = resolveType(from: pTypeNode, tree: tree, tokens: tokens)
                let pTok = tree.token(of: pNode)
                let pName = spelling(of: pTok, in: tokens)
                paramNames.append(pName)
                paramTypes.append(pType)
            }
        }

        let fnType = typePool.functionType(returnType: returnType, paramTypes: paramTypes)
        currentScope.insert(symbol: CSymbol(name: fnName, type: fnType, storage: .function(name: fnName)))

        // If there is a body (compoundStmt)
        var bodyNode: NodeId = .nilId
        if children.count >= 3 && tree.kind(of: children[2]) == .compoundStmt {
            bodyNode = children[2]
            let fnScope = CScope(parent: currentScope)
            self.currentScope = fnScope
            self.currentStackOffset = 0

            // Parameters are placed on stack:
            // SysV AMD64: first 6 params passed in registers (rdi, rsi, rdx, rcx, r8, r9)
            // We assign local stack slots for them so function body can load/store them uniformly
            for (idx, (pName, pType)) in zip(paramNames, paramTypes).enumerated() {
                if !pName.isEmpty {
                    let sz = 8
                    currentStackOffset += Int32(sz)
                    let offset = -currentStackOffset
                    currentScope.insert(symbol: CSymbol(name: pName, type: pType, storage: .param(index: idx, offset: offset)))
                }
            }

            analyzeStatement(bodyNode, tree: tree, tokens: tokens)

            // 16-byte align stack frame
            let rawFrame = currentStackOffset
            let alignedFrame = (rawFrame + 15) & ~15

            if !functionOrder.contains(fnName) {
                functionOrder.append(fnName)
            }
            functions[fnName] = FunctionSignature(
                name: fnName,
                returnType: returnType,
                paramNames: paramNames,
                paramTypes: paramTypes,
                bodyNode: bodyNode,
                stackFrameSize: alignedFrame
            )

            self.currentScope = fnScope.parent ?? CSScope()
        }
    }

    private func CSScope() -> CScope {
        CScope()
    }

    private mutating func analyzeGlobalVar(_ varNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: varNode)
        guard let typeNode = children.first else { return }
        let varType = resolveType(from: typeNode, tree: tree, tokens: tokens)
        let nameTok = tree.token(of: varNode)
        let name = spelling(of: nameTok, in: tokens)

        if children.count > 1 {
            let initExpr = children[1]
            _ = analyzeExpression(initExpr, tree: tree, tokens: tokens)
        }

        currentScope.insert(symbol: CSymbol(name: name, type: varType, storage: .global(name: name)))
    }

    private mutating func analyzeStatement(_ stmtNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let kind = tree.kind(of: stmtNode)
        switch kind {
        case .compoundStmt:
            let blockScope = CScope(parent: currentScope)
            self.currentScope = blockScope
            for child in tree.children(of: stmtNode) {
                analyzeStatement(child, tree: tree, tokens: tokens)
            }
            self.currentScope = blockScope.parent ?? CSScope()

        case .varDecl:
            let children = tree.children(of: stmtNode)
            guard let typeNode = children.first else { return }
            let varType = resolveType(from: typeNode, tree: tree, tokens: tokens)
            let nameTok = tree.token(of: stmtNode)
            let name = spelling(of: nameTok, in: tokens)

            let sz = 8
            currentStackOffset += Int32(sz)
            let offset = -currentStackOffset

            let sym = CSymbol(name: name, type: varType, storage: .local(offset: offset))
            currentScope.insert(symbol: sym)
            symbolRefs[stmtNode] = sym

            if children.count > 1 {
                let initExpr = children[1]
                let initType = analyzeExpression(initExpr, tree: tree, tokens: tokens)
                if initType != varType && varType != .long && varType != .pointer {
                    // Type checking warning/cast
                }
            }

        case .returnStmt:
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                let retType = analyzeExpression(expr, tree: tree, tokens: tokens)
                nodeTypes[stmtNode] = retType
            } else {
                nodeTypes[stmtNode] = .void
            }

        case .ifStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            _ = analyzeExpression(children[0], tree: tree, tokens: tokens)
            analyzeStatement(children[1], tree: tree, tokens: tokens)
            if children.count >= 3 {
                analyzeStatement(children[2], tree: tree, tokens: tokens)
            }

        case .whileStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            _ = analyzeExpression(children[0], tree: tree, tokens: tokens)
            analyzeStatement(children[1], tree: tree, tokens: tokens)

        case .exprStmt:
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                _ = analyzeExpression(expr, tree: tree, tokens: tokens)
            }

        default:
            break
        }
    }

    private mutating func analyzeExpression(_ exprNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> TypeId {
        let kind = tree.kind(of: exprNode)
        let resolvedType: TypeId

        switch kind {
        case .intLiteral:
            resolvedType = .int

        case .stringLiteral:
            let tok = tree.token(of: exprNode)
            var raw = spelling(of: tok, in: tokens)
            // Strip outer quotes if present
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            // Unescape common escape sequences like \n, \t, \0
            let unescaped = unescapeString(raw)
            if stringLiterals[unescaped] == nil {
                stringLiterals[unescaped] = stringCounter
                stringCounter += 1
            }
            resolvedType = typePool.pointerTo(.char)

        case .charLiteral:
            resolvedType = .char

        case .identExpr:
            let tok = tree.token(of: exprNode)
            let name = spelling(of: tok, in: tokens)
            if let sym = currentScope.lookup(name) {
                symbolRefs[exprNode] = sym
                resolvedType = sym.type
            } else {
                diagnostics.append("Use of undeclared identifier '\(name)'")
                resolvedType = .int
            }

        case .assignExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                resolvedType = .int
                break
            }
            let lhsType = analyzeExpression(children[0], tree: tree, tokens: tokens)
            _ = analyzeExpression(children[1], tree: tree, tokens: tokens)
            resolvedType = lhsType

        case .binaryExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                resolvedType = .int
                break
            }
            let lhsType = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let rhsType = analyzeExpression(children[1], tree: tree, tokens: tokens)

            let opTok = tree.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken

            switch opKind {
            case .equalEqual, .exclaimEqual, .less, .lessEqual, .greater, .greaterEqual, .ampAmp, .pipePipe:
                resolvedType = .int
            default:
                if lhsType == .long || rhsType == .long {
                    resolvedType = .long
                } else if typePool.isPointer(type: lhsType) {
                    resolvedType = lhsType
                } else {
                    resolvedType = .int
                }
            }

        case .unaryExpr:
            let children = tree.children(of: exprNode)
            guard let child = children.first else {
                resolvedType = .int
                break
            }
            let innerType = analyzeExpression(child, tree: tree, tokens: tokens)
            let opTok = tree.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken

            switch opKind {
            case .amp: // address-of
                resolvedType = typePool.pointerTo(innerType)
            case .star: // dereference
                resolvedType = typePool.pointeeType(of: innerType)
            case .exclaim:
                resolvedType = .int
            default:
                resolvedType = innerType
            }

        case .callExpr:
            let children = tree.children(of: exprNode)
            guard children.count >= 1 else {
                resolvedType = .int
                break
            }
            let calleeNode = children[0]
            let calleeTok = tree.token(of: calleeNode)
            let calleeName = spelling(of: calleeTok, in: tokens)

            var retType: TypeId = .int
            if let sym = currentScope.lookup(calleeName) {
                symbolRefs[calleeNode] = sym
                let info = typePool.typeInfo(of: sym.type)
                if case .function(let rType, _) = info.kind {
                    retType = rType
                }
            } else {
                diagnostics.append("Call to undeclared function '\(calleeName)'")
            }

            if children.count > 1 {
                let argListNode = children[1]
                for arg in tree.children(of: argListNode) {
                    _ = analyzeExpression(arg, tree: tree, tokens: tokens)
                }
            }
            resolvedType = retType

        default:
            resolvedType = .int
        }

        nodeTypes[exprNode] = resolvedType
        return resolvedType
    }

    private func unescapeString(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 1
                switch chars[i] {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "0": result.append("\0")
                default: result.append(chars[i])
                }
            } else {
                result.append(chars[i])
            }
            i += 1
        }
        return result
    }
}
