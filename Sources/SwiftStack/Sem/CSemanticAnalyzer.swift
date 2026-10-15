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
extension DiagId {
    public static let semaInvalidDeclaration    = DiagId(74)
    public static let semaInvalidBitField       = DiagId(75)
    public static let semaInvalidExpression     = DiagId(76)
}

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
    /// Instructions of expressions outside function bodies (initializers, `typeof`, `sizeof` operands), so that
    /// they are typed and checked like any other; not part of the module's instruction blocks.
    private let fileScopeContainer = SemInstBlockContainer(block: SemInstBlock())
    /// Resolved parameter lists by `paramList` node.
    private var parameterLists: [NodeId: ParameterList] = [:]
    /// Values of `constexpr` objects of integer type, which are integer constant expressions.
    private var constexprValues: [DeclId: IntConst] = [:]
    /// Set when constant evaluation divides by zero: the expression is then not an integer constant expression.
    private var constantDivisionByZero = false
    /// File-scope object definitions without an initializer whose type is incomplete where they are declared.
    private var tentativeDefinitions: [(name: String, type: QualType, tok: TokenId)] = []

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
        self.currentBlockContainer = fileScopeContainer
        _ = Self.diagnosticsRegistered

        setupBuiltins()
    }

    /// Sema diagnostics whose message is given in full by their argument.
    private static let diagnosticsRegistered: Void = {
        for (id, name) in [(DiagId.semaInvalidDeclaration, "invalid_declaration"), (.semaInvalidBitField, "invalid_bit_field"),
                           (.semaInvalidExpression, "invalid_expression")] {
            DiagnosticRegistry.shared.register(DiagnosticInfo(id: id, name: "sema.\(name)", severity: .error, category: .sema, messageTemplate: "%@"))
        }
    }()

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
            switch tree.kind(of: decl) {
            case .functionDecl:
                analyzeFunctionDefinition(decl, tree: tree, tokens: tokens)
            case .varDecl, .typedefDecl:
                analyzeDeclaration(decl, isFileScope: true, tree: tree, tokens: tokens)
            case .staticAssertDecl:
                analyzeStaticAssert(decl, tree: tree, tokens: tokens)
            default:
                break
            }
        }

        // C23 6.9.2p3: a tentative definition's type must be complete by the end of the translation unit
        for t in tentativeDefinitions where !typePool.isComplete(t.type.typeId) {
            reportError("tentative definition of '\(t.name)' has a type that is never completed", diagId: .semaInvalidDeclaration, at: t.tok, in: tokens,
                        args: ["tentative definition has type '\(typeName(t.type))' that is never completed"])
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
        case .typeName, .declSpecs, .structType, .unionType, .enumType, .typeofType, .typeofUnqualType, .atomicType, .bitIntType:
            return true
        default:
            return false
        }
    }

    /// Declaration specifiers (C23 6.7.1-6.7.5): the type they specify, and the storage-class specifiers among them.
    private struct DeclSpecs {
        var type: QualType = .int
        var isTypedef = false
        var isExtern = false
        var isStatic = false
        var isConstexpr = false
        /// C23 `auto` (or GNU `__auto_type`) without a type specifier: the type is that of the initializer.
        var infersType = false
    }

    /// The parameters of a function declarator: types after adjustment (C23 6.7.7.4p7-8), names, and `...`.
    private struct ParameterList {
        var types: [QualType] = []
        var names: [TokenId] = []
        var isVariadic = false
    }

    /// The type named by a type node: a type name, declaration specifiers, or a single type specifier.
    public mutating func resolveType(from typeNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> QualType {
        let kind = tree.kind(of: typeNode)
        switch kind {
        case .typeName:
            let children = tree.children(of: typeNode)
            guard let specs = children.first(where: { tree.kind(of: $0) == .declSpecs }) else { return .error }
            let base = resolveDeclSpecs(specs, tree: tree, tokens: tokens).type
            guard let declarator = children.first(where: { tree.kind(of: $0) == .declarator }) else { return base }
            return applyDeclarator(declarator, to: base, tree: tree, tokens: tokens).type

        case .declSpecs:
            return resolveDeclSpecs(typeNode, tree: tree, tokens: tokens).type

        case .structType, .unionType:
            return QualType(typeId: analyzeStructOrUnion(typeNode, tree: tree, tokens: tokens, isUnion: kind == .unionType))

        case .enumType:
            return QualType(typeId: analyzeEnum(typeNode, tree: tree, tokens: tokens))

        case .typeofType, .typeofUnqualType:
            guard let first = tree.children(of: typeNode).first(where: { tree.kind(of: $0) != .attributeSpec }) else { return .error }
            let t: QualType
            if isTypeNode(tree.kind(of: first)) {
                t = resolveType(from: first, tree: tree, tokens: tokens)
            } else {
                let inst = analyzeExpression(first, tree: tree, tokens: tokens)
                t = isTyped(inst) ? typeOf(inst) : .error
            }
            return (kind == .typeofUnqualType) ? t.unqualified() : t

        case .atomicType:
            guard let inner = tree.children(of: typeNode).first else { return .error }
            return resolveType(from: inner, tree: tree, tokens: tokens)

        default:
            return .error
        }
    }

    /// Resolves declaration specifiers (C23 6.7.3.1 lists the valid type-specifier combinations). A struct, union or
    /// enum specifier is analyzed here, declaring or defining its tag; `isTagOnlyDeclaration` marks `struct S;`.
    private mutating func resolveDeclSpecs(_ node: NodeId, isTagOnlyDeclaration: Bool = false, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> DeclSpecs {
        var spec = DeclSpecs()
        var void = false, bool = false, char = false, short = false, int = false, float = false, double = false
        var longs = 0, signed = false, unsigned = false, complex = false, int128 = false, auto = false
        var named: QualType? = nil
        var bitIntWidth: (width: Int?, tok: TokenId)? = nil
        var qualifiers: UInt32 = 0
        var sawSpecifier = false

        for child in tree.children(of: node) {
            switch tree.kind(of: child) {
            case .specifier:
                let tok = tree.token(of: child)
                switch CTokenKind(rawValue: tokens.kind(of: tok)) {
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
                case .kwConst: qualifiers |= 0b001; continue
                case .kwVolatile: qualifiers |= 0b010; continue
                case .kwRestrict: qualifiers |= 0b100; continue
                case .kwTypedef: spec.isTypedef = true; continue
                case .kwExtern: spec.isExtern = true; continue
                case .kwStatic: spec.isStatic = true; continue
                case .kwConstexpr: spec.isConstexpr = true; continue
                case .kwAuto: auto = true; continue
                case .identifier:
                    let name = spelling(of: tok, in: tokens)
                    // Builtin type names are reserved identifiers; anything else is a typedef name
                    switch name.utf8.first == UInt8(ascii: "_") ? name : "" {
                    case "_Float16", "__bf16": named = QualType(typeId: .float16)
                    case "_Float32": named = .float
                    case "_Float64", "_Float32x": named = .double
                    case "__float128", "_Float128", "_Float64x", "__float80", "__ibm128": named = QualType(typeId: .longdouble)
                    case "__int128", "__int128_t": int128 = true
                    case "__uint128_t": int128 = true; unsigned = true
                    case "_Complex", "__complex__", "__complex", "_Imaginary": complex = true
                    case "__auto_type": auto = true; continue
                    case "__builtin_va_list", "__gnuc_va_list", "_Decimal32", "_Decimal64", "_Decimal128":
                        named = .error  // target-specific or unsupported: unmodeled, so no check relies on it
                    default:
                        if let sym = currentScope.lookupOrdinary(name), case .typedef = sym.storage {
                            named = sym.type
                        } else {
                            if !name.hasPrefix("_") {
                                reportError("unknown type name '\(name)'", diagId: .semaUnknownTypeName, at: tok, in: tokens, args: [name])
                            }
                            named = .error
                        }
                    }
                default:
                    continue  // `_Atomic`, `inline`, `register`, `thread_local`
                }
                sawSpecifier = true
            case .structType, .unionType:
                named = QualType(typeId: analyzeStructOrUnion(child, tree: tree, tokens: tokens, isUnion: tree.kind(of: child) == .unionType,
                                                              isTagOnlyDeclaration: isTagOnlyDeclaration))
            case .enumType:
                named = QualType(typeId: analyzeEnum(child, tree: tree, tokens: tokens, isTagOnlyDeclaration: isTagOnlyDeclaration))
            case .typeofType, .typeofUnqualType, .atomicType:
                named = resolveType(from: child, tree: tree, tokens: tokens)
            case .bitIntType:
                let width = tree.children(of: child).first.flatMap { constantValue($0, tree: tree, tokens: tokens) }
                bitIntWidth = (width.map { $0.isNegative ? -1 : Int(clamping: $0.bits) }, tree.token(of: child))
            default:
                break
            }
        }

        let base: QualType
        if complex {
            base = .error  // complex types are not modeled
        } else if let (width, tok) = bitIntWidth {
            // C23 6.7.3.1: `_BitInt(N)` needs N >= 2 (N >= 1 if unsigned), up to BITINT_MAXWIDTH (8192, 02 §4.2.2)
            if let width, width >= (unsigned ? 1 : 2), width <= 8192 {
                base = QualType(typeId: typePool.integerType(width: width, isSigned: !unsigned))
            } else {
                if width != nil {
                    reportError("invalid _BitInt width", diagId: .semaInvalidDeclaration, at: tok, in: tokens,
                                args: ["\(unsigned ? "unsigned" : "signed") _BitInt must have a bit size of at least \(unsigned ? 1 : 2) and at most 8192"])
                }
                base = .error
            }
        } else if int128 {
            base = QualType(typeId: typePool.int128Type(isSigned: !unsigned))
        } else if let named {
            base = named
        } else if sawSpecifier {
            _ = int
            if void { base = .void }
            else if bool { base = .bool }
            else if char { base = unsigned ? QualType(typeId: .uchar) : (signed ? QualType(typeId: .schar) : .char) }
            else if float { base = .float }
            else if double { base = longs > 0 ? QualType(typeId: .longdouble) : .double }
            else if short { base = QualType(typeId: unsigned ? .ushort : .short) }
            else if longs >= 2 { base = QualType(typeId: unsigned ? .ulonglong : .longlong) }
            else if longs == 1 { base = unsigned ? QualType(typeId: .ulong) : .long }
            else { base = unsigned ? QualType(typeId: .uint) : .int }
        } else if auto {
            spec.infersType = true
            base = .error
        } else {
            // C23 has no implicit `int` (6.7.3p2)
            reportError("type specifier missing", diagId: .semaInvalidDeclaration, at: tree.token(of: node), in: tokens,
                        args: ["type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int"])
            base = .error
        }
        spec.type = QualType(rawValue: base.rawValue | qualifiers)
        if spec.isConstexpr { spec.type = spec.type.withConst() }
        return spec
    }

    /// What a declarator declares: the type, the identifier (`nilId` if abstract), the parameter list of the
    /// function suffix that makes the identifier a function, the qualifiers inside the brackets of an outermost
    /// array suffix (`int a[const 3]`: kept for the adjusted parameter type), and whether any array has a size
    /// that is not an integer constant expression (a variable length array).
    private struct DeclaratorInfo {
        var type: QualType
        var name: TokenId = .nilId
        var params: NodeId? = nil
        var arrayQualifiers: UInt32 = 0
        var isVariableLength = false
    }

    /// Applies a declarator (C23 6.7.7) to the type `base` of its declaration specifiers. At each level, pointers
    /// apply first, then the array and function suffixes from right to left, then the nested declarator: in
    /// `int *(*f[2])(void)`, `f` is an array of 2 pointers to functions returning `int *`.
    private mutating func applyDeclarator(_ declarator: NodeId, to base: QualType, tree: borrowing ParseTree,
                                          tokens: borrowing TokenBuffer) -> DeclaratorInfo {
        var info = DeclaratorInfo(type: base)
        applyDeclarator(declarator, to: &info, tree: tree, tokens: tokens)
        return info
    }

    private mutating func applyDeclarator(_ declarator: NodeId, to info: inout DeclaratorInfo, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        var nested: NodeId? = nil
        var suffixes: [NodeId] = []
        var qualifiesPointer = false
        for child in tree.children(of: declarator) {
            switch tree.kind(of: child) {
            case .pointerType:
                info.type = QualType(typeId: typePool.pointerTo(info.type))
                info.params = nil
                info.arrayQualifiers = 0
                qualifiesPointer = true
            case .specifier where qualifiesPointer:
                info.type = QualType(rawValue: info.type.rawValue | qualifierBits(of: tree.token(of: child), tokens: tokens))
            case .declarator:
                nested = child
                qualifiesPointer = false
            case .arrayType, .functionType:
                suffixes.append(child)
                qualifiesPointer = false
            default:
                break
            }
        }
        for suffix in suffixes.reversed() {
            let tok = tree.token(of: suffix)
            if tree.kind(of: suffix) == .arrayType {
                info.type = arrayType(of: info.type, suffix: suffix, isVariableLength: &info.isVariableLength, tree: tree, tokens: tokens)
                info.params = nil
                info.arrayQualifiers = tree.children(of: suffix).reduce(0) {
                    tree.kind(of: $1) == .specifier ? $0 | qualifierBits(of: tree.token(of: $1), tokens: tokens) : $0
                }
            } else {
                // C23 6.7.7.4p1: a function shall not return an array or a function
                if !info.type.isError && isArrayOrFunction(info.type) {
                    reportError("function cannot return an array or function type", diagId: .semaInvalidDeclaration, at: tok, in: tokens,
                                args: ["function cannot return \(isFunctionType(info.type) ? "function" : "array") type '\(typeName(info.type))'"])
                }
                guard let list = tree.children(of: suffix).first(where: { tree.kind(of: $0) == .paramList }) else {
                    info.type = .error
                    continue
                }
                let signature = resolveParameters(list, tree: tree, tokens: tokens)
                info.type = QualType(typeId: typePool.functionType(returnType: info.type, paramTypes: signature.types, isVariadic: signature.isVariadic))
                info.params = list
                info.arrayQualifiers = 0
            }
        }
        if let nested {
            applyDeclarator(nested, to: &info, tree: tree, tokens: tokens)
        } else {
            info.name = tree.token(of: declarator)
        }
    }

    private func qualifierBits(of tok: TokenId, tokens: borrowing TokenBuffer) -> UInt32 {
        switch CTokenKind(rawValue: tokens.kind(of: tok)) {
        case .kwConst: return 0b001
        case .kwVolatile: return 0b010
        case .kwRestrict: return 0b100
        default: return 0
        }
    }

    /// `T [N]` (C23 6.7.7.3): the size must not be negative (zero-length arrays are a GNU extension), and the
    /// element type must be complete and not a function type. A size that is not an integer constant expression
    /// makes a variable length array, modeled with an unknown (zero) length.
    private mutating func arrayType(of element: QualType, suffix: NodeId, isVariableLength: inout Bool, tree: borrowing ParseTree,
                                    tokens: borrowing TokenBuffer) -> QualType {
        let tok = tree.token(of: suffix)
        if isFunctionType(element) {
            reportError("array of functions", diagId: .semaInvalidDeclaration, at: tok, in: tokens, args: ["'\(typeName(element))' declared as array of functions"])
            return .error
        }
        if !element.isError && !typePool.isComplete(element.typeId) {
            reportError("array has incomplete element type", diagId: .semaInvalidDeclaration, at: tok, in: tokens,
                        args: ["array has incomplete element type '\(typeName(element))'"])
            return .error
        }
        var count: UInt64 = 0
        if let sizeNode = tree.children(of: suffix).first(where: { tree.kind(of: $0) != .specifier }) {
            constantDivisionByZero = false
            if let size = constantValue(sizeNode, tree: tree, tokens: tokens) {
                if size.isNegative {
                    reportError("array has a negative size", diagId: .semaInvalidDeclaration, at: tok, in: tokens, args: ["array declared with a negative size"])
                    return .error
                }
                count = size.bits
            } else {
                if constantDivisionByZero || refersToRuntimeValue(sizeNode, tree: tree, tokens: tokens) { isVariableLength = true }
                _ = analyzeExpression(sizeNode, tree: tree, tokens: tokens)  // a variable length: type-check the size
            }
        }
        return QualType(typeId: typePool.arrayType(elementType: element, count: count))
    }

    /// Resolves a parameter type list, adjusting array and function parameters to pointers (C23 6.7.7.4p7-8) and
    /// `(void)` to no parameters. Cached per node: a declarator may be resolved more than once.
    private mutating func resolveParameters(_ list: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> ParameterList {
        if let cached = parameterLists[list] { return cached }
        var result = ParameterList()
        // Function prototype scope (C23 6.2.1p4): a parameter is visible in the declarators of later ones (`int a[n]`)
        let prototypeScope = CScope(parent: currentScope)
        currentScope = prototypeScope
        defer { currentScope = prototypeScope.parent ?? CScope() }
        for param in tree.children(of: list) where tree.kind(of: param) == .paramDecl {
            let children = tree.children(of: param)
            if children.isEmpty, CTokenKind(rawValue: tokens.kind(of: tree.token(of: param))) == .ellipsis {
                result.isVariadic = true
                continue
            }
            guard let specsNode = children.first(where: { tree.kind(of: $0) == .declSpecs }) else {
                result.types.append(.error)
                result.names.append(.nilId)
                continue
            }
            let spec = resolveDeclSpecs(specsNode, tree: tree, tokens: tokens)
            var info = DeclaratorInfo(type: spec.type)
            if let declarator = children.first(where: { tree.kind(of: $0) == .declarator }) {
                info = applyDeclarator(declarator, to: spec.type, tree: tree, tokens: tokens)
            }
            var type = info.type
            switch canonicalKind(type) {
            case .array(let element, _): type = QualType(typeId: typePool.pointerTo(element), qualifiers: UInt8(info.arrayQualifiers))
            case .function: type = QualType(typeId: typePool.pointerTo(type))
            default: break
            }
            result.types.append(type)
            result.names.append(info.name)
            if info.name.isValid, CTokenKind(rawValue: tokens.kind(of: info.name)) == .identifier {
                let name = spelling(of: info.name, in: tokens)
                if prototypeScope.lookupLocalOrdinary(name) != nil {
                    reportError("redefinition of parameter '\(name)'", diagId: .semaRedefinition, at: info.name, in: tokens, args: [name])
                }
                prototypeScope.insertOrdinary(symbol: CSymbol(name: name, type: type, storage: .param(index: result.types.count - 1, offset: 0)))
            }
        }
        if result.types.count == 1, !result.names[0].isValid, typePool.canonical(of: result.types[0].typeId) == .void {
            result.types = []
            result.names = []
        }
        parameterLists[list] = result
        return result
    }

    // MARK: - Declarations

    /// A declaration (C23 6.7): `declSpecs`, then each declarator followed by its initializer, if any.
    private mutating func analyzeDeclaration(_ node: NodeId, isFileScope: Bool, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: node)
        guard let specsNode = children.first(where: { tree.kind(of: $0) == .declSpecs }) else { return }
        let hasDeclarators = children.contains { tree.kind(of: $0) == .declarator }
        let spec = resolveDeclSpecs(specsNode, isTagOnlyDeclaration: !hasDeclarators, tree: tree, tokens: tokens)
        let specAttributes = tree.children(of: specsNode).filter { tree.kind(of: $0) == .attributeSpec }
        var i = 0
        while i < children.count {
            let declarator = children[i]
            i += 1
            guard tree.kind(of: declarator) == .declarator else { continue }
            var initializer: NodeId? = nil
            var attributes = specAttributes
            if tree.subtreeSize(of: declarator) > 1 {
                attributes += tree.children(of: declarator).filter { tree.kind(of: $0) == .attributeSpec }
            }
            while i < children.count, tree.kind(of: children[i]) == .attributeSpec {
                attributes.append(children[i])
                i += 1
            }
            if i < children.count, tree.kind(of: children[i]) != .declarator {
                initializer = children[i]
                i += 1
            }
            let info = applyDeclarator(declarator, to: spec.type, tree: tree, tokens: tokens)
            let (type, nameTok) = (applyMachineMode(info.type, attributes: attributes, tree: tree, tokens: tokens), info.name)
            guard nameTok.isValid, CTokenKind(rawValue: tokens.kind(of: nameTok)) == .identifier else { continue }
            let name = spelling(of: nameTok, in: tokens)
            // C23 6.7.7.3p2: only block-scope identifiers without linkage may have a variably modified type
            if info.isVariableLength && (isFileScope || ((spec.isExtern || spec.isStatic) && !spec.isTypedef)) {
                reportError("variable length array declaration not allowed here", diagId: .semaInvalidDeclaration, at: nameTok, in: tokens,
                            args: [isFileScope ? "variable length array declaration not allowed at file scope"
                                               : "variable length array declaration cannot have 'extern' or 'static' storage"])
            }
            if spec.isTypedef {
                declareTypedef(name, type: type, at: nameTok, tokens: tokens)
            } else if isFunctionType(type) {
                if let initializer {
                    reportError("illegal initializer", diagId: .semaInvalidDeclaration, at: tree.token(of: initializer), in: tokens,
                                args: ["illegal initializer (only variables can be initialized)"])
                }
                _ = declareFunction(name, type: type, at: nameTok, tokens: tokens)
            } else {
                declareVariable(name, type: type, spec: spec, declarator: declarator, initializer: initializer, isFileScope: isFileScope,
                                at: nameTok, tree: tree, tokens: tokens)
            }
        }
    }

    /// GNU `__attribute__((mode(M)))` on an integer declaration selects the integer type of machine mode `M`
    /// (`QI`, `HI`, `SI`, `DI`, `TI`, `word`, `pointer`), keeping its signedness; compiler-rt's `ti_int` is one.
    private func applyMachineMode(_ type: QualType, attributes: [NodeId], tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> QualType {
        guard !attributes.isEmpty, let traits = integerTraits(type.typeId) else { return type }
        for attr in attributes where tree.kind(of: attr) == .attributeSpec {
            var i = Int(tree.token(of: attr).rawIndex) + 1
            var depth = 0
            repeat {
                guard i + 3 < tokens.count else { break }
                let tok = TokenId(UInt32(i))
                switch CTokenKind(rawValue: tokens.kind(of: tok)) {
                case .lParen: depth += 1
                case .rParen: depth -= 1
                case .identifier:
                    let word = spelling(of: tok, in: tokens)
                    if word == "mode" || word == "__mode__", CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i + 1)))) == .lParen {
                        let mode = spelling(of: TokenId(UInt32(i + 2)), in: tokens).replacingOccurrences(of: "__", with: "")
                        let sizes: [String: TypeId] = ["QI": .schar, "byte": .schar, "HI": .short, "SI": .int, "DI": .long,
                                                       "word": .long, "pointer": .long, "unwind_word": .long]
                        if mode == "TI" { return QualType(typeId: typePool.int128Type(isSigned: traits.isSigned), qualifiers: type.qualifiers) }
                        guard let signed = sizes[mode] else { return type }
                        let unsigned: [TypeId: TypeId] = [.schar: .uchar, .short: .ushort, .int: .uint, .long: .ulong]
                        return QualType(typeId: traits.isSigned ? signed : unsigned[signed]!, qualifiers: type.qualifiers)
                    }
                default: break
                }
                i += 1
            } while depth > 0
        }
        return type
    }

    private mutating func declareTypedef(_ name: String, type: QualType, at nameTok: TokenId, tokens: borrowing TokenBuffer) {
        let typedefTypeId = typePool.typedefType(name: name, underlying: type)
        let typedefQualType = QualType(typeId: typedefTypeId, qualifiers: type.qualifiers)

        // C23 6.7p3: a typedef may be redefined in the same scope only to denote the same type
        if let prior = currentScope.lookupLocalOrdinary(name) {
            let sameType = prior.storage == .typedef && prior.type.qualifiers == type.qualifiers
                && typesCompatible(prior.type.unqualified(), type.unqualified())
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
    }

    /// Declares a function; redeclarations in the same scope must have compatible types (C23 6.7p4).
    private mutating func declareFunction(_ name: String, type: QualType, at nameTok: TokenId, tokens: borrowing TokenBuffer) -> DeclId {
        if !builtinNames.contains(name), let prior = currentScope.lookupLocalOrdinary(name), !typesCompatible(prior.type, type) {
            reportError("conflicting types for '\(name)'", diagId: .semaRedeclaration, at: nameTok, in: tokens, args: [name])
        }
        let declId = declTable.append(
            kind: .function,
            name: name,
            type: type,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
        )
        currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: type, storage: .function(name: name)))
        return declId
    }

    private mutating func declareVariable(_ name: String, type declaredType: QualType, spec: DeclSpecs, declarator: NodeId, initializer: NodeId?,
                                          isFileScope: Bool, at nameTok: TokenId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        var varType = declaredType
        // An array of unknown size is completed by its initializer (C23 6.7.10p22)
        if let initializer, case .array(let element, 0) = canonicalKind(varType),
           let count = initializerLength(initializer, element: element, tree: tree, tokens: tokens) {
            varType = QualType(typeId: typePool.arrayType(elementType: element, count: count), qualifiers: varType.qualifiers)
        }
        let isVoid = !varType.isError && typePool.canonical(of: varType.typeId) == .void
        let isIncomplete = !spec.infersType && !varType.isError && !typePool.isComplete(varType.typeId)

        if isFileScope {
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
            // An object definition needs a complete type; a tentative one only by the end of the unit (6.9.2p3)
            if !spec.isExtern && (isVoid || (isIncomplete && initializer != nil)) {
                reportError("variable has incomplete type", diagId: .semaIncompleteType, at: nameTok, in: tokens, args: [typeName(varType)])
            } else if !spec.isExtern && isIncomplete && !isArrayType(varType) {
                tentativeDefinitions.append((name, varType, nameTok))
            }
            if let initializer {
                if !initializedGlobals.insert(name).inserted {
                    reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
                }
                // The identifier is in scope in its own initializer: `void *__dso_handle = &__dso_handle;`
                if !spec.infersType && currentScope.lookupLocalOrdinary(name) == nil {
                    currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: .nilId, type: varType, storage: .global(name: name)))
                }
                let initInst = analyzeExpression(initializer, tree: tree, tokens: tokens)
                if !isConstantInitializer(initializer, tree: tree, tokens: tokens) {
                    reportError("initializer element is not a compile-time constant", diagId: .semaConstantExprNotConstant, at: tree.token(of: initializer), in: tokens)
                } else if tree.kind(of: initializer) != .initList && !spec.infersType {
                    checkAssignment(to: varType, from: initInst, rhsNode: initializer, tree: tree, tokens: tokens)
                }
                if spec.infersType {
                    varType = isTyped(initInst) ? decayed(typeOf(initInst)).unqualified() : .error
                }
            }

            let declId = declTable.append(
                kind: .variable,
                name: name,
                type: varType,
                origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
            )
            let sym = CSymbol(name: name, declId: declId, type: varType, storage: .global(name: name))
            currentScope.insertOrdinary(symbol: sym)
            symbolRefs[declarator] = sym
            recordConstexprValue(declId, spec: spec, type: varType, initializer: initializer, tree: tree, tokens: tokens)
            return
        }

        if spec.isExtern {
            let declId = declTable.append(kind: .variable, name: name, type: varType,
                                          origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok)))
            currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: varType, storage: .global(name: name)))
            return
        }
        checkBlockScopeRedefinition(name, at: nameTok, tokens: tokens)
        if isVoid || isIncomplete {
            reportError("variable has incomplete type", diagId: .semaIncompleteType, at: nameTok, in: tokens, args: [typeName(varType)])
        }

        // Pre-insert the symbol so `int *p = malloc(sizeof *p)` resolves `p` in its own initializer
        if !spec.infersType {
            currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: .nilId, type: varType, storage: .local(offset: 0)))
        }

        var initInst: SemInstId? = nil
        if let initializer {
            let inst = analyzeExpression(initializer, tree: tree, tokens: tokens)
            initInst = inst
            if spec.isStatic && !isConstantInitializer(initializer, tree: tree, tokens: tokens) {
                reportError("initializer element is not a compile-time constant", diagId: .semaConstantExprNotConstant, at: tree.token(of: initializer), in: tokens)
            }
            if spec.infersType {
                varType = isTyped(inst) ? decayed(typeOf(inst)).unqualified() : .error
            } else if tree.kind(of: initializer) != .initList {
                checkAssignment(to: varType, from: inst, rhsNode: initializer, tree: tree, tokens: tokens)
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
        symbolRefs[declarator] = sym
        nodeTypes[declarator] = varType.typeId
        recordConstexprValue(declId, spec: spec, type: varType, initializer: initializer, tree: tree, tokens: tokens)

        if let initInst, let container = currentBlockContainer {
            let lhsInst = container.block.append(kind: .declRef, type: varType, arg0: declId.rawIndex, node: declarator)
            _ = container.block.append(kind: .assign, type: varType, arg0: lhsInst.rawIndex, arg1: initInst.rawIndex, node: declarator)
        }
    }

    /// A `constexpr` object of integer type is a named constant (C23 6.6p7): record its value for constant evaluation.
    private mutating func recordConstexprValue(_ declId: DeclId, spec: DeclSpecs, type: QualType, initializer: NodeId?,
                                               tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        guard spec.isConstexpr, let initializer, integerTraits(type.typeId) != nil,
              let value = constantValue(initializer, tree: tree, tokens: tokens) else { return }
        constexprValues[declId] = convert(value, to: type.typeId)
    }

    /// The length an initializer gives an array of unknown size: the number of elements of a braced list (one past
    /// the highest designated index), or the length of a string literal including its terminator.
    private mutating func initializerLength(_ initializer: NodeId, element: QualType, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> UInt64? {
        var node = initializer
        if tree.kind(of: node) == .initList {
            let items = tree.children(of: node)
            // `char s[] = { "abc" }`
            if items.count == 1, tree.kind(of: items[0]) == .stringLiteral, typePool.size(of: element.typeId) <= 4,
               typePool.isInteger(type: element.typeId) {
                node = items[0]
            } else {
                var next: UInt64 = 0, length: UInt64 = 0
                for item in items {
                    if tree.kind(of: item) == .designatedInit, CTokenKind(rawValue: tokens.kind(of: tree.token(of: item))) == .lBracket,
                       let index = tree.children(of: item).first.flatMap({ constantValue($0, tree: tree, tokens: tokens) }) {
                        next = index.bits
                    }
                    next += 1
                    length = max(length, next)
                }
                return length
            }
        }
        if tree.kind(of: node) == .stringLiteral {
            return stringLiteralInfo(tree.token(of: node), tokens: tokens).length
        }
        return nil
    }

    /// A function definition (C23 6.9.1): `declSpecs`, the declarator, and the body.
    private mutating func analyzeFunctionDefinition(_ fnNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: fnNode)
        guard let specsNode = children.first(where: { tree.kind(of: $0) == .declSpecs }),
              let declarator = children.first(where: { tree.kind(of: $0) == .declarator }),
              let bodyNode = children.last, tree.kind(of: bodyNode) == .compoundStmt else { return }
        let spec = resolveDeclSpecs(specsNode, tree: tree, tokens: tokens)
        let info = applyDeclarator(declarator, to: spec.type, tree: tree, tokens: tokens)
        let (fnType, fnTok, paramsNode) = (info.type, info.name, info.params)
        guard case .function(let returnType, _, _) = canonicalKind(fnType), let paramsNode,
              CTokenKind(rawValue: tokens.kind(of: fnTok)) == .identifier else { return }
        let fnName = spelling(of: fnTok, in: tokens)
        let signature = resolveParameters(paramsNode, tree: tree, tokens: tokens)
        let fnDeclId = declareFunction(fnName, type: fnType, at: fnTok, tokens: tokens)
        if !definedFunctions.insert(fnName).inserted {
            reportError("redefinition of '\(fnName)'", diagId: .semaRedefinition, at: fnTok, in: tokens, args: [fnName])
        }

        self.currentReturnType = returnType
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
        let paramNames = signature.names.map { $0.isValid ? spelling(of: $0, in: tokens) : "" }
        for (idx, pName) in paramNames.enumerated() {
            let pType = signature.types[idx]
            let sz = max(8, typePool.size(of: pType.typeId))
            currentStackOffset += Int32((sz + 7) & ~7)
            let offset = -currentStackOffset
            guard !pName.isEmpty else { continue }
            if currentScope.lookupLocalOrdinary(pName) != nil {
                reportError("redefinition of parameter '\(pName)'", diagId: .semaRedefinition, at: signature.names[idx], in: tokens, args: [pName])
            }
            let pDecl = declTable.append(
                kind: .parameter,
                name: pName,
                parent: fnDeclId,
                type: pType
            )
            currentScope.insertOrdinary(symbol: CSymbol(name: pName, declId: pDecl, type: pType, storage: .param(index: idx, offset: offset)))
        }

        analyzeStatement(bodyNode, tree: tree, tokens: tokens)
        self.currentBlockContainer = fileScopeContainer
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
            paramTypes: signature.types.map { $0.typeId },
            bodyNode: bodyNode,
            stackFrameSize: alignedFrame,
            declId: fnDeclId,
            blockId: blockId
        )

        self.currentScope = fnScope.parent ?? CScope()
    }

    /// A struct or union specifier (C23 6.7.2.1, 6.7.2.3). Tags are scoped: a definition, or a `struct S;`
    /// declaration, introduces a new type in the current scope, which hides an outer one; a reference resolves to
    /// the innermost visible tag, or declares a new incomplete type.
    private mutating func analyzeStructOrUnion(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer, isUnion: Bool,
                                               isTagOnlyDeclaration: Bool = false) -> TypeId {
        let nameTok = tree.token(of: node)
        let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
        let name = (tokKind == .kwStruct || tokKind == .kwUnion) ? "" : spelling(of: nameTok, in: tokens)
        let children = tree.children(of: node)
        let isDefinition = name.isEmpty || tokenFollowing(nameTok, tokens: tokens) == .lBrace
            || children.contains { tree.kind(of: $0) == .fieldDecl }

        if !isDefinition {
            if !isTagOnlyDeclaration, let existing = currentScope.lookupTag(name) {
                checkTagKind(existing, isUnion: isUnion, name: name, at: nameTok, tokens: tokens)
                return existing
            }
            if isTagOnlyDeclaration, let existing = currentScope.lookupLocalTag(name) {
                checkTagKind(existing, isUnion: isUnion, name: name, at: nameTok, tokens: tokens)
                return existing
            }
            let id = typePool.declareStruct(name: name, isUnion: isUnion)
            currentScope.insertTag(name: name, typeId: id)
            return id
        }

        var structTypeId: TypeId
        if !name.isEmpty, let existing = currentScope.lookupLocalTag(name), case .struct(_, _, let existingIsUnion) = canonicalKind(QualType(typeId: existing)),
           existingIsUnion == isUnion, !typePool.isComplete(existing) {
            structTypeId = existing  // completes a forward declaration in this scope
        } else {
            if !name.isEmpty, currentScope.lookupLocalTag(name) != nil {
                reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
            }
            structTypeId = typePool.declareStruct(name: name, isUnion: isUnion)
            if !name.isEmpty { currentScope.insertTag(name: name, typeId: structTypeId) }
        }

        var members: [StructMemberDecl] = []
        var memberNames: Set<String> = []
        for member in children where tree.kind(of: member) == .fieldDecl {
            let mChildren = tree.children(of: member)
            guard let specsNode = mChildren.first(where: { tree.kind(of: $0) == .declSpecs }) else { continue }
            let spec = resolveDeclSpecs(specsNode, tree: tree, tokens: tokens)
            if !mChildren.contains(where: { tree.kind(of: $0) == .declarator }) {
                // C11 anonymous struct or union member; a named tag here only declares the tag
                let specChildren = tree.children(of: specsNode)
                if let tag = specChildren.first(where: { tree.kind(of: $0) == .structType || tree.kind(of: $0) == .unionType }),
                   [.kwStruct, .kwUnion].contains(CTokenKind(rawValue: tokens.kind(of: tree.token(of: tag)))) {
                    members.append(StructMemberDecl(name: "", type: spec.type))
                }
                continue
            }
            var i = 0
            while i < mChildren.count {
                let declarator = mChildren[i]
                i += 1
                guard tree.kind(of: declarator) == .declarator else { continue }
                var widthNode: NodeId? = nil
                if i < mChildren.count, tree.kind(of: mChildren[i]) != .declarator, tree.kind(of: mChildren[i]) != .attributeSpec {
                    widthNode = mChildren[i]
                    i += 1
                }
                let info = applyDeclarator(declarator, to: spec.type, tree: tree, tokens: tokens)
                let (type, mTok) = (info.type, info.name)
                if info.isVariableLength {
                    reportError("fields must have a constant size", diagId: .semaInvalidDeclaration, at: mTok, in: tokens,
                                args: ["fields must have a constant size: variable length array in structure"])
                }
                let isNamed = mTok.isValid && CTokenKind(rawValue: tokens.kind(of: mTok)) == .identifier
                let mName = isNamed ? spelling(of: mTok, in: tokens) : ""
                let loc = isNamed ? mTok : tree.token(of: member)
                if isNamed && !memberNames.insert(mName).inserted {
                    reportError("duplicate member '\(mName)'", diagId: .semaInvalidDeclaration, at: mTok, in: tokens, args: ["duplicate member '\(mName)'"])
                }
                if isFunctionType(type) {
                    reportError("field declared as a function", diagId: .semaInvalidDeclaration, at: loc, in: tokens, args: ["field '\(mName)' declared as a function"])
                    continue
                }
                if !type.isError && !typePool.isComplete(type.typeId) && !isArrayType(type) {
                    reportError("field has incomplete type", diagId: .semaInvalidDeclaration, at: loc, in: tokens, args: ["field has incomplete type '\(typeName(type))'"])
                }
                var bitWidth: Int? = nil
                if let widthNode {
                    bitWidth = checkBitFieldWidth(widthNode, type: type, name: mName, at: loc, tree: tree, tokens: tokens)
                }
                members.append(StructMemberDecl(name: mName, type: type, bitWidth: bitWidth))
            }
        }

        typePool.completeStruct(structTypeId, fields: members, isPacked: hasPackedAttribute(children, tree: tree, tokens: tokens))
        if !name.isEmpty {
            _ = declTable.append(kind: isUnion ? .unionDecl : .structDecl, name: name, type: QualType(typeId: structTypeId))
        }
        return structTypeId
    }

    /// A bit-field's width (C23 6.7.2.1p4-5): an integer constant expression, not negative, at most the width of
    /// the bit-field's integer type, and zero only for an unnamed bit-field. Returns nil if the width is invalid.
    private mutating func checkBitFieldWidth(_ widthNode: NodeId, type: QualType, name: String, at tok: TokenId,
                                             tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Int? {
        let field = name.isEmpty ? "anonymous bit-field" : "bit-field '\(name)'"
        if !type.isError && !typePool.isInteger(type: type.typeId) {
            reportError("bit-field has non-integral type", diagId: .semaInvalidBitField, at: tok, in: tokens,
                        args: ["\(field) has non-integral type '\(typeName(type))'"])
            return nil
        }
        guard let width = requiredConstant(widthNode, tree: tree, tokens: tokens) else { return nil }
        let typeWidth = type.isError ? Int.max : integerWidth(type.typeId)
        if width.isNegative {
            reportError("bit-field has negative width", diagId: .semaInvalidBitField, at: tok, in: tokens, args: ["\(field) has negative width"])
            return nil
        }
        if width.bits > UInt64(typeWidth) {
            reportError("width of bit-field exceeds the width of its type", diagId: .semaInvalidBitField, at: tok, in: tokens,
                        args: ["width of \(field) (\(width.bits) bits) exceeds the width of its type (\(typeWidth) bit\(typeWidth == 1 ? "" : "s"))"])
            return nil
        }
        if width.bits == 0 && !name.isEmpty {
            reportError("named bit-field has zero width", diagId: .semaInvalidBitField, at: tok, in: tokens, args: ["named bit-field '\(name)' has zero width"])
            return nil
        }
        return Int(width.bits)
    }

    /// The width in bits of an integer type (`bool` has 1).
    private func integerWidth(_ type: TypeId) -> Int {
        switch typePool.typeInfo(of: typePool.canonical(of: type)).kind {
        case .int(let width, _): return width
        case .bool: return 1
        case .enum(_, let underlying, _): return integerWidth(underlying)
        default: return typePool.size(of: type) * 8
        }
    }

    /// Whether a struct or union specifier carries GNU `__attribute__((packed))`.
    private func hasPackedAttribute(_ children: [NodeId], tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        for attr in children where tree.kind(of: attr) == .attributeSpec {
            var i = Int(tree.token(of: attr).rawIndex) + 1
            var depth = 0
            repeat {
                guard i < tokens.count else { break }
                let tok = TokenId(UInt32(i))
                switch CTokenKind(rawValue: tokens.kind(of: tok)) {
                case .lParen: depth += 1
                case .rParen: depth -= 1
                case .identifier:
                    let word = spelling(of: tok, in: tokens)
                    if word == "packed" || word == "__packed__" { return true }
                default: break
                }
                i += 1
            } while depth > 0
        }
        return false
    }

    private mutating func checkTagKind(_ existing: TypeId, isUnion: Bool, name: String, at tok: TokenId, tokens: borrowing TokenBuffer) {
        let matches: Bool
        switch canonicalKind(QualType(typeId: existing)) {
        case .struct(_, _, let existingIsUnion): matches = existingIsUnion == isUnion
        default: matches = false
        }
        if !matches {
            reportError("use of '\(name)' with tag type that does not match previous declaration", diagId: .semaInvalidDeclaration, at: tok, in: tokens,
                        args: ["use of '\(name)' with tag type that does not match previous declaration"])
        }
    }

    private func tokenFollowing(_ tok: TokenId, tokens: borrowing TokenBuffer) -> CTokenKind? {
        let next = Int(tok.rawIndex) + 1
        guard next < tokens.count else { return nil }
        return CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(next))))
    }

    /// An enum specifier (C23 6.7.2.2). Without a fixed underlying type, the enumerated type is compatible with
    /// `unsigned int` if no value is negative and `int` otherwise (widened to 64 bits if a value needs it), as in
    /// GCC and Clang; an enumeration constant has type `int` if its value fits, else the enumerated type's.
    private mutating func analyzeEnum(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer, isTagOnlyDeclaration: Bool = false) -> TypeId {
        let nameTok = tree.token(of: node)
        let tokKind = CTokenKind(rawValue: tokens.kind(of: nameTok)) ?? .errorToken
        let name = (tokKind == .kwEnum) ? "" : spelling(of: nameTok, in: tokens)
        let children = tree.children(of: node)
        let enumerators = children.filter { tree.kind(of: $0) == .enumeratorDecl }
        var fixedType: TypeId? = nil
        if let specsNode = children.first(where: { tree.kind(of: $0) == .declSpecs }) {
            let t = resolveDeclSpecs(specsNode, tree: tree, tokens: tokens).type
            if t.isError || typePool.isInteger(type: t.typeId) {
                fixedType = t.isError ? .int : typePool.canonical(of: t.typeId)
            } else {
                reportError("invalid underlying type", diagId: .semaInvalidDeclaration, at: nameTok, in: tokens, args: ["non-integral type is an invalid underlying type"])
            }
        }
        let isDefinition = name.isEmpty || !enumerators.isEmpty
            || children.contains { tree.kind(of: $0) == .errorNode } || nextTokenAfterEnumHead(nameTok, tokens: tokens) == .lBrace

        if !isDefinition {
            if let existing = isTagOnlyDeclaration ? currentScope.lookupLocalTag(name) : currentScope.lookupTag(name) {
                return existing
            }
            let id = typePool.declareEnum(name: name, underlyingType: fixedType ?? .uint, isComplete: fixedType != nil)
            currentScope.insertTag(name: name, typeId: id)
            return id
        }

        let enumTypeId: TypeId
        if !name.isEmpty, let existing = currentScope.lookupLocalTag(name) {
            if case .enum(_, _, let cases) = canonicalKind(QualType(typeId: existing)), cases.isEmpty, fixedType != nil || !typePool.isComplete(existing) {
                enumTypeId = existing  // `enum E : T;` then `enum E : T { ... }`
            } else {
                reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
                enumTypeId = typePool.declareEnum(name: name)
                currentScope.insertTag(name: name, typeId: enumTypeId)
            }
        } else {
            enumTypeId = typePool.declareEnum(name: name, underlyingType: fixedType ?? .uint)
            if !name.isEmpty { currentScope.insertTag(name: name, typeId: enumTypeId) }
        }

        var enumCases: [(name: String, value: Int64)] = []
        var next = IntConst(bits: 0, type: fixedType ?? .int)
        var constants: [(name: String, value: IntConst, declId: DeclId)] = []
        for enumerator in enumerators {
            let cTok = tree.token(of: enumerator)
            let cName = spelling(of: cTok, in: tokens)
            if let valNode = tree.children(of: enumerator).first(where: { tree.kind(of: $0) != .attributeSpec }) {
                next = requiredConstant(valNode, tree: tree, tokens: tokens) ?? IntConst(bits: 0, type: .int)
            }
            if let fixedType { next = convert(next, to: fixedType) }
            if currentScope.lookupLocalOrdinary(cName) != nil {
                reportError("redefinition of enumerator '\(cName)'", diagId: .semaRedefinition, at: cTok, in: tokens, args: [cName])
            }
            let value = next.signedValue
            enumCases.append((name: cName, value: value))
            let constType: TypeId = fixedType ?? (next.fitsInt ? .int : typePool.canonical(of: next.type))
            let declId = declTable.append(kind: .enumConstant, name: cName, type: QualType(typeId: constType))
            currentScope.insertOrdinary(symbol: CSymbol(name: cName, declId: declId, type: QualType(typeId: constType), storage: .enumConstant(value: value)))
            constants.append((cName, next, declId))
            // The next value is one more, in a wider type if needed (C23 6.7.2.2p5)
            if next.type == .int && next.signedValue == Int64(Int32.max) {
                next = IntConst(bits: next.bits, type: .long)
            }
            next = makeConst(next.bits &+ 1, next.type)
        }

        var underlying = fixedType ?? .uint
        if fixedType == nil {
            let negative = constants.contains { $0.value.isNegative }
            let fits32 = constants.allSatisfy { negative ? $0.value.fitsInt : $0.value.bits <= UInt64(UInt32.max) }
            underlying = negative ? (fits32 ? .int : .long) : (fits32 ? .uint : .ulong)
        }
        typePool.completeEnum(enumTypeId, underlyingType: underlying, cases: enumCases)
        if !name.isEmpty {
            _ = declTable.append(kind: .enumDecl, name: name, type: QualType(typeId: enumTypeId))
        }
        return enumTypeId
    }

    /// The token after `enum E` and any fixed underlying type: `{` for a definition.
    private func nextTokenAfterEnumHead(_ nameTok: TokenId, tokens: borrowing TokenBuffer) -> CTokenKind? {
        var i = Int(nameTok.rawIndex) + 1
        if i < tokens.count, CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) == .colon {
            while i < tokens.count, let k = CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))), k != .lBrace, k != .semicolon {
                i += 1
            }
        }
        guard i < tokens.count else { return nil }
        return CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i))))
    }

    private mutating func analyzeStaticAssert(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let children = tree.children(of: node)
        guard let condNode = children.first else { return }
        guard let value = requiredConstant(condNode, tree: tree, tokens: tokens) else { return }
        if value.bits == 0 {
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
            guard children.count == 2, let outer = memberOffset(of: children[0], in: base, tree: tree, tokens: tokens),
                  let index = constantValue(children[1], tree: tree, tokens: tokens) else { return nil }
            let element = typePool.pointeeType(of: outer.type.typeId)
            return (outer.offset + index.signedValue * Int64(typePool.size(of: element.typeId)), element)
        default:
            return nil
        }
    }

    // MARK: - Constraint Checks (C23 6.5, 6.7, 6.8)

    private func canonicalKind(_ t: QualType) -> CTypeKind {
        typePool.typeInfo(of: typePool.canonical(of: t.typeId)).kind
    }

    /// The C spelling of a type, for diagnostics: `const char *`, `struct S`, `int (*)[4]`, `void (int, ...)`.
    private func typeName(_ t: QualType, declarator: String = "") -> String {
        let quals = [(t.isConst, "const"), (t.isVolatile, "volatile"), (t.isRestrict, "restrict")].filter(\.0).map(\.1).joined(separator: " ")
        func named(_ base: String) -> String {
            let spelled = quals.isEmpty ? base : quals + " " + base
            return declarator.isEmpty ? spelled : spelled + " " + declarator
        }
        switch typePool.typeInfo(of: t.typeId).kind {
        case .typedef(let name, _):
            return named(name)
        case .pointer(let pointee):
            let inner = "*" + quals + (declarator.isEmpty || quals.isEmpty ? "" : " ") + declarator
            return typeName(pointee, declarator: isArrayOrFunction(pointee) ? "(\(inner))" : inner)
        case .array(let element, let count):
            return typeName(element, declarator: declarator + "[\(count == 0 ? "" : String(count))]")
        case .function(let returnType, let params, let isVariadic):
            let list = params.map { typeName($0) } + (isVariadic ? ["..."] : [])
            return typeName(returnType, declarator: declarator + "(" + (list.isEmpty ? "void" : list.joined(separator: ", ")) + ")")
        case .struct(let name, _, let isUnion):
            return named((isUnion ? "union " : "struct ") + (name.isEmpty ? "(unnamed)" : name))
        case .enum(let name, _, _):
            return named("enum " + (name.isEmpty ? "(unnamed)" : name))
        case .int(let width, let isSigned):
            let builtin: [TypeId: String] = [.char: "char", .schar: "signed char", .uchar: "unsigned char", .short: "short",
                                             .ushort: "unsigned short", .int: "int", .uint: "unsigned int", .long: "long",
                                             .ulong: "unsigned long", .longlong: "long long", .ulonglong: "unsigned long long",
                                             .int128: "__int128"]
            return named(builtin[typePool.canonical(of: t.typeId)] ?? "\(isSigned ? "" : "unsigned ")_BitInt(\(width))")
        case .float:
            let can = typePool.canonical(of: t.typeId)
            return named(can == .float ? "float" : can == .double ? "double" : "long double")
        case .bool: return named("bool")
        case .void: return named("void")
        case .nullptr: return named("nullptr_t")
        case .error: return named("<unknown type>")
        }
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

    private func isFunctionType(_ t: QualType) -> Bool {
        if case .function = canonicalKind(t) { return true }
        return false
    }

    private func isArrayType(_ t: QualType) -> Bool {
        if case .array = canonicalKind(t) { return true }
        return false
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

    /// Array-to-pointer and function-to-pointer conversion (C23 6.3.2.1p3-4); other types are unchanged.
    private func decayed(_ t: QualType) -> QualType {
        switch canonicalKind(t) {
        case .array(let element, _): return QualType(typeId: typePool.pointerTo(element))
        case .function: return QualType(typeId: typePool.pointerTo(t.unqualified()))
        default: return t
        }
    }

    private func typeOf(_ inst: SemInstId) -> QualType {
        currentBlockContainer?.block.type(of: inst) ?? .error
    }

    /// Type compatibility (C23 6.2.7), structural so that separately created function/array types compare
    /// equal. A struct, union or enum type is compatible only with itself (tags are scoped, and a completed
    /// declaration is the same type); an enumeration also with its underlying integer type.
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
        case (.enum(_, let underlying, _), .int), (.enum(_, let underlying, _), .bool):
            return typePool.canonical(of: underlying) == cb
        case (.int, .enum(_, let underlying, _)), (.bool, .enum(_, let underlying, _)):
            return typePool.canonical(of: underlying) == ca
        default:
            return false
        }
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
            return isBuiltinFunctionName(spelling(of: tree.token(of: callee), in: tokens))
        default:
            return false
        }
    }

    /// The value of an expression that must be an integer constant expression (C23 6.6p6). One that certainly is
    /// not (see `refersToRuntimeValue`, and division by zero) is diagnosed; others the evaluator cannot fold are
    /// given the benefit of the doubt.
    private mutating func requiredConstant(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> IntConst? {
        constantDivisionByZero = false
        if let value = constantValue(node, tree: tree, tokens: tokens) { return value }
        if constantDivisionByZero || refersToRuntimeValue(node, tree: tree, tokens: tokens) {
            reportError("expression is not an integer constant expression", diagId: .semaConstantExprNotConstant, at: tree.token(of: node), in: tokens)
        }
        return nil
    }

    /// Compiler builtins, declared implicitly: `__builtin_*`, the GNU and C11 atomics, and the legacy `__sync_*`.
    private func isBuiltinFunctionName(_ name: String) -> Bool {
        name.hasPrefix("__builtin_") || name.hasPrefix("__atomic_") || name.hasPrefix("__c11_atomic_") || name.hasPrefix("__sync_")
    }

    /// Whether an expression where an integer constant expression is required certainly is not one: it reads an
    /// object or calls a function (outside `sizeof`/`alignof`), or has side effects. Constant forms the evaluator
    /// does not fold (GNU `(size_t)&((T *)0)->m`) are not flagged.
    private func refersToRuntimeValue(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        switch tree.kind(of: node) {
        case .identExpr:
            guard let sym = currentScope.lookupOrdinary(spelling(of: tree.token(of: node), in: tokens)),
                  constexprValues[sym.declId] == nil else { return false }
            switch sym.storage {
            case .global, .local, .param, .function: return true
            default: return false
            }
        case .unaryExpr:
            let op = CTokenKind(rawValue: tokens.kind(of: tree.token(of: node)))
            if op == .kwSizeof || op == .kwAlignof { return false }
            if op == .plusPlus || op == .minusMinus { return true }
        case .callExpr:
            guard let callee = tree.children(of: node).first, tree.kind(of: callee) == .identExpr,
                  isBuiltinFunctionName(spelling(of: tree.token(of: callee), in: tokens)) else { return true }
            return false
        case .assignExpr:
            return true
        default:
            break
        }
        return tree.children(of: node).contains { !isTypeNode(tree.kind(of: $0)) && refersToRuntimeValue($0, tree: tree, tokens: tokens) }
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

        case .varDecl, .typedefDecl:
            analyzeDeclaration(stmtNode, isFileScope: false, tree: tree, tokens: tokens)

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
            // Children: the clauses present (a declaration or expressions), then the body
            let children = tree.children(of: stmtNode)
            for (idx, child) in children.enumerated() {
                let ck = tree.kind(of: child)
                if idx == children.count - 1 || ck == .varDecl || ck == .typedefDecl || ck == .staticAssertDecl {
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
            if isFallthroughStatement(stmtNode, tree: tree, tokens: tokens) {
                checkFallthrough(stmtNode, tokens: tokens, tree: tree)
            }
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                _ = analyzeExpression(expr, tree: tree, tokens: tokens)
            }

        default:
            break
        }
    }

    /// `[[fallthrough]];` (or GNU `__attribute__((fallthrough));`): a null statement anchored at its attribute.
    private func isFallthroughStatement(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        guard tree.kind(of: node) == .exprStmt, tree.subtreeSize(of: node) == 1 else { return false }
        var i = Int(tree.token(of: node).rawIndex)
        guard CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) != .semicolon else { return false }
        while i < tokens.count, CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) != .semicolon {
            let word = spelling(of: TokenId(UInt32(i)), in: tokens)
            if word == "fallthrough" || word == "__fallthrough__" { return true }
            i += 1
        }
        return false
    }

    /// C23 6.7.13.5: a fallthrough declaration may appear only in a `switch`. (That the next statement executed is a
    /// `case` or `default` label is a flow-analysis diagnostic in Clang, a warning that is an error by default.)
    private mutating func checkFallthrough(_ node: NodeId, tokens: borrowing TokenBuffer, tree: borrowing ParseTree) {
        if switchStack.isEmpty {
            reportError("fallthrough annotation is outside switch statement", diagId: .semaInvalidDeclaration, at: tree.token(of: node), in: tokens,
                        args: ["fallthrough annotation is outside switch statement"])
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
            guard let literal = (kind == .charLiteral) ? characterConstant(txt) : integerConstant(txt) else {
                reportError("invalid integer constant '\(txt)'", diagId: .semaInvalidExpression, at: tok, in: tokens, args: ["invalid integer constant '\(txt)'"])
                nodeTypes[exprNode] = .int
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let type = QualType(typeId: literal.type)
            let res = container.block.appendIntLiteral(value: literal.signedValue, type: type, node: exprNode)
            nodeTypes[exprNode] = type.typeId
            return res

        case .floatLiteral:
            let tok = tree.token(of: exprNode)
            let txt = spelling(of: tok, in: tokens)
            guard let type = floatingConstantType(txt) else {
                reportError("invalid floating constant '\(txt)'", diagId: .semaInvalidExpression, at: tok, in: tokens, args: ["invalid floating constant '\(txt)'"])
                nodeTypes[exprNode] = .double
                return container.block.append(kind: .errorInst, type: .double, node: exprNode)
            }
            let val = Double(txt.replacingOccurrences(of: "'", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "fFlL"))) ?? 0.0
            let res = container.block.appendFloatLiteral(value: val, type: QualType(typeId: type), node: exprNode)
            nodeTypes[exprNode] = type
            return res

        case .stringLiteral:
            let tok = tree.token(of: exprNode)
            let unescaped = CLiteral.unescapedString(CLiteral.body(of: spelling(of: tok, in: tokens), quote: "\""))
            if stringLiterals[unescaped] == nil {
                stringLiterals[unescaped] = stringCounter
                stringCounter += 1
            }
            // An array of the encoding's code units, including the terminator (C23 6.4.5p6)
            let info = stringLiteralInfo(tok, tokens: tokens)
            let arrayType = typePool.arrayType(elementType: QualType(typeId: info.element), count: info.length)
            let res = container.block.appendStringLiteral(value: unescaped, type: QualType(typeId: arrayType), node: exprNode)
            nodeTypes[exprNode] = arrayType
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
                    return container.block.appendIntLiteral(value: val, type: sym.type, node: exprNode)
                default:
                    return container.block.append(kind: .declRef, type: sym.type, arg0: sym.declId.rawIndex, node: exprNode)
                }
            } else if isBuiltinFunctionName(name) ||
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
                // A member of a const- or volatile-qualified structure is so qualified (C23 6.5.2.3p3)
                let fieldType = QualType(rawValue: field.type.rawValue | UInt32(baseType.qualifiers & 0b011))
                nodeTypes[exprNode] = fieldType.typeId
                return container.block.append(kind: .memberRef, type: fieldType, arg0: baseInst.rawIndex, arg1: field.offset, node: exprNode)
            } else if !isTyped(baseInst) || baseType.isError {
                nodeTypes[exprNode] = .int
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            } else {
                reportError("no member named '\(memberName)' in struct", diagId: .semaInvalidMember, at: memberTok, in: tokens, args: [memberName, typeName(baseType.unqualified())])
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

            if opKind == .kwSizeof || opKind == .kwAlignof {
                let value = sizeOrAlignment(of: child, isAlignment: opKind == .kwAlignof, at: opTok, tree: tree, tokens: tokens)
                nodeTypes[exprNode] = .ulong
                return container.block.appendIntLiteral(value: value ?? 0, type: QualType(typeId: .ulong), node: exprNode)
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
            if tree.kind(of: children[1]) == .initList {
                // Compound literal `(T){ ... }`: an array of unknown size takes its length from the initializer
                if case .array(let element, 0) = canonicalKind(targetType),
                   let count = initializerLength(children[1], element: element, tree: tree, tokens: tokens) {
                    targetType = QualType(typeId: typePool.arrayType(elementType: element, count: count), qualifiers: targetType.qualifiers)
                }
            } else if isTyped(inner) && !targetType.isError {
                checkCast(from: typeOf(inner), to: targetType, at: tree.token(of: exprNode), tokens: tokens)
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

            // Argument count against the prototype (C23 6.5.2.2p2), for calls through functions and function pointers
            if let paramCount = calleeParamCount, !calleeName.hasPrefix("__builtin_"), !builtinNames.contains(calleeName) {
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
            checkScalarCondition(cond, at: tree.token(of: exprNode), tokens: tokens)
            var thenType = QualType.error
            if isTyped(thenInst) && isTyped(elseInst) {
                thenType = conditionalResultType(typeOf(thenInst), typeOf(elseInst), at: tree.token(of: exprNode), tokens: tokens)
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

    /// The type of `c ? a : b` (C23 6.5.15p3-7): the common arithmetic type, the common struct or union type, `void`,
    /// or a pointer type. A pointer may meet a null pointer constant, or (with a Clang warning) any integer or an
    /// incompatible pointer; other combinations are constraint violations.
    private mutating func conditionalResultType(_ a: QualType, _ b: QualType, at tok: TokenId, tokens: borrowing TokenBuffer) -> QualType {
        let l = decayed(a), r = decayed(b)
        let lPtr = typePool.isPointer(type: l.typeId), rPtr = typePool.isPointer(type: r.typeId)
        let lVoid = typePool.canonical(of: l.typeId) == .void, rVoid = typePool.canonical(of: r.typeId) == .void
        if typePool.isArithmetic(type: l.typeId) && typePool.isArithmetic(type: r.typeId) {
            return QualType(typeId: typePool.commonArithmeticType(l.typeId, r.typeId))
        }
        if isStructOrUnion(l) || isStructOrUnion(r) {
            if isStructOrUnion(l) && isStructOrUnion(r) && typesCompatible(l.unqualified(), r.unqualified()) { return l.unqualified() }
        } else if lVoid || rVoid {
            return .void
        } else if lPtr && rPtr {
            if case .nullptr = canonicalKind(l) { return r }
            return l
        } else if lPtr && typePool.isInteger(type: r.typeId) {
            return l
        } else if rPtr && typePool.isInteger(type: l.typeId) {
            return r
        }
        reportError("incompatible operand types in conditional expression", diagId: .semaInvalidExpression, at: tok, in: tokens,
                    args: ["incompatible operand types ('\(typeName(a))' and '\(typeName(b))')"])
        return .error
    }

    /// Explicit conversion constraints (C23 6.5.4p2-4): to `void`, or between scalar types, but not between a
    /// pointer and a floating type. GNU casts to a union from the type of one of its members are accepted.
    private mutating func checkCast(from source: QualType, to target: QualType, at tok: TokenId, tokens: borrowing TokenBuffer) {
        let src = decayed(source)
        // A cast to `void`, or to the operand's own type (a GNU extension for structures)
        if typePool.canonical(of: target.typeId) == .void || typesCompatible(target.unqualified(), src.unqualified()) { return }
        if case .struct(_, let fields, true) = canonicalKind(target),
           fields.contains(where: { typesCompatible($0.type.unqualified(), src.unqualified()) }) {
            return
        }
        let targetScalar = typePool.isScalar(type: target.typeId), sourceScalar = typePool.isScalar(type: src.typeId)
        let pointerFloat = (typePool.isPointer(type: target.typeId) && typePool.isFloating(type: src.typeId))
            || (typePool.isFloating(type: target.typeId) && typePool.isPointer(type: src.typeId))
        if !targetScalar || !sourceScalar || pointerFloat {
            reportError("invalid cast", diagId: .semaInvalidExpression, at: tok, in: tokens,
                        args: ["cannot cast '\(typeName(source))' to '\(typeName(target))'"])
        }
    }

    /// `sizeof` / `alignof` of a type name or an expression's type (C23 6.5.3.4): not a function type (GNU: 1) nor an
    /// incomplete type (GNU: `void` has size 1). Nil if the operand's type is not modeled.
    private mutating func sizeOrAlignment(of operand: NodeId, isAlignment: Bool, at tok: TokenId, tree: borrowing ParseTree,
                                          tokens: borrowing TokenBuffer) -> Int64? {
        let type: QualType
        if isTypeNode(tree.kind(of: operand)) {
            type = resolveType(from: operand, tree: tree, tokens: tokens)
        } else {
            let inner = analyzeExpression(operand, tree: tree, tokens: tokens)
            guard isTyped(inner) else { return nil }
            type = typeOf(inner)
        }
        guard !type.isError else { return nil }
        let can = typePool.canonical(of: type.typeId)
        if can == .void || isFunctionType(type) { return 1 }
        if !typePool.isComplete(can) {
            reportError("invalid application of 'sizeof' to an incomplete type", diagId: .semaInvalidExpression, at: tok, in: tokens,
                        args: ["invalid application of '\(isAlignment ? "alignof" : "sizeof")' to an incomplete type '\(typeName(type))'"])
            return nil
        }
        return Int64(isAlignment ? typePool.alignment(of: can) : typePool.size(of: can))
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

    /// An integer constant (C23 6.6) and its type. `bits` holds the value in two's complement, sign-extended from
    /// the type's width if the type is signed and zero-extended otherwise (types wider than 64 bits are truncated).
    private struct IntConst {
        var bits: UInt64
        var type: TypeId

        var signedValue: Int64 { Int64(bitPattern: bits) }
        var isNegative: Bool { signedValue < 0 }
        var fitsInt: Bool { signedValue >= Int64(Int32.min) && signedValue <= Int64(Int32.max) }
    }

    /// Width and signedness of an integer type (enumerations: of their underlying type), nil if not an integer type.
    private func integerTraits(_ t: TypeId) -> (width: Int, isSigned: Bool)? {
        switch typePool.typeInfo(of: typePool.canonical(of: t)).kind {
        case .int(let width, let isSigned): return (min(width, 64), isSigned)
        case .bool: return (1, false)
        case .enum(_, let underlying, _): return integerTraits(underlying)
        default: return nil
        }
    }

    /// The value `raw` converted to integer type `t` (C23 6.3.1.2-3): to `bool`, nonzero is 1; otherwise the
    /// value is reduced modulo 2^width, as GCC and Clang do for signed types too.
    private func makeConst(_ raw: UInt64, _ t: TypeId) -> IntConst {
        let can = typePool.canonical(of: t)
        guard let (width, isSigned) = integerTraits(can) else { return IntConst(bits: raw, type: can) }
        if case .bool = typePool.typeInfo(of: can).kind { return IntConst(bits: raw != 0 ? 1 : 0, type: can) }
        guard width < 64 else { return IntConst(bits: raw, type: can) }
        let masked = raw & ((1 << UInt64(width)) - 1)
        if isSigned && masked & (1 << UInt64(width - 1)) != 0 {
            return IntConst(bits: masked | ~((1 << UInt64(width)) - 1), type: can)
        }
        return IntConst(bits: masked, type: can)
    }

    private func convert(_ c: IntConst, to t: TypeId) -> IntConst {
        makeConst(c.bits, t)
    }

    /// Evaluates an integer constant expression (C23 6.6p8) with C's typing: literal types from their value and
    /// suffix, the integer promotions and usual arithmetic conversions, unsigned wrap-around, and `sizeof` of any
    /// expression or type. Nil if the expression is not one the evaluator can prove constant (including undefined
    /// operations such as division by zero), in which case callers do not diagnose on its account.
    private mutating func constantValue(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> IntConst? {
        switch tree.kind(of: node) {
        case .intLiteral:
            return integerConstant(spelling(of: tree.token(of: node), in: tokens))

        case .charLiteral:
            return characterConstant(spelling(of: tree.token(of: node), in: tokens))

        case .boolLiteral:
            return IntConst(bits: spelling(of: tree.token(of: node), in: tokens) == "true" ? 1 : 0, type: .bool)

        case .identExpr:
            let name = spelling(of: tree.token(of: node), in: tokens)
            guard let sym = currentScope.lookupOrdinary(name) else { return nil }
            if let value = constexprValues[sym.declId] { return value }
            guard case .enumConstant(let value) = sym.storage else { return nil }
            return makeConst(UInt64(bitPattern: value), sym.type.typeId)

        case .castExpr:
            let children = tree.children(of: node)
            guard children.count == 2, tree.kind(of: children[1]) != .initList else { return nil }
            let target = resolveType(from: children[0], tree: tree, tokens: tokens)
            guard integerTraits(target.typeId) != nil else { return nil }
            // A floating constant may be the immediate operand of a cast (C23 6.6p8)
            if tree.kind(of: children[1]) == .floatLiteral {
                let text = spelling(of: tree.token(of: children[1]), in: tokens).filter { $0 != "'" }
                guard let d = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "fFlL"))), d.isFinite,
                      d > -9.3e18, d < 1.8e19 else { return nil }
                return makeConst(d < 0 ? UInt64(bitPattern: Int64(d)) : UInt64(d), target.typeId)
            }
            guard let value = constantValue(children[1], tree: tree, tokens: tokens) else { return nil }
            return convert(value, to: target.typeId)

        case .unaryExpr:
            guard let child = tree.children(of: node).first else { return nil }
            let opTok = tree.token(of: node)
            let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken
            if opKind == .kwSizeof || opKind == .kwAlignof {
                guard let n = sizeOrAlignment(of: child, isAlignment: opKind == .kwAlignof, at: opTok, tree: tree, tokens: tokens) else { return nil }
                return IntConst(bits: UInt64(n), type: .ulong)
            }
            guard let operand = constantValue(child, tree: tree, tokens: tokens) else { return nil }
            let promoted = convert(operand, to: typePool.promote(type: operand.type))
            switch opKind {
            case .plus: return promoted
            case .minus: return makeConst(0 &- promoted.bits, promoted.type)
            case .tilde: return makeConst(~promoted.bits, promoted.type)
            case .exclaim: return IntConst(bits: operand.bits == 0 ? 1 : 0, type: .int)
            default: return nil
            }

        case .binaryExpr:
            let children = tree.children(of: node)
            guard children.count == 2 else { return nil }
            let opKind = CTokenKind(rawValue: tokens.kind(of: tree.token(of: node))) ?? .errorToken
            guard let l = constantValue(children[0], tree: tree, tokens: tokens) else { return nil }
            // `&&` and `||` do not evaluate their second operand when the first decides the result
            if opKind == .ampAmp && l.bits == 0 { return IntConst(bits: 0, type: .int) }
            if opKind == .pipePipe && l.bits != 0 { return IntConst(bits: 1, type: .int) }
            guard let r = constantValue(children[1], tree: tree, tokens: tokens) else { return nil }
            return binaryConstant(opKind, l, r)

        case .conditionalExpr:
            let children = tree.children(of: node)
            guard children.count == 3 || children.count == 2, let c = constantValue(children[0], tree: tree, tokens: tokens),
                  let a = children.count == 3 ? constantValue(children[1], tree: tree, tokens: tokens) : c,
                  let b = constantValue(children[children.count - 1], tree: tree, tokens: tokens) else { return nil }
            let common = typePool.commonArithmeticType(a.type, b.type)
            return convert(c.bits != 0 ? a : b, to: common)

        case .commaExpr:
            guard let last = tree.children(of: node).last else { return nil }
            return constantValue(last, tree: tree, tokens: tokens)

        case .callExpr:
            let children = tree.children(of: node)
            guard let callee = children.first, tree.kind(of: callee) == .identExpr, children.count > 1 else { return nil }
            let calleeName = spelling(of: tree.token(of: callee), in: tokens)
            let args = tree.children(of: children[1])
            // Lock-free atomics of 1, 2, 4 and 8 bytes on the supported 64-bit targets
            if calleeName == "__atomic_always_lock_free" || calleeName == "__c11_atomic_is_lock_free", let size = args.first,
               let n = constantValue(size, tree: tree, tokens: tokens) {
                return IntConst(bits: [1, 2, 4, 8].contains(n.bits) ? 1 : 0, type: .bool)
            }
            // `offsetof(T, m)` expands to `__builtin_offsetof(T, member-designator)`
            guard calleeName == "__builtin_offsetof" else { return nil }
            guard args.count == 2, isTypeNode(tree.kind(of: args[0])) else { return nil }
            let base = resolveType(from: args[0], tree: tree, tokens: tokens)
            guard let offset = memberOffset(of: args[1], in: base, tree: tree, tokens: tokens)?.offset else { return nil }
            return IntConst(bits: UInt64(bitPattern: offset), type: .ulong)

        default:
            return nil
        }
    }

    /// A binary operator over integer constants: the usual arithmetic conversions, then the operation in the
    /// common type (shifts: in the promoted left operand's type; comparisons and logical operators: `int`).
    private mutating func binaryConstant(_ op: CTokenKind, _ l: IntConst, _ r: IntConst) -> IntConst? {
        if op == .ampAmp || op == .pipePipe {
            return IntConst(bits: (op == .ampAmp ? (l.bits != 0 && r.bits != 0) : (l.bits != 0 || r.bits != 0)) ? 1 : 0, type: .int)
        }
        if op == .lessLess || op == .greaterGreater {
            let left = convert(l, to: typePool.promote(type: l.type))
            guard let (width, isSigned) = integerTraits(left.type), !r.isNegative || integerTraits(r.type)?.isSigned == false,
                  r.bits < UInt64(width) else { return nil }
            if op == .lessLess { return makeConst(left.bits << r.bits, left.type) }
            return makeConst(isSigned ? UInt64(bitPattern: left.signedValue >> Int64(r.bits)) : left.bits >> r.bits, left.type)
        }
        let common = typePool.commonArithmeticType(l.type, r.type)
        guard let (_, isSigned) = integerTraits(common) else { return nil }
        let a = convert(l, to: common), b = convert(r, to: common)
        func truth(_ value: Bool) -> IntConst { IntConst(bits: value ? 1 : 0, type: .int) }
        switch op {
        case .plus: return makeConst(a.bits &+ b.bits, common)
        case .minus: return makeConst(a.bits &- b.bits, common)
        case .star: return makeConst(a.bits &* b.bits, common)
        case .slash, .percent:
            guard b.bits != 0 else {
                constantDivisionByZero = true
                return nil
            }
            if isSigned {
                // `INT_MIN / -1` overflows: Clang folds it (with a warning) to the wrapped value
                let q = op == .slash ? a.signedValue.dividedReportingOverflow(by: b.signedValue).partialValue
                                     : a.signedValue.remainderReportingOverflow(dividingBy: b.signedValue).partialValue
                return makeConst(UInt64(bitPattern: q), common)
            }
            return makeConst(op == .slash ? a.bits / b.bits : a.bits % b.bits, common)
        case .amp: return makeConst(a.bits & b.bits, common)
        case .pipe: return makeConst(a.bits | b.bits, common)
        case .caret: return makeConst(a.bits ^ b.bits, common)
        case .equalEqual: return truth(a.bits == b.bits)
        case .exclaimEqual: return truth(a.bits != b.bits)
        case .less: return truth(isSigned ? a.signedValue < b.signedValue : a.bits < b.bits)
        case .lessEqual: return truth(isSigned ? a.signedValue <= b.signedValue : a.bits <= b.bits)
        case .greater: return truth(isSigned ? a.signedValue > b.signedValue : a.bits > b.bits)
        case .greaterEqual: return truth(isSigned ? a.signedValue >= b.signedValue : a.bits >= b.bits)
        default: return nil
        }
    }

    /// Value of an integer constant expression as `Int64` (0 if not constant).
    public mutating func evaluateIntegerConstant(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Int64 {
        constantValue(node, tree: tree, tokens: tokens)?.signedValue ?? 0
    }

    /// An integer constant's value and type (C23 6.4.4.1p6): the first of the candidate types for its suffix and
    /// base that can represent it; `wb`/`uwb` give the narrowest `_BitInt(N)`. Nil if the spelling is invalid.
    private func integerConstant(_ raw: String) -> IntConst? {
        guard let (value, _) = CLiteral.integerValue(raw) else { return nil }
        // Suffix letters, read backwards: `u`, `l`/`ll`, `wb` (hexadecimal digits never end in these)
        let bytes = Array(raw.utf8)
        var end = bytes.count
        var isUnsigned = false, isBitPrecise = false, longs = 0
        while end > 0 {
            let c = bytes[end - 1] | 0x20  // ASCII lowercase
            if c == UInt8(ascii: "b") && end > 1 && bytes[end - 2] | 0x20 == UInt8(ascii: "w") {
                isBitPrecise = true
                end -= 2
            } else if c == UInt8(ascii: "u") || c == UInt8(ascii: "l") {
                if c == UInt8(ascii: "u") { isUnsigned = true }
                if c == UInt8(ascii: "l") { longs += 1 }
                end -= 1
            } else {
                break
            }
        }
        // Valid suffixes (C23 6.4.4.1): `ll` and `wb` must not mix case
        if end < bytes.count {
            let suffix = bytes[end...]
            func sameCase(_ letters: [UInt8]) -> Bool {
                let found = suffix.filter { letters.contains($0 | 0x20) }
                return found.allSatisfy { $0 & 0x20 == found.first! & 0x20 }
            }
            guard Self.integerSuffixes.contains(String(decoding: suffix.map { $0 | 0x20 }, as: UTF8.self)),
                  sameCase([UInt8(ascii: "l")]), sameCase([UInt8(ascii: "w"), UInt8(ascii: "b")]) else { return nil }
        }
        guard end > 0, (bytes[end - 1] >= UInt8(ascii: "0") && bytes[end - 1] <= UInt8(ascii: "9"))
                || (bytes[end - 1] | 0x20 >= UInt8(ascii: "a") && bytes[end - 1] | 0x20 <= UInt8(ascii: "f")) else { return nil }
        let isDecimal = bytes[0] != UInt8(ascii: "0") || end == 1
        if isBitPrecise {
            // The narrowest `_BitInt(N)` (C23 6.4.4.1p6): N counts a sign bit unless unsigned
            let magnitudeBits = max(1, 64 - value.leadingZeroBitCount)
            return IntConst(bits: value, type: typePool.integerType(width: isUnsigned ? magnitudeBits : magnitudeBits + 1, isSigned: !isUnsigned))
        }
        let candidates: [TypeId]
        switch (longs, isUnsigned) {
        case (0, false): candidates = isDecimal ? Self.decimalCandidates : Self.nonDecimalCandidates
        case (0, true): candidates = [.uint, .ulong, .ulonglong]
        case (1, false): candidates = isDecimal ? [.long, .longlong] : [.long, .ulong, .longlong, .ulonglong]
        case (1, true): candidates = [.ulong, .ulonglong]
        case (_, false): candidates = isDecimal ? [.longlong] : [.longlong, .ulonglong]
        case (_, true): candidates = [.ulonglong]
        }
        for t in candidates {
            let (width, isSigned) = integerTraits(t)!
            let limit: UInt64 = isSigned ? UInt64(1) << UInt64(width - 1) : (width == 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1)
            if isSigned ? value < limit : value <= limit {
                return IntConst(bits: value, type: t)
            }
        }
        // A decimal constant too large for every signed candidate is `unsigned long long` in Clang (with a warning)
        return IntConst(bits: value, type: .ulonglong)
    }

    private static let integerSuffixes: Set<String> = ["u", "l", "ul", "lu", "ll", "ull", "llu", "wb", "uwb", "wbu"]
    private static let decimalCandidates: [TypeId] = [.int, .long, .longlong]
    private static let nonDecimalCandidates: [TypeId] = [.int, .uint, .long, .ulong, .longlong, .ulonglong]

    /// A floating constant's type (C23 6.4.4.2): `double`, `float` with `f`, `long double` with `l` (`_FloatN`
    /// suffixes are approximated). Nil if it is malformed: stray characters, an exponent without digits, or a
    /// hexadecimal constant without its binary exponent.
    private func floatingConstantType(_ raw: String) -> TypeId? {
        var bytes = Array(raw.utf8).filter { $0 != UInt8(ascii: "'") }.map { $0 | 0x20 }
        var type: TypeId = .double
        let isHex = bytes.count > 1 && bytes[0] == UInt8(ascii: "0") && bytes[1] == UInt8(ascii: "x")
        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
        func isMantissaDigit(_ c: UInt8) -> Bool { isDigit(c) || (isHex && c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")) }
        for (suffix, t) in [("f16", TypeId.float), ("f32", .float), ("f64", .double), ("f128", .longdouble), ("f32x", .double), ("f64x", .longdouble)]
            where bytes.count > suffix.utf8.count && bytes.suffix(suffix.utf8.count).elementsEqual(suffix.utf8) {
            bytes.removeLast(suffix.utf8.count)
            type = t
            break
        }
        // A trailing `f` is a suffix unless it is a hexadecimal digit (no binary exponent yet)
        if type == .double, let last = bytes.last, last == UInt8(ascii: "l") || (last == UInt8(ascii: "f") && (!isHex || bytes.contains(UInt8(ascii: "p")))) {
            type = last == UInt8(ascii: "f") ? .float : .longdouble
            bytes.removeLast()
        }
        var i = isHex ? 2 : 0
        var mantissaDigits = 0
        while i < bytes.count && isMantissaDigit(bytes[i]) { i += 1; mantissaDigits += 1 }
        if i < bytes.count && bytes[i] == UInt8(ascii: ".") { i += 1 }
        while i < bytes.count && isMantissaDigit(bytes[i]) { i += 1; mantissaDigits += 1 }
        guard mantissaDigits > 0 else { return nil }
        if i == bytes.count { return isHex ? nil : type }
        guard bytes[i] == UInt8(ascii: isHex ? "p" : "e") else { return nil }
        i += 1
        if i < bytes.count && (bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-")) { i += 1 }
        guard i < bytes.count, bytes[i...].allSatisfy(isDigit) else { return nil }
        return type
    }

    /// A character constant's value and type (C23 6.4.4.5): `int` unprefixed or `L` (`wchar_t`), `char8_t`
    /// (`unsigned char`) for `u8`, `char16_t` (`unsigned short`) for `u`, `char32_t` (`unsigned int`) for `U`.
    private func characterConstant(_ raw: String) -> IntConst? {
        let value = UInt64(bitPattern: CLiteral.characterValue(raw))
        if raw.hasPrefix("u8") { return makeConst(value, .uchar) }
        if raw.hasPrefix("u") { return makeConst(value, .ushort) }
        if raw.hasPrefix("U") { return makeConst(value, .uint) }
        return makeConst(value, .int)
    }

    /// A string literal and the adjacent literals concatenated with it (C23 6.4.5): its element type (from the
    /// encoding prefix) and its length in elements, including the terminating null.
    private func stringLiteralInfo(_ first: TokenId, tokens: borrowing TokenBuffer) -> (element: TypeId, length: UInt64) {
        var element: TypeId = .char
        var units: UInt64 = 0
        var i = Int(first.rawIndex)
        var pieces: [String] = []
        while i < tokens.count, CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) == .stringLiteral {
            let text = spelling(of: TokenId(UInt32(i)), in: tokens)
            if text.hasPrefix("u8") { element = .uchar }
            else if text.hasPrefix("u") { element = .ushort }
            else if text.hasPrefix("U") || text.hasPrefix("L") { element = text.hasPrefix("U") ? .uint : .int }
            pieces.append(text)
            i += 1
        }
        for text in pieces {
            let body = CLiteral.body(of: text, quote: "\"")
            switch element {
            case .char, .uchar: units += UInt64(CLiteral.stringBytes(body).count)
            case .ushort: units += UInt64(CLiteral.decodeEscapes(body).reduce(0) { $0 + ($1 > 0xFFFF ? 2 : 1) })
            default: units += UInt64(CLiteral.decodeEscapes(body).count)
            }
        }
        return (element, units + 1)
    }
}
