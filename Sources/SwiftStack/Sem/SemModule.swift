// Sources/SwiftStack/Sem/SemModule.swift
import Foundation

public final class SemInstBlockContainer: @unchecked Sendable {
    public var block: SemInstBlock
    public init(block: consuming SemInstBlock) {
        self.block = block
    }
}

/// Storage of a declared object or function (C23 6.2.2, 6.2.4), kept in `DeclTable.attrs` (`DeclAttributes`).
@frozen
public enum DeclStorage: UInt32, Sendable {
    case none = 0
    /// Automatic storage: a block-scope object without `static`/`extern` (also `register`), or a compound literal
    /// in a function body.
    case automatic = 1
    case parameter = 2
    /// Static storage with internal or no linkage: a file-scope `static`, a block-scope `static`, a file-scope
    /// compound literal.
    case internalStatic = 3
    /// External linkage: a file-scope declaration without `static`, or a block-scope `extern`.
    case external = 4
}

/// `DeclTable.attrs` for C objects and functions: storage in the low 4 bits, then flags.
public struct DeclAttributes: Sendable, Equatable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init(storage: DeclStorage, isThreadLocal: Bool = false, isDefinition: Bool = false) {
        rawValue = storage.rawValue | (isThreadLocal ? 0x10 : 0) | (isDefinition ? 0x20 : 0)
    }

    public var storage: DeclStorage { DeclStorage(rawValue: rawValue & 0xF) ?? .none }
    public var isThreadLocal: Bool { rawValue & 0x10 != 0 }
    public var isDefinition: Bool { rawValue & 0x20 != 0 }
    public var hasStaticStorage: Bool { storage == .internalStatic || storage == .external }
}

/// A function definition: its body block and parameters (in order).
public struct SemFunction: Sendable {
    public let declId: DeclId
    public let name: String
    public let blockId: InstBlockId
    public let params: [DeclId]
    /// Label names by number (index 0 is unused).
    public let labels: [String]
    public let isExternal: Bool
}

/// A relocation in a static object's data image: the address of `target` plus `addend`, stored in `size` bytes at
/// `offset`.
public struct DataRelocation: Sendable, Equatable {
    public enum Target: Sendable, Equatable, Hashable {
        /// An object or function, by its declaration.
        case decl(DeclId)
        /// A string literal in `SemModule.staticStrings`.
        case string(Int)
        /// A label of a function (GNU `&&label`), by its number.
        case label(function: DeclId, label: UInt32)
    }

    public let offset: Int
    public let size: Int
    public let target: Target
    public let addend: Int64
}

/// The initial contents of a static-storage object (C23 6.7.10p10): its bytes, with relocations for the address
/// constants in it.
public struct DataImage: Sendable, Equatable {
    public var bytes: [UInt8]
    public var relocations: [DataRelocation]

    public init(size: Int) {
        bytes = [UInt8](repeating: 0, count: size)
        relocations = []
    }

    public init(bytes: [UInt8], relocations: [DataRelocation] = []) {
        self.bytes = bytes
        self.relocations = relocations
    }

    public var isZero: Bool { relocations.isEmpty && bytes.allSatisfy { $0 == 0 } }
}

/// An object with static storage duration defined in the unit: a file-scope definition (or tentative definition),
/// a block-scope `static`, or a file-scope compound literal.
public struct SemGlobal: Sendable {
    public let declId: DeclId
    /// The object's symbol: its name, `function.name` for a block-scope static (as Clang names them), or
    /// `.compoundliteral` for a compound literal.
    public let symbol: String
    public let type: QualType
    public let isExternal: Bool
    public let isThreadLocal: Bool
    public let alignment: Int
    /// Where the initializer was analyzed (`.nilId`: the file-scope block), and its root (0: none, zero-initialized).
    public let initBlock: InstBlockId
    public let initInst: SemInstId
    public let isTentative: Bool
    /// The data image, from the static-initializer evaluator; nil if the evaluator could not fold the initializer.
    public var image: DataImage?
    /// Why the image is missing.
    public var unsupportedReason: String = ""
}

public final class SemModule: @unchecked Sendable {
    public var declTable: DeclTable
    public var instBlocks: [SemInstBlockContainer]
    public let typePool: TypePool
    public var diagnosticBag: DiagnosticBag
    /// Instructions outside function bodies: file-scope initializers.
    public var fileScopeBlock: SemInstBlockContainer
    public var functions: [SemFunction] = []
    public var globals: [SemGlobal] = []
    /// String literals that static initializers take the address of.
    public var staticStrings: [StringConstant] = []
    /// Symbols of block-scope statics and compound literals (`DeclId` → symbol); other objects are named by their
    /// declaration.
    public var staticSymbols: [DeclId: String] = [:]
    /// GNU `asm("name")` labels: the symbol of each object or function with linkage declared with one, by C name
    /// (glibc's `__REDIRECT` names `stat` `stat64` under `_FILE_OFFSET_BITS=64`).
    public var asmLabels: [String: String] = [:]

    public init(
        declTable: consuming DeclTable,
        instBlocks: [SemInstBlockContainer],
        typePool: TypePool,
        diagnosticBag: consuming DiagnosticBag,
        fileScopeBlock: SemInstBlockContainer = SemInstBlockContainer(block: SemInstBlock())
    ) {
        self.declTable = declTable
        self.instBlocks = instBlocks
        self.typePool = typePool
        self.diagnosticBag = diagnosticBag
        self.fileScopeBlock = fileScopeBlock
    }

    /// The block with `id`; `.nilId` is the file-scope block.
    public func block(_ id: InstBlockId) -> SemInstBlockContainer {
        id.isValid && Int(id.rawIndex) < instBlocks.count ? instBlocks[Int(id.rawIndex)] : fileScopeBlock
    }

    /// The symbol an object or function is known by in the object file.
    public func symbolName(of decl: DeclId) -> String {
        if let symbol = staticSymbols[decl] { return symbol }
        let name = declTable.name(of: decl)
        if let label = asmLabels[name], declTable.kind(of: decl) == .function || attributes(of: decl).hasStaticStorage {
            return label
        }
        return name
    }

    public func attributes(of decl: DeclId) -> DeclAttributes {
        DeclAttributes(rawValue: declTable.attrs[decl])
    }
}

public struct FunctionSignature: Sendable {
    public let name: String
    public let returnType: TypeId
    public let paramNames: [String]
    public let paramTypes: [TypeId]
    public let bodyNode: NodeId // compoundStmt node
    public let declId: DeclId
    public let blockId: InstBlockId
    /// The parameters' declarations, in order (nil for an unnamed parameter).
    public let paramDecls: [DeclId]

    public init(
        name: String,
        returnType: TypeId,
        paramNames: [String],
        paramTypes: [TypeId],
        bodyNode: NodeId,
        declId: DeclId = .nilId,
        blockId: InstBlockId = .nilId,
        paramDecls: [DeclId] = []
    ) {
        self.name = name
        self.returnType = returnType
        self.paramNames = paramNames
        self.paramTypes = paramTypes
        self.bodyNode = bodyNode
        self.declId = declId
        self.blockId = blockId
        self.paramDecls = paramDecls
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
