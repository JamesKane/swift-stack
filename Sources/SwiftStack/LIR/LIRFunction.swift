// Sources/SwiftStack/LIR/LIRFunction.swift
import Foundation

/// Target-neutral register operand for LIR (04-backend.md §4.3).
/// Bit 31 set = physical register (low 8 bits index register file).
/// Bit 31 clear = virtual register number (0 = none/nil row).
@frozen
public struct Operand: BitwiseCopyable, Hashable, Sendable, CustomStringConvertible {
    public var raw: UInt32

    @inlinable
    public init(raw: UInt32) {
        self.raw = raw
    }

    public static let none = Operand(raw: 0)

    @inlinable
    public static func vreg(_ index: UInt32) -> Operand {
        Operand(raw: index & 0x7FFF_FFFF)
    }

    @inlinable
    public static func preg(_ reg: X86Register) -> Operand {
        Operand(raw: 0x8000_0000 | UInt32(reg.rawValue))
    }

    @inlinable
    public var isPhysical: Bool {
        (raw & 0x8000_0000) != 0
    }

    @inlinable
    public var isVirtual: Bool {
        (raw & 0x8000_0000) == 0 && raw != 0
    }

    @inlinable
    public var isNone: Bool {
        raw == 0
    }

    @inlinable
    public var regIndex: UInt32 {
        raw & 0x7FFF_FFFF
    }

    @inlinable
    public var physicalReg: X86Register? {
        guard isPhysical else { return nil }
        return X86Register(rawValue: UInt8(raw & 0xFF))
    }

    public var description: String {
        if isNone { return "none" }
        if isPhysical {
            let reg = physicalReg ?? .rax
            return "%\(reg)"
        }
        return "v\(regIndex)"
    }
}

/// Physical x86-64 general purpose registers.
@frozen
public enum X86Register: UInt8, Sendable, BitwiseCopyable, CustomStringConvertible {
    case rax = 0
    case rcx = 1
    case rdx = 2
    case rbx = 3
    case rsp = 4
    case rbp = 5
    case rsi = 6
    case rdi = 7
    case r8  = 8
    case r9  = 9
    case r10 = 10
    case r11 = 11
    case r12 = 12
    case r13 = 13
    case r14 = 14
    case r15 = 15

    public var description: String {
        switch self {
        case .rax: return "rax"
        case .rcx: return "rcx"
        case .rdx: return "rdx"
        case .rbx: return "rbx"
        case .rsp: return "rsp"
        case .rbp: return "rbp"
        case .rsi: return "rsi"
        case .rdi: return "rdi"
        case .r8:  return "r8"
        case .r9:  return "r9"
        case .r10: return "r10"
        case .r11: return "r11"
        case .r12: return "r12"
        case .r13: return "r13"
        case .r14: return "r14"
        case .r15: return "r15"
        }
    }
}

/// x86-64 target LIR opcodes (04-backend.md §4.3).
@frozen
public enum X86Opcode: UInt16, Sendable, BitwiseCopyable, CustomStringConvertible {
    case nilOp = 0
    case mov_rr = 1
    case mov_ri = 2
    case mov_rm = 3      // mov dst, [rbp - imm]
    case mov_mr = 4      // mov [rbp - imm], src1
    case mov_mi = 5      // mov [rbp - imm], imm32
    case mov_load = 6    // mov dst, [src1]
    case mov_store = 7   // mov [dst], src1
    case lea_stack = 8   // lea dst, [rbp - imm]
    case lea_string = 9  // lea dst, [rip + str_offset]
    case add_rr = 10
    case add_ri = 11
    case sub_rr = 12
    case sub_ri = 13
    case imul_rr = 14
    case idiv_r = 15     // cqo; idiv src1 -> quotient rax, remainder rdx
    case and_rr = 16
    case and_ri = 17
    case or_rr = 18
    case or_ri = 19
    case xor_rr = 20
    case xor_ri = 21
    case shl_rr = 22
    case shl_ri = 23
    case sar_rr = 24
    case sar_ri = 25
    case cmp_rr = 26
    case cmp_ri = 27
    case setcc = 28      // flags = ConditionCode, result in dst
    case jmp = 29        // imm = target block
    case jcc = 30        // flags = ConditionCode, imm = target block
    case call = 31       // imm = callee index or symbol
    case ret = 32
    case push_r = 33
    case pop_r = 34
    case syscall = 35
    case label = 36      // imm = BlockId
    case mov_stack_arg = 37    // mov dst, [rbp + imm]
    case store_stack_arg = 38  // mov [rsp + imm], src1
    case sub_rsp = 39          // sub rsp, imm
    case add_rsp = 40          // add rsp, imm

    public var description: String {
        switch self {
        case .nilOp: return "nil"
        case .mov_rr: return "mov_rr"
        case .mov_ri: return "mov_ri"
        case .mov_rm: return "mov_rm"
        case .mov_mr: return "mov_mr"
        case .mov_mi: return "mov_mi"
        case .mov_load: return "mov_load"
        case .mov_store: return "mov_store"
        case .lea_stack: return "lea_stack"
        case .lea_string: return "lea_string"
        case .add_rr: return "add_rr"
        case .add_ri: return "add_ri"
        case .sub_rr: return "sub_rr"
        case .sub_ri: return "sub_ri"
        case .imul_rr: return "imul_rr"
        case .idiv_r: return "idiv_r"
        case .and_rr: return "and_rr"
        case .and_ri: return "and_ri"
        case .or_rr: return "or_rr"
        case .or_ri: return "or_ri"
        case .xor_rr: return "xor_rr"
        case .xor_ri: return "xor_ri"
        case .shl_rr: return "shl_rr"
        case .shl_ri: return "shl_ri"
        case .sar_rr: return "sar_rr"
        case .sar_ri: return "sar_ri"
        case .cmp_rr: return "cmp_rr"
        case .cmp_ri: return "cmp_ri"
        case .setcc: return "setcc"
        case .jmp: return "jmp"
        case .jcc: return "jcc"
        case .call: return "call"
        case .ret: return "ret"
        case .push_r: return "push_r"
        case .pop_r: return "pop_r"
        case .syscall: return "syscall"
        case .label: return "label"
        case .mov_stack_arg: return "mov_stack_arg"
        case .store_stack_arg: return "store_stack_arg"
        case .sub_rsp: return "sub_rsp"
        case .add_rsp: return "add_rsp"
        }
    }
}

@frozen
public enum ConditionCode: UInt16, Sendable, BitwiseCopyable {
    case eq = 0
    case ne = 1
    case lt = 2
    case le = 3
    case gt = 4
    case ge = 5
}

/// LIRFunction stored as Struct-of-Arrays (SoA) columns (04-backend.md §4.3).
/// Footprint: 28 bytes per instruction across 7 columns.
public struct LIRFunctionSoA: ~Copyable {
    public var name: String
    public var stackFrameSize: UInt32

    // Per instruction columns (indexed by LIRInstId)
    public var opcodes: Column<LIRInstId, UInt16> // 2 B
    public var dst: Column<LIRInstId, UInt32>     // 4 B (Operand)
    public var src1: Column<LIRInstId, UInt32>    // 4 B (Operand)
    public var src2: Column<LIRInstId, UInt32>    // 4 B (Operand)
    public var imm: Column<LIRInstId, Int64>      // 8 B
    public var flags: Column<LIRInstId, UInt16>   // 2 B
    public var extra: Column<LIRInstId, UInt32>   // 4 B

    public init(name: String, stackFrameSize: UInt32 = 0) {
        self.name = name
        self.stackFrameSize = stackFrameSize

        self.opcodes = Column<LIRInstId, UInt16>(reservedCapacity: 65536, defaultNilValue: 0)
        self.dst = Column<LIRInstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.src1 = Column<LIRInstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.src2 = Column<LIRInstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
        self.imm = Column<LIRInstId, Int64>(reservedCapacity: 65536, defaultNilValue: 0)
        self.flags = Column<LIRInstId, UInt16>(reservedCapacity: 65536, defaultNilValue: 0)
        self.extra = Column<LIRInstId, UInt32>(reservedCapacity: 65536, defaultNilValue: 0)
    }

    @inlinable
    public var instructionCount: UInt32 { opcodes.count }

    @inlinable
    public var bytesCommitted: Int {
        opcodes.bytesCommitted + dst.bytesCommitted + src1.bytesCommitted +
        src2.bytesCommitted + imm.bytesCommitted + flags.bytesCommitted +
        extra.bytesCommitted
    }

    @inlinable
    public var bytesReserved: Int {
        opcodes.bytesReserved + dst.bytesReserved + src1.bytesReserved +
        src2.bytesReserved + imm.bytesReserved + flags.bytesReserved +
        extra.bytesReserved
    }

    @discardableResult
    public mutating func append(
        opcode: X86Opcode,
        dst: Operand = .none,
        src1: Operand = .none,
        src2: Operand = .none,
        imm: Int64 = 0,
        flags: UInt16 = 0,
        extra: UInt32 = 0
    ) -> LIRInstId {
        let id = opcodes.append(opcode.rawValue)
        _ = self.dst.append(dst.raw)
        _ = self.src1.append(src1.raw)
        _ = self.src2.append(src2.raw)
        _ = self.imm.append(imm)
        _ = self.flags.append(flags)
        _ = self.extra.append(extra)
        return id
    }
}

/// Alternative Array-of-Structs (AoS) 32-byte layout for measurement comparison (04 §4.3, 18 §5.3).
@frozen
public struct LIRInstAoS: BitwiseCopyable {
    public var imm: Int64     // 8 B, aligned 8
    public var opcode: UInt16 // 2 B
    public var flags: UInt16  // 2 B
    public var dst: UInt32    // 4 B
    public var src1: UInt32   // 4 B
    public var src2: UInt32   // 4 B
    public var extra: UInt32  // 4 B
    public var pad: UInt32    // 4 B (total 32 bytes)

    public init(opcode: UInt16, dst: UInt32, src1: UInt32, src2: UInt32, imm: Int64, flags: UInt16, extra: UInt32) {
        self.imm = imm
        self.opcode = opcode
        self.flags = flags
        self.dst = dst
        self.src1 = src1
        self.src2 = src2
        self.extra = extra
        self.pad = 0
    }
}

public struct LIRFunctionAoS: ~Copyable {
    public var name: String
    public var instructions: Column<LIRInstId, LIRInstAoS>

    public init(name: String) {
        self.name = name
        self.instructions = Column<LIRInstId, LIRInstAoS>(
            reservedCapacity: 65536,
            defaultNilValue: LIRInstAoS(opcode: 0, dst: 0, src1: 0, src2: 0, imm: 0, flags: 0, extra: 0)
        )
    }

    @inlinable
    public var bytesCommitted: Int { instructions.bytesCommitted }

    @inlinable
    public var bytesReserved: Int { instructions.bytesReserved }
}
