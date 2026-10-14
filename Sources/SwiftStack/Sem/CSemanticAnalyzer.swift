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

    private mutating func resolvePrimitiveOrTypedef(_ txt: String, at tok: TokenId, in tokens: borrowing TokenBuffer) -> QualType {
        switch txt {
        case "void": return .void
        case "bool", "_Bool": return .bool
        case "char": return .char
        case "signed char": return QualType(typeId: .schar)
        case "unsigned char", "uint8_t": return QualType(typeId: .uchar)
        case "short", "int16_t": return QualType(typeId: .short)
        case "unsigned short", "uint16_t": return QualType(typeId: .ushort)
        case "int", "int32_t", "signed", "__signed", "__signed__": return .int
        case "unsigned", "unsigned int", "uint32_t": return QualType(typeId: .uint)
        case "long", "int64_t", "ssize_t", "ptrdiff_t", "intptr_t": return .long
        case "unsigned long", "uint64_t", "size_t", "uintptr_t": return QualType(typeId: .ulong)
        case "long long": return QualType(typeId: .longlong)
        case "unsigned long long": return QualType(typeId: .ulonglong)
        case "float", "_Float16", "_Float32": return .float
        case "double", "_Float64", "_Float32x": return .double
        case "long double", "__float128", "_Float128", "_Float64x": return QualType(typeId: .longdouble)
        case "nullptr_t": return .nullptr
        default:
            if let sym = currentScope.lookupOrdinary(txt), case .typedef = sym.storage {
                return sym.type
            }
            if let tagType = currentScope.lookupTag(txt) {
                return QualType(typeId: tagType)
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

        let paramListNode = children[1]
        let paramNodes = tree.children(of: paramListNode)

        var paramNames: [String] = []
        var paramTypes: [QualType] = []

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

        let fnTypeId = typePool.functionType(returnType: returnType, paramTypes: paramTypes)
        let fnQualType = QualType(typeId: fnTypeId)

        let fnDeclId = declTable.append(
            kind: .function,
            name: fnName,
            type: fnQualType,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: fnTok))
        )

        currentScope.insertOrdinary(symbol: CSymbol(name: fnName, declId: fnDeclId, type: fnQualType, storage: .function(name: fnName)))

        // If function has body (definition)
        if children.count >= 3 {
            let bodyNode = children[2]
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
        let varType = resolveType(from: typeNode, tree: tree, tokens: tokens)
        let baseType = unwrapBaseType(varType)
        let nameTok = tree.token(of: varNode)
        let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
        if tokKind == .semicolon || tokKind == .colon {
            return
        }
        let name = spelling(of: nameTok, in: tokens)

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
        let underlyingType = resolveType(from: typeNode, tree: tree, tokens: tokens)
        let nameTok = tree.token(of: typedefNode)
        let name = spelling(of: nameTok, in: tokens)

        let typedefTypeId = typePool.typedefType(name: name, underlying: underlyingType)
        let typedefQualType = QualType(typeId: typedefTypeId)

        let declId = declTable.append(
            kind: .typedefDecl,
            name: name,
            type: typedefQualType,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
        )
        currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: typedefQualType, storage: .typedef))
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
                    let fType = resolveType(from: fTypeNode, tree: tree, tokens: tokens)
                    let fBaseType = unwrapBaseType(fType)
                    let fTok = tree.token(of: child)
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
            reportError("static_assert failed", diagId: .semaConstantExprNotConstant, at: tok, in: tokens)
        }
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
            for child in tree.children(of: stmtNode) {
                analyzeStatement(child, tree: tree, tokens: tokens)
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
            let isAuto = (tree.kind(of: typeNode) == .typeSpec && spelling(of: tree.token(of: typeNode), in: tokens) == "auto")

            // Pre-insert symbol if not `auto` so `int *p = malloc(sizeof *p)` resolves `p` in its own initializer
            if !isAuto {
                let preSym = CSymbol(name: name, declId: .nilId, type: varType, storage: .local(offset: 0))
                currentScope.insertOrdinary(symbol: preSym)
            }

            var primaryInitInst: SemInstId? = nil
            if children.count > 1 && tree.kind(of: children[1]) != .fieldDecl {
                let initInst = analyzeExpression(children[1], tree: tree, tokens: tokens)
                primaryInitInst = initInst
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
                let (extraType, initNodes) = resolveExtraDeclaratorType(baseType: baseType, extraFieldNode: extraChild, tree: tree, tokens: tokens)
                if !extraName.isEmpty {
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
            currentBlockContainer?.block.append(kind: .branchCond, type: .void, arg0: condInst.rawIndex, node: stmtNode)
            analyzeStatement(children[1], tree: tree, tokens: tokens)
            if children.count >= 3 {
                analyzeStatement(children[2], tree: tree, tokens: tokens)
            }

        case .whileStmt, .doWhileStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            let condInst = analyzeExpression(children[0], tree: tree, tokens: tokens)
            currentBlockContainer?.block.append(kind: .branchCond, type: .void, arg0: condInst.rawIndex, node: stmtNode)
            analyzeStatement(children[1], tree: tree, tokens: tokens)

        case .forStmt:
            let forScope = CScope(parent: currentScope)
            self.currentScope = forScope
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
            analyzeStatement(children[1], tree: tree, tokens: tokens)

        case .caseStmt, .defaultStmt:
            let children = tree.children(of: stmtNode)
            for child in children {
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
            var raw = spelling(of: tok, in: tokens)
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            let unescaped = unescapeString(raw)
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

            let resType: QualType
            let semKind: SemInstKind

            switch opKind {
            case .plus:
                semKind = .add
                if typePool.isPointer(type: lhsType.typeId) {
                    resType = lhsType
                } else if typePool.isPointer(type: rhsType.typeId) {
                    resType = rhsType
                } else {
                    resType = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
                }
            case .minus:
                semKind = .sub
                if typePool.isPointer(type: lhsType.typeId) && typePool.isPointer(type: rhsType.typeId) {
                    resType = .long // ptrdiff_t
                } else if typePool.isPointer(type: lhsType.typeId) {
                    resType = lhsType
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
            let targetType = resolveType(from: children[0], tree: tree, tokens: tokens)
            let inner = analyzeExpression(children[1], tree: tree, tokens: tokens)
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
            let calleeInfo = typePool.typeInfo(of: typePool.canonical(of: calleeType.typeId))
            if case .function(let rType, _, _) = calleeInfo.kind {
                retType = rType
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
            let pointee = typePool.pointeeType(of: baseType.typeId)
            nodeTypes[exprNode] = pointee.typeId
            return container.block.append(kind: .subscriptOp, type: pointee, arg0: base.rawIndex, arg1: idx.rawIndex, node: exprNode)

        case .conditionalExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 3 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let cond = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let thenInst = analyzeExpression(children[1], tree: tree, tokens: tokens)
            _ = analyzeExpression(children[2], tree: tree, tokens: tokens)
            let thenType = container.block.type(of: thenInst)
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

            let chosen = selectedNode ?? defaultNode ?? children[0]
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

        default:
            nodeTypes[exprNode] = .int
            return container.block.append(kind: .intLiteral, type: .int, node: exprNode)
        }
    }

    // MARK: - Constant Evaluation

    public mutating func evaluateIntegerConstant(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Int64 {
        let kind = tree.kind(of: node)
        switch kind {
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
        var inner = raw
        if let firstQuote = inner.firstIndex(of: "'"), let lastQuote = inner.lastIndex(of: "'"), firstQuote < lastQuote {
            inner = String(inner[inner.index(after: firstQuote)..<lastQuote])
        }
        let unesc = unescapeString(inner)
        if let b = unesc.utf8.first {
            return Int64(b)
        }
        return 0
    }

    private func parseIntegerLiteral(_ raw: String) -> Int64 {
        var clean = raw.replacingOccurrences(of: "'", with: "")
        while clean.hasSuffix("u") || clean.hasSuffix("U") || clean.hasSuffix("l") || clean.hasSuffix("L") ||
              clean.hasSuffix("z") || clean.hasSuffix("Z") {
            clean.removeLast()
        }
        if clean.hasPrefix("0x") || clean.hasPrefix("0X") {
            if let v = UInt64(clean.dropFirst(2), radix: 16) { return Int64(bitPattern: v) }
            return 0
        }
        if clean.hasPrefix("0b") || clean.hasPrefix("0B") {
            if let v = UInt64(clean.dropFirst(2), radix: 2) { return Int64(bitPattern: v) }
            return 0
        }
        if clean.hasPrefix("0") && clean.count > 1 {
            if let v = UInt64(clean.dropFirst(1), radix: 8) { return Int64(bitPattern: v) }
            return 0
        }
        if let v = Int64(clean, radix: 10) { return v }
        if let uv = UInt64(clean, radix: 10) { return Int64(bitPattern: uv) }
        return 0
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
