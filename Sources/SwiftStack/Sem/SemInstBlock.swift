// Sources/SwiftStack/Sem/SemInstBlock.swift
import Foundation

/// SemIR instruction kind shared between C and Swift (10-semantic-ir-and-name-resolution.md §4.1, §4.11 for C).
///
/// A C body is a tree of instructions stored in evaluation order: every operand precedes its user, each
/// instruction has at most one user, and the body's root is its last instruction (a `compound`). Expressions yield
/// either an **lvalue** (the address of an object, or a function designator; `isLvalue`) or an **rvalue**, and
/// every implicit conversion is an instruction of its own. Statements have type `void` and give the body its
/// structured control flow. Operand layouts are listed per kind; "extra" means `arg1` is an offset into the block's
/// `extraOperands`, where `appendList` stores a count followed by the items.
@frozen
public enum SemInstKind: UInt16, BitwiseCopyable, Sendable, CaseIterable {
    case nilInst = 0

    // Constants (rvalues, except `stringLiteral`)
    /// arg0: index into `intConstants` (the value's two's-complement bits, extended per the type).
    case intLiteral = 1
    /// arg0: index into `floatConstants` (the encoding in the type's format).
    case floatLiteral = 2
    /// Lvalue of array type (a static array object). arg0: index into `stringConstants`; arg1: `StringEncoding`.
    case stringLiteral = 3
    case nullptrLiteral = 4

    // Objects and designators (lvalues)
    /// arg0: DeclId of an object or function.
    case declRef = 10
    /// A non-bit-field member. arg0: base lvalue (struct or union); arg1: byte offset.
    case member = 11
    /// A bit-field member. arg0: base lvalue; extra: [byte offset of the storage unit, bit offset in the unit,
    /// width, isSigned, storage unit size in bytes].
    case bitField = 12
    /// `*p`. arg0: pointer rvalue.
    case deref = 13
    /// `(T){...}`. arg0: DeclId of the unnamed object (automatic or static, per its storage); arg1: initializer.
    case compoundLiteral = 14
    /// A temporary holding an rvalue (`f().m`, `f().a[i]`). arg0: rvalue.
    case materialize = 15

    // Unary operators (rvalues). arg0: operand (an rvalue of the result type, or a `bool` for `logicalNot`).
    case neg = 20
    case bitNot = 21
    case logicalNot = 22
    /// `&lv`. arg0: lvalue (not a bit-field).
    case addrOf = 23
    /// arg0: modifiable lvalue; the result has its unqualified type (pointers step by the pointee size).
    case preInc = 25
    case preDec = 26
    case postInc = 27
    case postDec = 28

    // Binary operators (rvalues). arg0, arg1: rvalue operands, converted to the result type (comparisons: to a
    // common type; shifts: each promoted on its own).
    case add = 30
    case sub = 31
    case mul = 32
    case div = 33
    case mod = 34
    case shl = 35
    case shr = 36
    case bitAnd = 37
    case bitOr = 38
    case bitXor = 39
    case eq = 40
    case ne = 41
    case lt = 42
    case le = 43
    case gt = 44
    case ge = 45
    /// Short-circuit `&&`/`||`. arg0, arg1: `bool` operands; the result is an `int`.
    case logicalAnd = 46
    case logicalOr = 47
    /// arg0: lvalue; arg1: rvalue converted to the lvalue's unqualified type. Yields the stored value.
    case assign = 50
    /// `lv op= rhs`. arg0: lvalue; extra: [opcode (a `SemInstKind`), rhs, computation type, computation result type]
    /// (C23 6.5.16.2: the left operand is converted to the computation type, the operation's result back to its own).
    case compoundAssign = 51
    /// `p + n`, `p - n`. arg0: pointer; arg1: index converted to `ptrdiff_t`.
    case ptrAdd = 53
    case ptrSub = 54
    /// `p - q` in elements. arg0, arg1: pointers to compatible types; the result is `ptrdiff_t`.
    case ptrDiff = 55
    /// `a, b`. arg0: evaluated for side effects; arg1: the result.
    case comma = 56

    // Conversions (rvalues). arg0: operand; arg1: `CastKind` (the operation). The kind gives the reason.
    case explicitCast = 60
    /// Lvalue conversion (C23 6.3.2.1p2): loads the object; the type drops qualifiers.
    case lvalueToRvalue = 61
    case intPromotion = 62
    /// The usual arithmetic conversions (C23 6.3.1.8).
    case arithmeticConvert = 63
    /// arg0: lvalue of array type; yields a pointer to its first element.
    case arrayToPointer = 64
    /// arg0: function designator.
    case functionToPointer = 65
    /// Conversion as if by assignment (C23 6.5.16.1): assignment, initialization, arguments, `return`.
    case assignConvert = 66
    /// Default argument promotions (C23 6.5.2.2p6-7): variadic arguments.
    case argPromotion = 67
    /// A scalar compared against 0 (conditions, `!`, `&&`, `||`): yields `bool`.
    case boolConvert = 68
    /// A null pointer constant (an integer constant 0 or `nullptr`) converted to a pointer type.
    case nullPointerConvert = 69

    // Other expressions (rvalues)
    /// arg0: callee (a pointer to a function type); extra: [DeclId of a directly called function or 0, number of
    /// prototype parameters, argument count, arguments...]. Arguments past the prototype's parameters have had the
    /// default argument promotions.
    case call = 70
    /// `__builtin_va_arg(ap, T)`. arg0: the `va_list` (an lvalue).
    case vaArg = 71
    /// `c ? a : b`. extra: [condition (`bool`), then, else]; both arms converted to the result type (or `void`).
    case conditional = 72
    /// GNU `a ?: b`. arg0: `a` (an rvalue, tested against 0 and converted to the result type if nonzero); arg1: `b`
    /// converted to the result type.
    case elvis = 73
    /// A braced initializer of an aggregate (C23 6.7.10), resolved: extra holds (index, count, value) triples sorted
    /// by index, each value initializing `count` consecutive elements (a GNU range) or the member with ordinal
    /// `index` (the `TypePool` field index); a value is a scalar converted to the element type, a nested `initList`,
    /// a string literal (character arrays) or a struct/union rvalue. Everything not listed is zero-initialized.
    case initList = 74
    /// GNU `({ ... })`. arg0: the compound statement; arg1: the value (an rvalue) or 0 when the type is `void`.
    case stmtExpr = 75
    /// GNU `&&label`. arg0: label number.
    case labelAddress = 76
    /// `sizeof` of a variable length array type. arg0: the VLA `TypeId` (its length was evaluated where the type was).
    case vlaSizeof = 77

    // Statements (type `void`)
    /// extra: the statements in order. A scope: its declarations end at its end.
    case compound = 80
    /// A local object with automatic storage. arg0: DeclId; extra: [initializer or 0, VLA count, (VLA TypeId, length
    /// as `size_t`)...]; each VLA length is evaluated, outermost first, when the declaration is reached.
    case declLocal = 81
    /// arg0: the expression, evaluated for its side effects.
    case exprStmt = 82
    /// arg0: condition (`bool`); extra: [then, else or 0].
    case ifStmt = 83
    /// arg0: condition; arg1: body.
    case whileStmt = 84
    /// arg0: body; arg1: condition.
    case doWhileStmt = 85
    /// extra: [init statement or 0 (a `compound` of declarations, or an `exprStmt`), condition or 0, step expression
    /// or 0, body].
    case forStmt = 86
    /// arg0: controlling expression (promoted); extra: [body, `defaultLabel` or 0, case labels...].
    case switchStmt = 87
    /// arg0: the labeled statement or 0; arg1: index into `intConstants` (the value, converted to the promoted type
    /// of the controlling expression).
    case caseLabel = 88
    /// arg0: the labeled statement or 0.
    case defaultLabel = 89
    /// arg0: the labeled statement or 0; arg1: label number (1-based, per function; names in `SemFunction.labels`).
    case label = 90
    /// arg0: label number.
    case gotoStmt = 91
    /// GNU `goto *p`. arg0: pointer.
    case indirectGoto = 92
    /// Leave the innermost enclosing loop or `switch`.
    case breakStmt = 93
    /// Continue the innermost enclosing loop.
    case continueStmt = 94
    /// arg0: value converted to the return type, or 0.
    case returnStmt = 95
    /// Inline `asm`: its operands are not modeled yet.
    case asmStmt = 96
    case nullStmt = 97

    /// A construct sema does not model; it has type `error` (or the type sema assumed), and poisons its users.
    case errorInst = 99

    /// Whether the instruction yields an lvalue (an object's address, or a function designator).
    public var isLvalue: Bool {
        switch self {
        case .stringLiteral, .declRef, .member, .bitField, .deref, .compoundLiteral, .materialize: return true
        default: return false
        }
    }

    public var isStatement: Bool { rawValue >= 80 && rawValue < 99 }

    public var isConversion: Bool { rawValue >= 60 && rawValue < 70 }

    public var name: String {
        switch self {
        case .nilInst: return "nil"
        case .intLiteral: return "int"
        case .floatLiteral: return "float"
        case .stringLiteral: return "string"
        case .nullptrLiteral: return "nullptr"
        case .declRef: return "decl"
        case .member: return "member"
        case .bitField: return "bitfield"
        case .deref: return "deref"
        case .compoundLiteral: return "compound_literal"
        case .materialize: return "materialize"
        case .neg: return "neg"
        case .bitNot: return "bitnot"
        case .logicalNot: return "not"
        case .addrOf: return "addr"
        case .preInc: return "preinc"
        case .preDec: return "predec"
        case .postInc: return "postinc"
        case .postDec: return "postdec"
        case .add: return "add"
        case .sub: return "sub"
        case .mul: return "mul"
        case .div: return "div"
        case .mod: return "mod"
        case .shl: return "shl"
        case .shr: return "shr"
        case .bitAnd: return "and"
        case .bitOr: return "or"
        case .bitXor: return "xor"
        case .eq: return "eq"
        case .ne: return "ne"
        case .lt: return "lt"
        case .le: return "le"
        case .gt: return "gt"
        case .ge: return "ge"
        case .logicalAnd: return "land"
        case .logicalOr: return "lor"
        case .assign: return "assign"
        case .compoundAssign: return "compound_assign"
        case .ptrAdd: return "ptradd"
        case .ptrSub: return "ptrsub"
        case .ptrDiff: return "ptrdiff"
        case .comma: return "comma"
        case .explicitCast: return "cast"
        case .lvalueToRvalue: return "load"
        case .intPromotion: return "promote"
        case .arithmeticConvert: return "arith_convert"
        case .arrayToPointer: return "array_decay"
        case .functionToPointer: return "function_decay"
        case .assignConvert: return "assign_convert"
        case .argPromotion: return "arg_promote"
        case .boolConvert: return "to_bool"
        case .nullPointerConvert: return "null_to_pointer"
        case .call: return "call"
        case .vaArg: return "va_arg"
        case .conditional: return "cond"
        case .elvis: return "elvis"
        case .initList: return "init_list"
        case .stmtExpr: return "stmt_expr"
        case .labelAddress: return "label_addr"
        case .vlaSizeof: return "vla_sizeof"
        case .compound: return "compound"
        case .declLocal: return "local"
        case .exprStmt: return "expr"
        case .ifStmt: return "if"
        case .whileStmt: return "while"
        case .doWhileStmt: return "do"
        case .forStmt: return "for"
        case .switchStmt: return "switch"
        case .caseLabel: return "case"
        case .defaultLabel: return "default"
        case .label: return "label"
        case .gotoStmt: return "goto"
        case .indirectGoto: return "goto_indirect"
        case .breakStmt: return "break"
        case .continueStmt: return "continue"
        case .returnStmt: return "return"
        case .asmStmt: return "asm"
        case .nullStmt: return "null"
        case .errorInst: return "error"
        }
    }
}

/// The operation a conversion instruction performs (`arg1` of every conversion kind).
@frozen
public enum CastKind: UInt32, BitwiseCopyable, Sendable {
    /// No change of representation: qualifiers, an enumeration and its underlying type, `void *` and object
    /// pointers, identical types.
    case noop = 0
    /// Truncation or sign/zero extension per the source type's signedness.
    case intToInt = 1
    case intToFloat = 2
    case floatToInt = 3
    case floatToFloat = 4
    case pointerToInt = 5
    case intToPointer = 6
    case pointerToPointer = 7
    /// Scalar to `bool`: 0 if the operand compares equal to 0, else 1.
    case toBool = 8
    /// A null pointer constant to a pointer type.
    case nullToPointer = 9
    case toVoid = 10
    /// GNU cast to a union from one of its members' types.
    case toUnion = 11

    public var name: String {
        switch self {
        case .noop: return "noop"
        case .intToInt: return "int_to_int"
        case .intToFloat: return "int_to_float"
        case .floatToInt: return "float_to_int"
        case .floatToFloat: return "float_to_float"
        case .pointerToInt: return "ptr_to_int"
        case .intToPointer: return "int_to_ptr"
        case .pointerToPointer: return "ptr_to_ptr"
        case .toBool: return "to_bool"
        case .nullToPointer: return "null_to_ptr"
        case .toVoid: return "to_void"
        case .toUnion: return "to_union"
        }
    }
}

/// The encoding prefix of a string literal (C23 6.4.5).
@frozen
public enum StringEncoding: UInt32, BitwiseCopyable, Sendable {
    case ordinary = 0
    case utf8 = 1
    case utf16 = 2
    case utf32 = 3
    case wide = 4

    public var prefix: String {
        switch self {
        case .ordinary: return ""
        case .utf8: return "u8"
        case .utf16: return "u"
        case .utf32: return "U"
        case .wide: return "L"
        }
    }
}

/// A floating constant's encoding in its type's format: `lo` holds the low 64 bits (all of a `float` or `double`;
/// the significand of an x87 value), `hi` the rest (the x87 sign and exponent, or the high half of a binary128).
public struct FloatConstant: Sendable, Equatable, Hashable {
    public var lo: UInt64
    public var hi: UInt64

    public init(lo: UInt64, hi: UInt64 = 0) {
        self.lo = lo
        self.hi = hi
    }
}

/// A string literal's code units in the target's byte order, including the terminator.
public struct StringConstant: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]
    public var elementSize: Int
    public var encoding: StringEncoding
}

/// A position in a block, to discard what was emitted after it (operands of `sizeof`, `alignof` and `typeof`,
/// which are not evaluated).
public struct SemBlockMark {
    let count: UInt32
    let extra: Int
    let ints: Int
    let floats: Int
    let strings: Int
}

/// A flat, Column-backed block of SemIR instructions for a function body (10-semantic-ir-and-name-resolution.md §4.1).
/// SemInstId 0 is universally reserved as the nil instruction (Principle 7).
public struct SemInstBlock: ~Copyable {
    public var kinds: Column<SemInstId, UInt16>
    public var types: Column<SemInstId, QualType>
    public var arg0: Column<SemInstId, UInt32>
    public var arg1: Column<SemInstId, UInt32>
    public var nodes: Column<SemInstId, UInt32>

    // Side storage for auxiliary data
    public private(set) var extraOperands: [UInt32] = []
    public private(set) var intConstants: [Int64] = []
    public private(set) var floatConstants: [FloatConstant] = []
    public private(set) var stringConstants: [StringConstant] = []

    public init(reservedCapacity: Int = 1 << 20) {
        self.kinds = Column<SemInstId, UInt16>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.types = Column<SemInstId, QualType>(reservedCapacity: reservedCapacity, defaultNilValue: .error)
        self.arg0 = Column<SemInstId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.arg1 = Column<SemInstId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.nodes = Column<SemInstId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        // Offset 0 of `extraOperands` is the empty list, so an unset `arg1` reads as no items
        extraOperands.append(0)
    }

    public var count: UInt32 {
        kinds.count
    }

    /// The last instruction: a function body's root `compound`.
    public var root: SemInstId {
        count > 1 ? SemInstId(count - 1) : .nilId
    }

    @discardableResult
    public mutating func append(
        kind: SemInstKind,
        type: QualType,
        arg0: UInt32 = 0,
        arg1: UInt32 = 0,
        node: NodeId = .nilId
    ) -> SemInstId {
        let id = SemInstId(kinds.count)
        _ = kinds.append(kind.rawValue)
        _ = types.append(type)
        _ = self.arg0.append(arg0)
        _ = self.arg1.append(arg1)
        _ = nodes.append(node.rawIndex)
        return id
    }

    /// Stores `items` in `extraOperands` as a counted list and returns its offset (for `arg1`).
    public mutating func appendList(_ items: [UInt32]) -> UInt32 {
        let offset = UInt32(extraOperands.count)
        extraOperands.append(UInt32(items.count))
        extraOperands.append(contentsOf: items)
        return offset
    }

    /// The items of the counted list at `offset`.
    public func list(at offset: UInt32) -> ArraySlice<UInt32> {
        let start = Int(offset)
        guard start < extraOperands.count else { return [] }
        let n = Int(extraOperands[start])
        guard start + 1 + n <= extraOperands.count else { return [] }
        return extraOperands[(start + 1)..<(start + 1 + n)]
    }

    /// The items of an instruction's extra list (`arg1`).
    public func extra(of id: SemInstId) -> ArraySlice<UInt32> {
        list(at: arg1[id])
    }

    @discardableResult
    public mutating func appendIntLiteral(value: Int64, type: QualType, node: NodeId = .nilId) -> SemInstId {
        append(kind: .intLiteral, type: type, arg0: addIntConstant(value), arg1: 0, node: node)
    }

    public mutating func addIntConstant(_ value: Int64) -> UInt32 {
        intConstants.append(value)
        return UInt32(intConstants.count - 1)
    }

    @discardableResult
    public mutating func appendFloatLiteral(value: FloatConstant, type: QualType, node: NodeId = .nilId) -> SemInstId {
        let idx = UInt32(floatConstants.count)
        floatConstants.append(value)
        return append(kind: .floatLiteral, type: type, arg0: idx, arg1: 0, node: node)
    }

    @discardableResult
    public mutating func appendStringLiteral(value: StringConstant, type: QualType, node: NodeId = .nilId) -> SemInstId {
        let idx = UInt32(stringConstants.count)
        stringConstants.append(value)
        return append(kind: .stringLiteral, type: type, arg0: idx, arg1: value.encoding.rawValue, node: node)
    }

    public func kind(of id: SemInstId) -> SemInstKind {
        SemInstKind(rawValue: kinds[id]) ?? .nilInst
    }

    public func type(of id: SemInstId) -> QualType {
        types[id]
    }

    public func intConstant(of id: SemInstId) -> Int64 {
        let i = Int(arg0[id])
        return i < intConstants.count ? intConstants[i] : 0
    }

    public func intConstant(at index: UInt32) -> Int64 {
        Int(index) < intConstants.count ? intConstants[Int(index)] : 0
    }

    public func floatConstant(of id: SemInstId) -> FloatConstant {
        let i = Int(arg0[id])
        return i < floatConstants.count ? floatConstants[i] : FloatConstant(lo: 0)
    }

    public func stringConstant(of id: SemInstId) -> StringConstant {
        let i = Int(arg0[id])
        return i < stringConstants.count ? stringConstants[i] : StringConstant(bytes: [0], elementSize: 1, encoding: .ordinary)
    }

    public mutating func setArg0(_ id: SemInstId, _ value: UInt32) {
        arg0[id] = value
    }

    public mutating func setArg1(_ id: SemInstId, _ value: UInt32) {
        arg1[id] = value
    }

    public func mark() -> SemBlockMark {
        SemBlockMark(count: count, extra: extraOperands.count, ints: intConstants.count, floats: floatConstants.count,
                     strings: stringConstants.count)
    }

    /// Discards everything emitted after `mark`.
    public mutating func truncate(to mark: SemBlockMark) {
        guard mark.count <= count else { return }
        kinds.setCount(mark.count)
        types.setCount(mark.count)
        arg0.setCount(mark.count)
        arg1.setCount(mark.count)
        nodes.setCount(mark.count)
        extraOperands.removeLast(extraOperands.count - mark.extra)
        intConstants.removeLast(intConstants.count - mark.ints)
        floatConstants.removeLast(floatConstants.count - mark.floats)
        stringConstants.removeLast(stringConstants.count - mark.strings)
    }
}
