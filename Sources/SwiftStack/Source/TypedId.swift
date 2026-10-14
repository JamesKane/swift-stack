// Sources/SwiftStack/Source/TypedId.swift

/// A protocol for 32-bit handle types in flat, index-addressed tables.
/// Row 0 is universally reserved as the nil row (Principles 1 and 7).
public protocol TypedId: Hashable, Equatable, Sendable, BitwiseCopyable, CustomStringConvertible {
    var rawIndex: UInt32 { get }
    init(rawIndex: UInt32)
    static var nilId: Self { get }
}

extension TypedId {
    @inlinable
    public static var nilId: Self { Self(rawIndex: 0) }

    @inlinable
    public var isNil: Bool { rawIndex == 0 }

    @inlinable
    public var isValid: Bool { rawIndex != 0 }

    @inlinable
    public var description: String { "\(Self.self)(\(rawIndex))" }
}

/// Token handle in TokenBuffer.
@frozen
public struct TokenId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Source file handle in SourceManager.
@frozen
public struct FileId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Compilation unit handle.
@frozen
public struct UnitId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// ParseTree node handle.
@frozen
public struct NodeId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Interned string / atom handle.
@frozen
public struct AtomId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Diagnostic ID handle.
@frozen
public struct DiagId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Type handle in TypePool.
@frozen
public struct TypeId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    public static let void = TypeId(1)
    public static let int = TypeId(2)
    public static let long = TypeId(3)
    public static let char = TypeId(4)
    public static let pointer = TypeId(5)
}

/// Function handle.
@frozen
public struct FunctionId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// AIR Instruction handle.
@frozen
public struct InstId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// AIR Block handle.
@frozen
public struct BlockId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// AIR Value handle (tagged 32-bit handle per 03 §4.1).
@frozen
public struct ValueId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Index handle for extra operands column.
@frozen
public struct ExtraId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Index handle for block instruction ordering.
@frozen
public struct BlockOrderIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Index handle for successor edge column.
@frozen
public struct SuccEdgeIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Index handle for predecessor edge column.
@frozen
public struct PredEdgeIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// LIR Instruction handle.
@frozen
public struct LIRInstId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// LIR Block handle.
@frozen
public struct LIRBlockId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Symbol handle.
@frozen
public struct SymbolId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Object section index handle.
@frozen
public struct SectionIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Deterministic 16-bit FNV-1a hash for symbol IDs and linkage keys (D6 determinism).
@inlinable
public func fnv1a16(_ str: String) -> UInt32 {
    var h: UInt32 = 0x811c9dc5
    for b in str.utf8 {
        h ^= UInt32(b)
        h = h &* 0x01000193
    }
    return h & 0xFFFF
}

