// Sources/SwiftStack/AIR/Slice/SliceAIRFunction.swift
import Foundation

// The M0.5 vertical slice's AIR (integer-only, lowered from the parse tree). The code generator of the slice still
// reads it; M3 phase 3 replaces both with the AIR of `AIR/AIRFunction.swift` (milestones/M3-plan.md §2).

/// Opcodes of the M0.5 slice's AIR.
@frozen
public enum SliceAIROpcode: UInt8, Sendable, BitwiseCopyable, CustomStringConvertible {
    case nilOp = 0
    case iconst = 1        // aux = immediate 32-bit integer
    case stringConst = 2   // aux = string literal index
    case alloca = 3        // aux = stack size in bytes, returns pointer
    case load = 4          // op0 = pointer value, returns loaded value
    case store = 5         // op0 = value, op1 = pointer, returns void
    case add = 6           // op0 + op1
    case sub = 7           // op0 - op1
    case mul = 8           // op0 * op1
    case sdiv = 9          // op0 / op1
    case srem = 10         // op0 % op1
    case band = 11         // op0 & op1
    case bor = 12          // op0 | op1
    case bxor = 13         // op0 ^ op1
    case shl = 14          // op0 << op1
    case shr = 15          // op0 >> op1
    case icmp_eq = 16      // op0 == op1
    case icmp_ne = 17      // op0 != op1
    case icmp_slt = 18     // op0 < op1 (signed)
    case icmp_sle = 19     // op0 <= op1 (signed)
    case icmp_sgt = 20     // op0 > op1 (signed)
    case icmp_sge = 21     // op0 >= op1 (signed)
    case call = 22         // aux = callee function index, operands in extra
    case ret = 23          // op0 = return value (or 0 for void)
    case br = 24           // aux = target BlockId
    case cond_br = 25      // op0 = condition, aux = target BlockId true, op1 = target BlockId false
    case param = 26        // aux = param index
    case iconst64 = 27      // op0 = high 32 bits, aux = low 32 bits

    public var description: String {
        switch self {
        case .nilOp: return "nil"
        case .iconst: return "iconst"
        case .iconst64: return "iconst64"
        case .stringConst: return "string_const"
        case .alloca: return "alloca"
        case .load: return "load"
        case .store: return "store"
        case .add: return "add"
        case .sub: return "sub"
        case .mul: return "mul"
        case .sdiv: return "sdiv"
        case .srem: return "srem"
        case .band: return "band"
        case .bor: return "bor"
        case .bxor: return "bxor"
        case .shl: return "shl"
        case .shr: return "shr"
        case .icmp_eq: return "icmp_eq"
        case .icmp_ne: return "icmp_ne"
        case .icmp_slt: return "icmp_slt"
        case .icmp_sle: return "icmp_sle"
        case .icmp_sgt: return "icmp_sgt"
        case .icmp_sge: return "icmp_sge"
        case .call: return "call"
        case .ret: return "ret"
        case .br: return "br"
        case .cond_br: return "cond_br"
        case .param: return "param"
        }
    }
}

/// An AIR function stored in Struct-of-Arrays (SoA) columns (03-intermediate-representation.md §4.1).
/// Footprint: 17 bytes per instruction across 5 columns.
public struct SliceAIRFunction: ~Copyable {
    public var name: String
    public var returnType: TypeId
    public var paramTypes: [TypeId]
    public var stackFrameSize: Int32

    // Instruction columns (indexed by InstId)
    public var opcode: Column<InstId, UInt8>
    public var type: Column<InstId, UInt32>
    public var op0: Column<InstId, UInt32>
    public var op1: Column<InstId, UInt32>
    public var aux: Column<InstId, UInt32>
    public var extra: Column<ExtraId, UInt32>

    // Block columns (CSR layout)
    public var blockOrder: Column<BlockOrderIndex, UInt32> // InstId
    public var blockStart: Column<BlockId, UInt32>
    public var instBlock: Column<InstId, UInt32>
    public var blockCount: UInt32

    public init(name: String, returnType: TypeId, paramTypes: [TypeId], stackFrameSize: Int32 = 0) {
        self.name = name
        self.returnType = returnType
        self.paramTypes = paramTypes
        self.stackFrameSize = stackFrameSize

        self.opcode = Column<InstId, UInt8>(reservedCapacity: 65536, defaultNilValue: 0)
        self.type = Column<InstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.op0 = Column<InstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.op1 = Column<InstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.aux = Column<InstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.extra = Column<ExtraId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)

        self.blockOrder = Column<BlockOrderIndex, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.blockStart = Column<BlockId, UInt32>(reservedCapacity: 4096, defaultNilValue: 0)
        self.instBlock = Column<InstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.blockCount = 1 // Row 0 is nil block
    }

    @inlinable
    public var instructionCount: UInt32 {
        opcode.count
    }

    @inlinable
    public var bytesCommitted: Int {
        opcode.bytesCommitted + type.bytesCommitted + op0.bytesCommitted +
        op1.bytesCommitted + aux.bytesCommitted + extra.bytesCommitted +
        blockOrder.bytesCommitted + blockStart.bytesCommitted + instBlock.bytesCommitted
    }

    @inlinable
    public var bytesReserved: Int {
        opcode.bytesReserved + type.bytesReserved + op0.bytesReserved +
        op1.bytesReserved + aux.bytesReserved + extra.bytesReserved +
        blockOrder.bytesReserved + blockStart.bytesReserved + instBlock.bytesReserved
    }

    @discardableResult
    public mutating func createBlock() -> BlockId {
        let bId = BlockId(blockCount)
        blockCount += 1
        _ = blockStart.append(blockOrder.count)
        return bId
    }

    @discardableResult
    public mutating func appendInstruction(
        opcode op: SliceAIROpcode,
        type ty: TypeId,
        op0 v0: ValueId = .nilId,
        op1 v1: ValueId = .nilId,
        aux a: UInt32 = 0,
        inBlock block: BlockId
    ) -> InstId {
        let id = opcode.append(op.rawValue)
        _ = type.append(ty.rawIndex)
        _ = op0.append(v0.rawIndex)
        _ = op1.append(v1.rawIndex)
        _ = aux.append(a)
        _ = instBlock.append(block.rawIndex)

        _ = blockOrder.append(id.rawIndex)
        return id
    }

    @discardableResult
    public mutating func appendExtra(_ value: ValueId) -> ExtraId {
        extra.append(value.rawIndex)
    }
}

/// An alternative Array-of-Structs (AoS) AIR instruction representation for measurement comparison (18-data-catalog.md §5.3).
@frozen
public struct AIRInstAoS: BitwiseCopyable {
    public var opcode: UInt8
    public var pad: UInt8
    public var pad2: UInt16
    public var type: UInt32
    public var op0: UInt32
    public var op1: UInt32
    public var aux: UInt32

    public init(opcode: UInt8, type: UInt32, op0: UInt32, op1: UInt32, aux: UInt32) {
        self.opcode = opcode
        self.pad = 0
        self.pad2 = 0
        self.type = type
        self.op0 = op0
        self.op1 = op1
        self.aux = aux
    }
}

public struct AIRFunctionAoS: ~Copyable {
    public var name: String
    public var instructions: Column<InstId, AIRInstAoS>

    public init(name: String) {
        self.name = name
        self.instructions = Column<InstId, AIRInstAoS>(reservedCapacity: 65536, defaultNilValue: AIRInstAoS(opcode: 0, type: 0, op0: 0, op1: 0, aux: 0))
    }

    @inlinable
    public var bytesCommitted: Int { instructions.bytesCommitted }

    @inlinable
    public var bytesReserved: Int { instructions.bytesReserved }
}
