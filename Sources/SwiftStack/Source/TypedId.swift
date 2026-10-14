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
    public var rawValue: UInt32 { rawIndex }

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(rawValue: UInt32) {
        self.rawIndex = rawValue
    }

    // Reserved slots per 02-semantic-analysis.md §4.1
    public static let error = TypeId(0)
    public static let void = TypeId(1)
    public static let int1 = TypeId(2)
    public static let int8 = TypeId(3)
    public static let int16 = TypeId(4)
    public static let int32 = TypeId(5)
    public static let int64 = TypeId(6)
    public static let int128 = TypeId(7)
    public static let word = TypeId(8)
    public static let intLiteral = TypeId(9)
    public static let float16 = TypeId(10)
    public static let float32 = TypeId(11)
    public static let float64 = TypeId(12)
    public static let float80 = TypeId(13)
    public static let rawPointer = TypeId(14)
    public static let nativeObject = TypeId(15)

    // C Types (16-40)
    public static let bool = TypeId(16)
    public static let char = TypeId(17)
    public static let schar = TypeId(18)
    public static let uchar = TypeId(19)
    public static let short = TypeId(20)
    public static let ushort = TypeId(21)
    public static let int = TypeId(22)
    public static let uint = TypeId(23)
    public static let long = TypeId(24)
    public static let ulong = TypeId(25)
    public static let longlong = TypeId(26)
    public static let ulonglong = TypeId(27)
    public static let float = TypeId(28)
    public static let double = TypeId(29)
    public static let longdouble = TypeId(30)
    public static let nullptr = TypeId(31)
    public static let cVoid = TypeId(32)

    // Legacy M0.5 compatibility alias
    public static let pointer = TypeId(33)
}

/// Declaration handle in DeclTable.
@frozen
public struct DeclId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public var rawValue: UInt32 { rawIndex }

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(rawValue: UInt32) {
        self.rawIndex = rawValue
    }
}

/// SemIR Instruction Block handle.
@frozen
public struct InstBlockId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public var rawValue: UInt32 { rawIndex }

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// SemIR Instruction handle within an InstBlock.
@frozen
public struct SemInstId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public var rawValue: UInt32 { rawIndex }

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
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

