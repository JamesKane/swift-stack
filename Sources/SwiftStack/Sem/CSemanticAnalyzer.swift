// Sources/SwiftStack/Sem/CSemanticAnalyzer.swift
import Foundation

public final class SemInstBlockContainer: @unchecked Sendable {
    public var block: SemInstBlock
    public init(block: consuming SemInstBlock) {
        self.block = block
    }
}

public final class SemModule: @unchecked Sendable {
    public var declTable: DeclTable
    public var instBlocks: [SemInstBlockContainer]
    public let typePool: TypePool
    public var diagnosticBag: DiagnosticBag

    public init(
        declTable: consuming DeclTable,
        instBlocks: [SemInstBlockContainer],
        typePool: TypePool,
        diagnosticBag: consuming DiagnosticBag
    ) {
        self.declTable = declTable
        self.instBlocks = instBlocks
        self.typePool = typePool
        self.diagnosticBag = diagnosticBag
    }

    public func dump() {
        print("=== SemIR DeclTable (\(declTable.count - 1) declarations) ===")
        print("DeclId | DeclKind       | Name             | Type")
        print("-------+----------------+------------------+---------------------")
        for i in 1..<Int(declTable.count) {
            let did = DeclId(UInt32(i))
            let k = String(describing: declTable.kind(of: did))
            let name = declTable.name(of: did)
            let type = declTable.type(of: did)
            let kPad = k.padding(toLength: 14, withPad: " ", startingAt: 0)
            let nPad = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            print(String(format: "%6d | %@ | %@ | %@", i, kPad, nPad, "\(type)"))
        }

        print("\n=== SemIR Instruction Blocks (\(instBlocks.count - 1) bodies) ===")
        for (idx, container) in instBlocks.enumerated() {
            guard idx > 0 else { continue }
            print("--- Block #\(idx) (\(container.block.count - 1) instructions) ---")
            for j in 1..<Int(container.block.count) {
                let sid = SemInstId(UInt32(j))
                let k = String(describing: container.block.kind(of: sid))
                let t = container.block.type(of: sid)
                let a0 = container.block.arg0[sid]
                let a1 = container.block.arg1[sid]
                print(String(format: "  %%%d = %@ : %@ (arg0: %u, arg1: %u)", j, k, "\(t)", a0, a1))
            }
        }
    }
}

public struct FunctionSignature: Sendable {
    public let name: String
    public let returnType: TypeId
    public let paramNames: [String]
    public let paramTypes: [TypeId]
    public let bodyNode: NodeId // compoundStmt node
    public let stackFrameSize: Int32
    public let declId: DeclId
    public let blockId: InstBlockId

    public init(
        name: String,
        returnType: TypeId,
        paramNames: [String],
        paramTypes: [TypeId],
        bodyNode: NodeId,
        stackFrameSize: Int32,
        declId: DeclId = .nilId,
        blockId: InstBlockId = .nilId
    ) {
        self.name = name
        self.returnType = returnType
        self.paramNames = paramNames
        self.paramTypes = paramTypes
        self.bodyNode = bodyNode
        self.stackFrameSize = stackFrameSize
        self.declId = declId
        self.blockId = blockId
    }
}

public struct SemResult: @unchecked Sendable {
    public let nodeTypes: [NodeId: TypeId]
    public let symbolRefs: [NodeId: CSymbol]
    public let functions: [String: FunctionSignature]
    public let functionOrder: [String]
    public let stringLiterals: [String: Int]
    public let diagnostics: [String]
    public let semModule: SemModule

    public init(
        nodeTypes: [NodeId: TypeId],
        symbolRefs: [NodeId: CSymbol],
        functions: [String: FunctionSignature],
        functionOrder: [String],
        stringLiterals: [String: Int],
        diagnostics: [String],
        semModule: SemModule
    ) {
        self.nodeTypes = nodeTypes
        self.symbolRefs = symbolRefs
        self.functions = functions
        self.functionOrder = functionOrder
        self.stringLiterals = stringLiterals
        self.diagnostics = diagnostics
        self.semModule = semModule
    }
}

/// Comprehensive ISO C23 semantic analysis, type checking, and SemIR builder (02-semantic-analysis.md, 10-semantic-ir-and-name-resolution.md).
public struct CSemanticAnalyzer: ~Copyable {
    public let typePool: TypePool
    private let sourceBuffer: UnsafePointer<UInt8>
    private let sourceLength: Int
    private let sourceManager: SourceManager?

    // Module-wide SemIR structures
    private var declTable: DeclTable
    private var instBlocks: [SemInstBlockContainer] = []
    private var diagnosticBag: DiagnosticBag

    // Backwards-compatible mappings for M0.5 AIRLowering
    private var nodeTypes: [NodeId: TypeId] = [:]
    private var symbolRefs: [NodeId: CSymbol] = [:]
    private var functions: [String: FunctionSignature] = [:]
    private var functionOrder: [String] = []
    private var stringLiterals: [String: Int] = [:]
    private var stringCounter: Int = 0
    private var diagnostics: [String] = []

    // Scope and function tracking
    private var currentScope: CScope
    private var currentStackOffset: Int32 = 0
    private var currentReturnType: QualType = .void
    private var currentBlockContainer: SemInstBlockContainer? = nil

    // Constraint-checking state (C23 6.8.4.2 switch, 6.8.6 jumps, 6.9 external definitions)
    private var loopDepth: Int = 0
    private var switchStack: [(values: Set<Int64>, hasDefault: Bool)] = []
    private var functionLabels: [String: TokenId] = [:]
    private var pendingGotos: [(name: String, tok: TokenId)] = []
    private var definedFunctions: Set<String> = []
    private var initializedGlobals: Set<String> = []
    private var currentFunctionName: String = ""
    /// Names of the compiler-provided declarations (`write`, `exit`), which headers may redeclare.
    private var builtinNames: Set<String> = ["write", "exit"]

    public init(
        typePool: TypePool,
        sourceBuffer: UnsafePointer<UInt8>,
        sourceLength: Int,
        sourceManager: SourceManager? = nil,
        diagnosticBag: consuming DiagnosticBag = DiagnosticBag()
    ) {
        self.typePool = typePool
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
        self.sourceManager = sourceManager
        self.declTable = DeclTable()
        self.diagnosticBag = diagnosticBag
        self.currentScope = CScope()

        // Nil instruction block at index 0
        let nilBlock = SemInstBlock()
        self.instBlocks.append(SemInstBlockContainer(block: nilBlock))

        setupBuiltins()
    }

    private mutating func setupBuiltins() {
        // long write(int fd, const void *buf, unsigned long count)
        let voidPtr = typePool.pointerTo(.void)
        let writeType = typePool.functionType(returnType: .long, paramTypes: [.int, QualType(typeId: voidPtr), .ulong])
        let writeDecl = declTable.append(kind: .function, name: "write", type: QualType(typeId: writeType))
        currentScope.insertOrdinary(symbol: CSymbol(name: "write", declId: writeDecl, type: QualType(typeId: writeType), storage: .function(name: "write")))

        // void exit(int status)
        let exitType = typePool.functionType(returnType: .void, paramTypes: [.int])
        let exitDecl = declTable.append(kind: .function, name: "exit", type: QualType(typeId: exitType))
        currentScope.insertOrdinary(symbol: CSymbol(name: "exit", declId: exitDecl, type: QualType(typeId: exitType), storage: .function(name: "exit")))
    }

    public func spelling(of tok: TokenId, in tokens: borrowing TokenBuffer) -> String {
        guard tok.isValid else { return "" }
        let s = tokens.start(of: tok)
        let e = tokens.end(of: tok)
        let len = Int(e.rawValue - s.rawValue)
        guard len >= 0 else { return "" }

        if let sm = sourceManager, let text = sm.text(from: s, to: e) {
            return text
        }
        let sRaw = Int(s.rawValue)
        guard sRaw >= 0, sRaw + len <= sourceLength else { return "" }
        return String(decoding: UnsafeBufferPointer(start: sourceBuffer + sRaw, count: len), as: UTF8.self)
    }

    private mutating func reportError(_ message: String, diagId: DiagId = .semaTypeMismatch, at tok: TokenId, in tokens: borrowing TokenBuffer, args: [String] = []) {
        let loc = tok.isValid ? tokens.start(of: tok) : .zero
        let gLoc = GlobalLocation(unitId: UnitId(1), location: loc)
        diagnostics.append(message)
        diagnosticBag.report(diagId, at: gLoc, args: args)
    }

    // MARK: - Main Semantic Analysis Entry Point

    public consuming func analyze(tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemResult {
        let root = NodeId(tree.count - 1)
        guard root.isValid, tree.kind(of: root) == .translationUnit else {
            let emptyMod = SemModule(declTable: consume declTable, instBlocks: instBlocks, typePool: typePool, diagnosticBag: consume diagnosticBag)
            return SemResult(nodeTypes: [:], symbolRefs: [:], functions: [:], functionOrder: [], stringLiterals: [:], diagnostics: ["Empty or invalid translation unit"], semModule: emptyMod)
        }

        // Walk top-level declarations
        let decls = tree.children(of: root)
        for decl in decls {
            let k = tree.kind(of: decl)
            switch k {
            case .functionDecl:
                analyzeFunction(decl, tree: tree, tokens: tokens)
            case .varDecl:
                analyzeGlobalVar(decl, tree: tree, tokens: tokens)
            case .typedefDecl:
                analyzeTypedef(decl, tree: tree, tokens: tokens)
            case .structDecl, .unionDecl, .structType, .unionType:
                _ = analyzeStructOrUnion(decl, tree: tree, tokens: tokens, isUnion: (k == .unionDecl || k == .unionType))
            case .enumDecl, .enumType:
                _ = analyzeEnum(decl, tree: tree, tokens: tokens)
            case .staticAssertDecl:
                analyzeStaticAssert(decl, tree: tree, tokens: tokens)
            default:
                break
            }
        }

        let finalMod = SemModule(
            declTable: consume declTable,
            instBlocks: instBlocks,
            typePool: typePool,
            diagnosticBag: consume diagnosticBag
        )

        return SemResult(
            nodeTypes: nodeTypes,
            symbolRefs: symbolRefs,
            functions: functions,
            functionOrder: functionOrder,
            stringLiterals: stringLiterals,
            diagnostics: diagnostics,
            semModule: finalMod
        )
    }

    // MARK: - Type Resolution

    private func isTypeNode(_ kind: CNodeKind) -> Bool {
        switch kind {
        case .typeSpec, .pointerType, .arrayType, .structDecl, .unionDecl, .structType, .unionType,
             .enumDecl, .enumType, .typeofType, .typeofUnqualType, .functionType, .atomicType:
            return true
        default:
            return false
        }
    }

    public mutating func resolveType(from typeNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> QualType {
        let kind = tree.kind(of: typeNode)
        switch kind {
        case .typeSpec:
            let tok = tree.token(of: typeNode)
            if let primitive = resolvePrimitiveSpecifiers(startingAt: tok, in: tokens) {
                return primitive
            }
            let txt = spelling(of: tok, in: tokens)
            return resolvePrimitiveOrTypedef(txt, at: tok, in: tokens)

        case .pointerType:
            let children = tree.children(of: typeNode)
            let pointee = children.first.map { resolveType(from: $0, tree: tree, tokens: tokens) } ?? .void
            let ptrId = typePool.pointerTo(pointee)
            return QualType(typeId: ptrId)

        case .arrayType:
            let children = tree.children(of: typeNode)
            let element = children.first.map { resolveType(from: $0, tree: tree, tokens: tokens) } ?? .int
            var count: UInt64 = 0
            if children.count > 1 {
                let countVal = evaluateIntegerConstant(children[1], tree: tree, tokens: tokens)
                count = UInt64(max(0, countVal))
            }
            let arrId = typePool.arrayType(elementType: element, count: count)
            return QualType(typeId: arrId)

        case .structDecl, .unionDecl, .structType, .unionType:
            let tid = analyzeStructOrUnion(typeNode, tree: tree, tokens: tokens, isUnion: (kind == .unionDecl || kind == .unionType))
            return QualType(typeId: tid)

        case .enumDecl, .enumType:
            let tid = analyzeEnum(typeNode, tree: tree, tokens: tokens)
            return QualType(typeId: tid)

        case .typeofType, .typeofUnqualType:
            let children = tree.children(of: typeNode)
            guard let first = children.first else { return .int }
            if isTypeNode(tree.kind(of: first)) {
                let t = resolveType(from: first, tree: tree, tokens: tokens)
                return (kind == .typeofUnqualType) ? t.unqualified() : t
            } else if let container = currentBlockContainer {
                let inst = analyzeExpression(first, tree: tree, tokens: tokens)
                let t = container.block.type(of: inst)
                return (kind == .typeofUnqualType) ? t.unqualified() : t
            }
            return .int

        default:
            return .int
        }
    }

    /// Resolves a C type-specifier sequence (C23 6.7.3.1) such as `unsigned long long`, `long double` or
    /// `const unsigned volatile char`. The parser records only the first specifier token in the `typeSpec`
    /// node; the rest of the sequence follows it contiguously in the token buffer. Returns nil if the
    /// sequence has no keyword type specifier (typedef names, builtin extended types, C23 `auto`).
    private func resolvePrimitiveSpecifiers(startingAt first: TokenId, in tokens: borrowing TokenBuffer) -> QualType? {
        var void = false, bool = false, char = false, short = false, int = false, float = false, double = false
        var longs = 0, signed = false, unsigned = false, sawSpecifier = false
        var i = Int(first.rawIndex)
        let end = Int(tokens.count)
        while i < end {
            let tid = TokenId(UInt32(i))
            switch CTokenKind(rawValue: tokens.kind(of: tid)) {
            case .kwVoid: void = true
            case .kwBool: bool = true
            case .kwChar: char = true
            case .kwShort: short = true
            case .kwInt: int = true
            case .kwLong: longs += 1
            case .kwFloat: float = true
            case .kwDouble: double = true
            case .kwSigned: signed = true
            case .kwUnsigned: unsigned = true
            case .kwConst, .kwVolatile, .kwRestrict, .kwAtomic, .kwStatic, .kwExtern, .kwAuto,
                 .kwRegister, .kwThreadLocal, .kwConstexpr, .kwInline:
                i += 1
                continue
            default:
                i = end
                continue
            }
            sawSpecifier = true
            i += 1
        }
        guard sawSpecifier else { return nil }
        _ = int
        if void { return .void }
        if bool { return .bool }
        if char { return unsigned ? QualType(typeId: .uchar) : (signed ? QualType(typeId: .schar) : .char) }
        if float { return .float }
        if double { return longs > 0 ? QualType(typeId: .longdouble) : .double }
        if short { return QualType(typeId: unsigned ? .ushort : .short) }
        if longs >= 2 { return QualType(typeId: unsigned ? .ulonglong : .longlong) }
        if longs == 1 { return unsigned ? QualType(typeId: .ulong) : .long }
        return unsigned ? QualType(typeId: .uint) : .int
    }

    /// Resolves a single-identifier type: a builtin extended type name, a typedef name, or (C23 `auto`) a
    /// storage-class keyword with no type specifier.
    private mutating func resolvePrimitiveOrTypedef(_ txt: String, at tok: TokenId, in tokens: borrowing TokenBuffer) -> QualType {
        switch txt {
        case "_Float16", "_Float32": return .float
        case "_Float64", "_Float32x": return .double
        case "__float128", "_Float128", "_Float64x": return QualType(typeId: .longdouble)
        case "__int128", "__int128_t": return QualType(typeId: .longlong)
        case "__uint128_t": return QualType(typeId: .ulonglong)
        default:
            if let sym = currentScope.lookupOrdinary(txt), case .typedef = sym.storage {
                return sym.type
            }
            if let tagType = currentScope.lookupTag(txt) {
                return QualType(typeId: tagType)
            }
            if CTokenKind(rawValue: tokens.kind(of: tok)) == .identifier && !txt.hasPrefix("_") {
                reportError("unknown type name '\(txt)'", diagId: .semaUnknownTypeName, at: tok, in: tokens, args: [txt])
            }
            return .int
        }
    }

    // MARK: - Declarations

    private mutating func analyzeFunction(_ fnNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: fnNode)
        guard children.count >= 2 else { return }

        let retTypeNode = children[0]
        let returnType = resolveType(from: retTypeNode, tree: tree, tokens: tokens)
        self.currentReturnType = returnType

        let fnTok = tree.token(of: fnNode)
        let fnName = spelling(of: fnTok, in: tokens)

        // Attributes may sit between the return type and the parameter list (`void __attribute__((noreturn)) f(...)`)
        guard let paramListNode = children.dropFirst().first(where: { tree.kind(of: $0) == .paramList }) else { return }
        let paramNodes = tree.children(of: paramListNode)

        var paramNames: [String] = []
        var paramTypes: [QualType] = []
        var isVariadic = false

        for pNode in paramNodes {
            if CTokenKind(rawValue: tokens.kind(of: tree.token(of: pNode))) == .ellipsis {
                isVariadic = true
                continue
            }
            let pChildren = tree.children(of: pNode)
            if let pTypeNode = pChildren.first {
                var pType = resolveType(from: pTypeNode, tree: tree, tokens: tokens)
                let pTok = tree.token(of: pNode)
                // Array parameters are adjusted to pointers (C23 6.7.7.4p7); deeper shapes are not modeled
                let suffix = declaratorSuffix(after: pTok, tokens: tokens)
                if CTokenKind(rawValue: tokens.kind(of: pTok)) != .identifier,
                   typeNameHasParenthesizedDeclarator(castTok: TokenId(tree.token(of: pTypeNode).rawIndex - 1), tokens: tokens) {
                    pType = QualType(typeId: typePool.pointerTo(.error))  // abstract `void (*)(void)` parameter
                } else if suffix.parenthesized {
                    pType = QualType(typeId: typePool.pointerTo(.error))  // function-pointer parameter
                } else if suffix.arrayDims > 1 {
                    pType = .error
                } else if suffix.arrayDims == 1 {
                    pType = QualType(typeId: typePool.pointerTo(pType))
                }
                let pName = spelling(of: pTok, in: tokens)
                paramNames.append(pName)
                paramTypes.append(pType)
            }
        }

        // `(void)` declares a function with no parameters (C23 6.7.7.4p10)
        if paramTypes.count == 1 && typePool.canonical(of: paramTypes[0].typeId) == .void {
            paramTypes = []
            paramNames = []
        }

        let fnTypeId = typePool.functionType(returnType: returnType, paramTypes: paramTypes, isVariadic: isVariadic)
        let fnQualType = QualType(typeId: fnTypeId)

        // Redeclarations must have compatible types (C23 6.7p4)
        if !builtinNames.contains(fnName), let prior = currentScope.lookupLocalOrdinary(fnName),
           !typesCompatible(prior.type, fnQualType) {
            reportError("conflicting types for '\(fnName)'", diagId: .semaRedeclaration, at: fnTok, in: tokens, args: [fnName])
        }

        let fnDeclId = declTable.append(
            kind: .function,
            name: fnName,
            type: fnQualType,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: fnTok))
        )

        currentScope.insertOrdinary(symbol: CSymbol(name: fnName, declId: fnDeclId, type: fnQualType, storage: .function(name: fnName)))

        // If function has body (definition). Prototypes may also carry trailing attributes or an
        // `__asm__("label")`, so the body is the compound-statement child, not merely a third child.
        if let bodyNode = children.dropFirst(2).first(where: { tree.kind(of: $0) == .compoundStmt }) {
            if !definedFunctions.insert(fnName).inserted {
                reportError("redefinition of '\(fnName)'", diagId: .semaRedefinition, at: fnTok, in: tokens, args: [fnName])
            }
            currentFunctionName = fnName
            functionLabels = [:]
            pendingGotos = []
            let fnScope = CScope(parent: currentScope)
            self.currentScope = fnScope
            self.currentStackOffset = 0

            let blockContainer = SemInstBlockContainer(block: SemInstBlock())
            self.currentBlockContainer = blockContainer
            let blockId = InstBlockId(UInt32(instBlocks.count))
            instBlocks.append(blockContainer)
            declTable.setBody(for: fnDeclId, blockId: blockId.rawIndex)

            // Allocate and bind parameters
            for (idx, pName) in paramNames.enumerated() {
                let pType = paramTypes[idx]
                let sz = max(8, typePool.size(of: pType.typeId))
                currentStackOffset += Int32((sz + 7) & ~7)
                let offset = -currentStackOffset

                let pDecl = declTable.append(
                    kind: .parameter,
                    name: pName,
                    parent: fnDeclId,
                    type: pType
                )
                currentScope.insertOrdinary(symbol: CSymbol(name: pName, declId: pDecl, type: pType, storage: .param(index: idx, offset: offset)))
            }

            analyzeStatement(bodyNode, tree: tree, tokens: tokens)
            self.currentBlockContainer = nil
            for g in pendingGotos where functionLabels[g.name] == nil {
                reportError("use of undeclared label '\(g.name)'", diagId: .semaUndefinedLabel, at: g.tok, in: tokens, args: [g.name])
            }

            // 16-byte align stack frame
            let rawFrame = currentStackOffset
            let alignedFrame = (rawFrame + 15) & ~15

            if !functionOrder.contains(fnName) {
                functionOrder.append(fnName)
            }
            functions[fnName] = FunctionSignature(
                name: fnName,
                returnType: returnType.typeId,
                paramNames: paramNames,
                paramTypes: paramTypes.map { $0.typeId },
                bodyNode: bodyNode,
                stackFrameSize: alignedFrame,
                declId: fnDeclId,
                blockId: blockId
            )

            self.currentScope = fnScope.parent ?? CScope()
        }
    }

    private func unwrapBaseType(_ qt: QualType) -> QualType {
        var cur = qt
        while true {
            switch typePool.typeInfo(of: cur.typeId).kind {
            case .pointer(let pointee):
                cur = pointee
            case .array(let element, _):
                cur = element
            default:
                return cur
            }
        }
    }

    private mutating func resolveExtraDeclaratorType(
        baseType: QualType,
        extraFieldNode: NodeId,
        tree: borrowing ParseTree,
        tokens: borrowing TokenBuffer
    ) -> (type: QualType, initNodes: [NodeId]) {
        var cur = baseType
        var initNodes: [NodeId] = []
        for child in tree.children(of: extraFieldNode) {
            let ck = tree.kind(of: child)
            if ck == .pointerType {
                cur = QualType(typeId: typePool.pointerTo(cur))
            } else if ck == .arrayType {
                var count: Int64 = 0
                if let sizeExpr = tree.children(of: child).first {
                    count = evaluateIntegerConstant(sizeExpr, tree: tree, tokens: tokens)
                }
                cur = QualType(typeId: typePool.arrayType(elementType: cur, count: UInt64(max(0, count))))
            } else {
                initNodes.append(child)
            }
        }
        return (cur, initNodes)
    }

    private mutating func analyzeGlobalVar(_ varNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: varNode)
        guard let typeNode = children.first else { return }
        var varType = resolveType(from: typeNode, tree: tree, tokens: tokens)
        let baseType = unwrapBaseType(varType)
        let nameTok = tree.token(of: varNode)
        let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
        if tokKind == .semicolon || tokKind == .colon {
            return
        }
        let name = spelling(of: nameTok, in: tokens)
        if declaratorSuffix(after: nameTok, tokens: tokens).parenthesized { varType = parenthesizedDeclaratorType(nameTok: nameTok, tokens: tokens) }
        varType = applyObjectConst(varType, typeNode: typeNode, tree: tree, tokens: tokens)

        // C23 6.7p4 / 6.9.2: redeclarations must have compatible types; at most one external definition
        if let prior = currentScope.lookupLocalOrdinary(name), !builtinNames.contains(name) {
            switch prior.storage {
            case .global, .function:
                if !typesCompatible(prior.type.unqualified(), varType.unqualified()) {
                    reportError("redefinition of '\(name)' with a different type", diagId: .semaRedeclaration, at: nameTok, in: tokens, args: [name])
                }
            case .typedef, .enumConstant:
                reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
            default:
                break
            }
        }
        if children.count > 1, tree.kind(of: children[1]) != .fieldDecl {
            if !initializedGlobals.insert(name).inserted {
                reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
            }
            if !isConstantInitializer(children[1], tree: tree, tokens: tokens) {
                reportError("initializer element is not a compile-time constant", diagId: .semaConstantExprNotConstant, at: tree.token(of: children[1]), in: tokens)
            }
        }

        let declId = declTable.append(
            kind: .variable,
            name: name,
            type: varType,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
        )
        currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: varType, storage: .global(name: name)))

        for extraChild in children.dropFirst() {
            if tree.kind(of: extraChild) == .fieldDecl {
                let extraTok = tree.token(of: extraChild)
                let extraName = spelling(of: extraTok, in: tokens)
                let (extraType, initNodes) = resolveExtraDeclaratorType(baseType: baseType, extraFieldNode: extraChild, tree: tree, tokens: tokens)
                if !extraName.isEmpty {
                    let extraDeclId = declTable.append(
                        kind: .variable,
                        name: extraName,
                        type: extraType,
                        origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: extraTok))
                    )
                    currentScope.insertOrdinary(symbol: CSymbol(name: extraName, declId: extraDeclId, type: extraType, storage: .global(name: extraName)))
                }
                for initChild in initNodes {
                    _ = analyzeExpression(initChild, tree: tree, tokens: tokens)
                }
            } else {
                _ = analyzeExpression(extraChild, tree: tree, tokens: tokens)
            }
        }
    }

    private mutating func analyzeTypedef(_ typedefNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: typedefNode)
        guard let typeNode = children.first else { return }
        var underlyingType = resolveType(from: typeNode, tree: tree, tokens: tokens)
        let nameTok = tree.token(of: typedefNode)
        let name = spelling(of: nameTok, in: tokens)
        if CTokenKind(rawValue: tokens.kind(of: nameTok)) == .identifier {
            underlyingType = adjustTypedefDeclarator(underlyingType, nameTok: nameTok, tokens: tokens)
        }

        let typedefTypeId = typePool.typedefType(name: name, underlying: underlyingType)
        let typedefQualType = QualType(typeId: typedefTypeId)

        // C11 6.7p3: a typedef may be redeclared in the same scope only with the same type. (Typedefs that
        // name a builtin type such as `_Float128` have no identifier token and are not checked.)
        if CTokenKind(rawValue: tokens.kind(of: nameTok)) == .identifier, let prior = currentScope.lookupLocalOrdinary(name) {
            let sameType = prior.storage == .typedef
                && typePool.canonical(of: prior.type.typeId) == typePool.canonical(of: typedefTypeId)
            if !sameType {
                reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
            }
        }

        let declId = declTable.append(
            kind: .typedefDecl,
            name: name,
            type: typedefQualType,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
        )
        currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: typedefQualType, storage: .typedef))

        // Further declarators: `typedef struct _XOC *XOC, *XFontSet;`
        let baseType = resolveType(from: unwrapTypeSpecifier(typeNode, tree: tree), tree: tree, tokens: tokens)
        for extra in children.dropFirst() where tree.kind(of: extra) == .fieldDecl {
            let extraTok = tree.token(of: extra)
            let extraName = spelling(of: extraTok, in: tokens)
            var (extraType, _) = resolveExtraDeclaratorType(baseType: baseType, extraFieldNode: extra, tree: tree, tokens: tokens)
            extraType = adjustTypedefDeclarator(extraType, nameTok: extraTok, tokens: tokens)
            let extraTypeId = typePool.typedefType(name: extraName, underlying: extraType)
            let extraDecl = declTable.append(kind: .typedefDecl, name: extraName, type: QualType(typeId: extraTypeId),
                                             origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: extraTok)))
            currentScope.insertOrdinary(symbol: CSymbol(name: extraName, declId: extraDecl, type: QualType(typeId: extraTypeId), storage: .typedef))
        }
    }

    /// Typedef declarators the parser does not model: parenthesized ones (`typedef void (*fn)(void)`) and
    /// function types (`typedef int handler(int)`).
    private func adjustTypedefDeclarator(_ type: QualType, nameTok: TokenId, tokens: borrowing TokenBuffer) -> QualType {
        if declaratorSuffix(after: nameTok, tokens: tokens).parenthesized {
            return parenthesizedDeclaratorType(nameTok: nameTok, tokens: tokens)
        }
        let next = TokenId(nameTok.rawIndex + 1)
        if Int(next.rawIndex) < tokens.count, CTokenKind(rawValue: tokens.kind(of: next)) == .lParen {
            return .error
        }
        return type
    }

    /// The innermost type-specifier node under any pointer/array wrappers of a declaration's first declarator.
    private func unwrapTypeSpecifier(_ node: NodeId, tree: borrowing ParseTree) -> NodeId {
        var cur = node
        while tree.kind(of: cur) == .pointerType || tree.kind(of: cur) == .arrayType, let inner = tree.children(of: cur).first {
            cur = inner
        }
        return cur
    }

    private mutating func analyzeStructOrUnion(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer, isUnion: Bool) -> TypeId {
        let nameTok = tree.token(of: node)
        let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
        let name = (tokKind == .kwStruct || tokKind == .kwUnion) ? "" : spelling(of: nameTok, in: tokens)

        let children = tree.children(of: node)
        if children.isEmpty, !name.isEmpty, let existingId = currentScope.lookupTag(name) {
            return existingId
        }

        let hadExistingTag = !name.isEmpty && currentScope.lookupTag(name) != nil
        if !name.isEmpty && !hadExistingTag {
            let fwdId = typePool.structType(name: name, fields: [], isUnion: isUnion)
            currentScope.insertTag(name: name, typeId: fwdId)
        }

        var fields: [(name: String, type: QualType)] = []
        for child in children {
            let ck = tree.kind(of: child)
            if ck == .fieldDecl || ck == .varDecl {
                let fChildren = tree.children(of: child)
                if let fTypeNode = fChildren.first {
                    var fType = resolveType(from: fTypeNode, tree: tree, tokens: tokens)
                    let fBaseType = unwrapBaseType(fType)
                    let fTok = tree.token(of: child)
                    if CTokenKind(rawValue: tokens.kind(of: fTok)) == .identifier, declaratorSuffix(after: fTok, tokens: tokens).parenthesized {
                        fType = parenthesizedDeclaratorType(nameTok: fTok, tokens: tokens)
                    }
                    let fTokKind = CTokenKind(rawValue: tokens.kind(of: fTok)) ?? .errorToken
                    let fName = (fTokKind == .semicolon || fTokKind == .colon) ? "" : spelling(of: fTok, in: tokens)
                    fields.append((name: fName, type: fType))
                    for extra in fChildren.dropFirst() where tree.kind(of: extra) == .fieldDecl {
                        let extraName = spelling(of: tree.token(of: extra), in: tokens)
                        let (extraType, _) = resolveExtraDeclaratorType(baseType: fBaseType, extraFieldNode: extra, tree: tree, tokens: tokens)
                        if !extraName.isEmpty {
                            fields.append((name: extraName, type: extraType))
                        }
                    }
                }
            }
        }

        let structTypeId = typePool.structType(name: name, fields: fields, isUnion: isUnion)
        if !name.isEmpty {
            currentScope.insertTag(name: name, typeId: structTypeId)
            if !fields.isEmpty || !hadExistingTag {
                _ = declTable.append(
                    kind: isUnion ? .unionDecl : .structDecl,
                    name: name,
                    type: QualType(typeId: structTypeId)
                )
            }
        }
        return structTypeId
    }

    private mutating func analyzeEnum(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> TypeId {
        let nameTok = tree.token(of: node)
        let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
        let name = (tokKind == .kwEnum) ? "" : spelling(of: nameTok, in: tokens)

        var enumCases: [(name: String, value: Int64)] = []
        var nextVal: Int64 = 0

        for child in tree.children(of: node) {
            if tree.kind(of: child) == .enumeratorDecl {
                let cTok = tree.token(of: child)
                let cName = spelling(of: cTok, in: tokens)
                let cChildren = tree.children(of: child)
                if let valNode = cChildren.first {
                    nextVal = evaluateIntegerConstant(valNode, tree: tree, tokens: tokens)
                }
                let val = nextVal
                nextVal += 1
                enumCases.append((name: cName, value: val))
                currentScope.insertOrdinary(symbol: CSymbol(name: cName, type: .int, storage: .enumConstant(value: val)))
            }
        }

        let enumTypeId = typePool.enumType(name: name, underlyingType: .int, cases: enumCases)
        if !name.isEmpty {
            currentScope.insertTag(name: name, typeId: enumTypeId)
            if !enumCases.isEmpty {
                _ = declTable.append(kind: .enumDecl, name: name, type: QualType(typeId: enumTypeId))
            }
        }
        return enumTypeId
    }

    private mutating func analyzeStaticAssert(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: node)
        guard let condNode = children.first else { return }
        let val = evaluateIntegerConstant(condNode, tree: tree, tokens: tokens)
        if val == 0 {
            let tok = tree.token(of: node)
            let message = children.count > 1 ? ": " + spelling(of: tree.token(of: children[1]), in: tokens) : ""
            reportError("static assertion failed\(message)", diagId: .semaStaticAssertFailed, at: tok, in: tokens, args: [message])
        }
    }

    /// Offset and type of a member designator (`m`, `m.n`, `m[2]`) within `base`, for `offsetof`.
    private mutating func memberOffset(of designator: NodeId, in base: QualType, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> (offset: Int64, type: QualType)? {
        switch tree.kind(of: designator) {
        case .identExpr:
            let name = spelling(of: tree.token(of: designator), in: tokens)
            guard let field = typePool.lookupStructField(named: name, in: base.typeId) else { return nil }
            return (Int64(field.offset), field.type)
        case .memberExpr:
            let children = tree.children(of: designator)
            guard let inner = children.first, children.count > 1,
                  let outer = memberOffset(of: inner, in: base, tree: tree, tokens: tokens) else { return nil }
            let name = spelling(of: tree.token(of: children[1]), in: tokens)
            guard let field = typePool.lookupStructField(named: name, in: outer.type.typeId) else { return nil }
            return (outer.offset + Int64(field.offset), field.type)
        case .subscriptExpr:
            let children = tree.children(of: designator)
            guard children.count == 2, let outer = memberOffset(of: children[0], in: base, tree: tree, tokens: tokens) else { return nil }
            let element = typePool.pointeeType(of: outer.type.typeId)
            let index = evaluateIntegerConstant(children[1], tree: tree, tokens: tokens)
            return (outer.offset + index * Int64(typePool.size(of: element.typeId)), element)
        default:
            return nil
        }
    }

    // MARK: - Constraint Checks (C23 6.5, 6.7, 6.8)

    private func canonicalKind(_ t: QualType) -> CTypeKind {
        typePool.typeInfo(of: typePool.canonical(of: t.typeId)).kind
    }

    private func isStructOrUnion(_ t: QualType) -> Bool {
        if case .struct = canonicalKind(t) { return true }
        return false
    }

    private func isArrayOrFunction(_ t: QualType) -> Bool {
        switch canonicalKind(t) {
        case .array, .function: return true
        default: return false
        }
    }

    /// Pointer, array (decays) or function designator (decays): usable where a pointer operand is required.
    private func isPointerLike(_ t: QualType) -> Bool {
        typePool.isPointer(type: t.typeId) || isArrayOrFunction(t)
    }

    /// True if sema modeled the expression's type. Constructs it does not model yet produce `errorInst`,
    /// and every constraint check skips them rather than risk rejecting valid code.
    private func isTyped(_ inst: SemInstId) -> Bool {
        guard inst.isValid, let c = currentBlockContainer else { return false }
        return c.block.kind(of: inst) != .errorInst && !c.block.type(of: inst).isError
    }

    /// Array-to-pointer conversion (C23 6.3.2.1p3): `T[N]` → `T *`; other types are unchanged.
    private func decayed(_ t: QualType) -> QualType {
        if case .array(let element, _) = canonicalKind(t) {
            return QualType(typeId: typePool.pointerTo(element))
        }
        return t
    }

    private func typeOf(_ inst: SemInstId) -> QualType {
        currentBlockContainer?.block.type(of: inst) ?? .error
    }

    /// Type compatibility (C23 6.2.7), structural so that separately created function/array types compare
    /// equal. Enumerations are compatible with their underlying integer type.
    private func typesCompatible(_ a: QualType, _ b: QualType) -> Bool {
        if a.isError || b.isError { return true }
        let ca = typePool.canonical(of: a.typeId), cb = typePool.canonical(of: b.typeId)
        if ca == cb { return true }
        switch (typePool.typeInfo(of: ca).kind, typePool.typeInfo(of: cb).kind) {
        case (.pointer(let pa), .pointer(let pb)):
            return pa.qualifiers == pb.qualifiers && typesCompatible(pa, pb)
        case (.array(let ea, let na), .array(let eb, let nb)):
            return (na == 0 || nb == 0 || na == nb) && typesCompatible(ea, eb)
        case (.function(let ra, let pa, let va), .function(let rb, let pb, let vb)):
            guard typesCompatible(ra, rb), va == vb, pa.count == pb.count else { return false }
            return zip(pa, pb).allSatisfy { typesCompatible($0.unqualified(), $1.unqualified()) }
        case (.enum, .int), (.int, .enum):
            return true
        case (.struct(let na, _, let ua), .struct(let nb, _, let ub)):
            // Within a translation unit the same tag names the same type (forward declaration vs completion)
            return !na.isEmpty && na == nb && ua == ub
        default:
            return false
        }
    }

    /// Whether the declaration whose type specifier is `typeNode` carries storage-class keyword `kw`.
    /// Leading specifiers precede the type node's anchor token and trailing ones follow it.
    private func declarationHasStorageClass(_ kw: CTokenKind, typeNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        let anchor = Int(tree.token(of: typeNode).rawIndex)
        let specifierKinds: Set<CTokenKind> = [.kwConst, .kwVolatile, .kwRestrict, .kwAtomic, .kwStatic, .kwExtern,
                                               .kwAuto, .kwRegister, .kwThreadLocal, .kwConstexpr, .kwInline,
                                               .kwVoid, .kwChar, .kwShort, .kwInt, .kwLong, .kwFloat, .kwDouble,
                                               .kwSigned, .kwUnsigned, .kwBool]
        var i = anchor
        while i >= 1, let k = CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) {
            if k == kw { return true }
            if i != anchor && !specifierKinds.contains(k) { break }
            i -= 1
        }
        i = anchor + 1
        while i < tokens.count, let k = CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))), specifierKinds.contains(k) {
            if k == kw { return true }
            i += 1
        }
        return false
    }

    /// The parser models `T *name` and `T name[N]` declarators but not parenthesized ones such as
    /// `int (*tab[2])(int)`; those get the error type so no check relies on a wrong type.
    /// Returns the number of `[...]` suffixes after the name and whether the declarator is parenthesized.
    private func declaratorSuffix(after nameTok: TokenId, tokens: borrowing TokenBuffer) -> (arrayDims: Int, parenthesized: Bool) {
        let shape = declaratorShape(after: nameTok, tokens: tokens)
        return (shape.arrayDims, shape.parenthesized)
    }

    private func declaratorShape(after nameTok: TokenId, tokens: borrowing TokenBuffer) -> (arrayDims: Int, parenthesized: Bool, hasPointer: Bool) {
        var i = Int(nameTok.rawIndex) + 1
        var dims = 0
        while i < tokens.count, CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) == .lBracket {
            var depth = 0
            repeat {
                switch CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) {
                case .lBracket: depth += 1
                case .rBracket: depth -= 1
                default: break
                }
                i += 1
            } while depth > 0 && i < tokens.count
            dims += 1
        }
        // Parenthesized: `(` before the name, past any `*` and qualifiers (`int (*const p)[3]`)
        var j = Int(nameTok.rawIndex) - 1
        var sawStar = false
        while j >= 1, let k = CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(j)))),
              k == .star || k == .kwConst || k == .kwVolatile || k == .kwRestrict || k == .kwAtomic {
            if k == .star { sawStar = true }
            j -= 1
        }
        let opens = j >= 1 && CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(j)))) == .lParen
        return (dims, opens, sawStar)
    }

    /// Approximate type of a parenthesized declarator, which the parser does not model: nearly always a
    /// pointer (`void (*fn)(int)`, `int (*rows)[4]`) or an array of pointers (`void (*tab[4])(void)`).
    /// The pointee is the error type, so checks skip it, while sizes and layout stay correct.
    private func parenthesizedDeclaratorType(nameTok: TokenId, tokens: borrowing TokenBuffer) -> QualType {
        // `int (name)(args)` (Lua's API headers) declares a function: not a pointer, and not modeled here
        guard declaratorShape(after: nameTok, tokens: tokens).hasPointer else { return .error }
        let ptr = QualType(typeId: typePool.pointerTo(.error))
        let suffix = declaratorSuffix(after: nameTok, tokens: tokens)
        if suffix.arrayDims == 0 { return ptr }
        let lenTok = TokenId(nameTok.rawIndex + 2)
        if suffix.arrayDims == 1, CTokenKind(rawValue: tokens.kind(of: lenTok)) == .intLiteral,
           CTokenKind(rawValue: tokens.kind(of: TokenId(nameTok.rawIndex + 3))) == .rBracket,
           let n = CLiteral.integerValue(spelling(of: lenTok, in: tokens))?.value {
            return QualType(typeId: typePool.arrayType(elementType: ptr, count: n))
        }
        return .error
    }

    /// True if the parenthesized type name starting at `castTok` (`(`) contains a nested `(`.
    private func typeNameHasParenthesizedDeclarator(castTok: TokenId, tokens: borrowing TokenBuffer) -> Bool {
        var i = Int(castTok.rawIndex) + 1
        var depth = 1
        while i < tokens.count && depth > 0 {
            switch CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) {
            case .lParen:
                // `__attribute__((...))`, `_Atomic(T)` and `typeof(...)` also open parens; only a `(` that follows
                // a type keyword/identifier directly as a declarator (`T (*)`, `T (`) counts.
                let next = CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i + 1))))
                if next == .star || next == .caret { return true }
                depth += 1
            case .rParen:
                depth -= 1
            case .comma where depth == 1:
                return false  // end of this parameter's type name; a type name has no top-level comma
            default:
                break
            }
            i += 1
        }
        return false
    }

    /// `const int x` / `int const x` declares a const object; in `const char *p` the `const` belongs to the
    /// pointee (the declarator adds a pointer node), so the object itself stays modifiable.
    private func applyObjectConst(_ type: QualType, typeNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> QualType {
        guard !type.isError, tree.kind(of: typeNode) != .pointerType, tree.kind(of: typeNode) != .arrayType,
              declarationHasStorageClass(.kwConst, typeNode: typeNode, tree: tree, tokens: tokens) else { return type }
        return type.withConst()
    }

    /// C23 6.7p3: an identifier with no linkage shall not be declared twice in the same scope.
    private mutating func checkBlockScopeRedefinition(_ name: String, at tok: TokenId, tokens: borrowing TokenBuffer) {
        guard let prior = currentScope.lookupLocalOrdinary(name), prior.declId.isValid else { return }
        switch prior.storage {
        case .local, .param, .typedef, .enumConstant:
            reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: tok, in: tokens, args: [name])
        default:
            break
        }
    }

    /// Lvalue designation (C23 6.3.2.1). Unknown expression kinds count as lvalues (no false errors).
    private func isLvalue(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        switch tree.kind(of: node) {
        case .identExpr:
            guard let sym = symbolRefs[node] else { return true }
            switch sym.storage {
            case .local, .param, .global: return true
            default: return false
            }
        case .memberExpr:
            let opKind = CTokenKind(rawValue: tokens.kind(of: tree.token(of: node)))
            if opKind == .arrow { return true }
            guard let base = tree.children(of: node).first else { return true }
            return isLvalue(base, tree: tree, tokens: tokens)
        case .unaryExpr:
            return CTokenKind(rawValue: tokens.kind(of: tree.token(of: node))) == .star
        case .subscriptExpr, .compoundLiteralExpr, .stringLiteral:
            return true
        case .castExpr:
            // `(T){ ... }` is a compound literal (an lvalue), parsed as a cast of an initializer list
            return tree.children(of: node).last.map { tree.kind(of: $0) == .initList } ?? false
        case .intLiteral, .floatLiteral, .charLiteral, .boolLiteral, .nullptrLiteral, .binaryExpr, .assignExpr,
             .callExpr, .conditionalExpr, .commaExpr:
            return false
        default:
            return true
        }
    }

    /// Simple-assignment constraints (C23 6.5.16.1), also applied to initializers and `return`.
    /// Pointer-to-pointer mismatches are only warnings in Clang and are not diagnosed here.
    private mutating func checkAssignment(to dst: QualType, from rhs: SemInstId, rhsNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        guard isTyped(rhs), !dst.isError else { return }
        let src = typeOf(rhs)
        let loc = tree.token(of: rhsNode)
        let dstKind = canonicalKind(dst), srcKind = canonicalKind(src)
        if case .error = dstKind { return }
        if case .error = srcKind { return }
        func mismatch() {
            reportError("incompatible types in assignment", diagId: .semaTypeMismatch, at: loc, in: tokens, args: ["\(src)", "\(dst)"])
        }
        let dstIsStruct = isStructOrUnion(dst), srcIsStruct = isStructOrUnion(src)
        if dstIsStruct || srcIsStruct {
            if !(dstIsStruct && srcIsStruct && typesCompatible(dst.unqualified(), src.unqualified())) { mismatch() }
            return
        }
        if typePool.canonical(of: dst.typeId) == .void { return }
        let dstIsBool = typePool.canonical(of: dst.typeId) == .bool
        if case .pointer = dstKind {
            if typePool.isFloating(type: src.typeId) { mismatch(); return }
            // Integer → pointer requires a null pointer constant (Clang: -Wint-conversion is an error)
            if typePool.isInteger(type: src.typeId) && !isNullPointerConstant(rhsNode, tree: tree, tokens: tokens) { mismatch() }
            return
        }
        if typePool.isArithmetic(type: dst.typeId) && !dstIsBool {
            if case .nullptr = srcKind { mismatch(); return }
            if isPointerLike(src) { mismatch() }
        }
    }

    private mutating func isNullPointerConstant(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        isIntegerConstantExpression(node, tree: tree, tokens: tokens) && evaluateIntegerConstant(node, tree: tree, tokens: tokens) == 0
    }

    private mutating func checkScalarCondition(_ cond: SemInstId, at tok: TokenId, tokens: borrowing TokenBuffer) {
        guard isTyped(cond) else { return }
        let t = typeOf(cond)
        if isStructOrUnion(t) || typePool.canonical(of: t.typeId) == .void {
            reportError("statement requires expression of scalar type", diagId: .semaScalarRequired, at: tok, in: tokens, args: ["\(t)"])
        }
    }

    /// Integer constant expression (C23 6.6p8): literals, enumeration constants, `sizeof`/`alignof`, and
    /// operators over them. Used where a constant is required (case labels, null pointer constants).
    private func isIntegerConstantExpression(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        switch tree.kind(of: node) {
        case .intLiteral, .charLiteral, .boolLiteral:
            return true
        case .identExpr:
            let name = spelling(of: tree.token(of: node), in: tokens)
            if let sym = currentScope.lookupOrdinary(name), case .enumConstant = sym.storage { return true }
            return false
        case .unaryExpr:
            let op = CTokenKind(rawValue: tokens.kind(of: tree.token(of: node)))
            if op == .kwSizeof || op == .kwAlignof { return true }
            if op == .star || op == .amp || op == .plusPlus || op == .minusMinus { return false }
            return tree.children(of: node).allSatisfy { isIntegerConstantExpression($0, tree: tree, tokens: tokens) }
        case .castExpr:
            guard let operand = tree.children(of: node).last else { return false }
            return isIntegerConstantExpression(operand, tree: tree, tokens: tokens)
        case .binaryExpr, .conditionalExpr:
            return tree.children(of: node).allSatisfy { isIntegerConstantExpression($0, tree: tree, tokens: tokens) }
        case .callExpr:
            // `__builtin_offsetof`, `__builtin_constant_p`, ... fold to constants
            guard let callee = tree.children(of: node).first, tree.kind(of: callee) == .identExpr else { return false }
            return spelling(of: tree.token(of: callee), in: tokens).hasPrefix("__builtin_")
        default:
            return false
        }
    }

    /// Initializer of an object with static storage duration (C23 6.7.10p4): arithmetic constants, address
    /// constants (`&obj`, arrays and functions decay), string literals, and aggregates of those.
    private func isConstantInitializer(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        switch tree.kind(of: node) {
        case .identExpr:
            let name = spelling(of: tree.token(of: node), in: tokens)
            guard let sym = currentScope.lookupOrdinary(name) else { return true }
            switch sym.storage {
            case .enumConstant, .function: return true
            // Arrays/functions decay to address constants; const-qualified objects fold (a Clang/GCC extension)
            case .global: return isArrayOrFunction(sym.type) || sym.type.isConst || sym.type.isError
            case .local, .param: return false
            case .typedef: return true
            }
        case .unaryExpr:
            let op = CTokenKind(rawValue: tokens.kind(of: tree.token(of: node)))
            if op == .kwSizeof || op == .kwAlignof { return true }
            if op == .amp {
                // Address of an object with static storage (or a function); locals are not constant
                guard let operand = tree.children(of: node).first else { return true }
                return !refersToAutomaticObject(operand, tree: tree, tokens: tokens)
            }
            return tree.children(of: node).allSatisfy { isConstantInitializer($0, tree: tree, tokens: tokens) }
        case .callExpr:
            return isIntegerConstantExpression(node, tree: tree, tokens: tokens)
        case .assignExpr, .commaExpr:
            return false
        default:
            return tree.children(of: node).allSatisfy { child in
                isTypeNode(tree.kind(of: child)) || isConstantInitializer(child, tree: tree, tokens: tokens)
            }
        }
    }

    private func refersToAutomaticObject(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        if tree.kind(of: node) == .identExpr {
            let name = spelling(of: tree.token(of: node), in: tokens)
            if let sym = currentScope.lookupOrdinary(name) {
                switch sym.storage {
                case .local, .param: return true
                default: return false
                }
            }
            return false
        }
        return tree.children(of: node).contains { refersToAutomaticObject($0, tree: tree, tokens: tokens) }
    }

    // MARK: - Statements

    private mutating func analyzeStatement(_ stmtNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let kind = tree.kind(of: stmtNode)
        switch kind {
        case .compoundStmt:
            let blockScope = CScope(parent: currentScope)
            self.currentScope = blockScope
            for child in tree.children(of: stmtNode) {
                analyzeStatement(child, tree: tree, tokens: tokens)
            }
            self.currentScope = blockScope.parent ?? CScope()

        case .typedefDecl:
            analyzeTypedef(stmtNode, tree: tree, tokens: tokens)

        case .staticAssertDecl:
            analyzeStaticAssert(stmtNode, tree: tree, tokens: tokens)

        case .labelStmt:
            let labelTok = tree.token(of: stmtNode)
            let label = spelling(of: labelTok, in: tokens)
            if functionLabels[label] != nil {
                reportError("redefinition of label '\(label)'", diagId: .semaRedefinition, at: labelTok, in: tokens, args: [label])
            }
            functionLabels[label] = labelTok
            for child in tree.children(of: stmtNode) {
                analyzeStatement(child, tree: tree, tokens: tokens)
            }

        case .gotoStmt:
            let gotoTok = tree.token(of: stmtNode)
            let labelTok = TokenId(gotoTok.rawIndex + 1)
            if Int(labelTok.rawIndex) < tokens.count, CTokenKind(rawValue: tokens.kind(of: labelTok)) == .identifier {
                pendingGotos.append((spelling(of: labelTok, in: tokens), labelTok))
            }
            for child in tree.children(of: stmtNode) {
                _ = analyzeExpression(child, tree: tree, tokens: tokens)  // `goto *expr` (GNU computed goto)
            }

        case .breakStmt:
            if loopDepth == 0 && switchStack.isEmpty {
                reportError("'break' statement not in loop or switch statement", diagId: .semaJumpOutsideLoop, at: tree.token(of: stmtNode), in: tokens, args: ["break", "loop or switch statement"])
            }

        case .continueStmt:
            if loopDepth == 0 {
                reportError("'continue' statement not in loop statement", diagId: .semaJumpOutsideLoop, at: tree.token(of: stmtNode), in: tokens, args: ["continue", "loop statement"])
            }

        case .varDecl:
            let children = tree.children(of: stmtNode)
            guard let typeNode = children.first else { return }
            var varType = resolveType(from: typeNode, tree: tree, tokens: tokens)
            let baseType = unwrapBaseType(varType)
            let nameTok = tree.token(of: stmtNode)
            let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
            if tokKind == .semicolon || tokKind == .colon {
                return
            }
            let name = spelling(of: nameTok, in: tokens)
            let typeWord = tree.kind(of: typeNode) == .typeSpec ? spelling(of: tree.token(of: typeNode), in: tokens) : ""
            let isAuto = typeWord == "auto" || typeWord == "__auto_type"  // C23 `auto` / GNU `__auto_type`
            if declaratorSuffix(after: nameTok, tokens: tokens).parenthesized { varType = parenthesizedDeclaratorType(nameTok: nameTok, tokens: tokens) }
            varType = applyObjectConst(varType, typeNode: typeNode, tree: tree, tokens: tokens)
            let isExtern = declarationHasStorageClass(.kwExtern, typeNode: typeNode, tree: tree, tokens: tokens)
            let isStatic = declarationHasStorageClass(.kwStatic, typeNode: typeNode, tree: tree, tokens: tokens)
            if !isExtern {
                checkBlockScopeRedefinition(name, at: nameTok, tokens: tokens)
                if typePool.canonical(of: varType.typeId) == .void {
                    reportError("variable has incomplete type 'void'", diagId: .semaIncompleteType, at: nameTok, in: tokens, args: ["void"])
                }
            }

            // Pre-insert symbol if not `auto` so `int *p = malloc(sizeof *p)` resolves `p` in its own initializer
            if !isAuto {
                let preSym = CSymbol(name: name, declId: .nilId, type: varType, storage: .local(offset: 0))
                currentScope.insertOrdinary(symbol: preSym)
            }

            var primaryInitInst: SemInstId? = nil
            if children.count > 1 && tree.kind(of: children[1]) != .fieldDecl {
                let initInst = analyzeExpression(children[1], tree: tree, tokens: tokens)
                primaryInitInst = initInst
                if isStatic && !isConstantInitializer(children[1], tree: tree, tokens: tokens) {
                    reportError("initializer element is not a compile-time constant", diagId: .semaConstantExprNotConstant, at: tree.token(of: children[1]), in: tokens)
                }
                if !isAuto && tree.kind(of: children[1]) != .initList {
                    checkAssignment(to: varType, from: initInst, rhsNode: children[1], tree: tree, tokens: tokens)
                }
                if isAuto, let container = currentBlockContainer {
                    let inferred = container.block.type(of: initInst)
                    if inferred.typeId.isValid {
                        varType = inferred
                    }
                }
            }

            let sz = max(8, typePool.size(of: varType.typeId))
            currentStackOffset += Int32((sz + 7) & ~7)
            let offset = -currentStackOffset

            let declId = declTable.append(
                kind: .variable,
                name: name,
                type: varType,
                origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
            )
            let sym = CSymbol(name: name, declId: declId, type: varType, storage: .local(offset: offset))
            currentScope.insertOrdinary(symbol: sym)
            symbolRefs[stmtNode] = sym
            nodeTypes[stmtNode] = varType.typeId

            if let initInst = primaryInitInst, let container = currentBlockContainer {
                let lhsInst = container.block.append(kind: .declRef, type: varType, arg0: declId.rawIndex, node: stmtNode)
                _ = container.block.append(kind: .assign, type: varType, arg0: lhsInst.rawIndex, arg1: initInst.rawIndex, node: stmtNode)
            }

            for extraChild in children.dropFirst() where tree.kind(of: extraChild) == .fieldDecl {
                let extraTok = tree.token(of: extraChild)
                let extraName = spelling(of: extraTok, in: tokens)
                var (extraType, initNodes) = resolveExtraDeclaratorType(baseType: baseType, extraFieldNode: extraChild, tree: tree, tokens: tokens)
                if declaratorSuffix(after: extraTok, tokens: tokens).parenthesized {
                    extraType = parenthesizedDeclaratorType(nameTok: extraTok, tokens: tokens)
                }
                if !extraName.isEmpty {
                    if !isExtern { checkBlockScopeRedefinition(extraName, at: extraTok, tokens: tokens) }
                    let extraSz = max(8, typePool.size(of: extraType.typeId))
                    currentStackOffset += Int32((extraSz + 7) & ~7)
                    let extraOff = -currentStackOffset
                    let extraDeclId = declTable.append(
                        kind: .variable,
                        name: extraName,
                        type: extraType,
                        origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: extraTok))
                    )
                    let extraSym = CSymbol(name: extraName, declId: extraDeclId, type: extraType, storage: .local(offset: extraOff))
                    currentScope.insertOrdinary(symbol: extraSym)
                    for initChild in initNodes {
                        _ = analyzeExpression(initChild, tree: tree, tokens: tokens)
                    }
                }
            }

        case .returnStmt:
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                let retInst = analyzeExpression(expr, tree: tree, tokens: tokens)
                let retType = currentBlockContainer?.block.type(of: retInst) ?? currentReturnType
                if typePool.canonical(of: currentReturnType.typeId) == .void {
                    if isTyped(retInst) && typePool.canonical(of: retType.typeId) != .void {
                        reportError("void function '\(currentFunctionName)' should not return a value", diagId: .semaVoidReturnValue, at: tree.token(of: stmtNode), in: tokens, args: [currentFunctionName])
                    }
                } else {
                    checkAssignment(to: currentReturnType, from: retInst, rhsNode: expr, tree: tree, tokens: tokens)
                }
                nodeTypes[stmtNode] = retType.typeId
                currentBlockContainer?.block.append(kind: .returnInst, type: retType, arg0: retInst.rawIndex, node: stmtNode)
            } else {
                nodeTypes[stmtNode] = .void
                currentBlockContainer?.block.append(kind: .returnInst, type: .void, node: stmtNode)
            }

        case .ifStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            let condInst = analyzeExpression(children[0], tree: tree, tokens: tokens)
            checkScalarCondition(condInst, at: tree.token(of: stmtNode), tokens: tokens)
            currentBlockContainer?.block.append(kind: .branchCond, type: .void, arg0: condInst.rawIndex, node: stmtNode)
            analyzeStatement(children[1], tree: tree, tokens: tokens)
            if children.count >= 3 {
                analyzeStatement(children[2], tree: tree, tokens: tokens)
            }

        case .whileStmt, .doWhileStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            // `while (c) s` stores (c, s); `do s while (c)` stores (s, c)
            let (condNode, bodyNode) = kind == .whileStmt ? (children[0], children[1]) : (children[1], children[0])
            loopDepth += 1
            if kind == .doWhileStmt { analyzeStatement(bodyNode, tree: tree, tokens: tokens) }
            let condInst = analyzeExpression(condNode, tree: tree, tokens: tokens)
            checkScalarCondition(condInst, at: tree.token(of: stmtNode), tokens: tokens)
            currentBlockContainer?.block.append(kind: .branchCond, type: .void, arg0: condInst.rawIndex, node: stmtNode)
            if kind == .whileStmt { analyzeStatement(bodyNode, tree: tree, tokens: tokens) }
            loopDepth -= 1

        case .forStmt:
            let forScope = CScope(parent: currentScope)
            self.currentScope = forScope
            loopDepth += 1
            defer { loopDepth -= 1 }
            let children = tree.children(of: stmtNode)
            for child in children {
                let ck = tree.kind(of: child)
                if ck == .compoundStmt || ck == .varDecl || ck == .ifStmt || ck == .whileStmt ||
                   ck == .forStmt || ck == .doWhileStmt || ck == .switchStmt || ck == .returnStmt ||
                   ck == .exprStmt || ck == .breakStmt || ck == .continueStmt {
                    analyzeStatement(child, tree: tree, tokens: tokens)
                } else {
                    _ = analyzeExpression(child, tree: tree, tokens: tokens)
                }
            }
            self.currentScope = forScope.parent ?? CScope()

        case .switchStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            _ = analyzeExpression(children[0], tree: tree, tokens: tokens)
            switchStack.append((values: [], hasDefault: false))
            analyzeStatement(children[1], tree: tree, tokens: tokens)
            switchStack.removeLast()

        case .caseStmt:
            let children = tree.children(of: stmtNode)
            let caseTok = tree.token(of: stmtNode)
            if let valueNode = children.first {
                if switchStack.isEmpty {
                    reportError("'case' statement not in switch statement", diagId: .semaJumpOutsideLoop, at: caseTok, in: tokens, args: ["case", "switch statement"])
                } else if !isIntegerConstantExpression(valueNode, tree: tree, tokens: tokens) {
                    reportError("expression is not an integer constant expression", diagId: .semaConstantExprNotConstant, at: tree.token(of: valueNode), in: tokens)
                } else {
                    let v = evaluateIntegerConstant(valueNode, tree: tree, tokens: tokens)
                    if switchStack[switchStack.count - 1].values.insert(v).inserted == false {
                        reportError("duplicate case value '\(v)'", diagId: .semaDuplicateCase, at: tree.token(of: valueNode), in: tokens, args: ["case value '\(v)'"])
                    }
                }
            }
            for child in children.dropFirst() {
                analyzeStatement(child, tree: tree, tokens: tokens)
            }

        case .defaultStmt:
            let defaultTok = tree.token(of: stmtNode)
            if switchStack.isEmpty {
                reportError("'default' statement not in switch statement", diagId: .semaJumpOutsideLoop, at: defaultTok, in: tokens, args: ["default", "switch statement"])
            } else if switchStack[switchStack.count - 1].hasDefault {
                reportError("multiple default labels in one switch", diagId: .semaDuplicateCase, at: defaultTok, in: tokens, args: ["default label"])
            } else {
                switchStack[switchStack.count - 1].hasDefault = true
            }
            for child in tree.children(of: stmtNode) {
                analyzeStatement(child, tree: tree, tokens: tokens)
            }

        case .exprStmt:
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                _ = analyzeExpression(expr, tree: tree, tokens: tokens)
            }

        default:
            break
        }
    }

    // MARK: - Expressions

    private mutating func analyzeExpression(_ exprNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId {
        let kind = tree.kind(of: exprNode)
        guard let container = currentBlockContainer else {
            nodeTypes[exprNode] = .int
            return .nilId
        }

        switch kind {
        case .intLiteral, .charLiteral:
            let tok = tree.token(of: exprNode)
            let txt = spelling(of: tok, in: tokens)
            let val = (kind == .charLiteral) ? parseCharLiteral(txt) : parseIntegerLiteral(txt)
            let type: QualType = (val > Int64(Int32.max) || val < Int64(Int32.min)) ? .long : .int
            let res = container.block.appendIntLiteral(value: val, type: type, node: exprNode)
            nodeTypes[exprNode] = type.typeId
            return res

        case .floatLiteral:
            let tok = tree.token(of: exprNode)
            let txt = spelling(of: tok, in: tokens)
            let val = Double(txt.replacingOccurrences(of: "'", with: "")) ?? 0.0
            let res = container.block.appendFloatLiteral(value: val, type: .double, node: exprNode)
            nodeTypes[exprNode] = .double
            return res

        case .stringLiteral:
            let tok = tree.token(of: exprNode)
            let unescaped = CLiteral.unescapedString(CLiteral.body(of: spelling(of: tok, in: tokens), quote: "\""))
            if stringLiterals[unescaped] == nil {
                stringLiterals[unescaped] = stringCounter
                stringCounter += 1
            }
            let ptrChar = typePool.pointerTo(.char)
            let res = container.block.appendStringLiteral(value: unescaped, type: QualType(typeId: ptrChar), node: exprNode)
            nodeTypes[exprNode] = ptrChar
            return res

        case .nullptrLiteral:
            let res = container.block.append(kind: .nullptrLiteral, type: .nullptr, node: exprNode)
            nodeTypes[exprNode] = .nullptr
            return res

        case .boolLiteral:
            let tok = tree.token(of: exprNode)
            let txt = spelling(of: tok, in: tokens)
            let val: Int64 = (txt == "true") ? 1 : 0
            let res = container.block.appendIntLiteral(value: val, type: .bool, node: exprNode)
            nodeTypes[exprNode] = .bool
            return res

        case .identExpr:
            let tok = tree.token(of: exprNode)
            let name = spelling(of: tok, in: tokens)
            if let sym = currentScope.lookupOrdinary(name) {
                symbolRefs[exprNode] = sym
                nodeTypes[exprNode] = sym.type.typeId
                switch sym.storage {
                case .enumConstant(let val):
                    return container.block.appendIntLiteral(value: val, type: .int, node: exprNode)
                default:
                    return container.block.append(kind: .declRef, type: sym.type, arg0: sym.declId.rawIndex, node: exprNode)
                }
            } else if name.hasPrefix("__builtin_") || name.hasPrefix("__atomic_") || name.hasPrefix("__sync_") ||
                      name == "asm" || name == "__asm__" || name == "__asm" {
                let fnType = QualType(typeId: typePool.functionType(returnType: .long, paramTypes: [], isVariadic: true))
                let declId = declTable.append(kind: .function, name: name, type: fnType)
                let sym = CSymbol(name: name, declId: declId, type: fnType, storage: .function(name: name))
                currentScope.insertOrdinary(symbol: sym)
                symbolRefs[exprNode] = sym
                nodeTypes[exprNode] = fnType.typeId
                return container.block.append(kind: .declRef, type: fnType, arg0: declId.rawIndex, node: exprNode)
            } else if name == "__func__" || name == "__FUNCTION__" || name == "__PRETTY_FUNCTION__" {
                let ptrChar = typePool.pointerTo(.char)
                let res = container.block.appendStringLiteral(value: name, type: QualType(typeId: ptrChar), node: exprNode)
                nodeTypes[exprNode] = ptrChar
                return res
            } else {
                reportError("use of undeclared identifier '\(name)'", diagId: .semaUndeclaredIdentifier, at: tok, in: tokens, args: [name])
                nodeTypes[exprNode] = .int
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }

        case .memberExpr:
            let children = tree.children(of: exprNode)
            guard children.count >= 1 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let baseNode = children[0]
            let baseInst = analyzeExpression(baseNode, tree: tree, tokens: tokens)
            var baseType = container.block.type(of: baseInst)

            let opTok = tree.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken
            if opKind == .arrow {
                baseType = typePool.pointeeType(of: baseType.typeId)
            }

            let memberTok = (children.count > 1) ? tree.token(of: children[1]) : opTok
            let memberName = spelling(of: memberTok, in: tokens)

            if let field = typePool.lookupStructField(named: memberName, in: baseType.typeId) {
                nodeTypes[exprNode] = field.type.typeId
                return container.block.append(kind: .memberRef, type: field.type, arg0: baseInst.rawIndex, arg1: field.offset, node: exprNode)
            } else {
                reportError("no member named '\(memberName)' in struct", diagId: .semaInvalidMember, at: memberTok, in: tokens, args: [memberName, "struct"])
                nodeTypes[exprNode] = .int
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }

        case .assignExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let lhs = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let rhs = analyzeExpression(children[1], tree: tree, tokens: tokens)
            let lhsType = container.block.type(of: lhs)
            let assignTok = tree.token(of: exprNode)
            // C23 6.5.16p2: the left operand shall be a modifiable lvalue
            if !isLvalue(children[0], tree: tree, tokens: tokens) {
                reportError("expression is not assignable", diagId: .semaNotAssignable, at: assignTok, in: tokens, args: [""])
            } else if isTyped(lhs) && (isArrayOrFunction(lhsType) || lhsType.isConst) {
                reportError("expression is not assignable", diagId: .semaNotAssignable, at: assignTok, in: tokens, args: [lhsType.isConst ? " (const-qualified)" : ""])
            } else if CTokenKind(rawValue: tokens.kind(of: assignTok)) == .equal {
                checkAssignment(to: lhsType, from: rhs, rhsNode: children[1], tree: tree, tokens: tokens)
            } else if isTyped(lhs) && isTyped(rhs) && (isStructOrUnion(lhsType) || isStructOrUnion(typeOf(rhs))) {
                reportError("invalid operands to compound assignment", diagId: .semaInvalidOperands, at: assignTok, in: tokens, args: [spelling(of: assignTok, in: tokens), "\(lhsType)", "\(typeOf(rhs))"])
            }
            nodeTypes[exprNode] = lhsType.typeId
            return container.block.append(kind: .assign, type: lhsType, arg0: lhs.rawIndex, arg1: rhs.rawIndex, node: exprNode)

        case .binaryExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let lhs = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let rhs = analyzeExpression(children[1], tree: tree, tokens: tokens)
            let lhsType = container.block.type(of: lhs)
            let rhsType = container.block.type(of: rhs)

            let opTok = tree.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken
            if isTyped(lhs) && isTyped(rhs) && !binaryOperandsValid(opKind, lhsType, rhsType) {
                reportError("invalid operands to binary expression", diagId: .semaInvalidOperands, at: opTok, in: tokens, args: [spelling(of: opTok, in: tokens), "\(lhsType)", "\(rhsType)"])
            }

            var resType: QualType
            let semKind: SemInstKind

            switch opKind {
            case .plus:
                semKind = .add
                if isPointerLike(lhsType) {
                    resType = decayed(lhsType)
                } else if isPointerLike(rhsType) {
                    resType = decayed(rhsType)
                } else {
                    resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
                }
            case .minus:
                semKind = .sub
                if isPointerLike(lhsType) && isPointerLike(rhsType) {
                    resType = .long // ptrdiff_t
                } else if isPointerLike(lhsType) {
                    resType = decayed(lhsType)
                } else {
                    resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
                }
            case .star: semKind = .mul; resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            case .slash: semKind = .div; resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            case .percent: semKind = .mod; resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            case .amp: semKind = .bitAnd; resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            case .pipe: semKind = .bitOr; resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            case .caret: semKind = .bitXor; resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            case .lessLess: semKind = .shl; resType = lhsType
            case .greaterGreater: semKind = .shr; resType = lhsType
            case .equalEqual: semKind = .eq; resType = .int
            case .exclaimEqual: semKind = .ne; resType = .int
            case .less: semKind = .lt; resType = .int
            case .lessEqual: semKind = .le; resType = .int
            case .greater: semKind = .gt; resType = .int
            case .greaterEqual: semKind = .ge; resType = .int
            case .ampAmp: semKind = .logicalAnd; resType = .int
            case .pipePipe: semKind = .logicalOr; resType = .int
            default: semKind = .add; resType = .int
            }

            // An operand of unmodeled type makes the arithmetic result unmodeled too (comparisons stay `int`)
            let isComparisonOrLogical = [.equalEqual, .exclaimEqual, .less, .lessEqual, .greater, .greaterEqual, .ampAmp, .pipePipe].contains(opKind)
            if !isComparisonOrLogical && (!isTyped(lhs) || !isTyped(rhs)) {
                resType = .error
            }
            nodeTypes[exprNode] = resType.typeId
            return container.block.append(kind: semKind, type: resType, arg0: lhs.rawIndex, arg1: rhs.rawIndex, node: exprNode)

        case .unaryExpr:
            let children = tree.children(of: exprNode)
            guard let child = children.first else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let opTok = tree.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken

            if opKind == .kwSizeof {
                let targetType: QualType
                if isTypeNode(tree.kind(of: child)) {
                    targetType = resolveType(from: child, tree: tree, tokens: tokens)
                } else {
                    let inner = analyzeExpression(child, tree: tree, tokens: tokens)
                    targetType = container.block.type(of: inner)
                }
                let sz = typePool.size(of: targetType.typeId)
                nodeTypes[exprNode] = .ulong
                return container.block.appendIntLiteral(value: Int64(sz), type: QualType(typeId: .ulong), node: exprNode)
            }
            if opKind == .kwAlignof {
                let targetType: QualType
                if isTypeNode(tree.kind(of: child)) {
                    targetType = resolveType(from: child, tree: tree, tokens: tokens)
                } else {
                    let inner = analyzeExpression(child, tree: tree, tokens: tokens)
                    targetType = container.block.type(of: inner)
                }
                let al = typePool.alignment(of: targetType.typeId)
                nodeTypes[exprNode] = .ulong
                return container.block.appendIntLiteral(value: Int64(al), type: QualType(typeId: .ulong), node: exprNode)
            }
            if opKind == .ampAmp {
                let voidPtr = QualType(typeId: typePool.pointerTo(.void))
                nodeTypes[exprNode] = voidPtr.typeId
                return container.block.append(kind: .addrOf, type: voidPtr, node: exprNode)
            }

            let inner = analyzeExpression(child, tree: tree, tokens: tokens)
            let innerType = container.block.type(of: inner)
            checkUnaryOperand(opKind, operandNode: child, operand: inner, at: opTok, tree: tree, tokens: tokens)

            let resType: QualType
            let semKind: SemInstKind

            switch opKind {
            case .minus: semKind = .unaryNeg; resType = innerType
            case .tilde: semKind = .unaryBitNot; resType = innerType
            case .exclaim: semKind = .unaryLogicalNot; resType = .int
            case .amp:
                semKind = .addrOf
                resType = QualType(typeId: typePool.pointerTo(innerType))
            case .star:
                semKind = .deref
                resType = typePool.pointeeType(of: innerType.typeId)
            case .plusPlus: semKind = .postInc; resType = innerType
            case .minusMinus: semKind = .postDec; resType = innerType
            default: semKind = .unaryNeg; resType = innerType
            }

            nodeTypes[exprNode] = resType.typeId
            return container.block.append(kind: semKind, type: resType, arg0: inner.rawIndex, node: exprNode)

        case .castExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            var targetType = resolveType(from: children[0], tree: tree, tokens: tokens)
            let inner = analyzeExpression(children[1], tree: tree, tokens: tokens)
            // `(void (*)(void))fn`: abstract declarators with parentheses are not modeled
            if typeNameHasParenthesizedDeclarator(castTok: tree.token(of: exprNode), tokens: tokens) {
                targetType = QualType(typeId: typePool.pointerTo(.error))
            }
            nodeTypes[exprNode] = targetType.typeId
            return container.block.append(kind: .explicitCast, type: targetType, arg0: inner.rawIndex, node: exprNode)

        case .callExpr:
            let children = tree.children(of: exprNode)
            guard children.count >= 1 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let calleeNode = children[0]
            let callee = analyzeExpression(calleeNode, tree: tree, tokens: tokens)
            let calleeType = container.block.type(of: callee)

            var retType: QualType = .int
            var calleeInfo = typePool.typeInfo(of: typePool.canonical(of: calleeType.typeId))
            if case .pointer(let pointee) = calleeInfo.kind {
                calleeInfo = typePool.typeInfo(of: typePool.canonical(of: pointee.typeId))
            }
            var calleeParamCount: Int? = nil
            var calleeVariadic = true
            if case .function(let rType, let pTypes, let variadic) = calleeInfo.kind {
                retType = rType
                calleeParamCount = pTypes.count
                calleeVariadic = variadic
            } else if case .error = calleeInfo.kind {
                // Callee type not modeled (e.g. a function pointer from a parenthesized declarator)
                retType = .error
            } else if !isTyped(callee) {
                retType = .error
            } else {
                reportError("called object is not a function or function pointer", diagId: .semaNotCallable, at: tree.token(of: exprNode), in: tokens, args: ["\(calleeType)"])
            }

            let calleeName = (tree.kind(of: calleeNode) == .identExpr) ? spelling(of: tree.token(of: calleeNode), in: tokens) : ""
            let isOffsetof = (calleeName == "__builtin_offsetof")

            var argInsts: [SemInstId] = []
            if children.count > 1 {
                let argNodes = tree.children(of: children[1])
                for (argIdx, arg) in argNodes.enumerated() {
                    if isTypeNode(tree.kind(of: arg)) {
                        let t = resolveType(from: arg, tree: tree, tokens: tokens)
                        if calleeName == "__builtin_va_arg" && argIdx == 1 {
                            retType = t
                        }
                    } else if isOffsetof && argIdx == 1 {
                        // Second argument of __builtin_offsetof(type, member) is a member designator, not a variable
                        continue
                    } else {
                        argInsts.append(analyzeExpression(arg, tree: tree, tokens: tokens))
                    }
                }
            }

            // Argument count against the prototype (C23 6.5.2.2p2), for calls of declared functions
            if let paramCount = calleeParamCount, let sym = symbolRefs[calleeNode], case .function = sym.storage,
               !calleeName.hasPrefix("__builtin_"), !builtinNames.contains(calleeName) {
                let argCount = children.count > 1 ? tree.children(of: children[1]).count : 0
                if argCount < paramCount || (argCount > paramCount && !calleeVariadic) {
                    reportError("wrong number of arguments to function call", diagId: .semaCallArgCountMismatch, at: tree.token(of: exprNode), in: tokens,
                                args: [argCount < paramCount ? "few" : "many", "\(paramCount)", "\(argCount)"])
                }
            }

            nodeTypes[exprNode] = retType.typeId
            return container.block.appendCall(callee: callee, args: argInsts, type: retType, node: exprNode)

        case .subscriptExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let base = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let idx = analyzeExpression(children[1], tree: tree, tokens: tokens)
            let baseType = container.block.type(of: base)
            if isTyped(base) && isTyped(idx) {
                let idxType = typeOf(idx)
                let ok = (isPointerLike(baseType) && typePool.isInteger(type: idxType.typeId))
                    || (isPointerLike(idxType) && typePool.isInteger(type: baseType.typeId))
                if !ok {
                    reportError("subscripted value is not an array or pointer", diagId: .semaInvalidSubscript, at: tree.token(of: exprNode), in: tokens)
                }
            }
            // `i[p]` is `p[i]`: the element type comes from whichever operand is the pointer
            let pointerType = (!isPointerLike(baseType) && isTyped(idx) && isPointerLike(typeOf(idx))) ? typeOf(idx) : baseType
            let pointee = typePool.pointeeType(of: pointerType.typeId)
            nodeTypes[exprNode] = pointee.typeId
            return container.block.append(kind: .subscriptOp, type: pointee, arg0: base.rawIndex, arg1: idx.rawIndex, node: exprNode)

        case .conditionalExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 3 || children.count == 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let cond = analyzeExpression(children[0], tree: tree, tokens: tokens)
            // GNU `a ?: b` has no middle operand; its value is the condition
            let thenInst = children.count == 3 ? analyzeExpression(children[1], tree: tree, tokens: tokens) : cond
            let elseInst = analyzeExpression(children[children.count - 1], tree: tree, tokens: tokens)
            var thenType = container.block.type(of: thenInst)
            // C23 6.5.15p6: with a pointer and a null pointer constant the result is the pointer type
            if !isPointerLike(thenType) && isTyped(elseInst) && isPointerLike(typeOf(elseInst)) {
                thenType = typeOf(elseInst)
            }
            if !isTyped(thenInst) || !isTyped(elseInst) { thenType = .error }
            checkScalarCondition(cond, at: tree.token(of: exprNode), tokens: tokens)
            if isTyped(thenInst) && isTyped(elseInst) {
                let elseType = typeOf(elseInst)
                let thenStruct = isStructOrUnion(thenType), elseStruct = isStructOrUnion(elseType)
                if (thenStruct || elseStruct) && !(thenStruct && elseStruct && typesCompatible(thenType.unqualified(), elseType.unqualified())) {
                    reportError("incompatible operand types in conditional expression", diagId: .semaTypeMismatch, at: tree.token(of: exprNode), in: tokens, args: ["\(thenType)", "\(elseType)"])
                }
            }
            nodeTypes[exprNode] = thenType.typeId
            return container.block.append(kind: .conditional, type: thenType, arg0: cond.rawIndex, arg1: thenInst.rawIndex, node: exprNode)

        case .genericExpr:
            let children = tree.children(of: exprNode)
            guard children.count >= 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let ctrlInst = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let ctrlType = container.block.type(of: ctrlInst).unqualified()
            let ctrlCan = typePool.canonical(of: ctrlType.typeId)

            var selectedNode: NodeId? = nil
            var defaultNode: NodeId? = nil

            var i = 1
            while i < children.count {
                let assoc = children[i]
                let aChildren = tree.children(of: assoc)
                if aChildren.count >= 2 {
                    let aType = resolveType(from: aChildren[0], tree: tree, tokens: tokens).unqualified()
                    let aCan = typePool.canonical(of: aType.typeId)
                    if (aType.typeId == ctrlType.typeId || aCan == ctrlCan) && selectedNode == nil {
                        selectedNode = aChildren[1]
                    }
                } else if aChildren.count == 1 {
                    defaultNode = aChildren[0]
                }
                i += 1
            }

            guard let chosen = selectedNode ?? defaultNode else {
                // Association matching is approximate (no lvalue/array conversions yet): leave untyped
                nodeTypes[exprNode] = .int
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let chosenInst = analyzeExpression(chosen, tree: tree, tokens: tokens)
            let chosenType = container.block.type(of: chosenInst)
            nodeTypes[exprNode] = chosenType.typeId
            return chosenInst

        case .commaExpr:
            let children = tree.children(of: exprNode)
            guard !children.isEmpty else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            var lastInst: SemInstId = .nilId
            for child in children {
                lastInst = analyzeExpression(child, tree: tree, tokens: tokens)
            }
            let lastType = container.block.type(of: lastInst)
            nodeTypes[exprNode] = lastType.typeId
            return lastInst

        case .compoundStmt:
            // GNU statement expression `({ ... })`; its value type is not modeled
            analyzeStatement(exprNode, tree: tree, tokens: tokens)
            nodeTypes[exprNode] = .int
            return container.block.append(kind: .errorInst, type: .int, node: exprNode)

        case .compoundLiteralExpr:
            let children = tree.children(of: exprNode)
            for child in children where !isTypeNode(tree.kind(of: child)) {
                _ = analyzeExpression(child, tree: tree, tokens: tokens)
            }
            if let typeNode = children.first, isTypeNode(tree.kind(of: typeNode)) {
                let t = resolveType(from: typeNode, tree: tree, tokens: tokens)
                nodeTypes[exprNode] = t.typeId
                return container.block.append(kind: .explicitCast, type: t, node: exprNode)
            }
            nodeTypes[exprNode] = .int
            return container.block.append(kind: .errorInst, type: .int, node: exprNode)

        default:
            // Constructs whose type sema does not model yet: analyze operands, and mark the result untyped
            // (`errorInst`) so that constraint checks skip it instead of assuming `int`.
            for child in tree.children(of: exprNode) where !isTypeNode(tree.kind(of: child)) {
                _ = analyzeExpression(child, tree: tree, tokens: tokens)
            }
            nodeTypes[exprNode] = .int
            return container.block.append(kind: .errorInst, type: .int, node: exprNode)
        }
    }

    /// Operand constraints of binary operators (C23 6.5.5-6.5.14).
    private func binaryOperandsValid(_ op: CTokenKind, _ l: QualType, _ r: QualType) -> Bool {
        let lInt = typePool.isInteger(type: l.typeId), rInt = typePool.isInteger(type: r.typeId)
        let lArith = typePool.isArithmetic(type: l.typeId), rArith = typePool.isArithmetic(type: r.typeId)
        let lPtr = isPointerLike(l), rPtr = isPointerLike(r)
        let lStruct = isStructOrUnion(l), rStruct = isStructOrUnion(r)
        switch op {
        case .percent, .lessLess, .greaterGreater, .amp, .pipe, .caret:
            return lInt && rInt
        case .star, .slash:
            return lArith && rArith
        case .plus:
            return (lArith && rArith) || (lPtr && rInt) || (lInt && rPtr)
        case .minus:
            return (lArith && rArith) || (lPtr && rInt) || (lPtr && rPtr)
        case .less, .lessEqual, .greater, .greaterEqual, .equalEqual, .exclaimEqual, .ampAmp, .pipePipe:
            return !lStruct && !rStruct
        default:
            return true
        }
    }

    /// Operand constraints of unary operators (C23 6.5.3).
    private mutating func checkUnaryOperand(_ op: CTokenKind, operandNode: NodeId, operand: SemInstId, at tok: TokenId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let t = typeOf(operand)
        switch op {
        case .amp:
            let isFunctionDesignator = symbolRefs[operandNode].map { if case .function = $0.storage { return true } else { return false } } ?? false
            if !isFunctionDesignator && !isLvalue(operandNode, tree: tree, tokens: tokens) {
                reportError("cannot take the address of an rvalue", diagId: .semaAddressOfRvalue, at: tok, in: tokens)
            }
        case .plusPlus, .minusMinus:
            if !isLvalue(operandNode, tree: tree, tokens: tokens) || (isTyped(operand) && (isArrayOrFunction(t) || t.isConst || isStructOrUnion(t))) {
                reportError("expression is not assignable", diagId: .semaNotAssignable, at: tok, in: tokens, args: [""])
            }
        case .star:
            if isTyped(operand) && !isPointerLike(t) {
                reportError("indirection requires pointer operand", diagId: .semaIndirectionNonPointer, at: tok, in: tokens)
            }
        case .minus, .plus:
            if isTyped(operand) && !typePool.isArithmetic(type: t.typeId) {
                reportError("invalid argument type to unary expression", diagId: .semaInvalidOperands, at: tok, in: tokens, args: [spelling(of: tok, in: tokens), "\(t)", ""])
            }
        case .tilde:
            if isTyped(operand) && !typePool.isInteger(type: t.typeId) {
                reportError("invalid argument type to unary expression", diagId: .semaInvalidOperands, at: tok, in: tokens, args: ["~", "\(t)", ""])
            }
        case .exclaim:
            if isTyped(operand) && isStructOrUnion(t) {
                reportError("invalid argument type to unary expression", diagId: .semaInvalidOperands, at: tok, in: tokens, args: ["!", "\(t)", ""])
            }
        default:
            break
        }
    }

    // MARK: - Constant Evaluation

    public mutating func evaluateIntegerConstant(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Int64 {
        let kind = tree.kind(of: node)
        switch kind {
        case .callExpr:
            // `offsetof(T, m)` expands to `__builtin_offsetof(T, member-designator)`
            let children = tree.children(of: node)
            guard let callee = children.first, tree.kind(of: callee) == .identExpr,
                  spelling(of: tree.token(of: callee), in: tokens) == "__builtin_offsetof",
                  children.count > 1 else { return 0 }
            let args = tree.children(of: children[1])
            guard args.count == 2, isTypeNode(tree.kind(of: args[0])) else { return 0 }
            let base = resolveType(from: args[0], tree: tree, tokens: tokens)
            return memberOffset(of: args[1], in: base, tree: tree, tokens: tokens)?.offset ?? 0
        case .commaExpr:
            let children = tree.children(of: node)
            guard let last = children.last else { return 0 }
            return evaluateIntegerConstant(last, tree: tree, tokens: tokens)
        case .intLiteral:
            let tok = tree.token(of: node)
            return parseIntegerLiteral(spelling(of: tok, in: tokens))

        case .charLiteral:
            let tok = tree.token(of: node)
            return parseCharLiteral(spelling(of: tok, in: tokens))

        case .boolLiteral:
            let tok = tree.token(of: node)
            return (spelling(of: tok, in: tokens) == "true") ? 1 : 0

        case .identExpr:
            let tok = tree.token(of: node)
            let name = spelling(of: tok, in: tokens)
            if let sym = currentScope.lookupOrdinary(name), case .enumConstant(let val) = sym.storage {
                return val
            }
            return 0

        case .castExpr:
            let children = tree.children(of: node)
            if children.count == 2 {
                return evaluateIntegerConstant(children[1], tree: tree, tokens: tokens)
            }
            return 0

        case .conditionalExpr:
            let children = tree.children(of: node)
            if children.count == 3 {
                let c = evaluateIntegerConstant(children[0], tree: tree, tokens: tokens)
                return evaluateIntegerConstant(c != 0 ? children[1] : children[2], tree: tree, tokens: tokens)
            } else if children.count == 2 {
                let c = evaluateIntegerConstant(children[0], tree: tree, tokens: tokens)
                return c != 0 ? c : evaluateIntegerConstant(children[1], tree: tree, tokens: tokens)
            }
            return 0

        case .unaryExpr:
            let children = tree.children(of: node)
            guard let child = children.first else { return 0 }
            let opTok = tree.token(of: node)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken
            if opKind == .kwSizeof {
                let t = resolveType(from: child, tree: tree, tokens: tokens)
                return Int64(typePool.size(of: t.typeId))
            }
            if opKind == .kwAlignof {
                let t = resolveType(from: child, tree: tree, tokens: tokens)
                return Int64(typePool.alignment(of: t.typeId))
            }
            let inner = evaluateIntegerConstant(child, tree: tree, tokens: tokens)
            switch opKind {
            case .minus: return -inner
            case .tilde: return ~inner
            case .exclaim: return (inner == 0) ? 1 : 0
            default: return inner
            }

        case .binaryExpr:
            let children = tree.children(of: node)
            guard children.count == 2 else { return 0 }
            let l = evaluateIntegerConstant(children[0], tree: tree, tokens: tokens)
            let r = evaluateIntegerConstant(children[1], tree: tree, tokens: tokens)
            let opTok = tree.token(of: node)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken
            switch opKind {
            case .plus: return l &+ r
            case .minus: return l &- r
            case .star: return l &* r
            case .slash: return (r != 0) ? (l / r) : 0
            case .percent: return (r != 0) ? (l % r) : 0
            case .amp: return l & r
            case .pipe: return l | r
            case .caret: return l ^ r
            case .lessLess: return l << r
            case .greaterGreater: return l >> r
            case .equalEqual: return (l == r) ? 1 : 0
            case .exclaimEqual: return (l != r) ? 1 : 0
            case .less: return (l < r) ? 1 : 0
            case .lessEqual: return (l <= r) ? 1 : 0
            case .greater: return (l > r) ? 1 : 0
            case .greaterEqual: return (l >= r) ? 1 : 0
            case .ampAmp: return (l != 0 && r != 0) ? 1 : 0
            case .pipePipe: return (l != 0 || r != 0) ? 1 : 0
            default: return 0
            }

        default:
            return 1
        }
    }

    private func parseCharLiteral(_ raw: String) -> Int64 {
        CLiteral.characterValue(raw)
    }

    private func parseIntegerLiteral(_ raw: String) -> Int64 {
        Int64(bitPattern: CLiteral.integerValue(raw)?.value ?? 0)
    }
}
