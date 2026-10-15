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
    /// Byte offset of the member, or of the storage unit holding a bit-field.
    public let offset: UInt32
    /// Width of a bit-field (nil for an ordinary member) and its first bit within the storage unit at `offset`.
    public let bitWidth: Int?
    public let bitOffset: Int

    public init(name: String, type: QualType, offset: UInt32, bitWidth: Int? = nil, bitOffset: Int = 0) {
        self.name = name
        self.type = type
        self.offset = offset
        self.bitWidth = bitWidth
        self.bitOffset = bitOffset
    }
}

/// A member of a struct or union being laid out: an ordinary member, or a bit-field with its width.
public struct StructMemberDecl: Sendable {
    public let name: String
    public let type: QualType
    public let bitWidth: Int?

    public init(name: String, type: QualType, bitWidth: Int? = nil) {
        self.name = name
        self.type = type
        self.bitWidth = bitWidth
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
    /// Keyed by name and underlying type: a block-scope typedef may reuse an outer name for another type.
    private var typedefCache: [String: TypeId] = [:]
    /// Integer types beyond the reserved slots (`unsigned __int128`, `_BitInt(N)`), keyed by width and signedness.
    private var integerCache: [Int: TypeId] = [:]
    /// Struct, union and enum types declared but not (yet) defined. Tags are scoped by the semantic analyzer, so
    /// every declaration that introduces a tag creates a distinct type here.
    private var incompleteTags: Set<TypeId> = []

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
        if info.canonical.isValid { return info.canonical }
        // A typedef of the error type (an unmodeled declarator) is itself unmodeled
        if case .typedef(_, let underlying) = info.kind { return canonical(of: underlying.typeId) }
        return id
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
        case .error:
            return .error  // an unmodeled type stays unmodeled through `*` and `[]`
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
        if isFloating(type: l) || isFloating(type: r) { return isFloating(type: l) ? l : r }  // `_Float16`, `__bf16`

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

    /// An integer type of `width` bits (C23 `_BitInt(N)`, `__int128`): sized as Clang does for x86-64 System V
    /// (`_BitInt(N)` takes the smallest of 1, 2, 4 or 8 bytes that holds it, then whole 8-byte words).
    public func integerType(width: Int, isSigned: Bool) -> TypeId {
        let key = width << 1 | (isSigned ? 1 : 0)
        if let existing = integerCache[key] { return existing }
        let size: Int, align: Int
        switch width {
        case ...8: (size, align) = (1, 1)
        case ...16: (size, align) = (2, 2)
        case ...32: (size, align) = (4, 4)
        case ...64: (size, align) = (8, 8)
        default: (size, align) = ((width + 63) / 64 * 8, 8)
        }
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .int(width: width, isSigned: isSigned), size: size, alignment: align, canonical: id))
        integerCache[key] = id
        return id
    }

    /// `__int128` / `unsigned __int128`: 16 bytes, 16-byte aligned (unlike `_BitInt(128)`).
    public func int128Type(isSigned: Bool) -> TypeId {
        if isSigned { return .int128 }
        let key = -1
        if let existing = integerCache[key] { return existing }
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .int(width: 128, isSigned: false), size: 16, alignment: 16, canonical: id))
        integerCache[key] = id
        return id
    }

    /// Declares a new, incomplete struct or union type (C23 6.7.2.3).
    public func declareStruct(name: String, isUnion: Bool) -> TypeId {
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .struct(name: name, fields: [], isUnion: isUnion), size: 0, alignment: 1, canonical: id))
        incompleteTags.insert(id)
        return id
    }

    /// Creates a complete struct or union type.
    public func structType(name: String, fields: [StructMemberDecl], isUnion: Bool, isPacked: Bool = false) -> TypeId {
        let id = declareStruct(name: name, isUnion: isUnion)
        completeStruct(id, fields: fields, isPacked: isPacked)
        return id
    }

    /// Defines the members of a declared struct or union, laid out per the x86-64 System V psABI (the AArch64 and
    /// RISC-V psABIs share these rules): members at their alignment; a bit-field shares the storage unit of its
    /// declared type with the bits before it unless it would cross that unit's boundary; a zero-width bit-field ends
    /// the unit; unnamed bit-fields do not affect the alignment. `packed` aligns every member at 1 and lets
    /// bit-fields straddle units.
    public func completeStruct(_ id: TypeId, fields: [StructMemberDecl], isPacked: Bool = false) {
        guard case .struct(let name, _, let isUnion) = typeInfo(of: id).kind else { return }
        var structFields: [StructField] = []
        var bitOffset = 0  // next free bit (struct), or the widest member in bits (union)
        var maxAlign = 1

        for f in fields {
            let fSize = size(of: f.type.typeId)
            let fAlign = isPacked ? 1 : max(1, alignment(of: f.type.typeId))
            if let width = f.bitWidth {
                let unitBits = max(8, fSize * 8)
                if !f.name.isEmpty { maxAlign = max(maxAlign, fAlign) }
                if isUnion {
                    structFields.append(StructField(name: f.name, type: f.type, offset: 0, bitWidth: width))
                    bitOffset = max(bitOffset, width)
                    continue
                }
                if width == 0 {
                    bitOffset = (bitOffset + unitBits - 1) / unitBits * unitBits
                    continue
                }
                if !isPacked && bitOffset / unitBits != (bitOffset + width - 1) / unitBits {
                    bitOffset = (bitOffset + fAlign * 8 - 1) / (fAlign * 8) * (fAlign * 8)
                }
                let unitStart = isPacked ? bitOffset / 8 : bitOffset / unitBits * fSize
                structFields.append(StructField(name: f.name, type: f.type, offset: UInt32(unitStart), bitWidth: width,
                                                bitOffset: bitOffset - unitStart * 8))
                bitOffset += width
            } else {
                maxAlign = max(maxAlign, fAlign)
                if isUnion {
                    structFields.append(StructField(name: f.name, type: f.type, offset: 0))
                    bitOffset = max(bitOffset, fSize * 8)
                } else {
                    let byteOffset = ((bitOffset + 7) / 8 + fAlign - 1) / fAlign * fAlign
                    structFields.append(StructField(name: f.name, type: f.type, offset: UInt32(byteOffset)))
                    bitOffset = (byteOffset + fSize) * 8
                }
            }
        }

        let bytes = (bitOffset + 7) / 8
        let totalSize = (bytes + maxAlign - 1) / maxAlign * maxAlign
        types[Int(id.rawIndex)] = CTypeInfo(kind: .struct(name: name, fields: structFields, isUnion: isUnion), size: totalSize,
                                           alignment: maxAlign, canonical: id)
        incompleteTags.remove(id)
    }

    /// Declares a new enumeration type; it is incomplete until defined, unless its underlying type is fixed.
    public func declareEnum(name: String, underlyingType: TypeId = .uint, isComplete: Bool = false) -> TypeId {
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .enum(name: name, underlying: underlyingType, cases: []), size: size(of: underlyingType),
                               alignment: alignment(of: underlyingType), canonical: id))
        if !isComplete { incompleteTags.insert(id) }
        return id
    }

    /// Defines the enumeration constants and underlying type of a declared enumeration.
    public func completeEnum(_ id: TypeId, underlyingType: TypeId, cases: [(name: String, value: Int64)]) {
        guard case .enum(let name, _, _) = typeInfo(of: id).kind else { return }
        let enumCases = cases.map { EnumCase(name: $0.name, value: $0.value) }
        types[Int(id.rawIndex)] = CTypeInfo(kind: .enum(name: name, underlying: underlyingType, cases: enumCases),
                                           size: size(of: underlyingType), alignment: alignment(of: underlyingType), canonical: id)
        incompleteTags.remove(id)
    }

    public func enumType(name: String, underlyingType: TypeId = .uint, cases: [(name: String, value: Int64)]) -> TypeId {
        let id = declareEnum(name: name, underlyingType: underlyingType)
        completeEnum(id, underlyingType: underlyingType, cases: cases)
        return id
    }

    /// Whether objects of the type can be defined (C23 6.2.5p1): not `void`, nor a struct, union or enumeration
    /// that is only declared, nor an array of such elements.
    public func isComplete(_ id: TypeId) -> Bool {
        let can = canonical(of: id)
        switch typeInfo(of: can).kind {
        case .void: return false
        case .struct, .enum: return !incompleteTags.contains(can)
        case .array(let element, _): return isComplete(element.typeId)
        default: return true
        }
    }

    public func typedefType(name: String, underlying: QualType) -> TypeId {
        let key = "\(name)#\(underlying.typeId.rawIndex)"
        if let existing = typedefCache[key] {
            return existing
        }
        let can = canonical(of: underlying.typeId)
        let sz = size(of: can)
        let al = alignment(of: can)
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .typedef(name: name, underlying: underlying), size: sz, alignment: al, canonical: can))
        typedefCache[key] = id
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
