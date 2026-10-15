// Sources/SwiftStack/Sem/CSemanticAnalyzer.swift
import Foundation

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
    private var dataLayout: DataLayout { typePool.dataLayout }

    // Module-wide SemIR structures
    private var declTable: DeclTable
    private var instBlocks: [SemInstBlockContainer] = []
    private var diagnosticBag: DiagnosticBag
    private var semFunctions: [SemFunction] = []
    private var semGlobals: [SemGlobal] = []
    /// Index into `semGlobals` of each file-scope object name's definition (or tentative definition).
    private var globalIndexByName: [String: Int] = [:]
    private var staticSymbols: [DeclId: String] = [:]
    /// Explicit alignments (`alignas`, `aligned`) of objects.
    private var objectAlignments: [DeclId: Int] = [:]

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
    private var currentReturnType: QualType = .void
    private var currentBlockContainer: SemInstBlockContainer? = nil
    private var currentBlockId: InstBlockId = .nilId
    private var currentFunctionDecl: DeclId = .nilId
    /// Nesting of operands that are not evaluated (`sizeof`, `alignof`, `typeof`, `_Generic`'s controlling
    /// expression): their instructions are discarded, so they must not register objects.
    private var unevaluatedDepth = 0
    /// Instructions of expressions outside function bodies (initializers, `typeof`, `sizeof` operands), so that
    /// they are typed and checked like any other; the module's `fileScopeBlock`.
    private let fileScopeContainer = SemInstBlockContainer(block: SemInstBlock(reservedCapacity: 1 << 23))
    /// Resolved parameter lists by `paramList` node.
    private var parameterLists: [NodeId: ParameterList] = [:]
    /// Values of `constexpr` objects of integer type, which are integer constant expressions.
    private var constexprValues: [DeclId: IntConst] = [:]
    /// Set when constant evaluation divides by zero: the expression is then not an integer constant expression.
    private var constantDivisionByZero = false
    /// File-scope object definitions without an initializer whose type is incomplete where they are declared.
    private var tentativeDefinitions: [(name: String, type: QualType, tok: TokenId)] = []
    /// Lengths of the variable length array types elaborated since the last declaration took them: (VLA type, length
    /// as `size_t`), outermost first.
    private var pendingVLALengths: [(type: TypeId, length: SemInstId)] = []

    // Constraint-checking state (C23 6.8.4.2 switch, 6.8.6 jumps, 6.9 external definitions)
    private var loopDepth: Int = 0
    private var switchStack: [SwitchContext] = []
    private var functionLabels: [String: TokenId] = [:]
    /// Label numbers of the current function (`SemInstKind.label`), by name; `labelNames[n]` is label n's name.
    private var labelNumbers: [String: UInt32] = [:]
    private var labelNames: [String] = [""]
    private var pendingGotos: [(name: String, tok: TokenId)] = []
    private var definedFunctions: Set<String> = []
    private var initializedGlobals: Set<String> = []
    private var currentFunctionName: String = ""
    /// Names of the compiler-provided declarations (`write`, `exit`), which headers may redeclare.
    private var builtinNames: Set<String> = ["write", "exit"]

    /// A `switch` being analyzed: the case values seen (for duplicates), its labels, and the promoted type of its
    /// controlling expression.
    private struct SwitchContext {
        var values: Set<Int64> = []
        var hasDefault = false
        var cases: [UInt32] = []
        var defaultLabel: SemInstId = .nilId
        var controlType: QualType = .int
    }

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
        let nilBlock = SemInstBlock(reservedCapacity: 16)
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
        let writeDecl = declTable.append(kind: .function, name: "write", type: QualType(typeId: writeType),
                                         attrs: DeclAttributes(storage: .external).rawValue)
        currentScope.insertOrdinary(symbol: CSymbol(name: "write", declId: writeDecl, type: QualType(typeId: writeType), storage: .function(name: "write")))

        // void exit(int status)
        let exitType = typePool.functionType(returnType: .void, paramTypes: [.int])
        let exitDecl = declTable.append(kind: .function, name: "exit", type: QualType(typeId: exitType),
                                        attrs: DeclAttributes(storage: .external).rawValue)
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
                var none: [UInt32] = []
                analyzeDeclaration(decl, isFileScope: true, into: &none, tree: tree, tokens: tokens)
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
            diagnosticBag: consume diagnosticBag,
            fileScopeBlock: fileScopeContainer
        )
        finalMod.functions = semFunctions
        finalMod.globals = semGlobals
        finalMod.staticSymbols = staticSymbols

        // Data images of the static-storage objects (C23 6.7.10p10)
        var evaluator = StaticInitializerEvaluator(module: finalMod)
        for i in finalMod.globals.indices {
            switch evaluator.evaluate(finalMod.globals[i]) {
            case .image(let image):
                finalMod.globals[i].image = image
            case .notConstant(let reason, let node):
                finalMod.globals[i].unsupportedReason = reason
                let tok = tree.token(of: node)
                let loc = tok.isValid ? tokens.start(of: tok) : .zero
                diagnostics.append("initializer element is not a compile-time constant")
                finalMod.diagnosticBag.report(.semaConstantExprNotConstant, at: GlobalLocation(unitId: UnitId(1), location: loc), args: [])
            case .unsupported(let reason):
                finalMod.globals[i].unsupportedReason = reason
            }
        }
        finalMod.staticStrings = evaluator.staticStrings

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
        var isThreadLocal = false
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
            // The operand is not evaluated (C23 6.7.3.6p4): its instructions are discarded
            let t = sizeofOperandType(first, tree: tree, tokens: tokens) ?? .error
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
                case .kwThreadLocal: spec.isThreadLocal = true; continue
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
                    case "__builtin_va_list", "__gnuc_va_list":
                        named = QualType(typeId: typePool.builtinVaListType())
                    case "_Decimal32", "_Decimal64", "_Decimal128":
                        named = .error  // unsupported: unmodeled, so no check relies on it
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
            // C23 6.7.3.1: `_BitInt(N)` needs N >= 2 (N >= 1 if unsigned), up to the target's BITINT_MAXWIDTH (02 §4.2.2)
            let maxWidth = dataLayout.bitIntMaxWidth
            if let width, width >= (unsigned ? 1 : 2), width <= maxWidth {
                base = QualType(typeId: typePool.integerType(width: width, isSigned: !unsigned))
            } else {
                if width != nil {
                    reportError("invalid _BitInt width", diagId: .semaInvalidDeclaration, at: tok, in: tokens,
                                args: ["\(unsigned ? "unsigned" : "signed") _BitInt must have a bit size of at least \(unsigned ? 1 : 2) and at most \(maxWidth)"])
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
        if let sizeNode = tree.children(of: suffix).first(where: { tree.kind(of: $0) != .specifier && tree.kind(of: $0) != .attributeSpec }) {
            constantDivisionByZero = false
            if let size = constantValue(sizeNode, tree: tree, tokens: tokens) {
                if size.isNegative {
                    reportError("array has a negative size", diagId: .semaInvalidDeclaration, at: tok, in: tokens, args: ["array declared with a negative size"])
                    return .error
                }
                count = size.bits
            } else {
                let isVLA = constantDivisionByZero || refersToRuntimeValue(sizeNode, tree: tree, tokens: tokens)
                // A variable length: type-check the size, which the declaration evaluates
                let length = analyzeExpression(sizeNode, tree: tree, tokens: tokens)
                if isVLA {
                    isVariableLength = true
                    let vla = typePool.variableLengthArrayType(elementType: element)
                    pendingVLALengths.append((vla, convertImplicitly(rvalue(length), to: QualType(typeId: dataLayout.sizeType),
                                                                     reason: .assignConvert, node: sizeNode)))
                    return QualType(typeId: vla)
                }
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
                prototypeScope.insertOrdinary(symbol: CSymbol(name: name, type: type, storage: .param(index: result.types.count - 1)))
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

    /// A declaration (C23 6.7): `declSpecs`, then each declarator followed by its initializer, if any. At block scope,
    /// the statements it executes (a `declLocal` per automatic object) are appended to `stmts`.
    private mutating func analyzeDeclaration(_ node: NodeId, isFileScope: Bool, into stmts: inout [UInt32], tree: borrowing ParseTree,
                                             tokens: borrowing TokenBuffer) {
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
            pendingVLALengths.removeAll()
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
            let alignment = explicitAlignment(attributes, tree: tree, tokens: tokens)
            if spec.isTypedef {
                let declId = declareTypedef(name, type: type, alignment: alignment, at: nameTok, tokens: tokens)
                // A variably modified typedef evaluates its lengths where it is declared (C23 6.7.8p3)
                if !isFileScope && !pendingVLALengths.isEmpty {
                    stmts.append(emitLocalDeclaration(declId, initializer: .nilId, node: declarator).rawIndex)
                }
            } else if isFunctionType(type) {
                if let initializer {
                    reportError("illegal initializer", diagId: .semaInvalidDeclaration, at: tree.token(of: initializer), in: tokens,
                                args: ["illegal initializer (only variables can be initialized)"])
                }
                _ = declareFunction(name, type: type, isStatic: spec.isStatic, at: nameTok, tokens: tokens)
            } else {
                declareVariable(name, type: type, spec: spec, declarator: declarator, initializer: initializer, isFileScope: isFileScope,
                                alignment: alignment, at: nameTok, into: &stmts, tree: tree, tokens: tokens)
            }
        }
        pendingVLALengths.removeAll()
    }

    /// A `declLocal` statement for `decl`, taking the VLA lengths elaborated by its declarator.
    private mutating func emitLocalDeclaration(_ decl: DeclId, initializer: SemInstId, node: NodeId) -> SemInstId {
        var items: [UInt32] = [initializer.rawIndex, UInt32(pendingVLALengths.count)]
        for (type, length) in pendingVLALengths { items += [type.rawIndex, length.rawIndex] }
        pendingVLALengths.removeAll()
        return emitList(.declLocal, .void, arg0: decl.rawIndex, items: items, node: node)
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

    /// The alignment requested by `alignas(N)`, `alignas(T)` or `__attribute__((aligned(N)))` among `attributes` (the
    /// largest; a bare `aligned` is the target's largest alignment), or nil if none is.
    private mutating func explicitAlignment(_ attributes: [NodeId], tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Int? {
        var result: Int? = nil
        func raise(_ n: Int) { if n > 0 { result = max(result ?? 1, n) } }
        for attr in attributes where tree.kind(of: attr) == .attributeSpec {
            let anchor = tree.token(of: attr)
            if CTokenKind(rawValue: tokens.kind(of: anchor)) == .kwAlignas {
                guard let operand = tree.children(of: attr).first else { continue }
                if tree.kind(of: operand) == .typeName {
                    let t = resolveType(from: operand, tree: tree, tokens: tokens)
                    if !t.isError { raise(typePool.alignment(of: t.typeId)) }
                } else if let n = constantValue(operand, tree: tree, tokens: tokens), !n.isNegative {
                    raise(Int(clamping: n.bits))
                }
                continue
            }
            // `__attribute__((aligned(N)))`: each argument is a child; `aligned` without one is the largest alignment
            for operand in tree.children(of: attr) {
                if let n = constantValue(operand, tree: tree, tokens: tokens), !n.isNegative { raise(Int(clamping: n.bits)) }
            }
            var i = Int(anchor.rawIndex) + 1
            var depth = 0
            repeat {
                guard i + 1 < tokens.count else { break }
                let tok = TokenId(UInt32(i))
                switch CTokenKind(rawValue: tokens.kind(of: tok)) {
                case .lParen: depth += 1
                case .rParen: depth -= 1
                case .identifier:
                    let word = spelling(of: tok, in: tokens)
                    if (word == "aligned" || word == "__aligned__") && CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i + 1)))) != .lParen {
                        raise(dataLayout.maxAlignment)
                    }
                default: break
                }
                i += 1
            } while depth > 0
        }
        return result
    }

    @discardableResult
    private mutating func declareTypedef(_ name: String, type: QualType, alignment: Int? = nil, at nameTok: TokenId, tokens: borrowing TokenBuffer) -> DeclId {
        let typedefTypeId = typePool.typedefType(name: name, underlying: type, alignment: alignment)
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
        return declId
    }

    /// Declares a function; redeclarations in the same scope must have compatible types (C23 6.7p4).
    private mutating func declareFunction(_ name: String, type: QualType, isStatic: Bool, isDefinition: Bool = false, at nameTok: TokenId,
                                          tokens: borrowing TokenBuffer) -> DeclId {
        var isStatic = isStatic
        if !builtinNames.contains(name), let prior = currentScope.lookupLocalOrdinary(name) {
            if !typesCompatible(prior.type, type) {
                reportError("conflicting types for '\(name)'", diagId: .semaRedeclaration, at: nameTok, in: tokens, args: [name])
            }
            // A redeclaration keeps the linkage of the prior declaration (C23 6.2.2p5)
            if case .function = prior.storage, DeclAttributes(rawValue: declTable.attrs[prior.declId]).storage == .internalStatic {
                isStatic = true
            }
        }
        let declId = declTable.append(
            kind: .function,
            name: name,
            type: type,
            origin: GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok)),
            attrs: DeclAttributes(storage: isStatic ? .internalStatic : .external, isDefinition: isDefinition).rawValue
        )
        currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: type, storage: .function(name: name)))
        return declId
    }

    /// Records a file-scope object definition or tentative definition, keeping one per name: a definition replaces
    /// a tentative one (C23 6.9.2p2).
    private mutating func registerFileScopeObject(_ global: SemGlobal) {
        if let i = globalIndexByName[global.symbol] {
            if semGlobals[i].isTentative && !global.isTentative { semGlobals[i] = global }
            return
        }
        globalIndexByName[global.symbol] = semGlobals.count
        semGlobals.append(global)
    }

    private mutating func declareVariable(_ name: String, type declaredType: QualType, spec: DeclSpecs, declarator: NodeId, initializer: NodeId?,
                                          isFileScope: Bool, alignment: Int?, at nameTok: TokenId, into stmts: inout [UInt32],
                                          tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        var varType = declaredType
        // An array of unknown size is completed by its initializer (C23 6.7.10p22)
        if let initializer, case .array(let element, 0) = canonicalKind(varType), !typePool.isVariableLengthArray(varType.typeId),
           let count = initializerLength(initializer, element: element, tree: tree, tokens: tokens) {
            varType = QualType(typeId: typePool.arrayType(elementType: element, count: count), qualifiers: varType.qualifiers)
        }
        let isVoid = !varType.isError && typePool.canonical(of: varType.typeId) == .void
        let isIncomplete = !spec.infersType && !varType.isError && !typePool.isComplete(varType.typeId)
        let origin = GlobalLocation(unitId: UnitId(1), location: tokens.start(of: nameTok))
        let objectAlignment = max(alignment ?? 1, varType.isError ? 1 : typePool.alignment(of: varType.typeId))

        if isFileScope {
            // C23 6.7p4 / 6.9.2: redeclarations must have compatible types; at most one external definition
            var isStatic = spec.isStatic
            if let prior = currentScope.lookupLocalOrdinary(name), !builtinNames.contains(name) {
                switch prior.storage {
                case .global, .function:
                    if !typesCompatible(prior.type.unqualified(), varType.unqualified()) {
                        reportError("redefinition of '\(name)' with a different type", diagId: .semaRedeclaration, at: nameTok, in: tokens, args: [name])
                    }
                    if DeclAttributes(rawValue: declTable.attrs[prior.declId]).storage == .internalStatic { isStatic = true }
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
            let attrs = DeclAttributes(storage: isStatic ? .internalStatic : .external, isThreadLocal: spec.isThreadLocal,
                                       isDefinition: initializer != nil || !spec.isExtern)
            let declId = declTable.append(kind: .variable, name: name, type: varType, origin: origin, attrs: attrs.rawValue)
            if let alignment { objectAlignments[declId] = alignment }
            var initInst = SemInstId.nilId
            if let initializer {
                if !initializedGlobals.insert(name).inserted {
                    reportError("redefinition of '\(name)'", diagId: .semaRedefinition, at: nameTok, in: tokens, args: [name])
                }
                // The identifier is in scope in its own initializer: `void *__dso_handle = &__dso_handle;`
                if !spec.infersType && currentScope.lookupLocalOrdinary(name) == nil {
                    currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: varType, storage: .global(name: name)))
                }
                let resolved = resolveVariableInitializer(initializer, type: varType, infersType: spec.infersType, tree: tree, tokens: tokens)
                initInst = resolved.inst
                if !isConstantInitializer(initializer, tree: tree, tokens: tokens) {
                    reportError("initializer element is not a compile-time constant", diagId: .semaConstantExprNotConstant, at: tree.token(of: initializer), in: tokens)
                    initInst = .nilId  // diagnosed: no image
                } else if tree.kind(of: initializer) != .initList && !spec.infersType {
                    checkAssignment(to: varType, from: resolved.raw, rhsNode: initializer, tree: tree, tokens: tokens)
                }
                varType = resolved.type
                declTable.setType(for: declId, type: varType)
            }
            if initializer != nil || !spec.isExtern {
                registerFileScopeObject(SemGlobal(
                    declId: declId, symbol: name, type: varType, isExternal: !isStatic, isThreadLocal: spec.isThreadLocal,
                    alignment: max(objectAlignment, alignment ?? 1), initBlock: .nilId, initInst: initInst, isTentative: initializer == nil))
            }

            let sym = CSymbol(name: name, declId: declId, type: varType, storage: .global(name: name))
            currentScope.insertOrdinary(symbol: sym)
            symbolRefs[declarator] = sym
            recordConstexprValue(declId, spec: spec, type: varType, initializer: initializer, tree: tree, tokens: tokens)
            return
        }

        if spec.isExtern {
            let declId = declTable.append(kind: .variable, name: name, type: varType, origin: origin,
                                          attrs: DeclAttributes(storage: .external, isThreadLocal: spec.isThreadLocal).rawValue)
            currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: varType, storage: .global(name: name)))
            return
        }
        checkBlockScopeRedefinition(name, at: nameTok, tokens: tokens)
        if isVoid || isIncomplete {
            reportError("variable has incomplete type", diagId: .semaIncompleteType, at: nameTok, in: tokens, args: [typeName(varType)])
        }

        let storage: CSymbolStorage = spec.isStatic ? .staticLocal : .local
        let attrs = DeclAttributes(storage: spec.isStatic ? .internalStatic : .automatic, isThreadLocal: spec.isThreadLocal, isDefinition: true)
        let declId = declTable.append(kind: .variable, name: name, parent: currentFunctionDecl, type: varType, origin: origin, attrs: attrs.rawValue)
        if let alignment { objectAlignments[declId] = alignment }
        let vlaLengths = pendingVLALengths
        pendingVLALengths.removeAll()

        // Pre-insert the symbol so `int *p = malloc(sizeof *p)` resolves `p` in its own initializer
        if !spec.infersType {
            currentScope.insertOrdinary(symbol: CSymbol(name: name, declId: declId, type: varType, storage: storage))
        }

        var initInst = SemInstId.nilId
        if let initializer {
            let resolved = resolveVariableInitializer(initializer, type: varType, infersType: spec.infersType, tree: tree, tokens: tokens)
            initInst = resolved.inst
            if spec.isStatic && !isConstantInitializer(initializer, tree: tree, tokens: tokens) {
                reportError("initializer element is not a compile-time constant", diagId: .semaConstantExprNotConstant, at: tree.token(of: initializer), in: tokens)
                initInst = .nilId
            }
            if !spec.infersType && tree.kind(of: initializer) != .initList {
                checkAssignment(to: varType, from: resolved.raw, rhsNode: initializer, tree: tree, tokens: tokens)
            }
            varType = resolved.type
            declTable.setType(for: declId, type: varType)
        }

        let sym = CSymbol(name: name, declId: declId, type: varType, storage: storage)
        currentScope.insertOrdinary(symbol: sym)
        symbolRefs[declarator] = sym
        nodeTypes[declarator] = varType.typeId
        recordConstexprValue(declId, spec: spec, type: varType, initializer: initializer, tree: tree, tokens: tokens)

        if spec.isStatic {
            // A block-scope static is an object of the unit, initialized before program startup
            let symbol = "\(currentFunctionName).\(name)"
            staticSymbols[declId] = symbol
            semGlobals.append(SemGlobal(
                declId: declId, symbol: symbol, type: varType, isExternal: false, isThreadLocal: spec.isThreadLocal,
                alignment: max(objectAlignment, varType.isError ? 1 : typePool.alignment(of: varType.typeId)),
                initBlock: currentBlockId, initInst: initInst, isTentative: false))
        } else {
            pendingVLALengths = vlaLengths
            stmts.append(emitLocalDeclaration(declId, initializer: initInst, node: declarator).rawIndex)
        }
    }

    /// The initializer of a variable: resolved against its type (`resolveInitializer`), or, for C23 `auto`, the value
    /// whose type the variable takes (after lvalue conversion and decay, unqualified). `raw` is the analyzed
    /// expression of a non-braced initializer, for the assignment constraints.
    private mutating func resolveVariableInitializer(_ initializer: NodeId, type: QualType, infersType: Bool, tree: borrowing ParseTree,
                                                     tokens: borrowing TokenBuffer) -> (inst: SemInstId, raw: SemInstId, type: QualType) {
        if infersType {
            let raw = analyzeExpression(initializer, tree: tree, tokens: tokens)
            let inferred = isTyped(raw) ? decayed(typeOf(raw)).unqualified() : QualType.error
            return (rvalue(raw), raw, inferred)
        }
        return resolveInitializer(initializer, type: type, tree: tree, tokens: tokens)
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
        pendingVLALengths.removeAll()  // parameter VLA lengths: the parameters are pointers
        let (fnType, fnTok, paramsNode) = (info.type, info.name, info.params)
        guard case .function(let returnType, _, _) = canonicalKind(fnType), let paramsNode,
              CTokenKind(rawValue: tokens.kind(of: fnTok)) == .identifier else { return }
        let fnName = spelling(of: fnTok, in: tokens)
        let signature = resolveParameters(paramsNode, tree: tree, tokens: tokens)
        let fnDeclId = declareFunction(fnName, type: fnType, isStatic: spec.isStatic, isDefinition: true, at: fnTok, tokens: tokens)
        if !definedFunctions.insert(fnName).inserted {
            reportError("redefinition of '\(fnName)'", diagId: .semaRedefinition, at: fnTok, in: tokens, args: [fnName])
        }

        self.currentReturnType = returnType
        currentFunctionName = fnName
        currentFunctionDecl = fnDeclId
        functionLabels = [:]
        labelNumbers = [:]
        labelNames = [""]
        pendingGotos = []
        let fnScope = CScope(parent: currentScope)
        self.currentScope = fnScope

        let blockContainer = SemInstBlockContainer(block: SemInstBlock())
        self.currentBlockContainer = blockContainer
        let blockId = InstBlockId(UInt32(instBlocks.count))
        currentBlockId = blockId
        instBlocks.append(blockContainer)
        declTable.setBody(for: fnDeclId, blockId: blockId.rawIndex)

        // Bind the parameters; each has a declaration (an unnamed one too), in order
        let paramNames = signature.names.map { $0.isValid ? spelling(of: $0, in: tokens) : "" }
        var paramDecls: [DeclId] = []
        for (idx, pName) in paramNames.enumerated() {
            let pType = signature.types[idx]
            if !pName.isEmpty, currentScope.lookupLocalOrdinary(pName) != nil {
                reportError("redefinition of parameter '\(pName)'", diagId: .semaRedefinition, at: signature.names[idx], in: tokens, args: [pName])
            }
            let pDecl = declTable.append(kind: .parameter, name: pName, parent: fnDeclId, type: pType,
                                         attrs: DeclAttributes(storage: .parameter).rawValue)
            paramDecls.append(pDecl)
            guard !pName.isEmpty else { continue }
            currentScope.insertOrdinary(symbol: CSymbol(name: pName, declId: pDecl, type: pType, storage: .param(index: idx)))
        }

        // The body's `compound` is the block's last instruction, its root
        _ = analyzeCompound(bodyNode, tree: tree, tokens: tokens)
        self.currentBlockContainer = fileScopeContainer
        currentBlockId = .nilId
        currentFunctionDecl = .nilId
        for g in pendingGotos where functionLabels[g.name] == nil {
            reportError("use of undeclared label '\(g.name)'", diagId: .semaUndefinedLabel, at: g.tok, in: tokens, args: [g.name])
        }

        if !functionOrder.contains(fnName) {
            functionOrder.append(fnName)
        }
        functions[fnName] = FunctionSignature(
            name: fnName,
            returnType: returnType.typeId,
            paramNames: paramNames,
            paramTypes: signature.types.map { $0.typeId },
            bodyNode: bodyNode,
            declId: fnDeclId,
            blockId: blockId,
            paramDecls: paramDecls
        )
        semFunctions.append(SemFunction(declId: fnDeclId, name: fnName, blockId: blockId, params: paramDecls, labels: labelNames,
                                        isExternal: DeclAttributes(rawValue: declTable.attrs[fnDeclId]).storage == .external))
        currentFunctionName = ""

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
            let specAttributes = tree.children(of: specsNode).filter { tree.kind(of: $0) == .attributeSpec }
            if !mChildren.contains(where: { tree.kind(of: $0) == .declarator }) {
                // C11 anonymous struct or union member; a named tag here only declares the tag
                let specChildren = tree.children(of: specsNode)
                if let tag = specChildren.first(where: { tree.kind(of: $0) == .structType || tree.kind(of: $0) == .unionType }),
                   [.kwStruct, .kwUnion].contains(CTokenKind(rawValue: tokens.kind(of: tree.token(of: tag)))) {
                    let attributes = specAttributes + mChildren.filter { tree.kind(of: $0) == .attributeSpec }
                    members.append(StructMemberDecl(name: "", type: spec.type, alignment: explicitAlignment(attributes, tree: tree, tokens: tokens),
                                                    isPacked: hasPackedAttribute(attributes, tree: tree, tokens: tokens)))
                }
                continue
            }
            var i = 0
            while i < mChildren.count {
                let declarator = mChildren[i]
                i += 1
                guard tree.kind(of: declarator) == .declarator else { continue }
                // The declarator's attributes, its bit-field width, then attributes after the width
                var attributes = specAttributes + tree.children(of: declarator).filter { tree.kind(of: $0) == .attributeSpec }
                while i < mChildren.count, tree.kind(of: mChildren[i]) == .attributeSpec {
                    attributes.append(mChildren[i])
                    i += 1
                }
                var widthNode: NodeId? = nil
                if i < mChildren.count, tree.kind(of: mChildren[i]) != .declarator, tree.kind(of: mChildren[i]) != .attributeSpec {
                    widthNode = mChildren[i]
                    i += 1
                }
                while i < mChildren.count, tree.kind(of: mChildren[i]) == .attributeSpec {
                    attributes.append(mChildren[i])
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
                let memberType = applyMachineMode(type, attributes: attributes, tree: tree, tokens: tokens)
                members.append(StructMemberDecl(name: mName, type: memberType, bitWidth: bitWidth,
                                                alignment: explicitAlignment(attributes, tree: tree, tokens: tokens),
                                                isPacked: hasPackedAttribute(attributes, tree: tree, tokens: tokens)))
            }
        }

        let typeAttributes = children.filter { tree.kind(of: $0) == .attributeSpec }
        typePool.completeStruct(structTypeId, fields: members, isPacked: hasPackedAttribute(typeAttributes, tree: tree, tokens: tokens),
                                alignment: explicitAlignment(typeAttributes, tree: tree, tokens: tokens))
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
        typePool.integerWidth(type)
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
        typePool.name(of: t, declarator: declarator)
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
        case .array(let element, _): return QualType(typeId: typePool.pointerTo(QualType(rawValue: element.rawValue | UInt32(t.qualifiers))))
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
        case .local, .staticLocal, .param, .typedef, .enumConstant:
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
            case .local, .staticLocal, .param, .global: return true
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
            case .global, .local, .staticLocal, .param, .function: return true
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
            case .global, .staticLocal: return isArrayOrFunction(sym.type) || sym.type.isConst || sym.type.isError
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

    // MARK: - SemIR Emission

    /// The block instructions are emitted into: the current function body's, or the file-scope block.
    private var block: SemInstBlockContainer { currentBlockContainer ?? fileScopeContainer }

    @discardableResult
    private func emit(_ kind: SemInstKind, _ type: QualType, _ arg0: UInt32 = 0, _ arg1: UInt32 = 0, node: NodeId) -> SemInstId {
        block.block.append(kind: kind, type: type, arg0: arg0, arg1: arg1, node: node)
    }

    @discardableResult
    private func emitList(_ kind: SemInstKind, _ type: QualType, arg0: UInt32 = 0, items: [UInt32], node: NodeId) -> SemInstId {
        let offset = block.block.appendList(items)
        return block.block.append(kind: kind, type: type, arg0: arg0, arg1: offset, node: node)
    }

    private func kindOf(_ inst: SemInstId) -> SemInstKind {
        block.block.kind(of: inst)
    }

    private func nodeOf(_ inst: SemInstId) -> NodeId {
        NodeId(block.block.nodes[inst])
    }

    /// The value of an expression (C23 6.3.2.1p2-4): an lvalue is loaded (lvalue conversion, which drops the
    /// qualifiers), an array decays to a pointer to its first element, and a function designator to a pointer to the
    /// function. Rvalues, and expressions sema does not model, are returned unchanged.
    private func rvalue(_ inst: SemInstId) -> SemInstId {
        guard inst.isValid, isTyped(inst) else { return inst }
        let k = kindOf(inst), t = typeOf(inst)
        guard k.isLvalue else { return inst }
        switch canonicalKind(t) {
        case .array:
            return emit(.arrayToPointer, decayed(t), inst.rawIndex, node: nodeOf(inst))
        case .function:
            return emit(.functionToPointer, decayed(t), inst.rawIndex, node: nodeOf(inst))
        default:
            return emit(.lvalueToRvalue, t.unqualified(), inst.rawIndex, node: nodeOf(inst))
        }
    }

    /// The operation converting a value of type `from` to type `to`, or nil if C has none.
    private func castKind(from: QualType, to: QualType) -> CastKind? {
        let s = typePool.canonical(of: from.typeId), d = typePool.canonical(of: to.typeId)
        if d == .void || d == .cVoid { return .toVoid }
        if s == d { return .noop }
        let sk = typePool.typeInfo(of: s).kind, dk = typePool.typeInfo(of: d).kind
        let sInt = typePool.isInteger(type: s), sFloat = typePool.isFloating(type: s)
        var sPtr = false, sNull = false
        if case .pointer = sk { sPtr = true }
        if case .nullptr = sk { sNull = true }
        switch dk {
        case .bool:
            return (sInt || sFloat || sPtr || sNull) ? .toBool : nil
        case .int, .enum:
            if sInt {
                // An enumeration and its underlying type, or two types of one width and signedness, share a representation
                let same = typePool.integerWidth(s) == typePool.integerWidth(d)
                    && typePool.isSignedInteger(type: s) == typePool.isSignedInteger(type: d) && !(typePool.canonical(of: s) == .bool)
                return same ? .noop : .intToInt
            }
            if sFloat { return .floatToInt }
            if sPtr { return .pointerToInt }
            return nil
        case .float:
            if sInt { return .intToFloat }
            if sFloat { return typePool.size(of: s) == typePool.size(of: d) && sk == dk ? .noop : .floatToFloat }
            return nil
        case .pointer:
            if sPtr { return .pointerToPointer }
            if sNull { return .nullToPointer }
            if sInt { return .intToPointer }
            return nil
        case .nullptr:
            return sNull ? .noop : nil
        case .struct(_, let fields, let isUnion):
            if typesCompatible(QualType(typeId: s), QualType(typeId: d)) { return .noop }
            if isUnion && fields.contains(where: { typesCompatible($0.type.unqualified(), from.unqualified()) }) { return .toUnion }
            return nil
        default:
            return nil
        }
    }

    /// The conversion of rvalue `value` to `type` for `reason` (a conversion kind), or `value` itself if it already
    /// has that type. A value whose type sema does not model is returned unchanged; one that cannot be converted
    /// (a constraint violation, diagnosed elsewhere) becomes an `errorInst`.
    private func convertImplicitly(_ value: SemInstId, to type: QualType, reason: SemInstKind, node: NodeId) -> SemInstId {
        guard value.isValid, isTyped(value), !type.isError else { return value }
        let target = type.unqualified()
        let from = typeOf(value)
        if typePool.canonical(of: from.typeId) == typePool.canonical(of: target.typeId) { return value }
        guard let kind = castKind(from: from, to: target) else {
            return emit(.errorInst, target, value.rawIndex, node: node)
        }
        return emit(reason, target, value.rawIndex, kind.rawValue, node: node)
    }

    /// `raw` converted as if by assignment to `type` (C23 6.5.16.1p2): its value, with a null pointer constant (an
    /// integer constant 0, or `nullptr`) becoming a null pointer of the type.
    private mutating func convertForAssignment(_ raw: SemInstId, node: NodeId, to type: QualType, tree: borrowing ParseTree,
                                               tokens: borrowing TokenBuffer) -> SemInstId {
        let value = rvalue(raw)
        if isTyped(value), !type.isError, case .pointer = canonicalKind(type), let npc = nullPointerConversion(value, node: node, to: type, tree: tree, tokens: tokens) {
            return npc
        }
        return convertImplicitly(value, to: type, reason: .assignConvert, node: node)
    }

    /// A `nullPointerConvert` of `value` to pointer type `type` if `value` is a null pointer constant, else nil.
    private mutating func nullPointerConversion(_ value: SemInstId, node: NodeId, to type: QualType, tree: borrowing ParseTree,
                                                tokens: borrowing TokenBuffer) -> SemInstId? {
        let src = canonicalKind(typeOf(value))
        var isNull = false
        if case .nullptr = src { isNull = true }
        if !isNull && typePool.isInteger(type: typeOf(value).typeId) { isNull = isNullPointerConstant(node, tree: tree, tokens: tokens) }
        guard isNull else { return nil }
        return emit(.nullPointerConvert, type.unqualified(), value.rawIndex, CastKind.nullToPointer.rawValue, node: node)
    }

    /// The integer promotions (C23 6.3.1.1p2) of rvalue `value`; a bit-field narrower than `int` promotes to `int`.
    private func promoted(_ value: SemInstId, reason: SemInstKind = .intPromotion) -> SemInstId {
        guard isTyped(value), typePool.isInteger(type: typeOf(value).typeId) else { return value }
        return convertImplicitly(value, to: promotedType(of: value), reason: reason, node: nodeOf(value))
    }

    private func promotedType(of value: SemInstId) -> QualType {
        let t = typeOf(value)
        guard typePool.isInteger(type: t.typeId) else { return t.unqualified() }
        let promotedId = typePool.promote(type: t.typeId)
        // A bit-field of a type whose promoted type is `int` or `unsigned int` promotes to `int` if `int` can
        // represent all its values (C23 6.3.1.1p2)
        if kindOf(value) == .lvalueToRvalue, (promotedId == .int || promotedId == .uint) {
            let operand = SemInstId(block.block.arg0[value])
            if kindOf(operand) == .bitField, let width = block.block.extra(of: operand).dropFirst(2).first, width < 32 {
                return .int
            }
        }
        return QualType(typeId: promotedId)
    }

    /// The default argument promotions (C23 6.5.2.2p6): `float` (and `_Float16`) to `double`, and the integer
    /// promotions.
    private func argumentPromoted(_ value: SemInstId) -> SemInstId {
        guard isTyped(value) else { return value }
        let t = typeOf(value)
        if typePool.isFloating(type: t.typeId), typePool.size(of: typePool.canonical(of: t.typeId)) < 8 {
            return convertImplicitly(value, to: .double, reason: .argPromotion, node: nodeOf(value))
        }
        return promoted(value, reason: .argPromotion)
    }

    /// An expression used as a condition (`if`, loops, `?:`, `!`, `&&`, `||`): its value compared against 0, as `bool`.
    private func conditionValue(_ raw: SemInstId) -> SemInstId {
        let value = rvalue(raw)
        guard isTyped(value), typePool.isScalar(type: typeOf(value).typeId) else { return value }
        if typePool.canonical(of: typeOf(value).typeId) == .bool { return value }
        return emit(.boolConvert, .bool, value.rawIndex, CastKind.toBool.rawValue, node: nodeOf(value))
    }

    /// An integer operand of pointer arithmetic, converted to `ptrdiff_t`.
    private func pointerIndex(_ value: SemInstId) -> SemInstId {
        convertImplicitly(value, to: QualType(typeId: dataLayout.ptrdiffType), reason: .arithmeticConvert, node: nodeOf(value))
    }

    /// The number of a label in the current function (1-based), allocated on first use.
    private mutating func labelNumber(_ name: String) -> UInt32 {
        if let n = labelNumbers[name] { return n }
        let n = UInt32(labelNames.count)
        labelNames.append(name)
        labelNumbers[name] = n
        return n
    }

    /// Positions of the two `;` of a `for` statement's header, to tell which clause each child is.
    private func forHeaderSemicolons(_ forTok: TokenId, tokens: borrowing TokenBuffer) -> (UInt32, UInt32) {
        var depth = 0
        var semis: [UInt32] = []
        var i = Int(forTok.rawIndex) + 1
        scan: while i < tokens.count && semis.count < 2 {
            switch CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) {
            case .lParen, .lBracket, .lBrace: depth += 1
            case .rParen, .rBracket, .rBrace:
                depth -= 1
                if depth == 0 { break scan }
            case .semicolon where depth == 1: semis.append(UInt32(i))
            default: break
            }
            i += 1
        }
        return (semis.first ?? .max, semis.count > 1 ? semis[1] : .max)
    }

    // MARK: - Statements

    /// A compound statement (C23 6.8.3): a scope, and its statements in order.
    private mutating func analyzeCompound(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId {
        let blockScope = CScope(parent: currentScope)
        self.currentScope = blockScope
        var stmts: [UInt32] = []
        for child in tree.children(of: node) {
            analyzeStatement(child, into: &stmts, tree: tree, tokens: tokens)
        }
        self.currentScope = blockScope.parent ?? CScope()
        return emitList(.compound, .void, items: stmts, node: node)
    }

    /// A statement in a position that holds exactly one (a branch or a loop body): several (a declaration with many
    /// declarators) become a `compound`, none a `nullStmt`.
    private mutating func analyzeSubStatement(_ node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId {
        var stmts: [UInt32] = []
        analyzeStatement(node, into: &stmts, tree: tree, tokens: tokens)
        if stmts.count == 1 { return SemInstId(stmts[0]) }
        if stmts.isEmpty { return emit(.nullStmt, .void, node: node) }
        return emitList(.compound, .void, items: stmts, node: node)
    }

    private func isDeclarationNode(_ node: NodeId, tree: borrowing ParseTree) -> Bool {
        switch tree.kind(of: node) {
        case .varDecl, .typedefDecl, .staticAssertDecl: return true
        default: return false
        }
    }

    /// The labeled statement of a `label:`, `case v:` or `default:` (its children after `skip`): nil when the label
    /// precedes a declaration (C23 6.8.2), which then stays in the enclosing block; 0 when it ends the block.
    private mutating func labeledStatement(of node: NodeId, skip: Int, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId? {
        guard let child = tree.children(of: node).dropFirst(skip).first else { return .nilId }
        if isDeclarationNode(child, tree: tree) { return nil }
        return analyzeSubStatement(child, tree: tree, tokens: tokens)
    }

    private mutating func analyzeStatement(_ stmtNode: NodeId, into stmts: inout [UInt32], tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        let kind = tree.kind(of: stmtNode)
        switch kind {
        case .compoundStmt:
            stmts.append(analyzeCompound(stmtNode, tree: tree, tokens: tokens).rawIndex)

        case .varDecl, .typedefDecl:
            analyzeDeclaration(stmtNode, isFileScope: false, into: &stmts, tree: tree, tokens: tokens)

        case .staticAssertDecl:
            analyzeStaticAssert(stmtNode, tree: tree, tokens: tokens)

        case .labelStmt:
            let labelTok = tree.token(of: stmtNode)
            let label = spelling(of: labelTok, in: tokens)
            if functionLabels[label] != nil {
                reportError("redefinition of label '\(label)'", diagId: .semaRedefinition, at: labelTok, in: tokens, args: [label])
            }
            functionLabels[label] = labelTok
            let number = labelNumber(label)
            if let sub = labeledStatement(of: stmtNode, skip: 0, tree: tree, tokens: tokens) {
                stmts.append(emit(.label, .void, sub.rawIndex, number, node: stmtNode).rawIndex)
            } else {
                stmts.append(emit(.label, .void, 0, number, node: stmtNode).rawIndex)
                for child in tree.children(of: stmtNode) { analyzeStatement(child, into: &stmts, tree: tree, tokens: tokens) }
            }

        case .gotoStmt:
            let gotoTok = tree.token(of: stmtNode)
            let labelTok = TokenId(gotoTok.rawIndex + 1)
            let children = tree.children(of: stmtNode)
            if let target = children.first {
                // `goto *expr` (GNU computed goto)
                let address = rvalue(analyzeExpression(target, tree: tree, tokens: tokens))
                stmts.append(emit(.indirectGoto, .void, address.rawIndex, node: stmtNode).rawIndex)
            } else if Int(labelTok.rawIndex) < tokens.count, CTokenKind(rawValue: tokens.kind(of: labelTok)) == .identifier {
                let name = spelling(of: labelTok, in: tokens)
                pendingGotos.append((name, labelTok))
                stmts.append(emit(.gotoStmt, .void, labelNumber(name), node: stmtNode).rawIndex)
            }

        case .breakStmt:
            if loopDepth == 0 && switchStack.isEmpty {
                reportError("'break' statement not in loop or switch statement", diagId: .semaJumpOutsideLoop, at: tree.token(of: stmtNode), in: tokens, args: ["break", "loop or switch statement"])
            }
            stmts.append(emit(.breakStmt, .void, node: stmtNode).rawIndex)

        case .continueStmt:
            if loopDepth == 0 {
                reportError("'continue' statement not in loop statement", diagId: .semaJumpOutsideLoop, at: tree.token(of: stmtNode), in: tokens, args: ["continue", "loop statement"])
            }
            stmts.append(emit(.continueStmt, .void, node: stmtNode).rawIndex)

        case .returnStmt:
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                let retInst = analyzeExpression(expr, tree: tree, tokens: tokens)
                let retType = currentBlockContainer?.block.type(of: retInst) ?? currentReturnType
                let value: SemInstId
                if typePool.canonical(of: currentReturnType.typeId) == .void {
                    if isTyped(retInst) && typePool.canonical(of: retType.typeId) != .void {
                        reportError("void function '\(currentFunctionName)' should not return a value", diagId: .semaVoidReturnValue, at: tree.token(of: stmtNode), in: tokens, args: [currentFunctionName])
                    }
                    value = rvalue(retInst)  // `return f();` of a `void` expression
                } else {
                    checkAssignment(to: currentReturnType, from: retInst, rhsNode: expr, tree: tree, tokens: tokens)
                    value = convertForAssignment(retInst, node: expr, to: currentReturnType, tree: tree, tokens: tokens)
                }
                nodeTypes[stmtNode] = retType.typeId
                stmts.append(emit(.returnStmt, .void, value.rawIndex, node: stmtNode).rawIndex)
            } else {
                nodeTypes[stmtNode] = .void
                stmts.append(emit(.returnStmt, .void, node: stmtNode).rawIndex)
            }

        case .ifStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            let condInst = analyzeExpression(children[0], tree: tree, tokens: tokens)
            checkScalarCondition(condInst, at: tree.token(of: stmtNode), tokens: tokens)
            let cond = conditionValue(condInst)
            let thenStmt = analyzeSubStatement(children[1], tree: tree, tokens: tokens)
            let elseStmt = children.count >= 3 ? analyzeSubStatement(children[2], tree: tree, tokens: tokens) : .nilId
            stmts.append(emitList(.ifStmt, .void, arg0: cond.rawIndex, items: [thenStmt.rawIndex, elseStmt.rawIndex], node: stmtNode).rawIndex)

        case .whileStmt, .doWhileStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            // `while (c) s` stores (c, s); `do s while (c)` stores (s, c)
            let (condNode, bodyNode) = kind == .whileStmt ? (children[0], children[1]) : (children[1], children[0])
            loopDepth += 1
            var body = SemInstId.nilId
            if kind == .doWhileStmt { body = analyzeSubStatement(bodyNode, tree: tree, tokens: tokens) }
            let condInst = analyzeExpression(condNode, tree: tree, tokens: tokens)
            checkScalarCondition(condInst, at: tree.token(of: stmtNode), tokens: tokens)
            let cond = conditionValue(condInst)
            if kind == .whileStmt { body = analyzeSubStatement(bodyNode, tree: tree, tokens: tokens) }
            loopDepth -= 1
            if kind == .whileStmt {
                stmts.append(emit(.whileStmt, .void, cond.rawIndex, body.rawIndex, node: stmtNode).rawIndex)
            } else {
                stmts.append(emit(.doWhileStmt, .void, body.rawIndex, cond.rawIndex, node: stmtNode).rawIndex)
            }

        case .forStmt:
            let forScope = CScope(parent: currentScope)
            self.currentScope = forScope
            loopDepth += 1
            // Children: the clauses present (a declaration or expressions), then the body; a clause's position
            // relative to the header's semicolons tells which one it is
            let children = tree.children(of: stmtNode)
            let (semi1, semi2) = forHeaderSemicolons(tree.token(of: stmtNode), tokens: tokens)
            var initStmt = SemInstId.nilId, cond = SemInstId.nilId, step = SemInstId.nilId, body = SemInstId.nilId
            for (idx, child) in children.enumerated() {
                if idx == children.count - 1 {
                    body = analyzeSubStatement(child, tree: tree, tokens: tokens)
                } else if isDeclarationNode(child, tree: tree) {
                    var decls: [UInt32] = []
                    analyzeStatement(child, into: &decls, tree: tree, tokens: tokens)
                    initStmt = emitList(.compound, .void, items: decls, node: child)
                } else {
                    let position = tree.token(of: child).rawIndex
                    let e = analyzeExpression(child, tree: tree, tokens: tokens)
                    if position < semi1 {
                        initStmt = emit(.exprStmt, .void, e.rawIndex, node: child)
                    } else if position < semi2 {
                        checkScalarCondition(e, at: tree.token(of: stmtNode), tokens: tokens)
                        cond = conditionValue(e)
                    } else {
                        step = e
                    }
                }
            }
            loopDepth -= 1
            self.currentScope = forScope.parent ?? CScope()
            stmts.append(emitList(.forStmt, .void, items: [initStmt.rawIndex, cond.rawIndex, step.rawIndex, body.rawIndex], node: stmtNode).rawIndex)

        case .switchStmt:
            let children = tree.children(of: stmtNode)
            guard children.count >= 2 else { return }
            // The controlling expression undergoes the integer promotions (C23 6.8.5.3p5)
            let control = promoted(rvalue(analyzeExpression(children[0], tree: tree, tokens: tokens)))
            switchStack.append(SwitchContext(controlType: isTyped(control) ? typeOf(control) : .int))
            let body = analyzeSubStatement(children[1], tree: tree, tokens: tokens)
            let context = switchStack.removeLast()
            stmts.append(emitList(.switchStmt, .void, arg0: control.rawIndex, items: [body.rawIndex, context.defaultLabel.rawIndex] + context.cases,
                                  node: stmtNode).rawIndex)

        case .caseStmt:
            let children = tree.children(of: stmtNode)
            let caseTok = tree.token(of: stmtNode)
            var value: Int64 = 0
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
                    // The value converted to the promoted type of the controlling expression (C23 6.8.5.3p5)
                    let controlType = switchStack[switchStack.count - 1].controlType.typeId
                    value = integerTraits(controlType) != nil ? makeConst(UInt64(bitPattern: v), controlType).signedValue : v
                }
            }
            let constant = block.block.addIntConstant(value)
            let sub = labeledStatement(of: stmtNode, skip: 1, tree: tree, tokens: tokens)
            let label = emit(.caseLabel, .void, (sub ?? .nilId).rawIndex, constant, node: stmtNode)
            if !switchStack.isEmpty { switchStack[switchStack.count - 1].cases.append(label.rawIndex) }
            stmts.append(label.rawIndex)
            if sub == nil {
                for child in children.dropFirst() { analyzeStatement(child, into: &stmts, tree: tree, tokens: tokens) }
            }

        case .defaultStmt:
            let defaultTok = tree.token(of: stmtNode)
            var isFirstDefault = false
            if switchStack.isEmpty {
                reportError("'default' statement not in switch statement", diagId: .semaJumpOutsideLoop, at: defaultTok, in: tokens, args: ["default", "switch statement"])
            } else if switchStack[switchStack.count - 1].hasDefault {
                reportError("multiple default labels in one switch", diagId: .semaDuplicateCase, at: defaultTok, in: tokens, args: ["default label"])
            } else {
                switchStack[switchStack.count - 1].hasDefault = true
                isFirstDefault = true
            }
            let sub = labeledStatement(of: stmtNode, skip: 0, tree: tree, tokens: tokens)
            let label = emit(.defaultLabel, .void, (sub ?? .nilId).rawIndex, node: stmtNode)
            if isFirstDefault { switchStack[switchStack.count - 1].defaultLabel = label }
            stmts.append(label.rawIndex)
            if sub == nil {
                for child in tree.children(of: stmtNode) { analyzeStatement(child, into: &stmts, tree: tree, tokens: tokens) }
            }

        case .exprStmt:
            if isFallthroughStatement(stmtNode, tree: tree, tokens: tokens) {
                checkFallthrough(stmtNode, tokens: tokens, tree: tree)
            }
            let children = tree.children(of: stmtNode)
            if let expr = children.first {
                let e = analyzeExpression(expr, tree: tree, tokens: tokens)
                stmts.append(emit(.exprStmt, .void, e.rawIndex, node: stmtNode).rawIndex)
            } else {
                stmts.append(emit(.nullStmt, .void, node: stmtNode).rawIndex)
            }

        case .asmStmt:
            stmts.append(emit(.asmStmt, .void, node: stmtNode).rawIndex)

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

    /// Analyzes an expression and emits its instructions. The result is the expression itself: an lvalue for an
    /// expression that designates an object or function (C23 6.3.2.1), which the context converts with `rvalue`,
    /// or else an rvalue.
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
            // The value correctly rounded to the type's format, as clang's APFloat parses it
            let format = floatFormat(of: type) ?? .double
            let value = SoftFloat.parse(floatingConstantBody(txt), format: format) ?? .zero(format)
            let res = container.block.appendFloatLiteral(value: value.constant, type: QualType(typeId: type), node: exprNode)
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
            let constant = stringLiteralConstant(tok, tokens: tokens)
            let info = stringLiteralInfo(tok, tokens: tokens)
            let arrayType = typePool.arrayType(elementType: QualType(typeId: info.element), count: info.length)
            let res = container.block.appendStringLiteral(value: constant, type: QualType(typeId: arrayType), node: exprNode)
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
                case .typedef:
                    return container.block.append(kind: .errorInst, type: .error, node: exprNode)
                default:
                    return container.block.append(kind: .declRef, type: sym.type, arg0: sym.declId.rawIndex, node: exprNode)
                }
            } else if isBuiltinFunctionName(name) ||
                      name == "asm" || name == "__asm__" || name == "__asm" {
                let fnType = QualType(typeId: typePool.functionType(returnType: .long, paramTypes: [], isVariadic: true))
                let declId = declTable.append(kind: .function, name: name, type: fnType, attrs: DeclAttributes(storage: .external).rawValue)
                let sym = CSymbol(name: name, declId: declId, type: fnType, storage: .function(name: name))
                currentScope.insertOrdinary(symbol: sym)
                symbolRefs[exprNode] = sym
                nodeTypes[exprNode] = fnType.typeId
                return container.block.append(kind: .declRef, type: fnType, arg0: declId.rawIndex, node: exprNode)
            } else if name == "__func__" || name == "__FUNCTION__" || name == "__PRETTY_FUNCTION__" {
                // `static const char __func__[] = "function-name";` (C23 6.4.2.2)
                let bytes = Array(currentFunctionName.utf8) + [0]
                let arrayType = typePool.arrayType(elementType: QualType.char.withConst(), count: UInt64(bytes.count))
                let res = container.block.appendStringLiteral(value: StringConstant(bytes: bytes, elementSize: 1, encoding: .ordinary),
                                                              type: QualType(typeId: arrayType), node: exprNode)
                nodeTypes[exprNode] = typePool.pointerTo(.char)
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
            // The structure object: `*p` for `p->m`; a temporary for a member of an rvalue (`f().m`)
            var object = baseInst
            if opKind == .arrow {
                baseType = typePool.pointeeType(of: baseType.typeId)
                let pointer = rvalue(baseInst)
                if isTyped(pointer) { object = emit(.deref, baseType, pointer.rawIndex, node: exprNode) }
            } else if isTyped(baseInst) && !kindOf(baseInst).isLvalue {
                object = emit(.materialize, baseType.unqualified(), baseInst.rawIndex, node: baseNode)
            }

            let memberTok = (children.count > 1) ? tree.token(of: children[1]) : opTok
            let memberName = spelling(of: memberTok, in: tokens)

            if let field = typePool.lookupStructField(named: memberName, in: baseType.typeId) {
                // A member of a const- or volatile-qualified structure is so qualified (C23 6.5.2.3p3)
                let fieldType = QualType(rawValue: field.type.rawValue | UInt32(baseType.qualifiers & 0b011))
                nodeTypes[exprNode] = fieldType.typeId
                if let width = field.bitWidth {
                    let isSigned = typePool.isSignedInteger(type: field.type.typeId)
                    let unitBytes = UInt32(typePool.size(of: field.type.typeId))
                    return emitList(.bitField, fieldType, arg0: object.rawIndex,
                                    items: [field.offset, UInt32(field.bitOffset), UInt32(width), isSigned ? 1 : 0, unitBytes], node: exprNode)
                }
                return emit(.member, fieldType, object.rawIndex, field.offset, node: exprNode)
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
            let assignKind = CTokenKind(rawValue: tokens.kind(of: assignTok)) ?? .equal
            // C23 6.5.16p2: the left operand shall be a modifiable lvalue
            if !isLvalue(children[0], tree: tree, tokens: tokens) {
                reportError("expression is not assignable", diagId: .semaNotAssignable, at: assignTok, in: tokens, args: [""])
            } else if isTyped(lhs) && (isArrayOrFunction(lhsType) || lhsType.isConst) {
                reportError("expression is not assignable", diagId: .semaNotAssignable, at: assignTok, in: tokens, args: [lhsType.isConst ? " (const-qualified)" : ""])
            } else if assignKind == .equal {
                checkAssignment(to: lhsType, from: rhs, rhsNode: children[1], tree: tree, tokens: tokens)
            } else if isTyped(lhs) && isTyped(rhs) && (isStructOrUnion(lhsType) || isStructOrUnion(typeOf(rhs))) {
                reportError("invalid operands to compound assignment", diagId: .semaInvalidOperands, at: assignTok, in: tokens, args: [spelling(of: assignTok, in: tokens), "\(lhsType)", "\(typeOf(rhs))"])
            }
            nodeTypes[exprNode] = lhsType.typeId
            let resultType = lhsType.unqualified()
            if assignKind == .equal {
                let value = convertForAssignment(rhs, node: children[1], to: lhsType, tree: tree, tokens: tokens)
                return emit(.assign, resultType, lhs.rawIndex, value.rawIndex, node: exprNode)
            }
            // `lhs op= rhs` (C23 6.5.16.2): the operation in the type of `lhs op rhs`, the result converted back
            let op = Self.compoundAssignmentOperator(assignKind)
            var value = rvalue(rhs)
            var opcode = op.kind
            var computation = resultType
            if isTyped(lhs) && isTyped(value) {
                if isPointerLike(lhsType) && (opcode == .add || opcode == .sub) {
                    opcode = opcode == .add ? .ptrAdd : .ptrSub
                    value = pointerIndex(value)
                } else if opcode == .shl || opcode == .shr {
                    computation = QualType(typeId: typePool.promote(type: lhsType.typeId))
                    value = promoted(value)
                } else if typePool.isArithmetic(type: lhsType.typeId) && typePool.isArithmetic(type: typeOf(value).typeId) {
                    computation = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, typeOf(value).typeId))
                    value = convertImplicitly(value, to: computation, reason: .arithmeticConvert, node: children[1])
                }
            }
            return emitList(.compoundAssign, resultType, arg0: lhs.rawIndex,
                            items: [UInt32(opcode.rawValue), value.rawIndex, computation.rawValue, computation.rawValue], node: exprNode)

        case .binaryExpr:
            return analyzeBinary(exprNode, tree: tree, tokens: tokens)

        case .unaryExpr:
            return analyzeUnary(exprNode, tree: tree, tokens: tokens)

        case .castExpr:
            let children = tree.children(of: exprNode)
            guard children.count == 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            let targetType = resolveType(from: children[0], tree: tree, tokens: tokens)
            pendingVLALengths.removeAll()
            if tree.kind(of: children[1]) == .initList {
                // Compound literal `(T){ ... }`
                return compoundLiteral(type: targetType, initializer: children[1], node: exprNode, tree: tree, tokens: tokens)
            }
            let inner = analyzeExpression(children[1], tree: tree, tokens: tokens)
            if isTyped(inner) && !targetType.isError {
                checkCast(from: typeOf(inner), to: targetType, at: tree.token(of: exprNode), tokens: tokens)
            }
            nodeTypes[exprNode] = targetType.typeId
            let value = rvalue(inner)
            if isTyped(value) && !targetType.isError {
                let kind = castKind(from: typeOf(value), to: targetType) ?? .noop
                let resultType = kind == .toVoid ? QualType.void : targetType.unqualified()
                return emit(.explicitCast, resultType, value.rawIndex, kind.rawValue, node: exprNode)
            }
            return emit(.explicitCast, targetType.unqualified(), value.rawIndex, node: exprNode)

        case .callExpr:
            return analyzeCall(exprNode, tree: tree, tokens: tokens)

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
            // `i[p]` is `p[i]`: the element type comes from whichever operand is the pointer; `E1[E2]` is `*(E1 + E2)`
            let swapped = !isPointerLike(baseType) && isTyped(idx) && isPointerLike(typeOf(idx))
            let pointerType = swapped ? typeOf(idx) : baseType
            let pointee = typePool.pointeeType(of: pointerType.typeId)
            nodeTypes[exprNode] = pointee.typeId
            let pointer = rvalue(swapped ? idx : base)
            var index = rvalue(swapped ? base : idx)
            if isTyped(index) { index = pointerIndex(index) }
            let address = emit(.ptrAdd, isTyped(pointer) ? typeOf(pointer) : .error, pointer.rawIndex, index.rawIndex, node: exprNode)
            return emit(.deref, pointee, address.rawIndex, node: exprNode)

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
            if children.count == 2 {
                let value = rvalue(cond)
                let other = convertArm(elseInst, node: children[1], to: thenType, tree: tree, tokens: tokens)
                return emit(.elvis, thenType, value.rawIndex, other.rawIndex, node: exprNode)
            }
            let c = conditionValue(cond)
            let t = convertArm(thenInst, node: children[1], to: thenType, tree: tree, tokens: tokens)
            let e = convertArm(elseInst, node: children[2], to: thenType, tree: tree, tokens: tokens)
            return emitList(.conditional, thenType, items: [c.rawIndex, t.rawIndex, e.rawIndex], node: exprNode)

        case .genericExpr:
            let children = tree.children(of: exprNode)
            guard children.count >= 2 else {
                return container.block.append(kind: .errorInst, type: .int, node: exprNode)
            }
            // The controlling expression is not evaluated; its type is taken after lvalue conversion (C23 6.5.2.1p3)
            let mark = container.block.mark()
            unevaluatedDepth += 1
            let ctrlInst = analyzeExpression(children[0], tree: tree, tokens: tokens)
            let rawType = container.block.type(of: ctrlInst)
            let ctrlType = (isTyped(ctrlInst) ? decayed(rawType) : rawType).unqualified()
            unevaluatedDepth -= 1
            container.block.truncate(to: mark)
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
                // Association matching is approximate (types are compared by identity, not compatibility): leave untyped
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
            var result: SemInstId = .nilId
            for (idx, child) in children.enumerated() {
                let operand = analyzeExpression(child, tree: tree, tokens: tokens)
                if idx == 0 {
                    result = operand
                } else {
                    // The left operand is a void expression; the result is the right operand's value (C23 6.5.17)
                    let value = rvalue(operand)
                    result = emit(.comma, typeOf(value), result.rawIndex, value.rawIndex, node: exprNode)
                }
            }
            nodeTypes[exprNode] = container.block.type(of: result).typeId
            return result

        case .compoundStmt:
            // GNU statement expression `({ ... })`: its value is that of a final expression statement, else `void`
            let scope = CScope(parent: currentScope)
            currentScope = scope
            var stmts: [UInt32] = []
            let children = tree.children(of: exprNode)
            var value = SemInstId.nilId
            for (idx, child) in children.enumerated() {
                if idx == children.count - 1, tree.kind(of: child) == .exprStmt, let e = tree.children(of: child).first {
                    value = rvalue(analyzeExpression(e, tree: tree, tokens: tokens))
                } else {
                    analyzeStatement(child, into: &stmts, tree: tree, tokens: tokens)
                }
            }
            currentScope = scope.parent ?? CScope()
            let body = emitList(.compound, .void, items: stmts, node: exprNode)
            let type: QualType = value.isValid ? (isTyped(value) ? typeOf(value) : .error) : .void
            nodeTypes[exprNode] = type.typeId
            return emit(.stmtExpr, type, body.rawIndex, value.rawIndex, node: exprNode)

        case .compoundLiteralExpr:
            let children = tree.children(of: exprNode)
            if let typeNode = children.first, isTypeNode(tree.kind(of: typeNode)) {
                let t = resolveType(from: typeNode, tree: tree, tokens: tokens)
                pendingVLALengths.removeAll()
                if let list = children.dropFirst().first(where: { tree.kind(of: $0) == .initList }) {
                    return compoundLiteral(type: t, initializer: list, node: exprNode, tree: tree, tokens: tokens)
                }
            }
            for child in children where !isTypeNode(tree.kind(of: child)) {
                _ = analyzeExpression(child, tree: tree, tokens: tokens)
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

    /// The `SemInstKind` of the operation of a compound assignment operator (`+=` → `add`).
    private static func compoundAssignmentOperator(_ k: CTokenKind) -> (kind: SemInstKind, token: CTokenKind) {
        switch k {
        case .plusEqual: return (.add, .plus)
        case .minusEqual: return (.sub, .minus)
        case .starEqual: return (.mul, .star)
        case .slashEqual: return (.div, .slash)
        case .percentEqual: return (.mod, .percent)
        case .ampEqual: return (.bitAnd, .amp)
        case .pipeEqual: return (.bitOr, .pipe)
        case .caretEqual: return (.bitXor, .caret)
        case .lessLessEqual: return (.shl, .lessLess)
        case .greaterGreaterEqual: return (.shr, .greaterGreater)
        default: return (.add, .plus)
        }
    }

    /// An arm of `?:` converted to the result type (C23 6.5.15p5-6): the usual arithmetic conversions, a null
    /// pointer constant to a null pointer, a pointer to the composite pointer type, or to `void`.
    private mutating func convertArm(_ raw: SemInstId, node: NodeId, to type: QualType, tree: borrowing ParseTree,
                                     tokens: borrowing TokenBuffer) -> SemInstId {
        let value = rvalue(raw)
        guard isTyped(value), !type.isError else { return value }
        if typePool.isArithmetic(type: type.typeId) {
            return convertImplicitly(value, to: type, reason: .arithmeticConvert, node: node)
        }
        if case .pointer = canonicalKind(type), let npc = nullPointerConversion(value, node: node, to: type, tree: tree, tokens: tokens) {
            return npc
        }
        return convertImplicitly(value, to: type, reason: .assignConvert, node: node)
    }

    /// A compound literal `(T){ ... }` (C23 6.5.2.5): an unnamed object, automatic in a function body and static at
    /// file scope, initialized by the braced list. An array of unknown size takes its length from the initializer.
    private mutating func compoundLiteral(type: QualType, initializer: NodeId, node: NodeId, tree: borrowing ParseTree,
                                          tokens: borrowing TokenBuffer) -> SemInstId {
        let isFileScope = currentBlockContainer === fileScopeContainer
        let storage: DeclStorage = isFileScope ? .internalStatic : .automatic
        let declId = declTable.append(kind: .variable, name: "", parent: currentFunctionDecl, type: type,
                                      attrs: DeclAttributes(storage: storage, isDefinition: true).rawValue)
        let resolved = resolveInitializer(initializer, type: type, tree: tree, tokens: tokens)
        let objectType = type.isError ? type : QualType(typeId: resolved.type.typeId, qualifiers: type.qualifiers)
        declTable.setType(for: declId, type: objectType)
        if isFileScope && unevaluatedDepth == 0 {
            staticSymbols[declId] = ".compoundliteral"
            semGlobals.append(SemGlobal(
                declId: declId, symbol: ".compoundliteral", type: objectType, isExternal: false, isThreadLocal: false,
                alignment: objectType.isError ? 1 : typePool.alignment(of: objectType.typeId), initBlock: .nilId,
                initInst: resolved.inst, isTentative: false))
        }
        nodeTypes[node] = objectType.typeId
        return emit(.compoundLiteral, objectType, declId.rawIndex, resolved.inst.rawIndex, node: node)
    }

    /// A binary operator (C23 6.5.5-6.5.14): its operands converted (the usual arithmetic conversions, integer
    /// promotions for shifts, pointer arithmetic with a `ptrdiff_t` index, conditions for `&&`/`||`).
    private mutating func analyzeBinary(_ exprNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId {
        let children = tree.children(of: exprNode)
        guard children.count == 2 else {
            return emit(.errorInst, .int, node: exprNode)
        }
        let lhs = analyzeExpression(children[0], tree: tree, tokens: tokens)
        let rhs = analyzeExpression(children[1], tree: tree, tokens: tokens)
        let lhsType = typeOf(lhs)
        let rhsType = typeOf(rhs)

        let opTok = tree.token(of: exprNode)
        let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken
        if isTyped(lhs) && isTyped(rhs) && !binaryOperandsValid(opKind, lhsType, rhsType) {
            reportError("invalid operands to binary expression", diagId: .semaInvalidOperands, at: opTok, in: tokens, args: [spelling(of: opTok, in: tokens), "\(lhsType)", "\(rhsType)"])
        }
        let typed = isTyped(lhs) && isTyped(rhs)

        if opKind == .ampAmp || opKind == .pipePipe {
            nodeTypes[exprNode] = .int
            let l = conditionValue(lhs), r = conditionValue(rhs)
            return emit(opKind == .ampAmp ? .logicalAnd : .logicalOr, .int, l.rawIndex, r.rawIndex, node: exprNode)
        }

        let semKind: SemInstKind
        switch opKind {
        case .plus: semKind = .add
        case .minus: semKind = .sub
        case .star: semKind = .mul
        case .slash: semKind = .div
        case .percent: semKind = .mod
        case .amp: semKind = .bitAnd
        case .pipe: semKind = .bitOr
        case .caret: semKind = .bitXor
        case .lessLess: semKind = .shl
        case .greaterGreater: semKind = .shr
        case .equalEqual: semKind = .eq
        case .exclaimEqual: semKind = .ne
        case .less: semKind = .lt
        case .lessEqual: semKind = .le
        case .greater: semKind = .gt
        case .greaterEqual: semKind = .ge
        default: semKind = .add
        }
        let isComparison = [.eq, .ne, .lt, .le, .gt, .ge].contains(semKind)

        var l = rvalue(lhs), r = rvalue(rhs)
        // An operand of unmodeled type makes the arithmetic result unmodeled too (comparisons stay `int`)
        guard typed else {
            let resType: QualType = isComparison ? .int : .error
            nodeTypes[exprNode] = resType.typeId
            return emit(semKind, resType, l.rawIndex, r.rawIndex, node: exprNode)
        }
        let lPtr = isPointerLike(lhsType), rPtr = isPointerLike(rhsType)
        let lArith = typePool.isArithmetic(type: lhsType.typeId), rArith = typePool.isArithmetic(type: rhsType.typeId)

        if isComparison {
            nodeTypes[exprNode] = .int
            if lArith && rArith {
                let common = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
                l = convertImplicitly(l, to: common, reason: .arithmeticConvert, node: children[0])
                r = convertImplicitly(r, to: common, reason: .arithmeticConvert, node: children[1])
            } else if typePool.isPointer(type: typeOf(l).typeId) || typePool.isPointer(type: typeOf(r).typeId) {
                // Pointers are compared in the type of the pointer operand: a null pointer constant, `nullptr`, another
                // pointer, or (a Clang extension, with a warning) an integer is converted to it
                let lIsPointer: Bool
                if case .pointer = canonicalKind(typeOf(l)) { lIsPointer = true } else { lIsPointer = false }
                let target = lIsPointer ? typeOf(l) : typeOf(r)
                if lIsPointer {
                    r = comparisonOperand(r, node: children[1], to: target, tree: tree, tokens: tokens)
                } else {
                    l = comparisonOperand(l, node: children[0], to: target, tree: tree, tokens: tokens)
                }
            }
            return emit(semKind, .int, l.rawIndex, r.rawIndex, node: exprNode)
        }

        switch semKind {
        case .add where lPtr || rPtr:
            let (pointer, index) = lPtr ? (l, r) : (r, l)
            nodeTypes[exprNode] = typeOf(pointer).typeId
            return emit(.ptrAdd, typeOf(pointer), pointer.rawIndex, pointerIndex(index).rawIndex, node: exprNode)
        case .sub where lPtr && rPtr:
            let ptrdiff = QualType(typeId: dataLayout.ptrdiffType)
            nodeTypes[exprNode] = ptrdiff.typeId
            return emit(.ptrDiff, ptrdiff, l.rawIndex, r.rawIndex, node: exprNode)
        case .sub where lPtr:
            nodeTypes[exprNode] = typeOf(l).typeId
            return emit(.ptrSub, typeOf(l), l.rawIndex, pointerIndex(r).rawIndex, node: exprNode)
        case .shl, .shr:
            // Each operand is promoted on its own; the result has the promoted left operand's type (C23 6.5.7p3)
            l = promoted(l)
            r = promoted(r)
            nodeTypes[exprNode] = typeOf(l).typeId
            return emit(semKind, typeOf(l), l.rawIndex, r.rawIndex, node: exprNode)
        default:
            guard lArith && rArith else {
                // A constraint violation, diagnosed above
                nodeTypes[exprNode] = .int
                return emit(.errorInst, .int, l.rawIndex, r.rawIndex, node: exprNode)
            }
            let common = QualType(typeId: typePool.commonArithmeticType(lhsType.typeId, rhsType.typeId))
            l = convertImplicitly(l, to: common, reason: .arithmeticConvert, node: children[0])
            r = convertImplicitly(r, to: common, reason: .arithmeticConvert, node: children[1])
            nodeTypes[exprNode] = common.typeId
            return emit(semKind, common, l.rawIndex, r.rawIndex, node: exprNode)
        }
    }

    /// The other operand of a pointer comparison, converted to the pointer operand's type.
    private mutating func comparisonOperand(_ value: SemInstId, node: NodeId, to type: QualType, tree: borrowing ParseTree,
                                            tokens: borrowing TokenBuffer) -> SemInstId {
        if let npc = nullPointerConversion(value, node: node, to: type, tree: tree, tokens: tokens) { return npc }
        return convertImplicitly(value, to: type, reason: .arithmeticConvert, node: node)
    }

    /// A unary operator (C23 6.5.3): `&`, `*`, `+`, `-`, `~`, `!`, prefix and postfix `++`/`--`, `sizeof`, `alignof`,
    /// and GNU `&&label`.
    private mutating func analyzeUnary(_ exprNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId {
        let children = tree.children(of: exprNode)
        guard let child = children.first else {
            return emit(.errorInst, .int, node: exprNode)
        }
        let opTok = tree.token(of: exprNode)
        let opKind = CTokenKind(rawValue: tokens.kind(of: opTok)) ?? .errorToken

        if opKind == .kwSizeof || opKind == .kwAlignof {
            let sizeType = QualType(typeId: dataLayout.sizeType)
            nodeTypes[exprNode] = sizeType.typeId
            let lengthsBefore = pendingVLALengths.count
            let operandType = sizeofOperandType(child, tree: tree, tokens: tokens)
            // `sizeof` of a variable length array is evaluated (C23 6.5.3.4p2)
            if opKind == .kwSizeof, let t = operandType, typePool.isVariableLengthArray(t.typeId) {
                var items: [UInt32] = []
                for (type, length) in pendingVLALengths.dropFirst(lengthsBefore) { items += [type.rawIndex, length.rawIndex] }
                pendingVLALengths.removeLast(pendingVLALengths.count - lengthsBefore)
                return emitList(.vlaSizeof, sizeType, arg0: typePool.canonical(of: t.typeId).rawIndex, items: items, node: exprNode)
            }
            if pendingVLALengths.count > lengthsBefore { pendingVLALengths.removeLast(pendingVLALengths.count - lengthsBefore) }
            let value = operandType.flatMap { sizeOrAlignment(ofType: $0, isAlignment: opKind == .kwAlignof, at: opTok, tokens: tokens) }
            return block.block.appendIntLiteral(value: value ?? 0, type: sizeType, node: exprNode)
        }
        if opKind == .ampAmp {
            // GNU `&&label`: the address of a label, a `void *`
            let voidPtr = QualType(typeId: typePool.pointerTo(.void))
            nodeTypes[exprNode] = voidPtr.typeId
            let number = labelNumber(spelling(of: tree.token(of: child), in: tokens))
            return emit(.labelAddress, voidPtr, number, node: exprNode)
        }

        let inner = analyzeExpression(child, tree: tree, tokens: tokens)
        let innerType = typeOf(inner)
        checkUnaryOperand(opKind, operandNode: child, operand: inner, at: opTok, tree: tree, tokens: tokens)

        switch opKind {
        case .minus, .tilde, .plus:
            // The integer promotions apply to the operand, whose type the result has (C23 6.5.3.3)
            let value = promoted(rvalue(inner))
            let type = isTyped(value) ? typeOf(value) : innerType
            nodeTypes[exprNode] = type.typeId
            if opKind == .plus { return value }
            return emit(opKind == .minus ? .neg : .bitNot, type, value.rawIndex, node: exprNode)
        case .exclaim:
            nodeTypes[exprNode] = .int
            return emit(.logicalNot, .int, conditionValue(inner).rawIndex, node: exprNode)
        case .amp:
            let type = QualType(typeId: typePool.pointerTo(innerType))
            nodeTypes[exprNode] = type.typeId
            return emit(.addrOf, type, inner.rawIndex, node: exprNode)
        case .star:
            let type = typePool.pointeeType(of: innerType.typeId)
            nodeTypes[exprNode] = type.typeId
            return emit(.deref, type, rvalue(inner).rawIndex, node: exprNode)
        case .plusPlus, .minusMinus:
            // The operator precedes its operand's tokens when prefix, and follows them when postfix
            let isPrefix = opTok.rawIndex < tree.token(of: child).rawIndex
            let kind: SemInstKind = opKind == .plusPlus ? (isPrefix ? .preInc : .postInc) : (isPrefix ? .preDec : .postDec)
            nodeTypes[exprNode] = innerType.typeId
            return emit(kind, innerType.unqualified(), inner.rawIndex, node: exprNode)
        default:
            // `__real__`, `__imag__` and other GNU operators are not modeled
            nodeTypes[exprNode] = innerType.typeId
            return emit(.errorInst, innerType, inner.rawIndex, node: exprNode)
        }
    }

    /// A function call (C23 6.5.2.2): the callee converted to a pointer, each argument converted as if by
    /// assignment to its parameter's type, and the default argument promotions for the rest. Builtins that fold to
    /// constants (`__builtin_offsetof`, ...) become them, and `__builtin_va_arg` becomes `vaArg`.
    private mutating func analyzeCall(_ exprNode: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> SemInstId {
        let children = tree.children(of: exprNode)
        guard children.count >= 1 else {
            return emit(.errorInst, .int, node: exprNode)
        }
        let calleeNode = children[0]
        let calleeName = (tree.kind(of: calleeNode) == .identExpr) ? spelling(of: tree.token(of: calleeNode), in: tokens) : ""
        let argNodes = children.count > 1 ? tree.children(of: children[1]) : []

        if calleeName == "__builtin_va_arg", argNodes.count == 2, isTypeNode(tree.kind(of: argNodes[1])) {
            let type = resolveType(from: argNodes[1], tree: tree, tokens: tokens)
            let list = analyzeExpression(argNodes[0], tree: tree, tokens: tokens)
            nodeTypes[exprNode] = type.typeId
            return emit(.vaArg, type, list.rawIndex, node: exprNode)
        }
        if isBuiltinFunctionName(calleeName), currentScope.lookupOrdinary(calleeName) == nil || calleeName == "__builtin_offsetof",
           let value = constantValue(exprNode, tree: tree, tokens: tokens) {
            // `__builtin_offsetof`, `__atomic_always_lock_free`, ...: integer constants
            _ = analyzeExpression(calleeNode, tree: tree, tokens: tokens)  // declares the builtin, as for any call
            block.block.truncate(to: block.block.mark())
            nodeTypes[exprNode] = value.type
            return block.block.appendIntLiteral(value: value.signedValue, type: QualType(typeId: value.type), node: exprNode)
        }

        let callee = analyzeExpression(calleeNode, tree: tree, tokens: tokens)
        let calleeType = typeOf(callee)

        var retType: QualType = .int
        var calleeInfo = typePool.typeInfo(of: typePool.canonical(of: calleeType.typeId))
        if case .pointer(let pointee) = calleeInfo.kind {
            calleeInfo = typePool.typeInfo(of: typePool.canonical(of: pointee.typeId))
        }
        var calleeParamCount: Int? = nil
        var calleeVariadic = true
        var paramTypes: [QualType] = []
        if case .function(let rType, let pTypes, let variadic) = calleeInfo.kind {
            retType = rType
            calleeParamCount = pTypes.count
            calleeVariadic = variadic
            paramTypes = pTypes
        } else if case .error = calleeInfo.kind {
            // Callee type not modeled (e.g. a function pointer from a parenthesized declarator)
            retType = .error
        } else if !isTyped(callee) {
            retType = .error
        } else {
            reportError("called object is not a function or function pointer", diagId: .semaNotCallable, at: tree.token(of: exprNode), in: tokens, args: ["\(calleeType)"])
        }

        let isOffsetof = (calleeName == "__builtin_offsetof")
        var args: [(inst: SemInstId, node: NodeId)] = []
        for (argIdx, arg) in argNodes.enumerated() {
            if isTypeNode(tree.kind(of: arg)) {
                let t = resolveType(from: arg, tree: tree, tokens: tokens)
                pendingVLALengths.removeAll()
                if calleeName == "__builtin_va_arg" && argIdx == 1 {
                    retType = t
                }
            } else if isOffsetof && argIdx == 1 {
                // Second argument of __builtin_offsetof(type, member) is a member designator, not a variable
                continue
            } else {
                args.append((analyzeExpression(arg, tree: tree, tokens: tokens), arg))
            }
        }

        // Argument count against the prototype (C23 6.5.2.2p2), for calls through functions and function pointers
        if let paramCount = calleeParamCount, !calleeName.hasPrefix("__builtin_"), !builtinNames.contains(calleeName) {
            let argCount = argNodes.count
            if argCount < paramCount || (argCount > paramCount && !calleeVariadic) {
                reportError("wrong number of arguments to function call", diagId: .semaCallArgCountMismatch, at: tree.token(of: exprNode), in: tokens,
                            args: [argCount < paramCount ? "few" : "many", "\(paramCount)", "\(argCount)"])
            }
        }

        nodeTypes[exprNode] = retType.typeId
        let calleeValue = rvalue(callee)
        let directDecl: DeclId
        if kindOf(callee) == .declRef, declTable.kind(of: DeclId(block.block.arg0[callee])) == .function {
            directDecl = DeclId(block.block.arg0[callee])
        } else {
            directDecl = .nilId
        }
        var items: [UInt32] = [directDecl.rawIndex, UInt32(paramTypes.count), UInt32(args.count)]
        for (i, arg) in args.enumerated() {
            let value = i < paramTypes.count
                ? convertForAssignment(arg.inst, node: arg.node, to: paramTypes[i], tree: tree, tokens: tokens)
                : argumentPromoted(rvalue(arg.inst))
            items.append(value.rawIndex)
        }
        return emitList(.call, retType.unqualified(), arg0: calleeValue.rawIndex, items: items, node: exprNode)
    }

    // MARK: - Initializers (C23 6.7.10)

    /// A subobject being initialized by a braced initializer: either a value for the whole subobject (a scalar, a
    /// string literal for a character array, a struct or union rvalue), or initializers for its elements by index.
    private final class InitNode {
        let type: QualType
        var value: SemInstId = .nilId
        var elements: [Int: InitNode] = [:]
        /// GNU `[lo ... hi]` designators: the number of elements the entry at an index initializes.
        var counts: [Int: Int] = [:]
        /// One past the highest element index initialized (an array of unknown size takes this length).
        var length = 0

        init(type: QualType) { self.type = type }

        /// The node of element `index`: a fresh one if `fresh` (a braced initializer replaces the element's previous
        /// initializer), else the existing aggregate node (a designator into it keeps its other elements).
        func child(_ index: Int, type: QualType, fresh: Bool) -> InitNode {
            if !fresh, let existing = elements[index], !existing.value.isValid { return existing }
            let node = InitNode(type: type)
            elements[index] = node
            counts[index] = nil
            // A later initializer overrides the part of a range it overlaps; the range keeps the elements before it
            for (start, count) in counts where start < index && start + count > index { counts[start] = index - start }
            length = max(length, index + 1)
            return node
        }

        /// Makes the range `[lo, lo + count)` initialized by the entry at `lo` override the entries it overlaps: a
        /// later range starts after it, an earlier one is cut short where it begins.
        func claim(_ lo: Int, count: Int) {
            counts[lo] = count
            length = max(length, lo + count)
            for start in elements.keys.sorted() where start != lo {
                let end = start + (counts[start] ?? 1)
                if start < lo && end > lo {
                    counts[start] = lo - start
                } else if start > lo && start < lo + count {
                    let entry = elements.removeValue(forKey: start)
                    counts[start] = nil
                    if end > lo + count, let entry {
                        elements[lo + count] = entry
                        counts[lo + count] = end - (lo + count)
                    }
                }
            }
        }
    }

    /// The element of an aggregate initialized at `index`: an array element, or the struct or union member with that
    /// field ordinal (unnamed bit-fields are skipped by `nextIndex`). Nil past the end; an array of unknown size has
    /// no end.
    private func initElementType(of type: QualType, at index: Int) -> QualType? {
        switch canonicalKind(type) {
        case .array(let element, let count):
            let unbounded = count == 0 && !typePool.isVariableLengthArray(type.typeId)
            return unbounded || UInt64(index) < count ? QualType(rawValue: element.rawValue | UInt32(type.qualifiers)) : nil
        case .struct(_, let fields, _):
            guard index < fields.count else { return nil }
            return QualType(rawValue: fields[index].type.rawValue | UInt32(type.qualifiers & 0b011))
        default:
            return nil
        }
    }

    /// The first index at or after `index` that an initializer can initialize: unnamed bit-fields are skipped
    /// (C23 6.7.10p9), and a union takes only its first member positionally.
    private func nextIndex(of type: QualType, from index: Int, positional: Bool) -> Int {
        guard case .struct(_, let fields, let isUnion) = canonicalKind(type) else { return index }
        if isUnion && positional && index > 0 { return fields.count }
        var i = index
        while i < fields.count, fields[i].name.isEmpty, fields[i].bitWidth != nil { i += 1 }
        return i
    }

    private func isAggregate(_ t: QualType) -> Bool {
        switch canonicalKind(t) {
        case .array, .struct: return true
        default: return false
        }
    }

    /// A character array a string literal can initialize: an array of integers of the literal's element size.
    private func isStringInitializable(_ array: QualType, by node: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> Bool {
        guard tree.kind(of: node) == .stringLiteral, case .array(let element, _) = canonicalKind(array),
              typePool.isInteger(type: element.typeId) else { return false }
        let info = stringLiteralInfo(tree.token(of: node), tokens: tokens)
        return typePool.size(of: element.typeId) == typePool.size(of: info.element)
    }

    /// The initializer `node` of an object of `type`, resolved (C23 6.7.10): an `initList` for a braced initializer
    /// (a scalar's too), a string literal for a character array, or the value converted as if by assignment.
    /// Returns the instruction, the analyzed expression of a non-braced initializer (for the assignment constraints),
    /// and the type completed by the initializer (an array of unknown size takes its length from it).
    private mutating func resolveInitializer(_ node: NodeId, type: QualType, tree: borrowing ParseTree,
                                             tokens: borrowing TokenBuffer) -> (inst: SemInstId, raw: SemInstId, type: QualType) {
        if type.isError {
            let raw = analyzeExpression(node, tree: tree, tokens: tokens)
            return (rvalue(raw), raw, type)
        }
        if tree.kind(of: node) == .initList {
            let items = tree.children(of: node)
            // `char s[] = { "abc" }`
            if items.count == 1, isStringInitializable(type, by: items[0], tree: tree, tokens: tokens) {
                let s = analyzeExpression(items[0], tree: tree, tokens: tokens)
                return (s, .nilId, completedArrayType(type, length: Int(stringLiteralInfo(tree.token(of: items[0]), tokens: tokens).length)))
            }
            let root = InitNode(type: type)
            if isAggregate(type) {
                resolveBracedList(node, into: root, tree: tree, tokens: tokens)
            } else if let first = items.first {
                // Braces around a scalar initializer (C23 6.7.10p11); excess initializers are diagnosed as warnings
                let value = resolveInitializer(first, type: type, tree: tree, tokens: tokens).inst
                for extra in items.dropFirst() { _ = analyzeExpression(extra, tree: tree, tokens: tokens) }
                return (value, .nilId, type)
            }
            let completed = completedArrayType(type, length: root.length)
            let inst = emitInitializer(root, type: completed, node: node)
            return (inst, .nilId, completed)
        }
        if isStringInitializable(type, by: node, tree: tree, tokens: tokens) {
            let s = analyzeExpression(node, tree: tree, tokens: tokens)
            return (s, .nilId, completedArrayType(type, length: Int(stringLiteralInfo(tree.token(of: node), tokens: tokens).length)))
        }
        let raw = analyzeExpression(node, tree: tree, tokens: tokens)
        return (convertForAssignment(raw, node: node, to: type, tree: tree, tokens: tokens), raw, type)
    }

    /// `type` completed to `length` elements if it is an array of unknown size.
    private func completedArrayType(_ type: QualType, length: Int) -> QualType {
        guard case .array(let element, 0) = canonicalKind(type), !typePool.isVariableLengthArray(type.typeId), length > 0 else { return type }
        return QualType(typeId: typePool.arrayType(elementType: element, count: UInt64(length)), qualifiers: type.qualifiers)
    }

    /// Resolves the items of braced list `list` into `root` (C23 6.7.10p17-21): positional items initialize the next
    /// subobject in order, descending into a sub-aggregate whose initializer has no braces (brace elision); a
    /// designation selects the subobject from the list's object, and the items after it continue from there.
    private mutating func resolveBracedList(_ list: NodeId, into root: InitNode, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        // The current object hierarchy: each frame's node and the index of its next subobject
        var frames: [(node: InitNode, next: Int)] = [(root, nextIndex(of: root.type, from: 0, positional: false))]
        for item in tree.children(of: list) {
            guard tree.kind(of: item) == .designatedInit else {
                placeInitializer(item, frames: &frames, designated: false, tree: tree, tokens: tokens)
                continue
            }
            let children = tree.children(of: item)
            guard let valueNode = children.last else { continue }
            guard let path = designatorPath(item, indexNodes: Array(children.dropLast()), type: root.type, tree: tree, tokens: tokens) else {
                // An invalid designator: the value is still checked
                _ = analyzeExpression(valueNode, tree: tree, tokens: tokens)
                continue
            }
            frames = [(root, 0)]
            for (k, step) in path.enumerated() {
                let top = frames[frames.count - 1]
                frames[frames.count - 1].next = step.index
                guard k < path.count - 1, let elementType = initElementType(of: top.node.type, at: step.index) else { break }
                frames.append((top.node.child(step.index, type: elementType, fresh: false), 0))
            }
            let level = frames.count - 1
            placeInitializer(valueNode, frames: &frames, designated: true, tree: tree, tokens: tokens)
            if let last = path.last, last.count > 1, level < frames.count {
                // `[lo ... hi] = v` initializes each element of the range with v (evaluated once)
                frames[level].node.claim(last.index, count: last.count)
                if frames.count == level + 1 { frames[level].next = max(frames[level].next, last.index + last.count) }
            }
        }
    }

    /// The path of a designation (`.a.b[2]`, `[lo ... hi]`): per designator, the field ordinal or array index (through
    /// anonymous members, a field is several steps) and the number of elements of a range. Nil if a designator
    /// names no member or index of the current object (diagnosed).
    private mutating func designatorPath(_ item: NodeId, indexNodes: [NodeId], type: QualType, tree: borrowing ParseTree,
                                         tokens: borrowing TokenBuffer) -> [(index: Int, count: Int)]? {
        var path: [(index: Int, count: Int)] = []
        var current = type
        var nodes = indexNodes[...]
        // The designators are tokens from the first `.` or `[` to the `=`; index expressions are the item's children
        var i = Int(tree.token(of: item).rawIndex)
        if CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) == .identifier { i -= 1 }  // anchored at `.a`'s name
        while i < tokens.count {
            let tok = TokenId(UInt32(i))
            switch CTokenKind(rawValue: tokens.kind(of: tok)) {
            case .period:
                let nameTok = TokenId(UInt32(i + 1))
                let name = spelling(of: nameTok, in: tokens)
                guard let fieldPath = typePool.fieldPath(named: name, in: current.typeId) else {
                    if !current.isError && isStructOrUnion(current) {
                        reportError("field designator does not refer to any field", diagId: .semaInvalidMember, at: nameTok, in: tokens,
                                    args: [name, typeName(current.unqualified())])
                    }
                    return nil
                }
                for index in fieldPath {
                    guard let next = initElementType(of: current, at: index) else { return nil }
                    path.append((index, 1))
                    current = next
                }
                i += 2
            case .lBracket:
                guard let indexNode = nodes.popFirst(), let lo = constantValue(indexNode, tree: tree, tokens: tokens), !lo.isNegative else { return nil }
                var count = 1
                // A GNU range has a second index expression
                var j = i + 1
                var depth = 0
                while j < tokens.count {
                    let k = CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(j))))
                    if k == .lBracket || k == .lParen { depth += 1 }
                    if k == .rParen { depth -= 1 }
                    if k == .rBracket { if depth == 0 { break }; depth -= 1 }
                    if k == .ellipsis && depth == 0, let hiNode = nodes.popFirst(), let hi = constantValue(hiNode, tree: tree, tokens: tokens) {
                        count = max(1, Int(clamping: hi.signedValue - lo.signedValue + 1))
                    }
                    j += 1
                }
                guard case .array = canonicalKind(current), let next = initElementType(of: current, at: Int(clamping: lo.bits)) else { return nil }
                path.append((Int(clamping: lo.bits), count))
                current = next
                i = j + 1
            default:
                return path.isEmpty ? nil : path
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Places one initializer at the current position of `frames` (C23 6.7.10p20): a braced list initializes the
    /// next subobject entirely; an expression initializes it if it is a scalar, a compatible struct or union, or a
    /// character array initialized by a string literal; otherwise the expression initializes the subobject's first
    /// element, recursively (brace elision). Frames whose object is exhausted are popped.
    private mutating func placeInitializer(_ item: NodeId, frames: inout [(node: InitNode, next: Int)], designated: Bool,
                                           tree: borrowing ParseTree, tokens: borrowing TokenBuffer) {
        var analyzed: SemInstId? = nil
        var isDesignatedPosition = designated
        while true {
            let top = frames[frames.count - 1]
            let index = isDesignatedPosition ? top.next : nextIndex(of: top.node.type, from: top.next, positional: top.next > 0)
            isDesignatedPosition = false
            guard let elementType = initElementType(of: top.node.type, at: index) else {
                if frames.count > 1 {
                    frames.removeLast()
                    frames[frames.count - 1].next += 1
                    continue
                }
                // An excess initializer (a warning in Clang): checked, then dropped
                if analyzed == nil && tree.kind(of: item) != .initList { _ = analyzeExpression(item, tree: tree, tokens: tokens) }
                return
            }
            frames[frames.count - 1].next = index
            if tree.kind(of: item) == .initList {
                let child = top.node.child(index, type: elementType, fresh: true)
                if isAggregate(elementType) {
                    if tree.children(of: item).count == 1, isStringInitializable(elementType, by: tree.children(of: item)[0], tree: tree, tokens: tokens) {
                        child.value = analyzeExpression(tree.children(of: item)[0], tree: tree, tokens: tokens)
                    } else {
                        resolveBracedList(item, into: child, tree: tree, tokens: tokens)
                    }
                } else {
                    child.value = resolveInitializer(item, type: elementType, tree: tree, tokens: tokens).inst
                }
                frames[frames.count - 1].next = index + 1
                return
            }
            if isAggregate(elementType) {
                if isStringInitializable(elementType, by: item, tree: tree, tokens: tokens) {
                    top.node.child(index, type: elementType, fresh: true).value = analyzed ?? analyzeExpression(item, tree: tree, tokens: tokens)
                    frames[frames.count - 1].next = index + 1
                    return
                }
                let value = analyzed ?? analyzeExpression(item, tree: tree, tokens: tokens)
                analyzed = value
                if isStructOrUnion(elementType), isTyped(value), typesCompatible(typeOf(value).unqualified(), elementType.unqualified()) {
                    top.node.child(index, type: elementType, fresh: true).value = rvalue(value)
                    frames[frames.count - 1].next = index + 1
                    return
                }
                if !isTyped(value) && !isArrayType(elementType) && isStructOrUnion(elementType) && typeOf(value).isError {
                    // An unmodeled value: assume it initializes the whole member
                    top.node.child(index, type: elementType, fresh: true).value = value
                    frames[frames.count - 1].next = index + 1
                    return
                }
                // Brace elision: initialize the sub-aggregate's first element with this expression
                frames.append((top.node.child(index, type: elementType, fresh: false), 0))
                continue
            }
            let value = analyzed ?? analyzeExpression(item, tree: tree, tokens: tokens)
            top.node.child(index, type: elementType, fresh: true).value =
                convertForAssignment(value, node: item, to: elementType, tree: tree, tokens: tokens)
            frames[frames.count - 1].next = index + 1
            return
        }
    }

    /// Emits the resolved initializer tree: an `initList` of (index, count, value) triples sorted by index.
    private mutating func emitInitializer(_ node: InitNode, type: QualType, node parseNode: NodeId) -> SemInstId {
        if node.value.isValid { return node.value }
        var items: [UInt32] = []
        for index in node.elements.keys.sorted() {
            let child = node.elements[index]!
            let value = emitInitializer(child, type: child.type, node: parseNode)
            items += [UInt32(index), UInt32(node.counts[index] ?? 1), value.rawIndex]
        }
        return emitList(.initList, type, items: items, node: parseNode)
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

    /// The type of a `sizeof`/`alignof` operand: a type name, or the type of an expression, which is not evaluated
    /// (its instructions are discarded). Nil if the expression's type is not modeled.
    private mutating func sizeofOperandType(_ operand: NodeId, tree: borrowing ParseTree, tokens: borrowing TokenBuffer) -> QualType? {
        if isTypeNode(tree.kind(of: operand)) {
            return resolveType(from: operand, tree: tree, tokens: tokens)
        }
        let mark = block.block.mark()
        let lengths = pendingVLALengths.count
        unevaluatedDepth += 1
        let inner = analyzeExpression(operand, tree: tree, tokens: tokens)
        let type: QualType? = isTyped(inner) ? typeOf(inner) : nil
        unevaluatedDepth -= 1
        block.block.truncate(to: mark)
        if pendingVLALengths.count > lengths { pendingVLALengths.removeLast(pendingVLALengths.count - lengths) }
        return type
    }

    /// `sizeof` / `alignof` of a type (C23 6.5.3.4): not a function type (GNU: 1) nor an incomplete type (GNU: `void`
    /// has size 1). Nil if the type is not modeled, or for `sizeof` of a variable length array (not a constant).
    private mutating func sizeOrAlignment(ofType type: QualType, isAlignment: Bool, at tok: TokenId, tokens: borrowing TokenBuffer) -> Int64? {
        guard !type.isError else { return nil }
        let can = typePool.canonical(of: type.typeId)
        if can == .void || isFunctionType(type) { return 1 }
        if !isAlignment && typePool.isVariableLengthArray(can) { return nil }
        if !typePool.isComplete(can) {
            reportError("invalid application of 'sizeof' to an incomplete type", diagId: .semaInvalidExpression, at: tok, in: tokens,
                        args: ["invalid application of '\(isAlignment ? "alignof" : "sizeof")' to an incomplete type '\(typeName(type))'"])
            return nil
        }
        // An aligned typedef has its own alignment, and the size of the type it names
        return Int64(isAlignment ? typePool.alignment(of: type.typeId) : typePool.size(of: can))
    }

    /// `sizeof` / `alignof` of a type name or an expression's type, for constant evaluation.
    private mutating func sizeOrAlignment(of operand: NodeId, isAlignment: Bool, at tok: TokenId, tree: borrowing ParseTree,
                                          tokens: borrowing TokenBuffer) -> Int64? {
        guard let type = sizeofOperandType(operand, tree: tree, tokens: tokens) else { return nil }
        return sizeOrAlignment(ofType: type, isAlignment: isAlignment, at: tok, tokens: tokens)
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

    /// A character constant's value and type (C23 6.4.4.5): `int` unprefixed, `wchar_t` for `L`, `char8_t`
    /// (`unsigned char`) for `u8`, `char16_t` (`unsigned short`) for `u`, `char32_t` (`unsigned int`) for `U`. A
    /// single-byte unprefixed constant has the value of a `char`, whose signedness is the target's.
    private func characterConstant(_ raw: String) -> IntConst? {
        let value = UInt64(bitPattern: CLiteral.characterValue(raw, charIsSigned: dataLayout.charIsSigned))
        if raw.hasPrefix("u8") { return makeConst(value, .uchar) }
        if raw.hasPrefix("u") { return makeConst(value, .ushort) }
        if raw.hasPrefix("U") { return makeConst(value, .uint) }
        if raw.hasPrefix("L") { return makeConst(value, dataLayout.wcharType) }
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
            else if text.hasPrefix("U") || text.hasPrefix("L") { element = text.hasPrefix("U") ? .uint : dataLayout.wcharType }
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

    /// The code units of a string literal and the literals concatenated with it (C23 6.4.5p5-6), in the target's
    /// (little-endian) byte order, with the terminator: UTF-8 for ordinary and `u8` literals, UTF-16 for `u`, UTF-32
    /// for `U`, and `wchar_t` (32-bit) for `L`. An octal or hexadecimal escape is one code unit.
    private func stringLiteralConstant(_ first: TokenId, tokens: borrowing TokenBuffer) -> StringConstant {
        var encoding = StringEncoding.ordinary
        var bodies: [Substring] = []
        var i = Int(first.rawIndex)
        while i < tokens.count, CTokenKind(rawValue: tokens.kind(of: TokenId(UInt32(i)))) == .stringLiteral {
            let text = spelling(of: TokenId(UInt32(i)), in: tokens)
            if text.hasPrefix("u8") { encoding = .utf8 }
            else if text.hasPrefix("u") { encoding = .utf16 }
            else if text.hasPrefix("U") { encoding = .utf32 }
            else if text.hasPrefix("L") { encoding = .wide }
            bodies.append(CLiteral.body(of: text, quote: "\""))
            i += 1
        }
        let unitSize: Int
        switch encoding {
        case .ordinary, .utf8: unitSize = 1
        case .utf16: unitSize = 2
        case .utf32, .wide: unitSize = 4
        }
        var units: [UInt32] = []
        for body in bodies { units += CLiteral.codeUnits(body, unitSize: unitSize) }
        units.append(0)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count * unitSize)
        for unit in units {
            for b in 0..<unitSize { bytes.append(UInt8(truncatingIfNeeded: unit >> UInt32(8 * b))) }
        }
        return StringConstant(bytes: bytes, elementSize: unitSize, encoding: encoding)
    }

    /// The format of a floating type.
    private func floatFormat(of type: TypeId) -> FloatFormat? {
        typePool.floatFormat(of: type)
    }

    /// A floating constant's spelling without digit separators and its suffix (`f`, `l`, `f16`, `f32x`, ...).
    private func floatingConstantBody(_ raw: String) -> String {
        var s = raw.filter { $0 != "'" }
        let lower = s.lowercased()
        let isHex = lower.hasPrefix("0x")
        for suffix in ["f32x", "f64x", "f128", "bf16", "f16", "f32", "f64", "df", "dd", "dl"] where lower.hasSuffix(suffix) {
            // A hexadecimal constant's digits never end a binary exponent, so its suffix is never mistaken for one
            s.removeLast(suffix.count)
            return s
        }
        if let last = lower.last, last == "l" || (last == "f" && (!isHex || lower.contains("p"))) {
            s.removeLast()
        }
        return s
    }
}
