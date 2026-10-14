// Sources/SwiftStack/Sem/TypePool.swift
import Foundation

/// Canonical type representation for the C subset (02-semantic-analysis.md §4.1).
public enum CTypeKind: Sendable, Equatable {
    case void
    case int
    case long
    case char
    case pointer(pointee: TypeId)
    case function(returnType: TypeId, paramTypes: [TypeId])
}

public struct CTypeInfo: Sendable, Equatable {
    public let kind: CTypeKind
    public let size: Int
    public let alignment: Int

    public init(kind: CTypeKind, size: Int, alignment: Int) {
        self.kind = kind
        self.size = size
        self.alignment = alignment
    }
}

/// A pool interning canonical types for C23 semantic analysis.
/// Row 0 is the nil type; rows 1..5 are pre-seeded primitive types.
public final class TypePool {
    private var types: [CTypeInfo] = []
    private var pointerCache: [TypeId: TypeId] = [:]

    public init() {
        // Row 0: Nil type
        types.append(CTypeInfo(kind: .void, size: 0, alignment: 1))

        // Row 1: void (TypeId.void)
        types.append(CTypeInfo(kind: .void, size: 0, alignment: 1))

        // Row 2: int (TypeId.int, 32-bit signed)
        types.append(CTypeInfo(kind: .int, size: 4, alignment: 4))

        // Row 3: long (TypeId.long, 64-bit signed)
        types.append(CTypeInfo(kind: .long, size: 8, alignment: 8))

        // Row 4: char (TypeId.char, 8-bit)
        types.append(CTypeInfo(kind: .char, size: 1, alignment: 1))

        // Row 5: pointer (TypeId.pointer, void*)
        types.append(CTypeInfo(kind: .pointer(pointee: .void), size: 8, alignment: 8))
        pointerCache[.void] = TypeId.pointer
    }

    public var count: Int { types.count }

    public func typeInfo(of id: TypeId) -> CTypeInfo {
        let idx = Int(id.rawIndex)
        guard idx >= 0 && idx < types.count else { return types[0] }
        return types[idx]
    }

    public func size(of id: TypeId) -> Int {
        typeInfo(of: id).size
    }

    public func alignment(of id: TypeId) -> Int {
        typeInfo(of: id).alignment
    }

    public func isPointer(type: TypeId) -> Bool {
        if case .pointer = typeInfo(of: type).kind { return true }
        return false
    }

    public func pointeeType(of type: TypeId) -> TypeId {
        if case .pointer(let pointee) = typeInfo(of: type).kind {
            return pointee
        }
        return .void
    }

    public func pointerTo(_ pointee: TypeId) -> TypeId {
        if let existing = pointerCache[pointee] {
            return existing
        }
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .pointer(pointee: pointee), size: 8, alignment: 8))
        pointerCache[pointee] = id
        return id
    }

    public func functionType(returnType: TypeId, paramTypes: [TypeId]) -> TypeId {
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .function(returnType: returnType, paramTypes: paramTypes), size: 8, alignment: 8))
        return id
    }
}
