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
