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
    /// `alignas(N)` or `__attribute__((aligned(N)))` on the member: its alignment is at least N.
    public let alignment: Int?
    /// `__attribute__((packed))` on the member: alignment 1 (unless `alignment` is given), and a bit-field may
    /// straddle storage units.
    public let isPacked: Bool

    public init(name: String, type: QualType, bitWidth: Int? = nil, alignment: Int? = nil, isPacked: Bool = false) {
        self.name = name
        self.type = type
        self.bitWidth = bitWidth
        self.alignment = alignment
        self.isPacked = isPacked
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
    /// Array types whose length is not an integer constant expression (C23 6.7.7.3p4). Each VLA declarator gets its
    /// own type, whose length is the value of its size expression when the declaration is reached.
    private var variableLengthArrays: Set<TypeId> = []
    private var vaListId: TypeId = .nilId
    private var bitPreciseTypes: Set<TypeId> = []
    /// Alignments given to typedef names by `aligned` attributes.
    private var typedefAlignments: [TypeId: Int] = [:]

    /// The target's data layout: every size and alignment in the pool comes from it.
    public let dataLayout: DataLayout

    public init(dataLayout: DataLayout = .x86_64) {
        self.dataLayout = dataLayout
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
        let dl = dataLayout
        types.append(CTypeInfo(kind: .bool, size: 1, alignment: 1, canonical: .bool)) // 16: bool
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: dl.charIsSigned), size: 1, alignment: 1, canonical: .char)) // 17: char
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: true), size: 1, alignment: 1, canonical: .schar)) // 18: schar
        types.append(CTypeInfo(kind: .int(width: 8, isSigned: false), size: 1, alignment: 1, canonical: .uchar)) // 19: uchar
        types.append(CTypeInfo(kind: .int(width: 16, isSigned: true), size: 2, alignment: 2, canonical: .short)) // 20: short
        types.append(CTypeInfo(kind: .int(width: 16, isSigned: false), size: 2, alignment: 2, canonical: .ushort)) // 21: ushort
        types.append(CTypeInfo(kind: .int(width: 32, isSigned: true), size: 4, alignment: 4, canonical: .int)) // 22: int
        types.append(CTypeInfo(kind: .int(width: 32, isSigned: false), size: 4, alignment: 4, canonical: .uint)) // 23: uint
        let longBits = dl.longSize * 8
        types.append(CTypeInfo(kind: .int(width: longBits, isSigned: true), size: dl.longSize, alignment: dl.longSize, canonical: .long)) // 24: long
        types.append(CTypeInfo(kind: .int(width: longBits, isSigned: false), size: dl.longSize, alignment: dl.longSize, canonical: .ulong)) // 25: ulong
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: true), size: 8, alignment: 8, canonical: .longlong)) // 26: longlong
        types.append(CTypeInfo(kind: .int(width: 64, isSigned: false), size: 8, alignment: 8, canonical: .ulonglong)) // 27: ulonglong
        types.append(CTypeInfo(kind: .float(width: 32), size: 4, alignment: 4, canonical: .float)) // 28: float
        types.append(CTypeInfo(kind: .float(width: 64), size: 8, alignment: 8, canonical: .double)) // 29: double
        // `long double`: the x87 80-bit format in 16 bytes on x86-64, IEEE binary128 on AArch64 and RISC-V
        let longDoubleBits = dl.longDoubleFormat == .x87Extended ? 80 : 128
        types.append(CTypeInfo(kind: .float(width: longDoubleBits), size: 16, alignment: 16, canonical: .longdouble)) // 30: longdouble
        types.append(CTypeInfo(kind: .nullptr, size: dl.pointerSize, alignment: dl.pointerSize, canonical: .nullptr)) // 31: nullptr
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

    /// The size of a type; a typedef name has its type's (which a later definition may complete).
    public func size(of id: TypeId) -> Int {
        let info = typeInfo(of: id)
        if case .typedef = info.kind, info.canonical != id { return size(of: info.canonical) }
        return info.size
    }

    /// The alignment of a type; a typedef name has its type's, or that of its `aligned` attribute.
    public func alignment(of id: TypeId) -> Int {
        let info = typeInfo(of: id)
        if case .typedef(_, let underlying) = info.kind, info.canonical != id {
            return typedefAlignments[id] ?? alignment(of: underlying.typeId)
        }
        return info.alignment
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

    /// The binary format of a floating type: `long double` is the x87 80-bit format on x86-64 and binary128 elsewhere.
    public func floatFormat(of type: TypeId) -> FloatFormat? {
        guard case .float(let width) = typeInfo(of: canonical(of: type)).kind else { return nil }
        switch width {
        case 16: return .half
        case 32: return .single
        case 64: return .double
        case 80: return .x87Extended
        case 128: return .quad
        default: return nil
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

    /// Whether an integer type is bit-precise (`_BitInt(N)`), which the integer promotions leave alone.
    public func isBitPrecise(_ type: TypeId) -> Bool {
        bitPreciseTypes.contains(canonical(of: type))
    }

    /// The width in bits of an integer type (`bool` has 1; an enumeration, its underlying type's).
    public func integerWidth(_ type: TypeId) -> Int {
        switch typeInfo(of: canonical(of: type)).kind {
        case .int(let width, _): return width
        case .bool: return 1
        case .enum(_, let underlying, _): return integerWidth(underlying)
        default: return size(of: type) * 8
        }
    }

    /// The integer conversion rank (C23 6.3.1.1p1) as an ordering key: by width, a standard type above a bit-precise
    /// one of the same width, and `long long` above `long`.
    private func integerRank(_ t: TypeId) -> (Int, Int) {
        switch t {
        case .bool: return (1, 0)
        case .char, .schar, .uchar: return (8, 1)
        case .short, .ushort: return (16, 1)
        case .int, .uint: return (32, 1)
        case .long, .ulong: return (dataLayout.longSize * 8, 2)
        case .longlong, .ulonglong: return (64, 3)
        default: return (integerWidth(t), isBitPrecise(t) ? 0 : 4)
        }
    }

    /// The unsigned type corresponding to a signed integer type (C23 6.2.5p8).
    public func unsignedCounterpart(of t: TypeId) -> TypeId {
        switch canonical(of: t) {
        case .char, .schar: return .uchar
        case .short: return .ushort
        case .int: return .uint
        case .long: return .ulong
        case .longlong: return .ulonglong
        case .int128: return int128Type(isSigned: false)
        case let can:
            guard case .int(let width, true) = typeInfo(of: can).kind else { return can }
            return integerType(width: width, isSigned: false)
        }
    }

    /// The integer promotions (C23 6.3.1.1p2): a type whose rank is below `int`'s becomes `int` (its values all fit);
    /// an enumeration is first replaced by its underlying type; bit-precise types are not promoted.
    public func promote(type: TypeId) -> TypeId {
        var can = canonical(of: type)
        if case .enum(_, let underlying, _) = typeInfo(of: can).kind { can = canonical(of: underlying) }
        guard isInteger(type: can), !isBitPrecise(can) else { return can }
        return integerRank(can) < integerRank(.int) ? .int : can
    }

    /// The common real type of the usual arithmetic conversions (C23 6.3.1.8).
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
        let signL = isSignedInteger(type: pL), signR = isSignedInteger(type: pR)
        let rankL = integerRank(pL), rankR = integerRank(pR)
        if signL == signR { return rankL >= rankR ? pL : pR }
        let (u, s) = signL ? (pR, pL) : (pL, pR)
        let (rankU, rankS) = signL ? (rankR, rankL) : (rankL, rankR)
        // The unsigned type, if its rank is not lower; else the signed type, if it can represent every value of the
        // unsigned one; else the unsigned counterpart of the signed type
        if rankU >= rankS { return u }
        if integerWidth(s) > integerWidth(u) { return s }
        return unsignedCounterpart(of: s)
    }

    // MARK: - Type Constructors

    public func pointerTo(_ pointee: QualType) -> TypeId {
        if let existing = pointerCache[pointee] {
            return existing
        }
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .pointer(pointee: pointee), size: dataLayout.pointerSize, alignment: dataLayout.pointerSize, canonical: id))
        pointerCache[pointee] = id
        return id
    }

    /// `T [count]`; the alignment is the element type's, including the alignment of an aligned typedef.
    public func arrayType(elementType: QualType, count: UInt64) -> TypeId {
        let elSize = size(of: elementType.typeId)
        let elAlign = alignment(of: elementType.typeId)
        let totalSize = elSize * Int(count)
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .array(element: elementType, count: count), size: totalSize, alignment: elAlign, canonical: id))
        return id
    }

    /// A variable length array type `T [n]` (C23 6.7.7.3p4): a distinct type per declarator, with no static size.
    public func variableLengthArrayType(elementType: QualType) -> TypeId {
        let id = arrayType(elementType: elementType, count: 0)
        variableLengthArrays.insert(id)
        return id
    }

    /// Whether `id` (or the type it names) is a variable length array type.
    public func isVariableLengthArray(_ id: TypeId) -> Bool {
        variableLengthArrays.contains(canonical(of: id))
    }

    /// Whether `id` is variably modified (C23 6.7.7.1p3): a VLA, or derived from one by arrays and pointers.
    public func isVariablyModified(_ id: TypeId) -> Bool {
        let can = canonical(of: id)
        if variableLengthArrays.contains(can) { return true }
        switch typeInfo(of: can).kind {
        case .array(let element, _), .pointer(let element): return isVariablyModified(element.typeId)
        default: return false
        }
    }

    public func functionType(returnType: QualType, paramTypes: [QualType], isVariadic: Bool = false) -> TypeId {
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .function(returnType: returnType, paramTypes: paramTypes, isVariadic: isVariadic), size: 8, alignment: 8, canonical: id))
        return id
    }

    /// An integer type of `width` bits (C23 `_BitInt(N)`), laid out by the target psABI's rule
    /// (`DataLayout.bitIntLayout`).
    public func integerType(width: Int, isSigned: Bool) -> TypeId {
        let key = width << 1 | (isSigned ? 1 : 0)
        if let existing = integerCache[key] { return existing }
        let (size, align) = dataLayout.bitIntLayout(width: width)
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .int(width: width, isSigned: isSigned), size: size, alignment: align, canonical: id))
        integerCache[key] = id
        bitPreciseTypes.insert(id)
        return id
    }

    /// `__builtin_va_list` per psABI: on x86-64 `struct __va_list_tag[1]` (24 bytes), on AArch64 `struct __va_list`
    /// (32 bytes), on RISC-V `void *`.
    public func builtinVaListType() -> TypeId {
        if vaListId.isValid { return vaListId }
        let voidPtr = QualType(typeId: pointerTo(.void))
        switch dataLayout.arch {
        case .x86_64:
            let tag = structType(name: "__va_list_tag", fields: [
                StructMemberDecl(name: "gp_offset", type: .uint), StructMemberDecl(name: "fp_offset", type: .uint),
                StructMemberDecl(name: "overflow_arg_area", type: voidPtr), StructMemberDecl(name: "reg_save_area", type: voidPtr),
            ], isUnion: false)
            vaListId = arrayType(elementType: QualType(typeId: tag), count: 1)
        case .aarch64:
            vaListId = structType(name: "__va_list", fields: [
                StructMemberDecl(name: "__stack", type: voidPtr), StructMemberDecl(name: "__gr_top", type: voidPtr),
                StructMemberDecl(name: "__vr_top", type: voidPtr), StructMemberDecl(name: "__gr_offs", type: .int),
                StructMemberDecl(name: "__vr_offs", type: .int),
            ], isUnion: false)
        case .riscv64:
            vaListId = voidPtr.typeId
        }
        return vaListId
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
    public func structType(name: String, fields: [StructMemberDecl], isUnion: Bool, isPacked: Bool = false, alignment: Int? = nil) -> TypeId {
        let id = declareStruct(name: name, isUnion: isUnion)
        completeStruct(id, fields: fields, isPacked: isPacked, alignment: alignment)
        return id
    }

    /// Defines the members of a declared struct or union, laid out per the x86-64 System V psABI (the AArch64 and
    /// RISC-V psABIs share these rules): members at their alignment; a bit-field shares the storage unit of its
    /// declared type with the bits before it unless it would cross that unit's boundary; a zero-width bit-field ends
    /// the unit (and on AArch64 raises the structure's alignment to its type's); unnamed bit-fields do not affect the
    /// alignment. `packed` aligns every member at 1 and lets bit-fields straddle units. An `aligned`/`alignas`
    /// member alignment raises the member's alignment (also in a packed structure), and `alignment` (the type's own
    /// `aligned` attribute) raises the structure's.
    public func completeStruct(_ id: TypeId, fields: [StructMemberDecl], isPacked: Bool = false, alignment explicitAlignment: Int? = nil) {
        guard case .struct(let name, _, let isUnion) = typeInfo(of: id).kind else { return }
        var structFields: [StructField] = []
        var bitOffset = 0  // next free bit (struct), or the widest member in bits (union)
        var maxAlign = 1

        for f in fields {
            let fSize = size(of: f.type.typeId)
            let packed = isPacked || f.isPacked
            let fAlign = max(packed ? 1 : max(1, alignment(of: f.type.typeId)), f.alignment ?? 1)
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
                    if dataLayout.zeroWidthBitFieldAligns && !packed { maxAlign = max(maxAlign, fAlign) }
                    continue
                }
                if !packed && bitOffset / unitBits != (bitOffset + width - 1) / unitBits {
                    bitOffset = (bitOffset + fAlign * 8 - 1) / (fAlign * 8) * (fAlign * 8)
                }
                let unitStart = packed ? bitOffset / 8 : bitOffset / unitBits * fSize
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

        maxAlign = max(maxAlign, explicitAlignment ?? 1)
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

    /// A typedef name for `underlying`. `alignment` is an `aligned` attribute on the typedef, which (as in GCC and
    /// Clang) gives the name its own alignment, smaller or larger than the type's.
    public func typedefType(name: String, underlying: QualType, alignment explicitAlignment: Int? = nil) -> TypeId {
        let key = "\(name)#\(underlying.typeId.rawIndex)#\(explicitAlignment ?? 0)"
        if let existing = typedefCache[key] {
            return existing
        }
        let can = canonical(of: underlying.typeId)
        let sz = size(of: can)
        let al = explicitAlignment ?? alignment(of: underlying.typeId)
        let id = TypeId(UInt32(types.count))
        types.append(CTypeInfo(kind: .typedef(name: name, underlying: underlying), size: sz, alignment: al, canonical: can))
        typedefCache[key] = id
        if let explicitAlignment { typedefAlignments[id] = explicitAlignment }
        return id
    }

    public func lookupStructField(named fieldName: String, in typeId: TypeId) -> StructField? {
        let can = canonical(of: typeId)
        guard case .struct(_, let fields, _) = typeInfo(of: can).kind else { return nil }
        if let direct = fields.first(where: { $0.name == fieldName }) {
            return direct
        }
        // C11/C23 anonymous struct/union members
        for f in fields where f.name.isEmpty && f.bitWidth == nil {
            if let nested = lookupStructField(named: fieldName, in: f.type.typeId) {
                return StructField(name: nested.name, type: nested.type, offset: f.offset + nested.offset, bitWidth: nested.bitWidth,
                                   bitOffset: nested.bitOffset)
            }
        }
        return nil
    }

    /// The path of field indices to a member named `fieldName`, through anonymous struct and union members (for
    /// designators): `[i]` for a direct member, `[i, j]` for member `j` of the anonymous member `i`.
    public func fieldPath(named fieldName: String, in typeId: TypeId) -> [Int]? {
        guard case .struct(_, let fields, _) = typeInfo(of: canonical(of: typeId)).kind else { return nil }
        if let i = fields.firstIndex(where: { $0.name == fieldName }) { return [i] }
        for (i, f) in fields.enumerated() where f.name.isEmpty && f.bitWidth == nil {
            if let nested = fieldPath(named: fieldName, in: f.type.typeId) { return [i] + nested }
        }
        return nil
    }

    /// The fields of a struct or union type, in declaration order (empty for other types).
    public func fields(of typeId: TypeId) -> [StructField] {
        guard case .struct(_, let fields, _) = typeInfo(of: canonical(of: typeId)).kind else { return [] }
        return fields
    }

    public func isUnion(_ typeId: TypeId) -> Bool {
        if case .struct(_, _, true) = typeInfo(of: canonical(of: typeId)).kind { return true }
        return false
    }

    // MARK: - Spelling

    /// The C spelling of a type, for diagnostics and dumps: `const char *`, `struct S`, `int (*)[4]`, `void (int, ...)`.
    public func name(of t: QualType, declarator: String = "") -> String {
        let quals = [(t.isConst, "const"), (t.isVolatile, "volatile"), (t.isRestrict, "restrict")].filter(\.0).map(\.1).joined(separator: " ")
        func named(_ base: String) -> String {
            let spelled = quals.isEmpty ? base : quals + " " + base
            return declarator.isEmpty ? spelled : spelled + " " + declarator
        }
        func isArrayOrFunction(_ q: QualType) -> Bool {
            switch typeInfo(of: canonical(of: q.typeId)).kind {
            case .array, .function: return true
            default: return false
            }
        }
        switch typeInfo(of: t.typeId).kind {
        case .typedef(let name, _):
            return named(name)
        case .pointer(let pointee):
            let inner = "*" + quals + (declarator.isEmpty || quals.isEmpty ? "" : " ") + declarator
            return name(of: pointee, declarator: isArrayOrFunction(pointee) ? "(\(inner))" : inner)
        case .array(let element, let count):
            let bound = isVariableLengthArray(t.typeId) ? "*" : (count == 0 ? "" : String(count))
            return name(of: element, declarator: declarator + "[\(bound)]")
        case .function(let returnType, let params, let isVariadic):
            let list = params.map { name(of: $0) } + (isVariadic ? ["..."] : [])
            return name(of: returnType, declarator: declarator + "(" + (list.isEmpty ? "void" : list.joined(separator: ", ")) + ")")
        case .struct(let name, _, let isUnion):
            return named((isUnion ? "union " : "struct ") + (name.isEmpty ? "(unnamed)" : name))
        case .enum(let name, _, _):
            return named("enum " + (name.isEmpty ? "(unnamed)" : name))
        case .int(let width, let isSigned):
            let builtin: [TypeId: String] = [.char: "char", .schar: "signed char", .uchar: "unsigned char", .short: "short",
                                             .ushort: "unsigned short", .int: "int", .uint: "unsigned int", .long: "long",
                                             .ulong: "unsigned long", .longlong: "long long", .ulonglong: "unsigned long long",
                                             .int128: "__int128"]
            let can = canonical(of: t.typeId)
            if !isBitPrecise(can) && width == 128 && !isSigned { return named("unsigned __int128") }
            return named(builtin[can] ?? "\(isSigned ? "" : "unsigned ")_BitInt(\(width))")
        case .float(let width):
            let can = canonical(of: t.typeId)
            return named(can == .float ? "float" : can == .double ? "double" : can == .longdouble ? "long double" : "_Float\(width)")
        case .bool: return named("bool")
        case .void: return named("void")
        case .nullptr: return named("nullptr_t")
        case .error: return named("<unknown type>")
        }
    }
}
