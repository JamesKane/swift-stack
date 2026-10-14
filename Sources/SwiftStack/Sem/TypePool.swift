// Sources/SwiftStack/Sem/TypePool.swift
import Foundation

/// Canonical type representation for the C23 & Swift type system (02-semantic-analysis.md §4.1).
public enum CTypeKind: Sendable, Equatable {
    case error
    case void
    case bool
    case int(width: Int, isSigned: Bool)
    case float(width: Int)
    case nullptr
    case pointer(pointee: QualType)
    case array(element: QualType, count: UInt64)
    case function(returnType: QualType, paramTypes: [QualType], isVariadic: Bool)
    case `struct`(name: String, fields: [StructField], isUnion: Bool)
    case `enum`(name: String, underlying: TypeId, cases: [EnumCase])
    case typedef(name: String, underlying: QualType)
}

public struct StructField: Sendable, Equatable {
    public let name: String
    public let type: QualType
    public let offset: UInt32

    public init(name: String, type: QualType, offset: UInt32) {
        self.name = name
        self.type = type
        self.offset = offset
    }
}

public struct EnumCase: Sendable, Equatable {
    public let name: String
    public let value: Int64

    public init(name: String, value: Int64) {
        self.name = name
        self.value = value
    }
}

public struct CTypeInfo: Sendable, Equatable {
    public let kind: CTypeKind
    public let size: Int
    public let alignment: Int
    public let canonical: TypeId

    public init(kind: CTypeKind, size: Int, alignment: Int, canonical: TypeId? = nil) {
        self.kind = kind
        self.size = size
        self.alignment = alignment
        self.canonical = canonical ?? .nilId
    }
}

/// A pool interning canonical and sugared types for C23 and Swift (02-semantic-analysis.md §4.1).
/// Row 0 is the nil/error type; rows 1..32 are reserved for builtin and standard C types.
public final class TypePool {
    private var types: [CTypeInfo] = []
    private var pointerCache: [QualType: TypeId] = [:]
    private var typedefCache: [String: TypeId] = [:]
    private var structCache: [String: TypeId] = [:]
    private var enumCache: [String: TypeId] = [:]

    public init() {
        setupReservedSlots()
    }

    private func setupReservedSlots() {
        // Ensure slots 0..33 match TypeId constants exactly
        // 0: error
        types.append(CTypeInfo(kind: .error, size: 0, alignment: 1, canonical: .error))
        // 1: void
        types.append(CTypeInfo(kind: .void, size: 0, alignment: 1, canonical: .void))
        // 2..8: Builtin Ints
        types.append(CTypeInfo(kind: .int(width: 1, isSigned: false), size: 1, alignment: 1, canonical: .int1)) // int1
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: true), size: 1, alignment: 1, canonical: .int8)) // int8
        types.append(CTypeInfo(kind: .int(width: 16, isSigned: true), size: 2, alignment: 2, canonical: .int16)) // int16
        types.append(CTypeInfo(kind: .int(width: 32, isSigned: true), size: 4, alignment: 4, canonical: .int32)) // int32
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: true), size: 8, alignment: 8, canonical: .int64)) // int64
        types.append(CTypeInfo(kind: .int(width: 128, isSigned: true), size: 16, alignment: 16, canonical: .int128)) // int128
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: false), size: 8, alignment: 8, canonical: .word)) // word
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: true), size: 8, alignment: 8, canonical: .intLiteral)) // intLiteral
        // 10..13: Builtin Floats
        types.append(CTypeInfo(kind: .float(width: 16), size: 2, alignment: 2, canonical: .float16)) // float16
        types.append(CTypeInfo(kind: .float(width: 32), size: 4, alignment: 4, canonical: .float32)) // float32
        types.append(CTypeInfo(kind: .float(width: 64), size: 8, alignment: 8, canonical: .float64)) // float64
        types.append(CTypeInfo(kind: .float(width: 80), size: 16, alignment: 16, canonical: .float80)) // float80
        // 14..15: Pointers / Objects
        types.append(CTypeInfo(kind: .pointer(pointee: .void), size: 8, alignment: 8, canonical: .rawPointer)) // rawPointer
        types.append(CTypeInfo(kind: .pointer(pointee: .void), size: 8, alignment: 8, canonical: .nativeObject)) // nativeObject

        // 16..32: C Types
        types.append(CTypeInfo(kind: .bool, size: 1, alignment: 1, canonical: .bool)) // 16: bool
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: true), size: 1, alignment: 1, canonical: .char)) // 17: char
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: true), size: 1, alignment: 1, canonical: .schar)) // 18: schar
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: false), size: 1, alignment: 1, canonical: .uchar)) // 19: uchar
        types.append(CTypeInfo(kind: .int(width: 16, isSigned: true), size: 2, alignment: 2, canonical: .short)) // 20: short
        types.append(CTypeInfo(kind: .int(width: 16, isSigned: false), size: 2, alignment: 2, canonical: .ushort)) // 21: ushort
        types.append(CTypeInfo(kind: .int(width: 32, isSigned: true), size: 4, alignment: 4, canonical: .int)) // 22: int
        types.append(CTypeInfo(kind: .int(width: 32, isSigned: false), size: 4, alignment: 4, canonical: .uint)) // 23: uint
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: true), size: 8, alignment: 8, canonical: .long)) // 24: long
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: false), size: 8, alignment: 8, canonical: .ulong)) // 25: ulong
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: true), size: 8, alignment: 8, canonical: .longlong)) // 26: longlong
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: false), size: 8, alignment: 8, canonical: .ulonglong)) // 27: ulonglong
        types.append(CTypeInfo(kind: .float(width: 32), size: 4, alignment: 4, canonical: .float)) // 28: float
        types.append(CTypeInfo(kind: .float(width: 64), size: 8, alignment: 8, canonical: .double)) // 29: double
        types.append(CTypeInfo(kind: .float(width: 128), size: 16, alignment: 16, canonical: .longdouble)) // 30: longdouble
        types.append(CTypeInfo(kind: .nullptr, size: 8, alignment: 8, canonical: .nullptr)) // 31: nullptr
        types.append(CTypeInfo(kind: .void, size: 0, alignment: 1, canonical: .cVoid)) // 32: cVoid

        // 33: Legacy pointer
        types.append(CTypeInfo(kind: .pointer(pointee: .void), size: 8, alignment: 8, canonical: .pointer)) // 33: pointer
        pointerCache[.void] = .pointer
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

    public func canonical(of id: TypeId) -> TypeId {
        let info = typeInfo(of: id)
        return info.canonical.isValid ? info.canonical : id
    }

    // MARK: - Classification

    public func isInteger(type: TypeId) -> Bool {
        let can = canonical(of: type)
        switch typeInfo(of: can).kind {
        case .int, .bool, .enum: return true
        default: return false
        }
    }

    public func isSignedInteger(type: TypeId) -> Bool {
        let can = canonical(of: type)
        switch typeInfo(of: can).kind {
        case .int(_, let isSigned): return isSigned
        case .enum(_, let und, _): return isSignedInteger(type: und)
        default: return false
        }
    }

    public func isFloating(type: TypeId) -> Bool {
        let can = canonical(of: type)
        switch typeInfo(of: can).kind {
        case .float: return true
        default: return false
        }
    }

    public func isArithmetic(type: TypeId) -> Bool {
        isInteger(type: type) || isFloating(type: type)
    }

    public func isPointer(type: TypeId) -> Bool {
        let can = canonical(of: type)
        switch typeInfo(of: can).kind {
        case .pointer, .nullptr: return true
        default: return false
        }
    }

    public func isScalar(type: TypeId) -> Bool {
        isArithmetic(type: type) || isPointer(type: type)
    }

    public func pointeeType(of type: TypeId) -> QualType {
        let can = canonical(of: type)
        switch typeInfo(of: can).kind {
        case .pointer(let pointee):
            return pointee
        case .array(let element, _):
            return element
        default:
            return .void
        }
    }

    // MARK: - Conversions & Promotions

    /// Performs C integer promotion: types smaller than `int` promote to `int`.
    public func promote(type: TypeId) -> TypeId {
        let can = canonical(of: type)
        if isInteger(type: can) {
            let sz = size(of: can)
            if sz < 4 {
                return .int
            }
        }
        return can
    }

    /// Computes the usual arithmetic conversions between two arithmetic types.
    public func commonArithmeticType(_ lhs: TypeId, _ rhs: TypeId) -> TypeId {
        let l = canonical(of: lhs)
        let r = canonical(of: rhs)

        // Floating point rules
        if l == .longdouble || r == .longdouble { return .longdouble }
        if l == .double || r == .double { return .double }
        if l == .float || r == .float { return .float }

        // Both operands undergo integer promotions
        let pL = promote(type: l)
        let pR = promote(type: r)
        if pL == pR { return pL }

        let szL = size(of: pL)
        let szR = size(of: pR)
        let signL = isSignedInteger(type: pL)
        let signR = isSignedInteger(type: pR)

        if signL == signR {
            return szL >= szR ? pL : pR
        }

        // Mixed signedness
        if !signL && szL >= szR { return pL }
        if !signR && szR >= szL { return pR }

        if signL && szL > szR { return pL }
        if signR && szR > szL { return pR }

        // Fallback: unsigned version of signed operand
        return !signL ? pL : pR
    }

    // MARK: - Type Constructors

    public func pointerTo(_ pointee: QualType) -> TypeId {
        if let existing = pointerCache[pointee] {
            return existing
        }
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .pointer(pointee: pointee), size: 8, alignment: 8, canonical: id))
        pointerCache[pointee] = id
        return id
    }

    public func arrayType(elementType: QualType, count: UInt64) -> TypeId {
        let elSize = size(of: elementType.typeId)
        let elAlign = alignment(of: elementType.typeId)
        let totalSize = elSize * Int(count)
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .array(element: elementType, count: count), size: totalSize, alignment: elAlign, canonical: id))
        return id
    }

    public func functionType(returnType: QualType, paramTypes: [QualType], isVariadic: Bool = false) -> TypeId {
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .function(returnType: returnType, paramTypes: paramTypes, isVariadic: isVariadic), size: 8, alignment: 8, canonical: id))
        return id
    }

    /// Creates or retrieves a struct / union type with System V AMD64 ABI layout.
    public func structType(name: String, fields: [(name: String, type: QualType)], isUnion: Bool) -> TypeId {
        if !name.isEmpty, let existing = structCache[name] {
            if fields.isEmpty {
                return existing
            }
            if case .struct(_, let existingFields, _) = typeInfo(of: existing).kind, !existingFields.isEmpty {
                return existing
            }
        }

        var structFields: [StructField] = []
        var currentOffset: UInt32 = 0
        var maxAlign: Int = 1
        var maxSize: Int = 0

        for f in fields {
            let fSize = size(of: f.type.typeId)
            let fAlign = max(1, alignment(of: f.type.typeId))
            maxAlign = max(maxAlign, fAlign)

            if isUnion {
                structFields.append(StructField(name: f.name, type: f.type, offset: 0))
                maxSize = max(maxSize, fSize)
            } else {
                // Pad current offset to fAlign
                let pad = (UInt32(fAlign) - (currentOffset % UInt32(fAlign))) % UInt32(fAlign)
                currentOffset += pad
                structFields.append(StructField(name: f.name, type: f.type, offset: currentOffset))
                currentOffset += UInt32(fSize)
            }
        }

        let totalSize: Int
        if isUnion {
            let pad = (maxAlign - (maxSize % maxAlign)) % maxAlign
            totalSize = maxSize + pad
        } else {
            let pad = (maxAlign - (Int(currentOffset) % maxAlign)) % maxAlign
            totalSize = Int(currentOffset) + pad
        }

        if !name.isEmpty, let existing = structCache[name] {
            let idx = Int(existing.rawIndex)
            types[idx] = CTypeInfo(kind: .struct(name: name, fields: structFields, isUnion: isUnion), size: totalSize, alignment: maxAlign, canonical: existing)
            return existing
        }

        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .struct(name: name, fields: structFields, isUnion: isUnion), size: totalSize, alignment: maxAlign, canonical: id))
        if !name.isEmpty {
            structCache[name] = id
        }
        return id
    }

    public func enumType(name: String, underlyingType: TypeId = .int, cases: [(name: String, value: Int64)]) -> TypeId {
        if !name.isEmpty, let existing = enumCache[name] {
            return existing
        }
        let sz = size(of: underlyingType)
        let al = alignment(of: underlyingType)
        let enumCases = cases.map { EnumCase(name: $0.name, value: $0.value) }
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .enum(name: name, underlying: underlyingType, cases: enumCases), size: sz, alignment: al, canonical: id))
        if !name.isEmpty {
            enumCache[name] = id
        }
        return id
    }

    public func typedefType(name: String, underlying: QualType) -> TypeId {
        if let existing = typedefCache[name] {
            return existing
        }
        let can = canonical(of: underlying.typeId)
        let sz = size(of: can)
        let al = alignment(of: can)
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .typedef(name: name, underlying: underlying), size: sz, alignment: al, canonical: can))
        typedefCache[name] = id
        return id
    }

    public func lookupStructField(named fieldName: String, in typeId: TypeId) -> StructField? {
        let can = canonical(of: typeId)
        guard case .struct(_, let fields, _) = typeInfo(of: can).kind else { return nil }
        if let direct = fields.first(where: { $0.name == fieldName }) {
            return direct
        }
        // C11/C23 anonymous struct/union members
        for f in fields where f.name.isEmpty {
            if let nested = lookupStructField(named: fieldName, in: f.type.typeId) {
                return StructField(name: nested.name, type: nested.type, offset: f.offset + nested.offset)
            }
        }
        return nil
    }
}
