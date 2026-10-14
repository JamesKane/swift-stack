// Sources/SwiftStack/Sem/DeclTable.swift
import Foundation

/// Declaration kind in the module-wide DeclTable (10-semantic-ir-and-name-resolution.md §4.1).
@frozen
public enum DeclKind: UInt8, BitwiseCopyable, Sendable {
    case nilDecl = 0
    case function = 1
    case variable = 2
    case parameter = 3
    case structDecl = 4
    case unionDecl = 5
    case enumDecl = 6
    case enumConstant = 7
    case typedefDecl = 8
    case fieldDecl = 9
}

/// Module-wide flat SoA declaration table, indexed by DeclId (10-semantic-ir-and-name-resolution.md §4.1).
/// DeclId 0 is universally reserved as the nil declaration (Principle 7).
public struct DeclTable: ~Copyable {
    public var kinds: Column<DeclId, DeclKind>
    public var names: Column<DeclId, AtomId>
    public var parents: Column<DeclId, DeclId>
    public var types: Column<DeclId, QualType>
    public var genericSig: Column<DeclId, UInt32>
    public var bodies: Column<DeclId, UInt32> // InstBlockId of the body, or 0
    public var origin: Column<DeclId, GlobalLocation>
    public var attrs: Column<DeclId, UInt32>

    /// Side storage for string names of declarations for lookup and diagnostics.
    public private(set) var stringNames: [String] = []

    public init(reservedCapacity: Int = 1_048_576) {
        let nilLoc = GlobalLocation(unitId: UnitId(0), location: .zero)
        self.kinds = Column<DeclId, DeclKind>(reservedCapacity: reservedCapacity, defaultNilValue: .nilDecl)
        self.names = Column<DeclId, AtomId>(reservedCapacity: reservedCapacity, defaultNilValue: .nilId)
        self.parents = Column<DeclId, DeclId>(reservedCapacity: reservedCapacity, defaultNilValue: .nilId)
        self.types = Column<DeclId, QualType>(reservedCapacity: reservedCapacity, defaultNilValue: .error)
        self.genericSig = Column<DeclId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.bodies = Column<DeclId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.origin = Column<DeclId, GlobalLocation>(reservedCapacity: reservedCapacity, defaultNilValue: nilLoc)
        self.attrs = Column<DeclId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.stringNames.append("<nil>")
    }

    public var count: UInt32 {
        kinds.count
    }

    /// Appends a new declaration row into the table.
    @discardableResult
    public mutating func append(
        kind: DeclKind,
        name: String,
        atomId: AtomId = .nilId,
        parent: DeclId = .nilId,
        type: QualType = .error,
        genericSig: UInt32 = 0,
        body: UInt32 = 0,
        origin: GlobalLocation = GlobalLocation(unitId: UnitId(0), location: .zero),
        attrs: UInt32 = 0
    ) -> DeclId {
        let id = DeclId(kinds.count)
        _ = kinds.append(kind)
        _ = names.append(atomId)
        _ = parents.append(parent)
        _ = types.append(type)
        _ = self.genericSig.append(genericSig)
        _ = bodies.append(body)
        _ = self.origin.append(origin)
        _ = self.attrs.append(attrs)
        stringNames.append(name)
        return id
    }

    public func name(of id: DeclId) -> String {
        let idx = Int(id.rawIndex)
        guard idx >= 0 && idx < stringNames.count else { return "" }
        return stringNames[idx]
    }

    public func kind(of id: DeclId) -> DeclKind {
        kinds[id]
    }

    public func type(of id: DeclId) -> QualType {
        types[id]
    }

    public func parent(of id: DeclId) -> DeclId {
        parents[id]
    }

    public func body(of id: DeclId) -> UInt32 {
        bodies[id]
    }

    public mutating func setBody(for id: DeclId, blockId: UInt32) {
        bodies[id] = blockId
    }

    public mutating func setType(for id: DeclId, type: QualType) {
        types[id] = type
    }
}
