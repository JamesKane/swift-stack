// Sources/SwiftStack/LIR/LIR.swift
//
// LIR (04-backend.md §4.3): target instructions over virtual and physical registers, in SSA form until register
// allocation. Instruction selection (`X86InstructionSelector`) builds it from AIR, the allocator (`LinearScan`)
// assigns registers and stack slots, frame lowering (`X86FrameLowering`) resolves stack slots to frame offsets, and
// the printer (`X86AsmPrinter`) writes it as assembly.
//
// The layout is rows (an instruction is 12 bytes, an operand 32), not columns: the allocator, the rewriter and the
// printer all read every field of an instruction and its operands in order (04 §4.3 leaves the choice open).

import Foundation

/// A register operand: 0 is none; a virtual register is its number (1...); a physical register has bit 31 set and
/// its `PhysReg` number in the low bits.
@frozen
public struct LIRReg: Hashable, Sendable, BitwiseCopyable, Comparable, CustomStringConvertible {
    public var raw: UInt32

    @inlinable public init(raw: UInt32) { self.raw = raw }

    public static let none = LIRReg(raw: 0)
    @inlinable public static func virtual(_ n: UInt32) -> LIRReg { LIRReg(raw: n) }
    @inlinable public static func physical(_ r: PhysReg) -> LIRReg { LIRReg(raw: 0x8000_0000 | UInt32(r.rawValue)) }

    @inlinable public var isNone: Bool { raw == 0 }
    @inlinable public var isPhysical: Bool { raw & 0x8000_0000 != 0 }
    @inlinable public var isVirtual: Bool { raw != 0 && raw & 0x8000_0000 == 0 }
    @inlinable public var virtualIndex: Int { Int(raw) }
    @inlinable public var physical: PhysReg { PhysReg(rawValue: UInt8(raw & 0xFF))! }

    public static func < (a: LIRReg, b: LIRReg) -> Bool { a.raw < b.raw }

    public var description: String {
        if isNone { return "_" }
        if isPhysical { return "%" + physical.name(size: 8) }
        return "v\(raw)"
    }
}

/// x86-64 registers the allocator manages: the 16 general-purpose registers by hardware number, then `xmm0`–`xmm15`.
@frozen
public enum PhysReg: UInt8, Sendable, CaseIterable, Comparable {
    case rax = 0, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15
    case xmm0 = 16, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, xmm8, xmm9, xmm10, xmm11, xmm12, xmm13, xmm14, xmm15

    public static let count = 32

    public var isGPR: Bool { rawValue < 16 }
    public var isXMM: Bool { rawValue >= 16 }
    public var hw: UInt8 { rawValue & 15 }

    public static func < (a: PhysReg, b: PhysReg) -> Bool { a.rawValue < b.rawValue }

    public static func gpr(_ hw: UInt8) -> PhysReg { PhysReg(rawValue: hw)! }
    public static func xmm(_ n: Int) -> PhysReg { PhysReg(rawValue: 16 + UInt8(n))! }

    /// The encoder's register for this register at `size` bytes (a GPR's 1, 2, 4 or 8-byte form; an XMM register).
    public func x86Reg(size: Int) -> X86Reg {
        if isXMM { return .xmm(hw) }
        switch size {
        case 1: return .gpr8(hw, hasRex: true)
        case 2: return .gpr16(hw)
        case 4: return .gpr32(hw)
        default: return .gpr64(hw)
        }
    }

    public func name(size: Int) -> String { x86Reg(size: size).name }

    /// System V: the registers a call may change.
    public var isCallerSaved: Bool {
        switch self {
        case .rbx, .rbp, .rsp, .r12, .r13, .r14, .r15: return false
        default: return true
        }
    }
}

/// The register class of a virtual register.
@frozen
public enum LIRRegClass: UInt8, Sendable {
    case gpr = 0
    case xmm = 1

    public var allocatable: [PhysReg] {
        switch self {
        // Caller-saved registers first, so a value not live across a call does not cost a callee-saved register.
        case .gpr: return [.rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11, .rbx, .r12, .r13, .r14, .r15]
        case .xmm: return (0..<16).map { PhysReg.xmm($0) }
        }
    }
}

/// x86 condition codes, numbered as the encoding's `cc` field.
@frozen
public enum X86Cond: UInt8, Sendable, CaseIterable {
    case o = 0, no, b, ae, e, ne, be, a, s, ns, p, np, l, ge, le, g

    public var name: String { "\(self)" }
    public var inverted: X86Cond { X86Cond(rawValue: rawValue ^ 1)! }
}

/// A relocation modifier on a symbol operand.
@frozen
public enum LIRSymbolModifier: UInt8, Sendable {
    case none = 0, plt, gotpcrel, tpoff, gottpoff

    public var suffix: String {
        switch self {
        case .none: return ""
        case .plt: return "@PLT"
        case .gotpcrel: return "@GOTPCREL"
        case .tpoff: return "@tpoff"
        case .gottpoff: return "@gottpoff"
        }
    }
}

/// An operand of an LIR instruction.
///
/// - `reg`: `reg` at `size` bytes.
/// - `imm`: `value`, plus the address of symbol `symbol` if it is not 0 (`$sym+value`).
/// - `mem`: the address `base + index * scale + value`, plus the frame offset of stack slot `slot` (a frame-pointer
///   base), plus symbol `symbol` (RIP-relative if there is no base and no slot); `segment` is 0, or 4/5 for `%fs`/`%gs`.
/// - `block`: a block of the function (`value`).
/// - `symbol`: a direct call or jump target.
public struct LIROperand: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case none = 0, reg, imm, mem, block, symbol }

    /// Operand roles for the allocator.
    public struct Flags: OptionSet, Sendable, Equatable {
        public var rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Read (registers; the base and index of a memory operand are always read).
        public static let use = Flags(rawValue: 1)
        /// Written.
        public static let def = Flags(rawValue: 2)
        /// Not printed: a register the instruction reads or writes implicitly (`idiv`'s `rax`, a call's arguments).
        public static let implicit = Flags(rawValue: 4)
        /// Written before the inputs are read, so it may not share a register with them.
        public static let earlyClobber = Flags(rawValue: 8)
    }

    public var kind: Kind
    public var flags: Flags
    public var size: UInt8
    public var scale: UInt8
    public var modifier: LIRSymbolModifier
    public var segment: UInt8
    public var reg: LIRReg
    public var index: LIRReg
    public var slot: UInt32
    public var symbol: UInt32
    public var value: Int64

    public init(kind: Kind, flags: Flags = [], size: Int = 8, reg: LIRReg = .none, index: LIRReg = .none, scale: Int = 1,
                slot: UInt32 = 0, symbol: UInt32 = 0, modifier: LIRSymbolModifier = .none, segment: UInt8 = 0, value: Int64 = 0) {
        self.kind = kind
        self.flags = flags
        self.size = UInt8(size)
        self.scale = UInt8(scale)
        self.modifier = modifier
        self.segment = segment
        self.reg = reg
        self.index = index
        self.slot = slot
        self.symbol = symbol
        self.value = value
    }

    public static func use(_ r: LIRReg, _ size: Int) -> LIROperand { LIROperand(kind: .reg, flags: .use, size: size, reg: r) }
    public static func def(_ r: LIRReg, _ size: Int) -> LIROperand { LIROperand(kind: .reg, flags: .def, size: size, reg: r) }
    /// A register read and written in place (the first operand of a two-address instruction).
    public static func useDef(_ r: LIRReg, _ size: Int) -> LIROperand { LIROperand(kind: .reg, flags: [.use, .def], size: size, reg: r) }
    public static func imm(_ v: Int64) -> LIROperand { LIROperand(kind: .imm, value: v) }
    public static func block(_ b: Int) -> LIROperand { LIROperand(kind: .block, value: Int64(b)) }
    public static func symbol(_ s: UInt32, _ modifier: LIRSymbolModifier = .none) -> LIROperand {
        LIROperand(kind: .symbol, symbol: s, modifier: modifier)
    }
    public static func implicitUse(_ r: PhysReg) -> LIROperand {
        LIROperand(kind: .reg, flags: [.use, .implicit], size: 8, reg: .physical(r))
    }
    public static func implicitDef(_ r: PhysReg) -> LIROperand {
        LIROperand(kind: .reg, flags: [.def, .implicit], size: 8, reg: .physical(r))
    }

    public var isReg: Bool { kind == .reg }
    public var isMem: Bool { kind == .mem }
    public var isUse: Bool { flags.contains(.use) }
    public var isDef: Bool { flags.contains(.def) }
    public var isImplicit: Bool { flags.contains(.implicit) }
}

/// An address for a memory operand, before it is placed in an instruction.
public struct LIRAddress: Sendable, Equatable {
    public var base: LIRReg = .none
    public var index: LIRReg = .none
    public var scale: Int = 1
    public var disp: Int64 = 0
    /// A stack slot (`LIRFunction.slots`), addressed from the frame pointer; 0 for none.
    public var slot: UInt32 = 0
    /// A symbol (`LIRSymbols`), 0 for none.
    public var symbol: UInt32 = 0
    public var modifier: LIRSymbolModifier = .none
    public var segment: UInt8 = 0

    public init(base: LIRReg = .none, index: LIRReg = .none, scale: Int = 1, disp: Int64 = 0, slot: UInt32 = 0,
                symbol: UInt32 = 0, modifier: LIRSymbolModifier = .none, segment: UInt8 = 0) {
        self.base = base
        self.index = index
        self.scale = scale
        self.disp = disp
        self.slot = slot
        self.symbol = symbol
        self.modifier = modifier
        self.segment = segment
    }

    public static func slot(_ s: UInt32, _ disp: Int64 = 0) -> LIRAddress { LIRAddress(disp: disp, slot: s) }
    public static func symbol(_ s: UInt32, _ disp: Int64 = 0) -> LIRAddress { LIRAddress(disp: disp, symbol: s) }

    /// The operand for an access of `size` bytes.
    public func operand(size: Int) -> LIROperand {
        LIROperand(kind: .mem, flags: [], size: size, reg: base, index: index, scale: scale, slot: slot, symbol: symbol,
                   modifier: modifier, segment: segment, value: disp)
    }

    public func adding(_ d: Int64) -> LIRAddress {
        var a = self
        a.disp += d
        return a
    }
}

/// LIR opcodes for x86-64. Most are x86 instructions, named by their AT&T mnemonic without the size suffix (the
/// instruction's `size` gives it); the rest are pseudo-instructions the allocator and frame lowering expand.
@frozen
public enum LIROp: UInt16, Sendable {
    // Pseudo-instructions
    /// A register-to-register copy of the instruction's class (`mov`, or `movaps` for XMM): [def, use].
    case copy = 1
    /// Stands for the function's incoming arguments at entry: implicit defs of the argument registers.
    case entry
    /// Stack adjustment around a call that passes arguments in memory: value = bytes (frame lowering).
    case callFrameSetup, callFrameDestroy
    /// Sets a register to zero without reading it: `xorps` for XMM; `movl $0` for a GPR (flags are kept).
    case zero
    /// A call frame information directive: operands [kind (0 `def_cfa_offset`, 1 `offset`, 2 `def_cfa_register`),
    /// register, offset] as immediates.
    case cfi
    /// A GNU `asm` statement: operand 0 (implicit) is its index in `LIRFunction.asmStatements`; then its operands.
    case inlineAsm

    // Integer
    case mov = 16, movabs, movzb, movzw, movsb, movsw, movslq, lea
    case add, sub, adc, sbb, and, or, xor, cmp, test, imul, imul3, mul, div, idiv, neg, not
    case shl, shr, sar, shld, shrd, rol, ror
    case cltq, cqto, cltd, cwtl, repMovsb, repStosb
    case setcc, cmovcc, bswap, bsr, bsf, popcnt
    case xchg, xadd, cmpxchg, cmpxchg16b, mfence
    case push, pop
    case jmp, jcc, call, ret, ud2, jmpIndirect, callIndirect
    case movsbq, movswq, movzbq, movzwq

    // SSE
    case movss = 96, movsd, movaps, movups, movd, movq, movdqa
    case addss, addsd, subss, subsd, mulss, mulsd, divss, divsd, sqrtss, sqrtsd
    case xorps, andps, andnps, orps, xorpd, andpd
    case ucomiss, ucomisd
    case cvtsi2ss, cvtsi2sd, cvttss2si, cvttsd2si, cvtss2sd, cvtsd2ss
    case pxor

    // x87 (operands are memory operands or `%st(value)` given as an immediate index)
    case fldt = 140, fstpt, flds, fldl, fstps, fstpl, fild, fistp, fisttp, fld, fstp
    case faddp, fsubp, fsubrp, fmulp, fdivp, fdivrp, fchs, fabs, fucomip, fucomi, fxch, fldz, fld1
    case fnstcw, fldcw, fadds, fsubs

    public var isPseudo: Bool { rawValue < 16 }
    public var isTerminator: Bool { self == .jmp || self == .jcc || self == .ret || self == .ud2 || self == .jmpIndirect }

    /// The AT&T mnemonic, with the size suffix added for `size` where AT&T needs one.
    public func mnemonic(size: Int, cond: X86Cond) -> String {
        let s: String
        switch size {
        case 1: s = "b"
        case 2: s = "w"
        case 4: s = "l"
        default: s = "q"
        }
        switch self {
        case .copy, .entry, .callFrameSetup, .callFrameDestroy, .inlineAsm, .zero, .cfi: return "#\(self)"
        case .mov, .lea, .add, .sub, .adc, .sbb, .and, .or, .xor, .cmp, .test, .mul, .div, .idiv, .neg, .not, .shl, .shr, .sar,
             .shld, .shrd, .rol, .ror, .xchg, .xadd, .cmpxchg, .push, .pop:
            return "\(self)" + s
        case .imul, .imul3: return "imul" + s
        case .movabs: return "movabsq"
        case .movzb: return size == 2 ? "movzbw" : "movzbl"
        case .movzw: return "movzwl"
        case .movsb: return size == 2 ? "movsbw" : "movsbl"
        case .movsw: return "movswl"
        case .movslq: return "movslq"
        case .movsbq: return "movsbq"
        case .movswq: return "movswq"
        case .movzbq: return "movzbq"
        case .movzwq: return "movzwq"
        case .cltq: return "cltq"
        case .cqto: return "cqto"
        case .cltd: return "cltd"
        case .cwtl: return "cwtl"
        case .setcc: return "set" + cond.name
        case .cmovcc: return "cmov" + cond.name + s
        case .bswap, .bsr, .bsf, .popcnt: return "\(self)"
        case .cmpxchg16b: return "cmpxchg16b"
        case .repMovsb: return "rep movsb"
        case .repStosb: return "rep stosb"
        case .mfence: return "mfence"
        case .jmp: return "jmp"
        case .jcc: return "j" + cond.name
        case .call: return "callq"
        case .callIndirect: return "callq"
        case .jmpIndirect: return "jmpq"
        case .ret: return "retq"
        case .ud2: return "ud2"
        case .movd: return "movd"
        case .movq: return "movq"
        case .cvtsi2ss, .cvtsi2sd: return "\(self)" + s
        case .fild, .fistp, .fisttp:
            switch size {
            case 2: return "\(self)s"
            case 4: return "\(self)l"
            default: return "\(self)ll"
            }
        default: return "\(self)"
        }
    }
}

/// An LIR instruction: its opcode, the operation size in bytes, a condition code, flags, and its operands
/// (`LIRFunction.operands[firstOperand ..< firstOperand + operandCount]`).
public struct LIRInst: Sendable {
    public var op: LIROp
    public var size: UInt8
    public var cond: X86Cond
    public var lock: Bool
    public var operandCount: UInt16
    public var firstOperand: UInt32

    public init(op: LIROp, size: Int, cond: X86Cond = .o, lock: Bool = false, firstOperand: UInt32, operandCount: Int) {
        self.op = op
        self.size = UInt8(size)
        self.cond = cond
        self.lock = lock
        self.operandCount = UInt16(operandCount)
        self.firstOperand = firstOperand
    }

    public var operandRange: Range<Int> { Int(firstOperand)..<(Int(firstOperand) + Int(operandCount)) }
}

/// A `phi` of LIR: the register it defines and the register each predecessor block supplies.
public struct LIRPhi: Sendable {
    public var def: LIRReg
    public var incoming: [(block: Int, reg: LIRReg)]

    public func value(from block: Int) -> LIRReg? { incoming.first { $0.block == block }?.reg }
}

public struct LIRBlock: Sendable {
    public var insts: [LIRInst] = []
    public var phis: [LIRPhi] = []
    public var successors: [Int] = []
    public var predecessors: [Int] = []
    /// The AIR block it came from (0 for a block made by codegen, such as a split edge).
    public var airBlock: UInt32 = 0
    /// Whether its address is taken (a computed `goto` target, or a jump table entry); its label must be kept.
    public var addressTaken: Bool = false
    public var loopDepth: Int = 0
    /// The jump table (`LIRFunction.jumpTables`) the block's indirect jump goes through, or -1.
    public var jumpTable: Int = -1
}

/// A GNU `asm` statement: its template, and for each operand number the instruction operand it is (or -1 for one
/// with no text, such as a flag output), its size in bytes, and its `[name]`; its `goto` labels (blocks) and their
/// C names; the block holding it.
public struct LIRAsmStatement: Sendable {
    public var template: String
    public var operandIndex: [Int] = []
    public var operandSize: [Int] = []
    public var operandName: [String?] = []
    public var labels: [Int] = []
    public var labelNames: [String?] = []
    public var block = 0
}

/// A stack slot of a frame: an `alloca`, a spill slot, an argument copy, the register save area...
public struct LIRStackSlot: Sendable {
    public var size: Int
    public var alignment: Int
    /// The frame-pointer offset, set by frame lowering (or fixed, for the incoming arguments).
    public var offset: Int = 0
    /// Fixed: an incoming stack argument at `offset` from the frame pointer.
    public var isFixed: Bool = false
}

/// Symbol names an LIR function refers to; a symbol operand holds an index here (from 1).
public final class LIRSymbols: @unchecked Sendable {
    public private(set) var names: [String] = [""]
    private var index: [String: UInt32] = [:]

    public init() {}

    public func intern(_ name: String) -> UInt32 {
        if let i = index[name] { return i }
        names.append(name)
        index[name] = UInt32(names.count - 1)
        return UInt32(names.count - 1)
    }

    public subscript(_ i: UInt32) -> String { names[Int(i)] }
}

/// A function in LIR.
public struct LIRFunction: Sendable {
    public var name: String
    public var blocks: [LIRBlock] = []
    public var operands: [LIROperand] = []
    /// Virtual register classes, indexed by register number (0 unused).
    public var regClass: [LIRRegClass] = [.gpr]
    /// Stack slots; slot 0 is unused.
    public var slots: [LIRStackSlot] = [LIRStackSlot(size: 0, alignment: 1)]
    /// The `asm` statements of the function (an `inlineAsm` instruction's first operand is its index here).
    public var asmStatements: [LIRAsmStatement] = []
    /// Jump tables: the blocks of each, by index (a symbol `.LJTI<function>_<k>` names table k).
    public var jumpTables: [[Int]] = []
    /// Read-only constants the function uses: label, bytes and alignment.
    public var constants: [(label: UInt32, bytes: [UInt8], alignment: Int)] = []
    /// The function calls another (the frame must keep the stack aligned for calls) or has dynamic allocations.
    public var hasCalls = false
    public var hasDynamicAlloca = false
    /// A variadic function: the register save area slot (176 bytes), 0 if none.
    public var registerSaveArea: UInt32 = 0
    /// Bytes of outgoing stack arguments the largest call needs.
    public var maxOutgoingArgs = 0
    /// Callee-saved registers the allocator used.
    public var usedCalleeSaved: [PhysReg] = []
    /// Bytes below the frame pointer (callee-saved registers and slots), set by frame lowering.
    public var frameSize = 0
    /// The LIR block of each AIR block (for `&&label` in static data).
    public var airBlockMap: [Int] = []

    public init(name: String) { self.name = name }

    public var vregCount: Int { regClass.count }

    public mutating func newVReg(_ c: LIRRegClass) -> LIRReg {
        regClass.append(c)
        return .virtual(UInt32(regClass.count - 1))
    }

    public mutating func newSlot(size: Int, alignment: Int) -> UInt32 {
        slots.append(LIRStackSlot(size: max(size, 1), alignment: max(alignment, 1)))
        return UInt32(slots.count - 1)
    }

    public func operands(of inst: LIRInst) -> ArraySlice<LIROperand> { operands[inst.operandRange] }

    /// The class of a register: a virtual register's, or a physical register's.
    public func regClass(of r: LIRReg) -> LIRRegClass {
        if r.isPhysical { return r.physical.isXMM ? .xmm : .gpr }
        return regClass[r.virtualIndex]
    }

    public mutating func append(_ block: Int, _ op: LIROp, size: Int, cond: X86Cond = .o, lock: Bool = false, _ ops: [LIROperand]) {
        let first = UInt32(operands.count)
        operands.append(contentsOf: ops)
        blocks[block].insts.append(LIRInst(op: op, size: size, cond: cond, lock: lock, firstOperand: first, operandCount: ops.count))
    }

    /// Builds the predecessor lists from the successor lists.
    public mutating func computePredecessors() {
        for b in blocks.indices { blocks[b].predecessors = [] }
        for b in blocks.indices {
            for s in blocks[b].successors where !blocks[s].predecessors.contains(b) { blocks[s].predecessors.append(b) }
        }
    }
}

extension LIRFunction {
    /// A textual form for tests and `--dump=lir`.
    public func dumpText(symbols: LIRSymbols) -> String {
        var out = "function \(name)\n"
        for (b, block) in blocks.enumerated() {
            out += ".b\(b):"
            if !block.predecessors.isEmpty { out += " ; preds " + block.predecessors.map { "b\($0)" }.joined(separator: ", ") }
            out += "\n"
            for phi in block.phis {
                out += "  \(phi.def) = phi " + phi.incoming.map { "[b\($0.block): \($0.reg)]" }.joined(separator: ", ") + "\n"
            }
            for inst in block.insts {
                out += "  " + describe(inst, symbols: symbols) + "\n"
            }
        }
        return out
    }

    public func describe(_ inst: LIRInst, symbols: LIRSymbols) -> String {
        var text = (inst.lock ? "lock " : "") + inst.op.mnemonic(size: Int(inst.size), cond: inst.cond)
        let ops = operands(of: inst).map { describe($0, symbols: symbols) }
        if !ops.isEmpty { text += " " + ops.joined(separator: ", ") }
        return text
    }

    func describe(_ o: LIROperand, symbols: LIRSymbols) -> String {
        var prefix = ""
        if o.isDef { prefix += o.isUse ? "=+" : "=" }
        if o.isImplicit { prefix += "imp:" }
        switch o.kind {
        case .none: return "_"
        case .reg:
            if o.reg.isPhysical { return prefix + "%" + o.reg.physical.name(size: Int(o.size)) }
            return prefix + "\(o.reg)/\(o.size)"
        case .imm:
            return o.symbol != 0 ? "$\(symbols[o.symbol])\(o.modifier.suffix)+\(o.value)" : "$\(o.value)"
        case .mem:
            var parts: [String] = []
            if o.segment != 0 { parts.append(o.segment == 4 ? "%fs:" : "%gs:") }
            if o.symbol != 0 { parts.append(symbols[o.symbol] + o.modifier.suffix) }
            if o.slot != 0 { parts.append("s\(o.slot)") }
            if !o.reg.isNone { parts.append("\(o.reg)") }
            if !o.index.isNone { parts.append("\(o.index)*\(o.scale)") }
            if o.value != 0 || parts.isEmpty { parts.append("\(o.value)") }
            return "[" + parts.joined(separator: " + ") + "]/\(o.size)"
        case .block: return "b\(o.value)"
        case .symbol: return symbols[o.symbol] + o.modifier.suffix
        }
    }
}
