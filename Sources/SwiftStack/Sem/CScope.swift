// Sources/SwiftStack/Sem/CScope.swift
import Foundation

/// Storage duration and linkage of a symbol in C (02-semantic-analysis.md §4.2).
public enum CSymbolStorage: Equatable, Sendable {
    case global(name: String)
    case function(name: String)
    case param(index: Int, offset: Int32)
    case local(offset: Int32)
    case typedef
    case enumConstant(value: Int64)
}

/// A resolved symbol in the C ordinary identifier namespace.
public struct CSymbol: Equatable, Sendable {
    public let name: String
    public let declId: DeclId
    public let type: QualType
    public let storage: CSymbolStorage

    public init(name: String, declId: DeclId = .nilId, type: QualType, storage: CSymbolStorage) {
        self.name = name
        self.declId = declId
        self.type = type
        self.storage = storage
    }
}

/// Lexical scope implementing the 4 separate C namespaces (10-semantic-ir-and-name-resolution.md §4.3):
/// 1. Ordinary identifiers (vars, funcs, typedefs, enum constants)
/// 2. Tag types (structs, unions, enums)
/// 3. Labels (function-scoped)
/// 4. Members (per-struct/union, resolved via TypePool)
public final class CScope {
    public let parent: CScope?
    private var ordinarySymbols: [String: CSymbol] = [:]
    private var tagSymbols: [String: TypeId] = [:]
    private var labels: [String: NodeId] = [:] // Function-scoped

    public init(parent: CScope? = nil) {
        self.parent = parent
    }

    // MARK: - Ordinary Identifier Namespace

    public func insertOrdinary(symbol: CSymbol) {
        ordinarySymbols[symbol.name] = symbol
    }

    public func lookupOrdinary(_ name: String) -> CSymbol? {
        if let sym = ordinarySymbols[name] {
            return sym
        }
        return parent?.lookupOrdinary(name)
    }

    public func lookupLocalOrdinary(_ name: String) -> CSymbol? {
        ordinarySymbols[name]
    }

    // MARK: - Tag Namespace (struct / union / enum)

    public func insertTag(name: String, typeId: TypeId) {
        tagSymbols[name] = typeId
    }

    public func lookupTag(_ name: String) -> TypeId? {
        if let tid = tagSymbols[name] {
            return tid
        }
        return parent?.lookupTag(name)
    }

    public func lookupLocalTag(_ name: String) -> TypeId? {
        tagSymbols[name]
    }

    // MARK: - Label Namespace (function-scoped)

    public func insertLabel(name: String, node: NodeId) {
        if let parent = parent {
            parent.insertLabel(name: name, node: node)
        } else {
            labels[name] = node
        }
    }

    public func lookupLabel(_ name: String) -> NodeId? {
        if let parent = parent {
            return parent.lookupLabel(name)
        }
        return labels[name]
    }
}
