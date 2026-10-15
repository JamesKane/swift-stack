// Sources/SwiftStack/AIR/AIRFunction.swift
//
// AIR (03-intermediate-representation.md §4.1): an SSA form stored as columns. This file holds the value types
// (`AIRType`), the opcodes with their operand layouts, a function's storage (`AIRFunction`), and the builder that
// lowering appends to (`AIRBuilder`), which numbers instructions in block order when it finishes.
//
// AIR values are scalars: integers of any width (`i1` ... `i8192`), floats (`f16`, `f32`, `f64`, the x87 `f80`,
// `f128`) and pointers. Aggregates (C structs, unions and arrays) live in memory and are handled by address: an
// aggregate argument is passed as the address of its value, an aggregate result is written through a destination
// address, and an aggregate parameter is the address of the callee's copy. The ABI lowering of M3 phase 3 decides
// how each one travels.

import Foundation

/// The type of an AIR value: `void`, an integer of a width in bits, a float of a width, or a pointer.
@frozen
public struct AIRType: Hashable, Sendable, BitwiseCopyable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue }

    public enum Kind: UInt32 {
        case void = 0, int = 1, float = 2, pointer = 3
    }

    @inlinable public init(kind: Kind, width: Int) { rawValue = kind.rawValue << 24 | UInt32(width) }

    public static func int(_ width: Int) -> AIRType { AIRType(kind: .int, width: width) }
    public static func float(_ width: Int) -> AIRType { AIRType(kind: .float, width: width) }

    public static let void = AIRType(rawValue: 0)
    public static let i1 = int(1)
    public static let i8 = int(8)
    public static let i16 = int(16)
    public static let i32 = int(32)
    public static let i64 = int(64)
    public static let f32 = float(32)
    public static let f64 = float(64)
    public static let ptr = AIRType(kind: .pointer, width: 64)

    public var kind: Kind { Kind(rawValue: rawValue >> 24) ?? .void }
    /// Bits of the value (for `f80`, 80; a pointer, 64).
    public var width: Int { Int(rawValue & 0xFF_FFFF) }
    public var isVoid: Bool { rawValue == 0 }
    public var isInt: Bool { kind == .int }
    public var isFloat: Bool { kind == .float }
    public var isPointer: Bool { kind == .pointer }

    public var description: String {
        switch kind {
        case .void: return "void"
        case .int: return "i\(width)"
        case .float: return "f\(width)"
        case .pointer: return "ptr"
        }
    }
}

/// AIR opcodes. Operand layouts: `op0`, `op1` and `aux` hold `ValueId`s unless noted; "extra" means `aux` is the
/// offset of a list in the function's `extra` column (`AIRFunction.extraList`), which stores a count and the items.
@frozen
public enum AIROpcode: UInt8, Sendable, BitwiseCopyable, CaseIterable {
    case nilOp = 0
    /// Removed by a pass (storage is append-only).
    case dead = 1

    // Memory
    /// A fixed stack slot (aux: index into `slots`), in the entry block. Result: `ptr`.
    case alloca = 10
    /// A dynamic stack allocation (VLAs, `__builtin_alloca`). op0: size in bytes (`i64`); aux: alignment. Result `ptr`.
    case dynAlloca = 11
    /// op0: address; aux: `AIRMemFlags`. Result: the loaded value, of the instruction's type.
    case load = 12
    /// op0: value; op1: address; aux: `AIRMemFlags`.
    case store = 13
    /// `memcpy`: op0: destination; op1: source (equal or not overlapping); extra: [size (`i64`), `AIRMemFlags`].
    case copy = 14
    /// `memset`: op0: destination; op1: the byte (`i8`); extra: [size (`i64`), `AIRMemFlags`].
    case fill = 15
    /// op0: pointer; op1: byte offset (`i64`). Result: `ptr`.
    case ptrAdd = 16
    /// The address of a thread-local object in the current thread. op0: the object (a global). Result: `ptr`.
    case tlsAddr = 17
    /// The address of a block (GNU `&&label`). aux: BlockId. Result: `ptr`.
    case blockAddr = 18
    /// The stack pointer, to release dynamic allocations with `stackRestore`. Result: `ptr`.
    case stackSave = 19
    /// op0: a `stackSave` result.
    case stackRestore = 20

    // Integer arithmetic: op0, op1 and the result have one integer type. Shifts take the count in that type too.
    case add = 30, sub, mul, sdiv, udiv, srem, urem, and, or, xor, shl, lshr, ashr
    // Floating arithmetic: op0, op1 and the result have one float type; `fneg` and `fabs` take op0 only.
    case fadd = 50, fsub, fmul, fdiv, fneg, fabs
    /// Unary integer operations: op0 and the result have one integer type (`clz`/`ctz` of 0 are undefined).
    case bswap = 60, clz, ctz, popcount

    /// op0, op1: integers or pointers of one type; aux: `AIRICmp`. Result: `i1`.
    case icmp = 70
    /// op0, op1: floats of one type; aux: `AIRFCmp`. Result: `i1`.
    case fcmp = 71
    /// op0: `i1`; op1: the value if true; aux: the value if false (a ValueId).
    case select = 72

    // Conversions: op0 is the operand.
    case trunc = 76, zext, sext, fptrunc, fpext, fptosi, fptoui, sitofp, uitofp, ptrtoint, inttoptr
    /// Reinterprets the bits of an integer as a float of the same width, or the reverse.
    case bitcast = 87

    /// A call. op0: callee (a function global or a `ptr`); op1: the destination address of an aggregate result, or
    /// nil; extra: [C function TypeId, argument count, arguments...]. An aggregate argument is the address of its
    /// value. Result: the scalar result, or `void`.
    case call = 90
    /// op0: the `va_list` object's address.
    case vaStart = 91
    case vaEnd = 92
    /// op0: destination `va_list`; op1: source `va_list`.
    case vaCopy = 93
    /// op0: the `va_list` object's address; aux: the argument's C TypeId. Result: the address of the argument (`ptr`).
    case vaArg = 94

    // Atomics. Orderings are `AIRAtomicOrdering`.
    /// op0: address; aux: ordering | `AIRMemFlags` << 8.
    case atomicLoad = 100
    /// op0: value; op1: address; aux: ordering | `AIRMemFlags` << 8.
    case atomicStore = 101
    /// op0: address; op1: operand; aux: ordering | `AIRAtomicOp` << 8. Result: the previous value.
    case atomicRMW = 102
    /// op0: address; op1: expected value; extra: [desired value, success ordering, failure ordering, weak (0/1)].
    /// Result: the previous value (the exchange happened if it equals the expected value).
    case cmpxchg = 103
    /// aux: ordering | 0x100 for a signal fence (a compiler barrier only).
    case fence = 104

    /// GNU inline `asm`; extra: `AIRAsm`.
    case inlineAsm = 110
    /// aux: frame level. Result: `ptr`.
    case frameAddress = 111
    case returnAddress = 112
    /// extra: [(BlockId, value) per predecessor]. Only at the start of a block.
    case phi = 113

    // Terminators: the last instruction of every block, and only there.
    /// aux: BlockId.
    case br = 120
    /// op0: `i1`; op1: BlockId if true; aux: BlockId if false.
    case condBr = 121
    /// op0: integer value; extra: [default BlockId, (case constant, BlockId)...].
    case `switch` = 122
    /// op0: `ptr` (a `blockAddr`); extra: [the possible BlockIds].
    case indirectBr = 123
    /// op0: the result (the address of an aggregate result), or nil.
    case ret = 124
    case unreachable = 125
    case trap = 126
    /// `asm goto`; extra: `AIRAsm`, whose labels are the successors after the fallthrough (the first label).
    case asmGoto = 127

    public var isTerminator: Bool { rawValue >= 120 }

    public var name: String {
        switch self {
        case .nilOp: return "nil"
        case .dead: return "dead"
        case .alloca: return "alloca"
        case .dynAlloca: return "dyn_alloca"
        case .load: return "load"
        case .store: return "store"
        case .copy: return "copy"
        case .fill: return "fill"
        case .ptrAdd: return "ptradd"
        case .tlsAddr: return "tls_addr"
        case .blockAddr: return "block_addr"
        case .stackSave: return "stack_save"
        case .stackRestore: return "stack_restore"
        case .add: return "add"
        case .sub: return "sub"
        case .mul: return "mul"
        case .sdiv: return "sdiv"
        case .udiv: return "udiv"
        case .srem: return "srem"
        case .urem: return "urem"
        case .and: return "and"
        case .or: return "or"
        case .xor: return "xor"
        case .shl: return "shl"
        case .lshr: return "lshr"
        case .ashr: return "ashr"
        case .fadd: return "fadd"
        case .fsub: return "fsub"
        case .fmul: return "fmul"
        case .fdiv: return "fdiv"
        case .fneg: return "fneg"
        case .fabs: return "fabs"
        case .bswap: return "bswap"
        case .clz: return "clz"
        case .ctz: return "ctz"
        case .popcount: return "popcount"
        case .icmp: return "icmp"
        case .fcmp: return "fcmp"
        case .select: return "select"
        case .trunc: return "trunc"
        case .zext: return "zext"
        case .sext: return "sext"
        case .fptrunc: return "fptrunc"
        case .fpext: return "fpext"
        case .fptosi: return "fptosi"
        case .fptoui: return "fptoui"
        case .sitofp: return "sitofp"
        case .uitofp: return "uitofp"
        case .ptrtoint: return "ptrtoint"
        case .inttoptr: return "inttoptr"
        case .bitcast: return "bitcast"
        case .call: return "call"
        case .vaStart: return "va_start"
        case .vaEnd: return "va_end"
        case .vaCopy: return "va_copy"
        case .vaArg: return "va_arg"
        case .atomicLoad: return "atomic_load"
        case .atomicStore: return "atomic_store"
        case .atomicRMW: return "atomic_rmw"
        case .cmpxchg: return "cmpxchg"
        case .fence: return "fence"
        case .inlineAsm: return "asm"
        case .frameAddress: return "frame_address"
        case .returnAddress: return "return_address"
        case .phi: return "phi"
        case .br: return "br"
        case .condBr: return "cond_br"
        case .switch: return "switch"
        case .indirectBr: return "indirect_br"
        case .ret: return "ret"
        case .unreachable: return "unreachable"
        case .trap: return "trap"
        case .asmGoto: return "asm_goto"
        }
    }

    public var isIntegerBinary: Bool { rawValue >= 30 && rawValue <= 42 }
    public var isFloatBinary: Bool { rawValue >= 50 && rawValue <= 53 }
    public var isConversion: Bool { rawValue >= 76 && rawValue <= 87 }

    /// What `op0`, `op1` and `aux` hold.
    public enum Field { case none, value, block, immediate }

    public var fields: (op0: Field, op1: Field, aux: Field) {
        switch self {
        case .nilOp, .dead, .stackSave, .unreachable, .trap:
            return (.none, .none, .none)
        case .alloca, .frameAddress, .returnAddress, .fence:
            return (.none, .none, .immediate)
        case .dynAlloca:
            return (.value, .none, .immediate)
        case .load:
            return (.value, .none, .immediate)
        case .icmp, .fcmp:
            return (.value, .value, .immediate)
        case .store, .atomicStore, .atomicRMW:
            return (.value, .value, .immediate)
        case .copy, .fill, .cmpxchg:
            return (.value, .value, .immediate)  // aux: extra offset
        case .ptrAdd, .vaCopy:
            return (.value, .value, .none)
        case .tlsAddr, .stackRestore, .vaStart, .vaEnd, .fneg, .fabs, .bswap, .clz, .ctz, .popcount, .ret:
            return (.value, .none, .none)
        case .blockAddr, .br:
            return (.none, .none, .block)
        case .add, .sub, .mul, .sdiv, .udiv, .srem, .urem, .and, .or, .xor, .shl, .lshr, .ashr, .fadd, .fsub, .fmul, .fdiv:
            return (.value, .value, .none)
        case .select:
            return (.value, .value, .value)
        case .trunc, .zext, .sext, .fptrunc, .fpext, .fptosi, .fptoui, .sitofp, .uitofp, .ptrtoint, .inttoptr, .bitcast:
            return (.value, .none, .none)
        case .call:
            return (.value, .value, .immediate)  // aux: extra offset
        case .vaArg, .atomicLoad:
            return (.value, .none, .immediate)
        case .inlineAsm, .phi, .asmGoto:
            return (.none, .none, .immediate)  // aux: extra offset
        case .condBr:
            return (.value, .block, .block)
        case .switch, .indirectBr:
            return (.value, .none, .immediate)  // aux: extra offset
        }
    }

    /// Whether `aux` is the offset of an extra list.
    public var hasExtra: Bool {
        switch self {
        case .copy, .fill, .cmpxchg, .call, .inlineAsm, .phi, .asmGoto, .switch, .indirectBr: return true
        default: return false
        }
    }
}

/// Flags of a memory access (`aux` of `load`/`store`, the flags item of `copy`/`fill`): volatile, and the alignment
/// the address is known to have.
public struct AIRMemFlags: Equatable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init(alignment: Int, isVolatile: Bool = false) {
        let log2 = UInt32(max(0, Int.bitWidth - 1 - max(1, alignment).leadingZeroBitCount))
        rawValue = (isVolatile ? 1 : 0) | log2 << 1
    }

    public var isVolatile: Bool { rawValue & 1 != 0 }
    public var alignment: Int { 1 << Int((rawValue >> 1) & 0x1F) }
}

/// Integer comparison predicates (`aux` of `icmp`).
@frozen
public enum AIRICmp: UInt32, Sendable, CaseIterable {
    case eq = 0, ne, slt, sle, sgt, sge, ult, ule, ugt, uge

    public var name: String { "\(self)" }
}

/// Floating comparison predicates (`aux` of `fcmp`): `o` ordered (false if either operand is NaN), `u` unordered
/// (true if either is).
@frozen
public enum AIRFCmp: UInt32, Sendable, CaseIterable {
    case oeq = 0, one, olt, ole, ogt, oge, ueq, une, ult, ule, ugt, uge, ord, uno

    public var name: String { "\(self)" }
}

/// Memory orderings, numbered as `__ATOMIC_*`.
@frozen
public enum AIRAtomicOrdering: UInt32, Sendable {
    case relaxed = 0, consume, acquire, release, acqRel, seqCst

    public var name: String {
        switch self {
        case .relaxed: return "relaxed"
        case .consume: return "consume"
        case .acquire: return "acquire"
        case .release: return "release"
        case .acqRel: return "acq_rel"
        case .seqCst: return "seq_cst"
        }
    }
}

/// Read-modify-write operations (`atomicRMW`).
@frozen
public enum AIRAtomicOp: UInt32, Sendable {
    case xchg = 0, add, sub, and, or, xor, nand

    public var name: String { "\(self)" }
}

extension ValueId {
    /// The 2-bit tag of a value (03 §4.1): instruction result, function parameter, constant-pool entry, or global.
    public enum Tag: UInt32 { case inst = 0, parameter = 1, constant = 2, global = 3 }

    @inlinable
    public static func instResult(_ inst: InstId) -> ValueId {
        ValueId(inst.rawIndex & 0x3FFF_FFFF)
    }

    @inlinable
    public static func parameter(_ idx: UInt32) -> ValueId {
        ValueId(0x4000_0000 | (idx & 0x3FFF_FFFF))
    }

    @inlinable
    public static func constant(_ idx: UInt32) -> ValueId {
        ValueId(0x8000_0000 | (idx & 0x3FFF_FFFF))
    }

    @inlinable
    public static func global(_ idx: UInt32) -> ValueId {
        ValueId(0xC000_0000 | (idx & 0x3FFF_FFFF))
    }

    @inlinable
    public var tag: UInt32 { rawIndex >> 30 }

    public var valueTag: Tag { Tag(rawValue: tag)! }

    @inlinable
    public var index: UInt32 { rawIndex & 0x3FFF_FFFF }

    public var inst: InstId { InstId(index) }
}

/// A fixed stack slot of a function: a named local, a parameter's home, or a temporary.
public struct AIRSlot: Sendable, Equatable {
    public var size: Int
    public var alignment: Int
    /// The C name of the object (empty for a temporary).
    public var name: String
    public var decl: DeclId
}

/// The constant pool of a function: each constant's type and its bits in 64-bit words (least significant first; a
/// float holds its encoding, an `f80` its significand then its sign and exponent).
public struct AIRConstantPool: Sendable {
    public private(set) var types: [AIRType] = [.void]
    public private(set) var wordStart: [UInt32] = [0, 0]
    public private(set) var words: [UInt64] = []
    private var index: [Key: UInt32] = [:]

    private struct Key: Hashable {
        let type: AIRType
        let words: [UInt64]
    }

    public init() {}

    public var count: Int { types.count }

    /// The constant of `type` with `words`, which are masked to the type's width.
    public mutating func intern(_ type: AIRType, _ value: [UInt64]) -> ValueId {
        let n = max(1, (type.width + 63) / 64)
        var w = Array(value.prefix(n))
        while w.count < n { w.append(0) }
        let rem = type.width % 64
        if rem != 0 { w[n - 1] &= (1 << UInt64(rem)) - 1 }
        let key = Key(type: type, words: w)
        if let i = index[key] { return .constant(i) }
        let i = UInt32(types.count)
        types.append(type)
        words.append(contentsOf: w)
        wordStart.append(UInt32(words.count))
        index[key] = i
        return .constant(i)
    }

    public func type(_ i: UInt32) -> AIRType { Int(i) < types.count ? types[Int(i)] : .void }

    public func words(_ i: UInt32) -> ArraySlice<UInt64> {
        guard Int(i) + 1 < wordStart.count else { return [] }
        return words[Int(wordStart[Int(i)])..<Int(wordStart[Int(i) + 1])]
    }

    /// The low 64 bits of an integer constant, sign-extended from its width if `signed`.
    public func int64(_ i: UInt32, signed: Bool = false) -> Int64 {
        let w = words(i).first ?? 0
        let width = type(i).width
        guard signed, width < 64, width > 0 else { return Int64(bitPattern: w) }
        let shift = UInt64(64 - width)
        return Int64(bitPattern: w << shift) >> Int64(shift)
    }
}

/// An AIR function (03 §4.1): instruction columns indexed by `InstId`, numbered in block order, and the CFG in CSR
/// form. Built by `AIRBuilder`.
public struct AIRFunction: ~Copyable {
    /// The function's symbol in `AIRModule.symbols`.
    public var symbol: Int
    public var name: String
    /// The C function type.
    public var cType: TypeId
    public var returnType: AIRType
    /// Whether the C result is an aggregate, returned through `ret` of its address.
    public var returnsAggregate: Bool
    public var paramTypes: [AIRType]
    /// Per parameter: whether it is an aggregate (its value is the address of the callee's copy).
    public var paramIsAggregate: [Bool]
    public var slots: [AIRSlot]
    public var constants: AIRConstantPool

    // Instruction columns (InstId 0 is the nil row).
    public var opcode: Column<InstId, UInt8>
    public var type: Column<InstId, UInt32>
    public var op0: Column<InstId, UInt32>
    public var op1: Column<InstId, UInt32>
    public var aux: Column<InstId, UInt32>
    /// The SemIR node each instruction came from (a parse-tree NodeId), for source locations.
    public var node: Column<InstId, UInt32>
    public var extra: Column<ExtraId, UInt32>

    // Blocks (BlockId 0 is the nil block; block 1 is the entry). Instructions of block b are
    // InstIds blockStart[b] ..< blockStart[b + 1].
    public var blockStart: Column<BlockId, UInt32>
    public var succStart: Column<BlockId, UInt32>
    public var succEdges: Column<SuccEdgeIndex, UInt32>
    public var predStart: Column<BlockId, UInt32>
    public var predEdges: Column<PredEdgeIndex, UInt32>
    public var blockCount: UInt32
    /// Blocks whose address is taken (`blockAddr`, or a label address in a static initializer).
    public var addressTakenBlocks: [BlockId]
    /// The block of each C label (by its number in `SemFunction.labels`) that remains.
    public var labelBlocks: [UInt32: BlockId] = [:]
    /// Names of blocks for dumps (C labels).
    public var blockNames: [BlockId: String] = [:]

    init(symbol: Int, name: String, cType: TypeId, returnType: AIRType, returnsAggregate: Bool, paramTypes: [AIRType],
         paramIsAggregate: [Bool], capacity: Int) {
        self.symbol = symbol
        self.name = name
        self.cType = cType
        self.returnType = returnType
        self.returnsAggregate = returnsAggregate
        self.paramTypes = paramTypes
        self.paramIsAggregate = paramIsAggregate
        self.slots = []
        self.constants = AIRConstantPool()
        let n = max(1024, capacity + 1)
        opcode = Column(reservedCapacity: n, defaultNilValue: 0)
        type = Column(reservedCapacity: n, defaultNilValue: 0)
        op0 = Column(reservedCapacity: n, defaultNilValue: 0)
        op1 = Column(reservedCapacity: n, defaultNilValue: 0)
        aux = Column(reservedCapacity: n, defaultNilValue: 0)
        node = Column(reservedCapacity: n, defaultNilValue: 0)
        extra = Column(reservedCapacity: max(1024, 4 * n), defaultNilValue: 0)
        blockStart = Column(reservedCapacity: n + 2, defaultNilValue: 1)
        succStart = Column(reservedCapacity: n + 2, defaultNilValue: 0)
        succEdges = Column(reservedCapacity: max(1024, 4 * n), defaultNilValue: 0)
        predStart = Column(reservedCapacity: n + 2, defaultNilValue: 0)
        predEdges = Column(reservedCapacity: max(1024, 4 * n), defaultNilValue: 0)
        blockCount = 1
        addressTakenBlocks = []
    }

    public var instructionCount: UInt32 { opcode.count }

    public func op(_ i: InstId) -> AIROpcode { AIROpcode(rawValue: opcode[i]) ?? .nilOp }
    public func resultType(_ i: InstId) -> AIRType { AIRType(rawValue: type[i]) }

    /// The instructions of block `b`.
    public func instructions(of b: BlockId) -> Range<UInt32> {
        blockStart[b]..<blockStart[BlockId(b.rawIndex + 1)]
    }

    public func successors(of b: BlockId) -> [BlockId] {
        (succStart[b]..<succStart[BlockId(b.rawIndex + 1)]).map { BlockId(succEdges[SuccEdgeIndex($0)]) }
    }

    public func predecessors(of b: BlockId) -> [BlockId] {
        (predStart[b]..<predStart[BlockId(b.rawIndex + 1)]).map { BlockId(predEdges[PredEdgeIndex($0)]) }
    }

    /// The items of the extra list at `offset`.
    public func extraList(_ offset: UInt32) -> [UInt32] {
        guard offset > 0, offset < extra.count else { return [] }
        let n = extra[ExtraId(offset)]
        guard offset + n < extra.count else { return [] }
        return (0..<n).map { extra[ExtraId(offset + 1 + $0)] }
    }

    /// The type of a value: an instruction's result, a parameter's, a constant's; a global is a `ptr`.
    public func valueType(_ v: ValueId) -> AIRType {
        switch v.valueTag {
        case .inst: return v.index < opcode.count ? resultType(v.inst) : .void
        case .parameter: return Int(v.index) < paramTypes.count ? paramTypes[Int(v.index)] : .void
        case .constant: return constants.type(v.index)
        case .global: return .ptr
        }
    }

    /// The block holding instruction `i` (a binary search of `blockStart`).
    public func block(of i: InstId) -> BlockId {
        var lo: UInt32 = 1, hi = blockCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if blockStart[BlockId(mid)] <= i.rawIndex { lo = mid } else { hi = mid - 1 }
        }
        return BlockId(lo)
    }

    /// The successors a terminator names, in order (duplicates kept).
    public func terminatorTargets(_ i: InstId) -> [BlockId] {
        switch op(i) {
        case .br: return [BlockId(aux[i])]
        case .condBr: return [BlockId(op1[i]), BlockId(aux[i])]
        case .switch:
            let items = extraList(aux[i])
            guard let first = items.first else { return [] }
            return [BlockId(first)] + stride(from: 2, to: items.count, by: 2).map { BlockId(items[$0]) }
        case .indirectBr:
            return extraList(aux[i]).map { BlockId($0) }
        case .asmGoto:
            return AIRAsm(extraList(aux[i]))?.labels ?? []
        default:
            return []
        }
    }
}

/// The extra list of `inlineAsm`/`asmGoto`: [template, flags, output count, input count, clobber count, label count,
/// per output (constraint, name, address), per input (constraint, name, value or address), clobbers, label
/// BlockIds]. Strings are indices into `AIRModule.strings`; a missing name is `AIRAsm.noName`.
public struct AIRAsm {
    public static let noName = UInt32.max

    public struct Operand {
        public let constraint: UInt32
        public let name: UInt32
        public let value: ValueId
    }

    public let template: UInt32
    /// `SemAsm` flags.
    public let flags: UInt32
    public let outputs: [Operand]
    public let inputs: [Operand]
    public let clobbers: [UInt32]
    public let labels: [BlockId]

    public init?(_ items: [UInt32]) {
        guard items.count >= 6 else { return nil }
        let nOut = Int(items[2]), nIn = Int(items[3]), nClobber = Int(items[4]), nLabel = Int(items[5])
        guard items.count == 6 + 3 * (nOut + nIn) + nClobber + nLabel else { return nil }
        func operands(_ start: Int, _ n: Int) -> [Operand] {
            (0..<n).map { Operand(constraint: items[start + 3 * $0], name: items[start + 3 * $0 + 1], value: ValueId(items[start + 3 * $0 + 2])) }
        }
        template = items[0]
        flags = items[1]
        outputs = operands(6, nOut)
        inputs = operands(6 + 3 * nOut, nIn)
        let c = 6 + 3 * (nOut + nIn)
        clobbers = Array(items[c..<(c + nClobber)])
        labels = items[(c + nClobber)...].map { BlockId($0) }
    }

    /// The positions in the list of the operand values and of the labels.
    static func valuePositions(_ items: [UInt32]) -> (values: [Int], labels: [Int]) {
        guard items.count >= 6 else { return ([], []) }
        let nOut = Int(items[2]), nIn = Int(items[3]), nClobber = Int(items[4])
        let values = (0..<(nOut + nIn)).map { 6 + 3 * $0 + 2 }
        let labelStart = 6 + 3 * (nOut + nIn) + nClobber
        return (values, Array(labelStart..<items.count))
    }
}

/// Builds an `AIRFunction`. Instructions are appended to the current block; blocks are laid out in the order they
/// are first entered. `finish` drops blocks unreachable from the entry (keeping address-taken ones), numbers the
/// instructions in block order, and builds the CFG.
public struct AIRBuilder {
    struct Inst {
        var op: AIROpcode
        var type: AIRType
        var op0: UInt32
        var op1: UInt32
        var aux: UInt32
        var node: UInt32
    }

    var insts: [Inst] = [Inst(op: .nilOp, type: .void, op0: 0, op1: 0, aux: 0, node: 0)]
    /// Instructions of each block, in order (index 0 unused).
    var blockInsts: [[UInt32]] = [[]]
    /// Blocks in the order they were first entered.
    var layout: [UInt32] = []
    var entered: [Bool] = [false]
    var extra: [UInt32] = [0]
    public var constants = AIRConstantPool()
    public var slots: [AIRSlot] = []
    public private(set) var current: BlockId = .nilId
    public private(set) var entry: BlockId = .nilId
    /// The `alloca`s, which go at the start of the entry block.
    var allocas: [UInt32] = []
    public var addressTaken: [BlockId] = []
    /// C labels: the block of each label number, and its name (for dumps).
    public var labelBlocks: [UInt32: BlockId] = [:]
    public var blockNames: [BlockId: String] = [:]
    /// The SemIR node of the instructions being emitted.
    public var node: UInt32 = 0

    public init() {
        entry = newBlock()
        position(at: entry)
    }

    public mutating func newBlock() -> BlockId {
        blockInsts.append([])
        entered.append(false)
        return BlockId(UInt32(blockInsts.count - 1))
    }

    /// Makes `b` the block instructions are appended to.
    public mutating func position(at b: BlockId) {
        if !entered[Int(b.rawIndex)] {
            entered[Int(b.rawIndex)] = true
            layout.append(b.rawIndex)
        }
        current = b
    }

    /// Whether the current block ends with a terminator.
    public var isTerminated: Bool {
        guard let last = blockInsts[Int(current.rawIndex)].last else { return false }
        return insts[Int(last)].op.isTerminator
    }

    public func opcode(of v: ValueId) -> AIROpcode? {
        v.valueTag == .inst && Int(v.index) < insts.count ? insts[Int(v.index)].op : nil
    }

    public func aux(of v: ValueId) -> UInt32 { insts[Int(v.index)].aux }
    public func op0(of v: ValueId) -> ValueId { ValueId(insts[Int(v.index)].op0) }

    public func type(of v: ValueId, params: [AIRType]) -> AIRType {
        switch v.valueTag {
        case .inst: return insts[Int(v.index)].type
        case .parameter: return params[Int(v.index)]
        case .constant: return constants.type(v.index)
        case .global: return .ptr
        }
    }

    /// Appends an instruction to the current block. After a terminator the block is closed, and further code goes to
    /// a fresh unreachable block (`finish` drops it).
    @discardableResult
    public mutating func emit(_ op: AIROpcode, _ type: AIRType = .void, _ op0: UInt32 = 0, _ op1: UInt32 = 0, aux: UInt32 = 0) -> ValueId {
        if let folded = fold(op, type, ValueId(op0), ValueId(op1), aux: aux) { return folded }
        if isTerminated { position(at: newBlock()) }
        let id = UInt32(insts.count)
        insts.append(Inst(op: op, type: type, op0: op0, op1: op1, aux: aux, node: node))
        blockInsts[Int(current.rawIndex)].append(id)
        return .instResult(InstId(id))
    }

    @discardableResult
    public mutating func emit(_ op: AIROpcode, _ type: AIRType = .void, _ op0: ValueId, _ op1: ValueId = .nilId, aux: UInt32 = 0) -> ValueId {
        emit(op, type, op0.rawIndex, op1.rawIndex, aux: aux)
    }

    static func floatFormat(_ t: AIRType) -> FloatFormat? {
        switch t.width {
        case 16: return .half
        case 32: return .single
        case 64: return .double
        case 80: return .x87Extended
        case 128: return .quad
        default: return nil
        }
    }

    /// The bits of an integer constant of at most 64 bits.
    func constantBits(_ v: ValueId) -> (type: AIRType, bits: UInt64)? {
        guard v.valueTag == .constant else { return nil }
        let t = constants.type(v.index)
        guard t.isInt, t.width <= 64 else { return nil }
        return (t, constants.words(v.index).first ?? 0)
    }

    /// Folds an integer operation on constants (of at most 64 bits) into a constant, as LLVM's IR builder does;
    /// operations whose result is undefined (a shift by the width or more) and divisions are left alone.
    mutating func fold(_ op: AIROpcode, _ type: AIRType, _ a: ValueId, _ b: ValueId, aux: UInt32) -> ValueId? {
        // Width changes of integer constants of any width
        if op == .trunc || op == .zext || op == .sext, a.valueTag == .constant, constants.type(a.index).isInt, type.isInt {
            let from = constants.type(a.index)
            var words = Array(constants.words(a.index))
            let n = max(1, (type.width + 63) / 64)
            let negative = op == .sext && (words[(from.width - 1) / 64] >> UInt64((from.width - 1) % 64)) & 1 == 1
            if negative, from.width % 64 != 0 { words[words.count - 1] |= ~0 << UInt64(from.width % 64) }
            while words.count < n { words.append(negative ? ~0 : 0) }
            return constants.intern(type, words)
        }
        // `p + 0`, `x + 0`, `x * 1`
        if op == .ptrAdd || op == .add, let y = constantBits(b), y.bits == 0 { return a }
        if op == .mul, let y = constantBits(b), y.bits == 1 { return a }
        if op == .mul, let x = constantBits(a), x.bits == 1, b.valueTag != .constant { return b }
        // Conversions of constants to floats, exactly rounded
        if type.isFloat, a.valueTag == .constant, let format = Self.floatFormat(type) {
            let from = constants.type(a.index)
            let words = Array(constants.words(a.index))
            var result: SoftFloat?
            switch op {
            case .sitofp, .uitofp where from.isInt && from.width <= 64:
                let bits = words.first ?? 0
                if op == .sitofp && from.width > 1 {
                    let v = from.width >= 64 ? Int64(bitPattern: bits) : Int64(bitPattern: bits << UInt64(64 - from.width)) >> Int64(64 - from.width)
                    result = SoftFloat.fromInteger(BigUInt(v < 0 ? UInt64(bitPattern: 0 &- v) : UInt64(v)), negative: v < 0, format: format)
                } else {
                    result = SoftFloat.fromInteger(BigUInt(bits), negative: false, format: format)
                }
            case .fpext, .fptrunc where from.isFloat:
                if let fromFormat = Self.floatFormat(from) {
                    result = SoftFloat.decode(FloatConstant(lo: words.first ?? 0, hi: words.count > 1 ? words[1] : 0), format: fromFormat).converted(to: format)
                }
            default:
                break
            }
            if let result {
                let c = result.constant
                return constants.intern(type, [c.lo, c.hi])
            }
        }
        guard let x = constantBits(a) else { return nil }
        func signed(_ v: UInt64, _ w: Int) -> Int64 { w >= 64 ? Int64(bitPattern: v) : Int64(bitPattern: v << UInt64(64 - w)) >> Int64(64 - w) }
        func make(_ t: AIRType, _ v: UInt64) -> ValueId { constants.intern(t, [v]) }
        switch op {
        case .add, .sub, .mul, .and, .or, .xor, .shl, .lshr, .ashr, .icmp:
            guard let y = constantBits(b), x.type == y.type else { return nil }
            let w = x.type.width
            switch op {
            case .add: return make(type, x.bits &+ y.bits)
            case .sub: return make(type, x.bits &- y.bits)
            case .mul: return make(type, x.bits &* y.bits)
            case .and: return make(type, x.bits & y.bits)
            case .or: return make(type, x.bits | y.bits)
            case .xor: return make(type, x.bits ^ y.bits)
            case .shl, .lshr, .ashr:
                guard y.bits < UInt64(w) else { return nil }
                if op == .shl { return make(type, x.bits << y.bits) }
                if op == .lshr { return make(type, x.bits >> y.bits) }
                return make(type, UInt64(bitPattern: signed(x.bits, w) >> Int64(y.bits)))
            default:
                guard let p = AIRICmp(rawValue: aux) else { return nil }
                let sx = signed(x.bits, w), sy = signed(y.bits, w)
                let r: Bool
                switch p {
                case .eq: r = x.bits == y.bits
                case .ne: r = x.bits != y.bits
                case .slt: r = sx < sy
                case .sle: r = sx <= sy
                case .sgt: r = sx > sy
                case .sge: r = sx >= sy
                case .ult: r = x.bits < y.bits
                case .ule: r = x.bits <= y.bits
                case .ugt: r = x.bits > y.bits
                case .uge: r = x.bits >= y.bits
                }
                return make(.i1, r ? 1 : 0)
            }
        default:
            return nil
        }
    }

    /// A stack slot and its `alloca` (at the start of the entry block).
    public mutating func alloca(size: Int, alignment: Int, name: String = "", decl: DeclId = .nilId) -> ValueId {
        slots.append(AIRSlot(size: size, alignment: alignment, name: name, decl: decl))
        let id = UInt32(insts.count)
        insts.append(Inst(op: .alloca, type: .ptr, op0: 0, op1: 0, aux: UInt32(slots.count - 1), node: node))
        allocas.append(id)
        return .instResult(InstId(id))
    }

    /// Stores a counted list in `extra` and returns its offset.
    public mutating func list(_ items: [UInt32]) -> UInt32 {
        let offset = UInt32(extra.count)
        extra.append(UInt32(items.count))
        extra.append(contentsOf: items)
        return offset
    }

    public func extraList(_ offset: UInt32) -> [UInt32] {
        guard offset > 0, Int(offset) < extra.count else { return [] }
        let n = Int(extra[Int(offset)])
        return Array(extra[(Int(offset) + 1)..<(Int(offset) + 1 + n)])
    }

    /// Replaces the `aux` of an instruction (an `indirectBr`'s target list, completed at the end of the function).
    public mutating func setAux(_ v: ValueId, _ aux: UInt32) {
        insts[Int(v.index)].aux = aux
    }

    /// Branches to `b` unless the current block is closed.
    public mutating func branch(to b: BlockId) {
        if !isTerminated { emit(.br, aux: b.rawIndex) }
    }

    // MARK: - Finishing

    /// The block operands and the value operands of an instruction, as positions to rewrite.
    private func targets(_ inst: Inst) -> [BlockId] {
        switch inst.op {
        case .br: return [BlockId(inst.aux)]
        case .condBr: return [BlockId(inst.op1), BlockId(inst.aux)]
        case .switch:
            let items = extraList(inst.aux)
            guard let first = items.first else { return [] }
            return [BlockId(first)] + stride(from: 2, to: items.count, by: 2).map { BlockId(items[$0]) }
        case .indirectBr:
            return extraList(inst.aux).map { BlockId($0) }
        case .asmGoto:
            let items = extraList(inst.aux)
            return AIRAsm.valuePositions(items).labels.map { BlockId(items[$0]) }
        default:
            return []
        }
    }

    public consuming func finish(symbol: Int, name: String, cType: TypeId, returnType: AIRType, returnsAggregate: Bool,
                                 paramTypes: [AIRType], paramIsAggregate: [Bool]) -> AIRFunction {
        // The allocas open the entry block
        blockInsts[Int(entry.rawIndex)].insert(contentsOf: allocas, at: 0)

        // Reachability from the entry and the address-taken blocks
        var reachable = [Bool](repeating: false, count: blockInsts.count)
        var work = [entry] + addressTaken
        for b in work { reachable[Int(b.rawIndex)] = true }
        while let b = work.popLast() {
            guard let last = blockInsts[Int(b.rawIndex)].last else { continue }
            for t in targets(insts[Int(last)]) where !reachable[Int(t.rawIndex)] {
                reachable[Int(t.rawIndex)] = true
                work.append(t)
            }
        }
        let order = layout.filter { reachable[Int($0)] }
        var newBlock = [UInt32](repeating: 0, count: blockInsts.count)
        for (i, b) in order.enumerated() { newBlock[Int(b)] = UInt32(i + 1) }
        var newInst = [UInt32](repeating: 0, count: insts.count)
        var next: UInt32 = 1
        for b in order {
            for i in blockInsts[Int(b)] {
                newInst[Int(i)] = next
                next += 1
            }
        }
        func value(_ raw: UInt32) -> UInt32 {
            let v = ValueId(raw)
            guard raw != 0, v.valueTag == .inst else { return raw }
            return newInst[Int(v.index)]
        }
        func block(_ raw: UInt32) -> UInt32 { newBlock[Int(raw)] }

        var f = AIRFunction(symbol: symbol, name: name, cType: cType, returnType: returnType, returnsAggregate: returnsAggregate,
                            paramTypes: paramTypes, paramIsAggregate: paramIsAggregate, capacity: Int(next))
        f.slots = slots
        f.constants = constants
        f.addressTakenBlocks = addressTaken.map { BlockId(block($0.rawIndex)) }
        for (label, b) in labelBlocks where reachable[Int(b.rawIndex)] { f.labelBlocks[label] = BlockId(block(b.rawIndex)) }
        for (b, name) in blockNames where reachable[Int(b.rawIndex)] { f.blockNames[BlockId(block(b.rawIndex))] = name }
        // Extra lists are copied per instruction, with their values and blocks renumbered (row 0 is the nil row)
        var extraOut: [UInt32] = [0]
        func copyList(_ offset: UInt32, rewrite: (Int, UInt32) -> UInt32) -> UInt32 {
            let items = extraList(offset)
            let start = UInt32(extraOut.count)
            extraOut.append(UInt32(items.count))
            for (k, item) in items.enumerated() { extraOut.append(rewrite(k, item)) }
            return start
        }
        for b in order {
            _ = f.blockStart.append(f.opcode.count)
            for i in blockInsts[Int(b)] {
                var inst = insts[Int(i)]
                let fields = inst.op.fields
                if fields.op0 == .value { inst.op0 = value(inst.op0) }
                if fields.op1 == .value { inst.op1 = value(inst.op1) } else if fields.op1 == .block { inst.op1 = block(inst.op1) }
                if fields.aux == .value { inst.aux = value(inst.aux) } else if fields.aux == .block { inst.aux = block(inst.aux) }
                switch inst.op {
                case .copy, .fill:
                    inst.aux = copyList(inst.aux) { k, item in k == 0 ? value(item) : item }
                case .cmpxchg:
                    inst.aux = copyList(inst.aux) { k, item in k == 0 ? value(item) : item }
                case .call:
                    inst.aux = copyList(inst.aux) { k, item in k >= 2 ? value(item) : item }
                case .phi:
                    // Incoming edges from dropped blocks go
                    let items = extraList(inst.aux)
                    var kept: [UInt32] = []
                    for k in stride(from: 0, to: items.count - 1, by: 2) where reachable[Int(items[k])] {
                        kept += [block(items[k]), value(items[k + 1])]
                    }
                    inst.aux = UInt32(extraOut.count)
                    extraOut.append(UInt32(kept.count))
                    extraOut += kept
                case .switch:
                    inst.aux = copyList(inst.aux) { k, item in k == 0 || k % 2 == 0 ? block(item) : item }
                case .indirectBr:
                    inst.aux = copyList(inst.aux) { _, item in block(item) }
                case .inlineAsm, .asmGoto:
                    let positions = AIRAsm.valuePositions(extraList(inst.aux))
                    let values = Set(positions.values), labels = Set(positions.labels)
                    inst.aux = copyList(inst.aux) { k, item in values.contains(k) ? value(item) : (labels.contains(k) ? block(item) : item) }
                default:
                    break
                }
                _ = f.opcode.append(inst.op.rawValue)
                _ = f.type.append(inst.type.rawValue)
                _ = f.op0.append(inst.op0)
                _ = f.op1.append(inst.op1)
                _ = f.aux.append(inst.aux)
                _ = f.node.append(inst.node)
            }
        }
        _ = f.blockStart.append(f.opcode.count)
        for item in extraOut.dropFirst() { _ = f.extra.append(item) }
        f.blockCount = UInt32(order.count + 1)
        f.buildCFG()
        return f
    }
}

extension AIRFunction {
    /// Rebuilds the successor and predecessor lists from the terminators.
    public mutating func buildCFG() {
        succStart.setCount(1)
        succEdges.setCount(1)
        predStart.setCount(1)
        predEdges.setCount(1)
        var preds = [[UInt32]](repeating: [], count: Int(blockCount))
        for b in 1..<blockCount {
            _ = succStart.append(succEdges.count)
            let range = instructions(of: BlockId(b))
            guard !range.isEmpty else { continue }
            var seen = Set<UInt32>()
            for t in terminatorTargets(InstId(range.upperBound - 1)) where seen.insert(t.rawIndex).inserted {
                _ = succEdges.append(t.rawIndex)
                if Int(t.rawIndex) < preds.count { preds[Int(t.rawIndex)].append(b) }
            }
        }
        _ = succStart.append(succEdges.count)
        for b in 1..<blockCount {
            _ = predStart.append(predEdges.count)
            for p in preds[Int(b)] { _ = predEdges.append(p) }
        }
        _ = predStart.append(predEdges.count)
    }
}
