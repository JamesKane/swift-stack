import Foundation
import Testing
@testable import SwiftStack

// Exhaustive AArch64 encoder/disassembler sweep (09-roadmap.md §M2 exit criterion: "encoder/disassembler
// round-trip is exhaustive over the instruction tables"; 05-assembler.md §4.11).
//
// For every descriptor in `A64InstructionTable.entries`, every operand form it supports is generated:
// every register width / scalar width / vector arrangement the descriptor accepts, every register slot
// swept over all 32 encodings (so SP vs ZR is exercised wherever register 31 is legal), every addressing
// mode and extend/shift, all conditions, and boundary immediates (all bitmask immediates, all bitfield
// `immr:imms` pairs, all FP8 immediates, all hint numbers). Each instruction is then
//
//   1. encoded, decoded, and re-encoded: the words must be identical and decode to the same descriptor;
//   2. assembled by llvm-mc from our disassembly text: the bytes must be exactly ours;
//   3. disassembled by llvm-mc: its text must equal ours (Swift-Stack prints the preferred aliases LLVM
//      prints: `mov`, `cmp`, `lsl`, `stadd`, `cset`, ...);
//   4. assembled by our own assembler from our disassembly text: the bytes must be exactly ours.
//
// Forms LLVM rejects as unpredictable (writeback base equal to a transfer register, `ldp` with Rt == Rt2,
// an exclusive store whose status register is also a source) are not generated. Every descriptor must
// produce at least one instruction, so a new table entry cannot escape the sweep.
//
// A second test checks rejection: representative invalid operand forms of every descriptor (`A64Mutation`:
// wrong arrangement or element width, out-of-range immediate or lane, wrong register width or class) must be
// rejected by our assembler exactly when llvm-mc rejects them, and every descriptor must have some that both
// reject. All lines of each pass go to llvm-mc in one invocation (`LLVMMC`), which keeps the run bounded.

enum A64Sweep {
    typealias GPRSlot = WritableKeyPath<A64Instruction, A64GPR>
    typealias VSlot = WritableKeyPath<A64Instruction, A64VReg>

    /// The generated base forms of one descriptor and the register slots swept over each distinct shape.
    struct Forms {
        var bases: [A64Instruction] = []
        var gprSlots: [GPRSlot] = []
        var vSlots: [VSlot] = []
    }

    static let allConds = A64Cond.allCases

    /// A base instruction with distinct default registers (no slot aliases another).
    static func base(_ desc: A64InstrDesc, _ configure: (inout A64Instruction) -> Void = { _ in }) -> A64Instruction {
        var inst = A64Instruction(opcode: desc.id, rd: A64GPR(rawValue: 1), rn: A64GPR(rawValue: 2), rm: A64GPR(rawValue: 3),
                                  ra: A64GPR(rawValue: 4), vd: A64VReg(rawValue: 5), vn: A64VReg(rawValue: 6),
                                  vm: A64VReg(rawValue: 7), va: A64VReg(rawValue: 8))
        configure(&inst)
        return inst
    }

    static func widths(_ desc: A64InstrDesc) -> [A64ScalarWidth] {
        [A64ScalarWidth.b, .h, .s, .d, .q].filter { desc.allows($0) }
    }

    static func arrangements(_ desc: A64InstrDesc) -> [A64Arrangement] {
        A64Arrangement.allCases.filter { desc.allows($0) }
    }

    /// Register widths of a GPR load/store or exclusive: both when bit 30 (`size<0>`) is a variable field,
    /// otherwise the one the fixed opcode implies (sign-extending loads with `opc<0>` = 0 target X).
    static func gprWidths(_ desc: A64InstrDesc) -> [Bool] {
        if desc.scaleLog2 == 255 || desc.opcodeMask & (1 << 30) == 0 { return [false, true] }
        if desc.id == .ldrswLit { return [true] }
        // Fixed-size exclusives and acquire/release forms (`ldarb`, `ldaprh`, ...) always use W registers.
        if [.atomicLoad, .atomicStore, .atomicStoreExcl].contains(desc.format) { return [false] }
        return [(desc.opcodeBits >> 23) & 1 != 0 && (desc.opcodeBits >> 22) & 1 == 0]
    }

    /// Byte scale of a GPR load/store's offset or index shift.
    static func gprScale(_ desc: A64InstrDesc, is64: Bool) -> Int64 {
        desc.scaleLog2 == 255 ? (is64 ? 8 : 4) : Int64(1) << Int64(desc.scaleLog2)
    }

    /// Every value `and`/`orr`/`eor`/`ands` (immediate) can encode at the given width.
    static func bitmaskImmediates(is64: Bool) -> [UInt64] {
        var values = Set<UInt64>()
        for n: UInt32 in is64 ? [0, 1] : [0] {
            for immr: UInt32 in 0..<64 {
                for imms: UInt32 in 0..<64 {
                    if let v = A64BitmaskImmediate.decode(n: n, immr: immr, imms: imms, is64Bit: is64) { values.insert(v) }
                }
            }
        }
        return values.sorted()
    }
    static let bitmask64 = bitmaskImmediates(is64: true)
    static let bitmask32 = bitmaskImmediates(is64: false)

    /// System registers LLVM only allows on one side of `mrs`/`msr`.
    static let readOnlySysRegs: Set<String> = [
        "currentel", "midr_el1", "mpidr_el1", "ctr_el0", "cntvct_el0", "pmceid0_el0", "icc_iar1_el1", "rndr",
        "id_aa64pfr0_el1", "id_aa64pfr1_el1", "id_aa64zfr0_el1", "id_aa64smfr0_el1", "id_aa64dfr0_el1",
        "id_aa64mmfr0_el1", "id_aa64mmfr1_el1", "id_aa64mmfr2_el1", "id_aa64mmfr3_el1",
        "id_aa64isar0_el1", "id_aa64isar1_el1", "id_aa64isar2_el1",
    ]
    static let writeOnlySysRegs: Set<String> = ["oslar_el1", "icc_eoir1_el1", "icc_sgi1r_el1"]
    /// Encodings outside the named table (IMPLEMENTATION DEFINED space), printed in generic `s3_...` form.
    static let genericSysRegs: [A64SysReg] = [
        A64SysReg(op0: 3, op1: 0, crn: 15, crm: 0, op2: 0), A64SysReg(op0: 3, op1: 7, crn: 15, crm: 15, op2: 7),
        A64SysReg(op0: 3, op1: 1, crn: 11, crm: 2, op2: 5), A64SysReg(op0: 2, op1: 7, crn: 15, crm: 15, op2: 7),
    ]

    static func forms(_ desc: A64InstrDesc) -> Forms {
        var f = Forms()
        let g = desc
        func add(_ configure: (inout A64Instruction) -> Void) { f.bases.append(base(g, configure)) }

        switch desc.format {
        case .addSubImm:
            f.gprSlots = [\.rd, \.rn]
            for is64 in [false, true] { for imm: Int64 in [0, 1, 0x800, 0xFFF] { for sh: UInt8 in [0, 12] {
                add { $0.is64Bit = is64; $0.imm = imm; $0.amount = sh }
            } } }

        case .movWide:
            f.gprSlots = [\.rd]
            for is64 in [false, true] {
                for sh: UInt8 in is64 ? [0, 16, 32, 48] : [0, 16] { for imm: Int64 in [0, 1, 0x1234, 0x8000, 0xFFFF] {
                    add { $0.is64Bit = is64; $0.imm = imm; $0.amount = sh }
                } }
            }

        case .pcRel:
            f.gprSlots = [\.rd]
            let disps: [Int64] = [0, 1, -1, 4, -4, (1 << 20) - 1, -(1 << 20)]
            for d in disps { add { $0.imm = desc.id == .adrp ? d << 12 : d } }

        case .logicalImm:
            f.gprSlots = [\.rd, \.rn]
            for v in bitmask32 { add { $0.is64Bit = false; $0.imm = Int64(v) } }
            for v in bitmask64 { add { $0.is64Bit = true; $0.imm = Int64(bitPattern: v) } }

        case .bitfield:
            f.gprSlots = [\.rd, \.rn]
            for is64 in [false, true] {
                let w: Int64 = is64 ? 64 : 32
                for immr in 0..<w { for imms in 0..<w { add { $0.is64Bit = is64; $0.imm = immr; $0.imm2 = UInt8(imms) } } }
            }

        case .extract:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for is64 in [false, true] {
                for lsb in 0..<UInt8(is64 ? 64 : 32) {
                    add { $0.is64Bit = is64; $0.amount = lsb }
                    add { $0.is64Bit = is64; $0.amount = lsb; $0.rm = $0.rn }  // `ror` alias
                }
            }

        case .addSubShifted, .logicalShifted:
            f.gprSlots = [\.rd, \.rn, \.rm]
            let kinds: [A64ShiftKind] = desc.format == .logicalShifted ? [.lsl, .lsr, .asr, .ror] : [.lsl, .lsr, .asr]
            for is64 in [false, true] { for k in kinds { for amt: UInt8 in [0, 1, is64 ? 63 : 31] {
                add { $0.is64Bit = is64; $0.shiftKind = k; $0.amount = amt }
            } } }

        case .addSubExtended:
            f.gprSlots = [\.rd, \.rn, \.rm]
            let exts: [A64ExtendKind] = [.uxtb, .uxth, .uxtw, .uxtx, .sxtb, .sxth, .sxtw, .sxtx]
            for is64 in [false, true] { for e in exts { for amt: UInt8 in 0...4 {
                add { $0.is64Bit = is64; $0.extendKind = e; $0.amount = amt }
            } } }

        case .dp2Source, .dp3Source, .addSubCarry:
            f.gprSlots = desc.format == .dp3Source ? [\.rd, \.rn, \.rm, \.ra] : [\.rd, \.rn, \.rm]
            for is64 in [false, true] { add { $0.is64Bit = is64 } }

        case .dp3Long:
            f.gprSlots = [\.rd, \.rn, \.rm, \.ra]
            add { $0.is64Bit = true }

        case .crc32:
            f.gprSlots = [\.rd, \.rn, \.rm]
            add { _ in }

        case .dp1Source:
            f.gprSlots = [\.rd, \.rn]
            for is64 in desc.id == .rev32 ? [true] : [false, true] { add { $0.is64Bit = is64 } }

        case .mulHigh:
            f.gprSlots = [\.rd, \.rn, \.rm]
            add { $0.is64Bit = true }

        case .condSelect:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for is64 in [false, true] { for c in allConds { add { $0.is64Bit = is64; $0.cond = c } } }

        case .condCompareReg, .condCompareImm:
            f.gprSlots = desc.format == .condCompareReg ? [\.rn, \.rm] : [\.rn]
            for is64 in [false, true] { for c in allConds { for nzcv: UInt8 in [0, 5, 15] { for imm: Int64 in [0, 31] {
                if desc.format == .condCompareReg && imm != 0 { continue }
                add { $0.is64Bit = is64; $0.cond = c; $0.imm2 = nzcv; $0.imm = imm }
            } } } }

        case .branchImm26:
            for d: Int64 in [0, 4, -4, (1 << 27) - 4, -(1 << 27)] { add { $0.imm = d } }

        case .branchCond19:
            for c in allConds { for d: Int64 in [0, 4, -4, (1 << 20) - 4, -(1 << 20)] { add { $0.cond = c; $0.imm = d } } }

        case .compareBranch19:
            f.gprSlots = [\.rd]
            for is64 in [false, true] { for d: Int64 in [0, 4, -4, (1 << 20) - 4, -(1 << 20)] { add { $0.is64Bit = is64; $0.imm = d } } }

        case .testBranch14:
            f.gprSlots = [\.rd]
            for bit: UInt8 in 0..<64 { add { $0.is64Bit = bit >= 32; $0.amount = bit; $0.imm = 8 } }
            for bit: UInt8 in [0, 63] { for d: Int64 in [0, -4, (1 << 15) - 4, -(1 << 15)] {
                add { $0.is64Bit = bit >= 32; $0.amount = bit; $0.imm = d }
            } }

        case .branchReg:
            f.gprSlots = [\.rn]
            add { _ in }

        case .exceptionImm16, .udfImm16:
            for imm: Int64 in [0, 1, 0x1234, 0x8000, 0xFFFF] { add { $0.imm = imm } }

        case .fixedSystem:
            add { _ in }

        case .hintImm7:
            // `hint #0`-`#5` are `nop`, `yield`, `wfe`, `wfi`, `sev`, `sevl`, which have descriptors of their own.
            for imm: Int64 in 6...127 { add { $0.imm = imm } }

        case .barrier:
            for crm: UInt8 in 0...15 { add { $0.barrierOption = A64BarrierOption(rawValue: crm) } }

        case .mrs, .msrReg:
            f.gprSlots = [\.rd]
            let excluded = desc.format == .mrs ? writeOnlySysRegs : readOnlySysRegs
            for (name, reg) in A64SysReg.namedTable where !excluded.contains(name) { add { $0.sysReg = reg } }
            for reg in genericSysRegs { add { $0.sysReg = reg } }

        case .msrPState:
            for field: A64PStateField in [.spsel, .daifset, .daifclr, .pan] {
                let maxImm: Int64 = field == .pan ? 1 : 15
                for imm in 0...maxImm { add { $0.pstateField = field; $0.imm = imm } }
            }

        case .sysMaint:
            f.gprSlots = [\.rd]
            for op in A64SysMaintOp.allCases { add { $0.sysMaintOp = op; if !op.takesRegister { $0.rd = .xzr } } }

        case .ldstUnsignedImm12:
            if let sw = desc.scalarWidth {
                f.gprSlots = [\.rn]
                f.vSlots = [\.vd]
                let s = Int64(1) << Int64(desc.scaleLog2)
                for k: Int64 in [0, 1, 2048, 4095] { add { $0.scalarWidth = sw; $0.imm = k * s } }
            } else {
                f.gprSlots = [\.rd, \.rn]
                for is64 in gprWidths(desc) {
                    let s = gprScale(desc, is64: is64)
                    for k: Int64 in [0, 1, 2048, 4095] { add { $0.is64Bit = is64; $0.imm = k * s } }
                }
            }

        case .ldstPreImm9, .ldstPostImm9, .ldstUnscaledImm9, .ldstUnprivImm9:
            f.gprSlots = [\.rd, \.rn]
            for is64 in gprWidths(desc) { for imm: Int64 in [-256, -1, 0, 1, 255] { add { $0.is64Bit = is64; $0.imm = imm } } }

        case .ldstRegOffset:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for is64 in gprWidths(desc) {
                let natural = UInt8(gprScale(desc, is64: is64).trailingZeroBitCount)
                for e: A64ExtendKind in [.uxtw, .uxtx, .sxtw, .sxtx] {
                    add { $0.is64Bit = is64; $0.extendKind = e }
                    add { $0.is64Bit = is64; $0.extendKind = e; $0.amount = natural; $0.imm2 = natural == 0 ? 1 : 0 }
                }
            }

        case .ldrLiteral:
            f.gprSlots = [\.rd]
            for is64 in gprWidths(desc) { for d: Int64 in [0, 4, -4, (1 << 20) - 4, -(1 << 20)] { add { $0.is64Bit = is64; $0.imm = d } } }

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for is64 in [false, true] {
                let s: Int64 = is64 ? 8 : 4
                for k: Int64 in [-64, -1, 0, 1, 63] { add { $0.is64Bit = is64; $0.imm = k * s } }
            }

        case .atomicLoad, .atomicStore:
            f.gprSlots = [\.rd, \.rn]
            for is64 in gprWidths(desc) { add { $0.is64Bit = is64 } }

        case .atomicStoreExcl:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for is64 in gprWidths(desc) { add { $0.is64Bit = is64 } }

        case .atomicLoadPair:
            f.gprSlots = [\.rd, \.rn, \.ra]
            for is64 in gprWidths(desc) { add { $0.is64Bit = is64 } }

        case .atomicStoreExclPair:
            f.gprSlots = [\.rd, \.rn, \.rm, \.ra]
            for is64 in gprWidths(desc) { add { $0.is64Bit = is64 } }

        case .lseAtomic, .lseCas:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for w in widths(desc) { for acq in [false, true] { for rel in [false, true] {
                add { $0.is64Bit = w == .d; $0.scalarWidth = w; $0.acquire = acq; $0.release = rel }
            } } }

        case .lseCasp:
            f.gprSlots = [\.rd, \.rn, \.rm]
            for w in widths(desc) { for acq in [false, true] { for rel in [false, true] {
                add { $0.is64Bit = w == .d; $0.scalarWidth = w; $0.acquire = acq; $0.release = rel; $0.rm = A64GPR(rawValue: 2); $0.rd = A64GPR(rawValue: 4); $0.rn = A64GPR(rawValue: 1) }
            } } }

        case .fpLdstPreImm9, .fpLdstPostImm9, .fpLdstUnscaledImm9:
            f.gprSlots = [\.rn]
            f.vSlots = [\.vd]
            for w in widths(desc) { for imm: Int64 in [-256, -1, 0, 1, 255] { add { $0.scalarWidth = w; $0.imm = imm } } }

        case .fpLdstRegOffset:
            f.gprSlots = [\.rn, \.rm]
            f.vSlots = [\.vd]
            for w in widths(desc) { for e: A64ExtendKind in [.uxtw, .uxtx, .sxtw, .sxtx] {
                add { $0.scalarWidth = w; $0.extendKind = e }
                add { $0.scalarWidth = w; $0.extendKind = e; $0.amount = w.rawValue; $0.imm2 = w == .b ? 1 : 0 }
            } }

        case .fpLdrLiteral:
            f.vSlots = [\.vd]
            for w in widths(desc) { for d: Int64 in [0, 4, -4, (1 << 20) - 4, -(1 << 20)] { add { $0.scalarWidth = w; $0.imm = d } } }

        case .fpLdpStpSigned, .fpLdpStpPre, .fpLdpStpPost:
            f.gprSlots = [\.rn]
            f.vSlots = [\.vd, \.vn]
            for w in widths(desc) {
                let s = Int64(w.byteCount)
                for k: Int64 in [-64, -1, 0, 1, 63] { add { $0.scalarWidth = w; $0.imm = k * s } }
            }

        case .fpMovGprToFp, .fpMovFpToGpr:
            f.gprSlots = desc.format == .fpMovGprToFp ? [\.rn] : [\.rd]
            f.vSlots = desc.format == .fpMovGprToFp ? [\.vd] : [\.vn]
            for (w, is64) in [(A64ScalarWidth.h, false), (.h, true), (.s, false), (.d, true)] { add { $0.scalarWidth = w; $0.is64Bit = is64 } }

        case .fpDp1, .fpBinary, .fpDp3, .fpCmpReg, .fpCmpZero:
            let slots: [A64InstrFormat: [VSlot]] = [.fpDp1: [\.vd, \.vn], .fpBinary: [\.vd, \.vn, \.vm], .fpDp3: [\.vd, \.vn, \.vm, \.va],
                                                    .fpCmpReg: [\.vn, \.vm], .fpCmpZero: [\.vn]]
            f.vSlots = slots[desc.format]!
            for w in widths(desc) { add { $0.scalarWidth = w } }

        case .fpCvtPrecision:
            f.vSlots = [\.vd, \.vn]
            for dst in widths(desc) { for src in widths(desc) where src != dst { add { $0.scalarWidth = dst; $0.scalarWidth2 = src } } }

        case .fpIntToFp, .fpToInt:
            f.gprSlots = desc.format == .fpIntToFp ? [\.rn] : [\.rd]
            f.vSlots = desc.format == .fpIntToFp ? [\.vd] : [\.vn]
            for w in widths(desc) { for is64 in [false, true] { add { $0.scalarWidth = w; $0.is64Bit = is64 } } }

        case .fpFixedToFp, .fpToFixed:
            f.gprSlots = desc.format == .fpFixedToFp ? [\.rn] : [\.rd]
            f.vSlots = desc.format == .fpFixedToFp ? [\.vd] : [\.vn]
            for w in widths(desc) { for is64 in [false, true] { for fbits: Int64 in [1, 16, is64 ? 64 : 32] {
                add { $0.scalarWidth = w; $0.is64Bit = is64; $0.imm = fbits }
            } } }

        case .fpCondCompare:
            f.vSlots = [\.vn, \.vm]
            for w in widths(desc) { for c in allConds { for nzcv: UInt8 in [0, 15] { add { $0.scalarWidth = w; $0.cond = c; $0.imm2 = nzcv } } } }

        case .fpCondSelect:
            f.vSlots = [\.vd, \.vn, \.vm]
            for w in widths(desc) { for c in allConds { add { $0.scalarWidth = w; $0.cond = c } } }

        case .fpImm:
            f.vSlots = [\.vd]
            for w in widths(desc) { for imm8: Int64 in 0...255 { add { $0.scalarWidth = w; $0.imm = imm8 } } }

        case .simdThreeSameInt, .simdThreeSameBit, .simdThreeSameFp, .simdPermute:
            f.vSlots = [\.vd, \.vn, \.vm]
            for a in arrangements(desc) { add { $0.arrangement = a } }

        case .simdThreeLong, .simdThreeWide, .simdThreeNarrow, .simdDot:
            f.vSlots = [\.vd, \.vn, \.vm]
            for a in arrangements(desc) { add { $0.arrangement = a } }

        case .simdTwoRegMisc, .simdTwoRegMiscFp, .simdCmpZero, .simdAcrossLanes, .simdNarrow, .simdLongPairwise,
             .simdFpCmpZero, .simdFpNarrow, .simdFpLong, .simdScalarPairwise, .simdAcrossLanesLong, .simdAcrossLanesFp:
            f.vSlots = [\.vd, \.vn]
            for a in arrangements(desc) { add { $0.arrangement = a } }

        case .simdScalarTwoRegMiscFp, .simdScalarFpCmpZero, .simdScalarThreeSameFp:
            f.vSlots = desc.format == .simdScalarThreeSameFp ? [\.vd, \.vn, \.vm] : [\.vd, \.vn]
            for w in widths(desc) { add { $0.scalarWidth = w } }

        case .simdElem, .simdElemLong, .simdDotElem:
            // Every lane of every arrangement; `vm` is swept too (h elements take v0-v15 only).
            f.vSlots = [\.vd, \.vn, \.vm]
            for a in arrangements(desc) {
                let lanes = desc.format == .simdDotElem ? 4 : UInt8(16 >> a.elementWidth.rawValue)
                for idx in 0..<lanes { add { $0.arrangement = a; $0.index = idx } }
            }

        case .simdScalarElem:
            f.vSlots = [\.vd, \.vn, \.vm]
            for w in widths(desc) { for idx in 0..<UInt8(16 >> w.rawValue) { add { $0.scalarWidth = w; $0.index = idx } } }

        case .cryptoAes, .cryptoSha2:
            f.vSlots = [\.vd, \.vn]
            add { _ in }

        case .cryptoSha3:
            f.vSlots = [\.vd, \.vn, \.vm]
            add { _ in }

        case .simdShiftImm, .simdShiftLong, .simdShiftNarrow:
            f.vSlots = [\.vd, \.vn]
            for a in arrangements(desc) {
                let esize = UInt8(8 << a.elementWidth.rawValue)
                let leftShift = [.simdShl, .simdSli, .simdSshll, .simdUshll, .simdSqshlImm, .simdUqshlImm, .simdSqshlu].contains(desc.id)
                for amt in leftShift ? [0, 1, esize - 1] : [1, esize / 2, esize] { add { $0.arrangement = a; $0.amount = amt } }
            }

        case .simdDupElem:
            f.vSlots = [\.vd, \.vn]
            for a in arrangements(desc) { for idx in 0..<UInt8(16 >> a.elementWidth.rawValue) { add { $0.arrangement = a; $0.index = idx } } }

        case .simdDupGpr:
            f.gprSlots = [\.rn]
            f.vSlots = [\.vd]
            for a in arrangements(desc) { add { $0.arrangement = a } }

        case .simdDupScalar, .simdInsGpr:
            f.gprSlots = desc.format == .simdInsGpr ? [\.rn] : []
            f.vSlots = desc.format == .simdInsGpr ? [\.vd] : [\.vd, \.vn]
            for w in widths(desc) { for idx in 0..<UInt8(16 >> w.rawValue) { add { $0.scalarWidth = w; $0.index = idx } } }

        case .simdInsElem:
            f.vSlots = [\.vd, \.vn]
            for w in widths(desc) {
                let lanes = UInt8(16 >> w.rawValue)
                for idx in 0..<lanes { for idx2 in 0..<lanes { add { $0.scalarWidth = w; $0.index = idx; $0.imm2 = idx2 } } }
            }

        case .simdUmovSmov:
            f.gprSlots = [\.rd]
            f.vSlots = [\.vn]
            let shapes: [(A64ScalarWidth, Bool)] = desc.id == .simdUmov
                ? [(.b, false), (.h, false), (.s, false), (.d, true)]
                : [(.b, false), (.b, true), (.h, false), (.h, true), (.s, true)]
            for (w, is64) in shapes { for idx in 0..<UInt8(16 >> w.rawValue) { add { $0.scalarWidth = w; $0.is64Bit = is64; $0.index = idx } } }

        case .simdModImm:
            f.vSlots = [\.vd]
            for a in arrangements(desc) {
                switch (desc.id, a.elementWidth) {
                case (.simdFmovImm, _):
                    for imm8: Int64 in 0...255 { add { $0.arrangement = a; $0.imm = imm8 } }
                case (.simdMovi, .d):
                    for imm8 in 0...255 { add { $0.arrangement = a; $0.imm = Int64(bitPattern: A64SIMDByteMask.decode(UInt8(imm8))) } }
                case (.simdMovi, .b):
                    for imm8: Int64 in 0...255 { add { $0.arrangement = a; $0.imm = imm8 } }
                case (_, .h):
                    for amt: UInt8 in [0, 8] { for imm: Int64 in [0, 1, 0xAB, 0xFF] { add { $0.arrangement = a; $0.imm = imm; $0.amount = amt } } }
                default:
                    for amt: UInt8 in [0, 8, 16, 24] { for imm: Int64 in [0, 1, 0xAB, 0xFF] { add { $0.arrangement = a; $0.imm = imm; $0.amount = amt } } }
                    if desc.id == .simdMovi || desc.id == .simdMvni {
                        for amt: UInt8 in [8, 16] { for imm: Int64 in [0, 0xAB, 0xFF] { add { $0.arrangement = a; $0.imm = imm; $0.shiftKind = .msl; $0.amount = amt } } }
                    }
                }
            }

        case .simdLdStMulti, .simdLdStMultiPost:
            let isPost = desc.format == .simdLdStMultiPost
            f.gprSlots = isPost ? [\.rn, \.rm] : [\.rn]
            f.vSlots = [\.vd]
            let counts: [UInt8]
            switch desc.id {
            case .simdLd1, .simdSt1, .simdLd1Post, .simdSt1Post: counts = [1, 2, 3, 4]
            case .simdLd2, .simdSt2, .simdLd2Post, .simdSt2Post: counts = [2]
            case .simdLd3, .simdSt3, .simdLd3Post, .simdSt3Post: counts = [3]
            default: counts = [4]
            }
            for a in arrangements(desc) { for n in counts {
                // Post-index: `rm` = 31 is the immediate form, whose only legal value is the bytes transferred.
                add { $0.arrangement = a; $0.imm2 = n; $0.rm = .xzr; $0.imm = isPost ? Int64(n) * Int64(a.qBit == 1 ? 16 : 8) : 0 }
            } }

        case .simdLd1R, .simdLd1RPost:
            let isPost = desc.format == .simdLd1RPost
            f.gprSlots = isPost ? [\.rn, \.rm] : [\.rn]
            f.vSlots = [\.vd]
            let count = Int64(A64Encoder.structureCount(desc.id))
            for a in arrangements(desc) { add { $0.arrangement = a; $0.rm = .xzr; $0.imm = isPost ? count * Int64(a.elementWidth.byteCount) : 0 } }

        case .simdLdStLane, .simdLdStLanePost:
            let isPost = desc.format == .simdLdStLanePost
            f.gprSlots = isPost ? [\.rn, \.rm] : [\.rn]
            f.vSlots = [\.vd]
            let count = Int64(A64Encoder.structureCount(desc.id))
            for w in widths(desc) { for idx in 0..<UInt8(16 >> w.rawValue) {
                add { $0.scalarWidth = w; $0.index = idx; $0.rm = .xzr; $0.imm = isPost ? count * Int64(w.byteCount) : 0 }
            } }

        case .simdTbl:
            f.vSlots = [\.vd, \.vn, \.vm]
            for a in arrangements(desc) { for n: UInt8 in 1...4 { add { $0.arrangement = a; $0.imm2 = n } } }

        case .simdExt:
            f.vSlots = [\.vd, \.vn, \.vm]
            for a in arrangements(desc) { for idx in 0..<UInt8(a.qBit == 1 ? 16 : 8) { add { $0.arrangement = a; $0.amount = idx } } }

        case .sveLdrStrZ, .sveLdrStrP:
            f.gprSlots = [\.rn]
            for imm: Int64 in [-256, -1, 0, 1, 255] { add { $0.imm = imm } }
            for r in 0..<UInt8(desc.format == .sveLdrStrZ ? 32 : 16) {
                add { $0.imm = 3; $0.zd = A64ZReg(rawValue: r); $0.pd = A64PReg(rawValue: r) }
            }

        case .sveAddVlPl:
            f.gprSlots = [\.rd, \.rn]
            for imm: Int64 in [-32, -1, 0, 1, 31] { add { $0.imm = imm } }

        case .sveRdffr, .sveWrffr:
            for r in 0..<UInt8(16) { add { $0.pd = A64PReg(rawValue: r) } }
        }
        return f
    }

    /// False for forms LLVM rejects as unpredictable and register combinations the encoding forbids.
    static func isLegal(_ i: A64Instruction, _ desc: A64InstrDesc) -> Bool {
        let rd = i.rd.rawValue, rn = i.rn.rawValue, rm = i.rm.rawValue, ra = i.ra.rawValue
        let isLoad = desc.mnemonic.hasPrefix("ld")
        switch desc.format {
        case .ldpStpSigned:
            return !(isLoad && rd == rm)
        case .ldpStpPre, .ldpStpPost:
            return !(isLoad && rd == rm) && (rn == 31 || (rd != rn && rm != rn))
        case .ldstPreImm9, .ldstPostImm9:
            return rn == 31 || rd != rn
        case .fpLdpStpSigned, .fpLdpStpPre, .fpLdpStpPost:
            return !(isLoad && i.vd == i.vn)
        case .atomicStoreExcl:
            return rm != rd && (rn == 31 || rm != rn)
        case .atomicStoreExclPair:
            return rm != rd && rm != ra && (rn == 31 || rm != rn)
        case .atomicLoadPair:
            return rd != ra
        case .lseCasp:
            return rd & 1 == 0 && rm & 1 == 0
        case .simdElem, .simdElemLong:
            // A by-element operand with `h` elements is in v0-v15 (the `M` bit is part of the lane).
            return i.arrangement.elementWidth != .h || i.vm.rawValue < 16
        case .simdScalarElem:
            return i.scalarWidth != .h || i.vm.rawValue < 16
        default:
            return true
        }
    }

    /// Every generated instruction for `desc`: its base forms, plus each register slot swept over all 32
    /// encodings for every distinct shape (register width, element width, arrangement, ordering, ...).
    /// The operand shape of a base form: what selects a different encoding of the same descriptor.
    struct Shape: Hashable {
        let is64: Bool, w: A64ScalarWidth, w2: A64ScalarWidth, arr: A64Arrangement, ext: A64ExtendKind
        let imm2: UInt8, acq: Bool, rel: Bool, sysMaint: A64SysMaintOp

        init(_ b: A64Instruction, _ desc: A64InstrDesc) {
            (is64, w, w2, arr, ext) = (b.is64Bit, b.scalarWidth, b.scalarWidth2, b.arrangement, b.extendKind)
            imm2 = desc.format == .simdLdStMulti || desc.format == .simdLdStMultiPost || desc.format == .simdTbl ? b.imm2 : 0
            (acq, rel, sysMaint) = (b.acquire, b.release, b.sysMaintOp)
        }
    }

    /// Up to `limit` legal base forms of `desc` with distinct shapes, spread over its shapes.
    static func representatives(_ desc: A64InstrDesc, limit: Int = 4) -> [A64Instruction] {
        var seenShapes = Set<Shape>()
        let distinct = forms(desc).bases.filter { isLegal($0, desc) && seenShapes.insert(Shape($0, desc)).inserted }
        guard distinct.count > limit else { return distinct }
        return (0..<limit).map { distinct[$0 * (distinct.count - 1) / (limit - 1)] }
    }

    static func cases(_ desc: A64InstrDesc) -> [A64Instruction] {
        let f = forms(desc)
        var seenShapes = Set<Shape>()
        var seen = Set<A64Instruction>()
        var out: [A64Instruction] = []
        func emit(_ i: A64Instruction) {
            if isLegal(i, desc) && seen.insert(i).inserted { out.append(i) }
        }
        for b in f.bases {
            emit(b)
            guard seenShapes.insert(Shape(b, desc)).inserted else { continue }
            for slot in f.gprSlots {
                // `sysMaint` operations without a register operand encode Rt = 31 only.
                if desc.format == .sysMaint && !b.sysMaintOp.takesRegister { continue }
                for r in 0..<UInt8(32) {
                    var i = b
                    i[keyPath: slot] = A64GPR(rawValue: r)
                    emit(i)
                }
            }
            for slot in f.vSlots {
                for r in 0..<UInt8(32) {
                    var i = b
                    i[keyPath: slot] = A64VReg(rawValue: r)
                    emit(i)
                }
            }
        }
        return out
    }
}

/// Representative invalid operand forms, made by mutating the text of a valid instruction: each vector
/// arrangement or element width replaced by the others (wrong arrangement), each integer immediate by values at
/// and beyond common field limits and each FP immediate by unrepresentable ones (out-of-range immediate), each lane
/// index by the first out-of-range one (out-of-range lane), each register by one of another width or class, a
/// memory base by a W register (wrong register class), and an operand added to an instruction that takes none.
/// Some mutations are still valid (`#4` -> `#5`); the sweep requires that LLVM and our assembler agree on every
/// one (and on the bytes where both accept it), and that each descriptor has mutations both reject.
enum A64Mutation {
    static let arrangements = ["16b", "8b", "8h", "4h", "4s", "2s", "2d", "1d", "1q"]
    static let elementWidths = ["b", "h", "s", "d"]

    /// The mnemonic and top-level operands of `mnem op, { list }, [mem], ...`.
    static func split(_ text: String) -> (mnemonic: String, operands: [String]) {
        guard let space = text.firstIndex(of: " ") else { return (text, []) }
        var ops: [String] = [], current = "", depth = 0
        for ch in text[text.index(after: space)...] {
            if ch == "{" || ch == "[" { depth += 1 }
            if ch == "}" || ch == "]" { depth -= 1 }
            if ch == "," && depth == 0 {
                ops.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        ops.append(current.trimmingCharacters(in: .whitespaces))
        return (String(text[..<space]), ops)
    }

    /// Ranges of the suffix `token` (`.4s`, `.b`) in `s` not followed by a letter or digit.
    static func occurrences(of token: String, in s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = s.startIndex
        while let r = s.range(of: token, range: from..<s.endIndex) {
            let after = r.upperBound == s.endIndex ? nil : s[r.upperBound]
            if !(after.map { $0.isLetter || $0.isNumber } ?? false) {
                out.append(r)
            }
            from = r.upperBound
        }
        return out
    }

    /// Variants of one operand.
    static func operandMutations(_ op: String) -> [String] {
        var out: [String] = []
        // Wrong arrangement: every `.T` of the operand (all registers of a list) replaced at once.
        for arr in arrangements where !occurrences(of: ".\(arr)", in: op).isEmpty {
            for alt in arrangements where alt != arr { out.append(op.replacingOccurrences(of: ".\(arr)", with: ".\(alt)")) }
        }
        // Elements and lane lists (`v1.s[2]`, `{ v0.h, v1.h }[3]`, `v2.4b[1]`): wrong element width, lane out of range.
        if op.hasSuffix("]"), let lb = op.lastIndex(of: "["), !op.hasPrefix("[") {
            let head = op[..<lb]
            let widthTokens = elementWidths.filter { !occurrences(of: ".\($0)", in: String(head)).isEmpty }
            if let w = widthTokens.first {
                for alt in elementWidths where alt != w { out.append(op.replacingOccurrences(of: ".\(w)", with: ".\(alt)")) }
                out.append("\(head)[\(16 >> elementWidths.firstIndex(of: w)!)]")
            } else if head.hasSuffix(".4b") {
                out.append("\(head)[4]")
            }
        }
        // Immediates (also inside a memory operand).
        if let hash = op.firstIndex(of: "#") {
            let start = op.index(after: hash)
            let end = op[start...].firstIndex(where: { $0 == "]" || $0 == "," || $0 == " " }) ?? op.endIndex
            let literal = String(op[start..<end])
            let (prefix, suffix) = (op[..<start], op[end...])
            if literal.contains(".") {
                for alt in ["0.1", "64.0", "-0.0"] where alt != literal { out.append("\(prefix)\(alt)\(suffix)") }
            } else if let value = literal.hasPrefix("0x") ? Int64(literal.dropFirst(2), radix: 16) : Int64(literal) {
                let candidates: [Int64] = [-1, 0, 5, value + 1, value - 1, 64, 4096, 65536, 1 << 26, 1 << 32]
                for alt in candidates where alt != value { out.append("\(prefix)\(alt)\(suffix)") }
            }
        }
        // Wrong register class or width.
        out += registerMutations(op)
        if op.hasPrefix("[") {
            let inner = op.dropFirst()
            let base = inner.prefix { $0 != "," && $0 != "]" }
            for alt in registerMutations(String(base)) where alt.hasPrefix("w") { out.append("[\(alt)\(inner.dropFirst(base.count))") }
        }
        return out
    }

    static func registerMutations(_ op: String) -> [String] {
        let lower = op.lowercased()
        switch lower {
        case "sp":  return ["wsp", "xzr"]
        case "wsp": return ["sp", "wzr"]
        case "xzr": return ["wzr", "sp"]
        case "wzr": return ["xzr", "wsp"]
        default: break
        }
        guard let first = lower.first, let n = Int(lower.dropFirst().prefix { $0.isNumber }) else { return [] }
        let rest = lower.dropFirst(1 + String(n).count)
        switch (first, rest.isEmpty) {
        case ("x", true): return ["w\(n)", "q\(n)"]
        case ("w", true): return ["x\(n)", "s\(n)"]
        case ("b", true), ("h", true), ("s", true), ("d", true), ("q", true):
            return ["b", "h", "s", "d", "q"].filter { $0 != String(first) }.map { "\($0)\(n)" } + ["x\(n)"]
        case ("v", false) where rest.hasPrefix(".") && !rest.contains("["):
            return ["q\(n)", "x\(n)"]
        case ("p", false) where rest == ".b":
            return ["p\(n).h", "p\(n + 16).b"]
        default:
            return []
        }
    }

    /// Every mutation of `text` (distinct, and different from `text`).
    static func mutations(_ text: String) -> [String] {
        let (mnemonic, ops) = split(text)
        var out: [String] = ops.isEmpty || (ops.count == 1 && ops[0].isEmpty) ? ["\(mnemonic) x0"] : []
        for (i, op) in ops.enumerated() {
            for alt in operandMutations(op) {
                var mutated = ops
                mutated[i] = alt
                out.append("\(mnemonic) " + mutated.joined(separator: ", "))
            }
        }
        var seen: Set<String> = [text]
        return out.filter { seen.insert($0).inserted }
    }
}

/// One generated instruction after the self round trip.
private struct A64SweepOutcome {
    let descriptorIndex: Int
    let word: UInt32
    let text: String
    var bytes: [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
}

private func hexWord(_ w: UInt32) -> String { String(format: "%08x", w) }

/// Canonical text for comparing our disassembly with LLVM's: lower case (LLVM prints system registers in
/// upper case), single spaces, no space after commas.
private func canonicalA64(_ text: String) -> String {
    let parts = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let mnem = parts.first else { return "" }
    return parts.count == 1 ? String(mnem) : "\(mnem) " + parts.dropFirst().joined(separator: " ").replacingOccurrences(of: ", ", with: ",")
}

/// `.text` bytes of `lines` assembled by our own assembler (Asm/AArch64Assembler.swift), and the error count.
private func ownAssembleA64(_ lines: [String]) -> (bytes: [UInt8], errors: Int) {
    var diags = DiagnosticBag()
    let obj = Assembler.assemble(source: lines.joined(separator: "\n") + "\n", arch: .aarch64, diagnostics: &diags)
    return (obj.findSection(name: ".text").map { obj.sectionData($0) } ?? [], diags.errorCount)
}

@Suite("M2 — Exhaustive AArch64 encoder sweep against LLVM MC")
struct M2AArch64ExhaustiveTests {
    static var llvmMC: String? { ExternalTool.find("llvm-mc") }
    /// The features the table covers: base A64, LSE, RDM, RCpc, CRC32, FP16, Advanced SIMD with dot product and
    /// the AES/SHA1/SHA256 crypto extension (the Q8B's Armv8.2-A set), the SVE subset, the PAC/BTI/PAN system
    /// aliases (without `+pauth`/`+bti`/`+pan`, LLVM prints and accepts only the raw `hint`/`msr` forms), and what
    /// `smc` (`+el3`) and the EL2/SME/RNDR system registers VectraOS's arm64 loader and kernel name require.
    static let llvmArgs = ["--triple=aarch64", "-mattr=+lse,+rdm,+rcpc,+crc,+fp-armv8,+neon,+fullfp16,+dotprod,+aes,+sha2,+sve,"
                           + "+pauth,+bti,+pan,+el3,+el2vmsa,+sme,+rand"]

    @Test("Every AArch64 descriptor: all operand forms round-trip and match llvm-mc bit for bit",
          .enabled(if: M2AArch64ExhaustiveTests.llvmMC != nil))
    func exhaustiveSweep() throws {
        let mc = try #require(Self.llvmMC)
        let table = A64InstructionTable.entries

        var outcomes: [A64SweepOutcome] = []
        var failures: [String] = []
        var covered = Set<Int>()

        // 1. Self round trip.
        for (index, desc) in table.enumerated() {
            for inst in A64Sweep.cases(desc) {
                guard let word = A64Encoder.encode(inst) else {
                    failures.append("encoder rejects generated form of \(desc.id): \(A64Disassembler.format(inst))")
                    continue
                }
                guard let decoded = A64Disassembler.decode(word) else {
                    failures.append("decode: \(desc.id) [\(hexWord(word))] \(A64Disassembler.format(inst))")
                    continue
                }
                let text = A64Disassembler.format(decoded)
                if decoded.opcode != desc.id {
                    failures.append("decodes to another descriptor: \(desc.id) -> \(decoded.opcode) [\(hexWord(word))] \(text)")
                    continue
                }
                guard let reencoded = A64Encoder.encode(decoded), reencoded == word else {
                    failures.append("round trip: \(text) [\(hexWord(word))] -> [\(A64Encoder.encode(decoded).map(hexWord) ?? "rejected")]")
                    continue
                }
                covered.insert(index)
                outcomes.append(A64SweepOutcome(descriptorIndex: index, word: word, text: text))
            }
        }

        // 2. LLVM assembles our disassembly text to exactly our bytes. Branch targets are numeric
        //    displacements, which llvm-mc reads the same way, so every instruction is compared directly.
        var llvmChecked = 0
        let llvm = try LLVMMC.assemble(outcomes.map(\.text), mc: mc, args: Self.llvmArgs)
        for (o, l) in zip(outcomes, llvm) {
            guard let l else {
                failures.append("llvm-mc rejects our disassembly: \(o.text) [\(hexWord(o.word))]")
                continue
            }
            if l.fixup || l.bytes != o.bytes {
                failures.append("encoding: \(o.text) ours=[\(hexWord(o.word))] llvm=[\(l.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))\(l.fixup ? " +fixup" : "")]")
            } else {
                llvmChecked += 1
            }
        }

        // 3. LLVM disassembles our bytes to our text (the preferred alias, as llvm-objdump prints it).
        var textChecked = 0
        let theirs = try LLVMMC.disassemble(outcomes.map(\.bytes), mc: mc, args: Self.llvmArgs)
        for (o, t) in zip(outcomes, theirs) {
            guard let t else {
                failures.append("llvm-mc cannot disassemble (or warns about) [\(hexWord(o.word))] ours=\(o.text)")
                continue
            }
            if canonicalA64(t) != canonicalA64(o.text) {
                failures.append("disassembly text: ours=\(o.text) llvm=\(t) [\(hexWord(o.word))]")
            } else {
                textChecked += 1
            }
        }

        // 4. Our own assembler accepts our disassembly and reproduces the bytes. Lines are checked in chunks;
        //    a mismatching chunk is re-assembled line by line to name the culprits.
        var asmChecked = 0
        let chunkSize = 4096
        for start in stride(from: 0, to: outcomes.count, by: chunkSize) {
            let chunk = outcomes[start..<min(start + chunkSize, outcomes.count)]
            let (bytes, errors) = ownAssembleA64(chunk.map(\.text))
            if errors == 0 && bytes == chunk.flatMap(\.bytes) {
                asmChecked += chunk.count
                continue
            }
            for o in chunk {
                let (b, e) = ownAssembleA64([o.text])
                if e != 0 || b != o.bytes {
                    failures.append("assembler: \(o.text) ours=[\(hexWord(o.word))] assembled=[\(b.map { String(format: "%02x", $0) }.joined(separator: " "))] errors=\(e)")
                } else {
                    asmChecked += 1
                }
            }
        }

        let missing = table.indices.filter { !covered.contains($0) }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("ss_a64_exhaustive.txt").path
        let summary = "descriptors \(table.count), covered \(covered.count), generated \(outcomes.count), llvm-encoding-checked \(llvmChecked), "
            + "llvm-text-checked \(textChecked), assembler-checked \(asmChecked), failures \(failures.count)"
        let lines = [summary] + missing.map { "NOT COVERED: #\($0) \(table[$0].id) \(table[$0].format)" } + failures
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        print("AArch64 exhaustive sweep: \(summary) (report: \(report))")

        #expect(covered.count == table.count, Comment(rawValue: "descriptors with no round-tripping instruction: " + missing.prefix(30).map { "\(table[$0].id)" }.joined(separator: ", ")))
        #expect(failures.count == 0, Comment(rawValue: "\(failures.count) failures (report: \(report)):\n  " + failures.prefix(40).joined(separator: "\n  ")))
    }

    /// Descriptors for which llvm-mc 22 accepts an invalid operand and encodes a different instruction: an out-of-range
    /// fixed-point `#fbits` on scalar `scvtf`/`ucvtf` from an X register or to an H register (truncated), an out-of-range
    /// `ext` index (truncated), a 32-bit `mov` immediate above 32 bits (truncated), and a W register with `sxtx` in
    /// `adds`/`subs` (encoded as the X register).
    static let llvmAlteringDescriptors: Set<A64OpcodeId> = [.scvtfFixed, .ucvtfFixed, .simdExt, .movz, .movn, .addsExtended, .subsExtended]

    @Test("Every AArch64 descriptor: invalid operand forms are rejected by our assembler exactly when llvm-mc rejects them",
          .enabled(if: M2AArch64ExhaustiveTests.llvmMC != nil))
    func rejectionSweep() throws {
        let mc = try #require(Self.llvmMC)
        let table = A64InstructionTable.entries

        // 1. Mutate the text of up to four representative forms (distinct shapes) of every descriptor.
        var lines: [(descriptor: Int, text: String)] = []
        var seen = Set<String>()
        for (index, desc) in table.enumerated() {
            for inst in A64Sweep.representatives(desc) {
                guard let word = A64Encoder.encode(inst), let decoded = A64Disassembler.decode(word) else { continue }
                for m in A64Mutation.mutations(A64Disassembler.format(decoded)) where seen.insert(m).inserted {
                    lines.append((index, m))
                }
            }
        }

        // 2. LLVM and our assembler must agree on every line: both reject it, or both accept it with the same bytes.
        //    llvm-mc 22 accepts a few invalid operands and silently encodes something else (`llvmAlteringDescriptors`);
        //    where its bytes do not decode to the line it was given, our rejection counts as agreement and the case is
        //    listed in the report.
        var failures: [String] = []
        var llvmTruncations: [String] = []
        var verdicts: [String] = []
        var rejectedBoth = [Int](repeating: 0, count: table.count)
        var acceptedBoth = 0
        let llvm = try LLVMMC.assemble(lines.map(\.text), mc: mc, args: Self.llvmArgs)
        for (line, l) in zip(lines, llvm) {
            let (bytes, errors) = ownAssembleA64([line.text])
            let ours = errors == 0 && !bytes.isEmpty ? bytes : nil
            verdicts.append("\(table[line.descriptor].id)\t\(l == nil ? "llvm-rejects" : "llvm-accepts")\t\(ours == nil ? "rejected" : "accepted")\t\(line.text)")
            if let l, ours == nil, Self.llvmAlteringDescriptors.contains(table[line.descriptor].id), l.bytes.count == 4,
               let decoded = A64Disassembler.decode(l.bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }),
               canonicalA64(A64Disassembler.format(decoded)) != canonicalA64(line.text) {
                llvmTruncations.append("llvm-mc alters: \(line.text) -> \(A64Disassembler.format(decoded))")
                rejectedBoth[line.descriptor] += 1
                continue
            }
            switch (l, ours) {
            case (nil, nil):
                rejectedBoth[line.descriptor] += 1
            case (let l?, let ours?) where !l.fixup && l.bytes == ours:
                acceptedBoth += 1
            case (nil, let ours?):
                failures.append("accepted, llvm-mc rejects: \(line.text) -> [\(ours.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            case (let l?, nil):
                failures.append("rejected, llvm-mc accepts: \(line.text) llvm=[\(l.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))]")
            case (let l?, let ours?):
                failures.append("encoding: \(line.text) ours=[\(ours.map { String(format: "%02x", $0) }.joined(separator: " "))] "
                                + "llvm=[\(l.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))\(l.fixup ? " +fixup" : "")]")
            }
        }

        let uncovered = table.indices.filter { rejectedBoth[$0] == 0 }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("ss_a64_rejection.txt").path
        let summary = "descriptors \(table.count), invalid-form candidates \(lines.count), rejected by both \(rejectedBoth.reduce(0, +)) "
            + "(of which llvm-mc alters \(llvmTruncations.count)), accepted by both \(acceptedBoth), failures \(failures.count)"
        let reportLines = [summary] + uncovered.map { "NO REJECTED FORM: #\($0) \(table[$0].id) \(table[$0].format)" } + failures + llvmTruncations
        try reportLines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        try verdicts.joined(separator: "\n").write(toFile: report.replacingOccurrences(of: ".txt", with: "_lines.txt"), atomically: true, encoding: .utf8)
        print("AArch64 rejection sweep: \(summary) (report: \(report))")

        #expect(uncovered.isEmpty, Comment(rawValue: "descriptors without a rejected invalid form: " + uncovered.prefix(30).map { "\(table[$0].id)" }.joined(separator: ", ")))
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures (report: \(report)):\n  " + failures.prefix(40).joined(separator: "\n  ")))
    }
}
