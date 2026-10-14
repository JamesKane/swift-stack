// Sources/SwiftStack/Sem/QualType.swift
import Foundation

/// Canonical or sugared type representation.
/// Upper 29 bits: TypeId index into TypePool. Low 3 bits: C qualifiers (02-semantic-analysis.md §4.1).
@frozen
public struct QualType: Hashable, Sendable, BitwiseCopyable, CustomStringConvertible {
    public var rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    @inlinable
    public init(typeId: TypeId, qualifiers: UInt8 = 0) {
        self.rawValue = (typeId.rawValue << 3) | UInt32(qualifiers & 0b111)
    }

    @inlinable
    public var typeId: TypeId {
        TypeId(rawValue: rawValue >> 3)
    }

    @inlinable
    public var qualifiers: UInt8 {
        UInt8(rawValue & 0b111)
    }

    @inlinable
    public var isConst: Bool {
        (rawValue & 0b001) != 0
    }

    @inlinable
    public var isVolatile: Bool {
        (rawValue & 0b010) != 0
    }

    @inlinable
    public var isRestrict: Bool {
        (rawValue & 0b100) != 0
    }

    @inlinable
    public func withConst() -> QualType {
        QualType(rawValue: rawValue | 0b001)
    }

    @inlinable
    public func withVolatile() -> QualType {
        QualType(rawValue: rawValue | 0b010)
    }

    @inlinable
    public func withRestrict() -> QualType {
        QualType(rawValue: rawValue | 0b100)
    }

    @inlinable
    public func unqualified() -> QualType {
        QualType(rawValue: rawValue & ~0b111)
    }

    @inlinable
    public var isError: Bool {
        typeId == .error
    }

    @inlinable
    public var description: String {
        var str = "QualType(\(typeId.rawIndex)"
        if isConst { str += ", const" }
        if isVolatile { str += ", volatile" }
        if isRestrict { str += ", restrict" }
        str += ")"
        return str
    }

    public static let error = QualType(typeId: .error)
    public static let void = QualType(typeId: .void)
    public static let int = QualType(typeId: .int)
    public static let uint = QualType(typeId: .uint)
    public static let long = QualType(typeId: .long)
    public static let ulong = QualType(typeId: .ulong)
    public static let longlong = QualType(typeId: .longlong)
    public static let ulonglong = QualType(typeId: .ulonglong)
    public static let short = QualType(typeId: .short)
    public static let ushort = QualType(typeId: .ushort)
    public static let char = QualType(typeId: .char)
    public static let schar = QualType(typeId: .schar)
    public static let uchar = QualType(typeId: .uchar)
    public static let bool = QualType(typeId: .bool)
    public static let double = QualType(typeId: .double)
    public static let float = QualType(typeId: .float)
    public static let longdouble = QualType(typeId: .longdouble)
    public static let nullptr = QualType(typeId: .nullptr)
    public static let cVoid = QualType(typeId: .cVoid)
}
