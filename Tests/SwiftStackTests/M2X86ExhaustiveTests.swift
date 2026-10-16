import Foundation
import Testing
@testable import SwiftStack

// Exhaustive x86-64 encoder/disassembler sweep (09-roadmap.md §M2 exit criterion: "encoder/disassembler
// round-trip is exhaustive over the instruction tables"; 05-assembler.md §4.11).
//
// For every descriptor in `X86InstructionTable.descriptors`, every operand form its format allows is
// generated: each register slot swept over all 16 registers of its class (plus %ah..%bh and %spl..%dil
// for byte registers), all low/extended combinations of the register slots (REX.R/X/B, VEX.R/X/B/vvvv,
// 2- vs 3-byte VEX), a set of memory operands covering every ModR/M / SIB special case, and boundary
// immediates. Each instruction is then
//
//   1. encoded, disassembled, and re-encoded: bytes must be identical and the whole encoding consumed;
//   2. assembled by `llvm-mc --show-encoding` from both the generated text and our disassembly text:
//      both must produce exactly our bytes (no "equivalent alternative" allowance);
//   3. when our encoder rejects a generated form, LLVM must reject it too.
//
// Relative branches, whose numeric target LLVM reads as a fixup, are compared through LLVM's
// disassembler instead. Every descriptor must be selected by the encoder for at least one generated
// instruction, so a new table entry cannot escape the sweep.

enum X86Sweep {
    /// A generated instruction, tagged with the descriptor it was generated from.
    struct Case {
        let descriptorIndex: Int
        let inst: X86Instruction
    }

    /// Operand slot of a descriptor's format, in AT&T order.
    enum Slot {
        case reg(X86RegClass)
        case rm(X86RegClass, allowReg: Bool, allowMem: Bool, indirect: Bool)
        case vsib(X86RegClass)
        case imm([Int64])
        case fixed(X86Operand)
        case rel([Int64])
        case moffs([X86Mem])
    }

    static func regs(_ rc: X86RegClass) -> [X86Reg] {
        switch rc {
        case .gpr8:     return (0..<16).map { X86Reg.gpr8($0) } + [.ah, .ch, .dh, .bh]
        case .gpr8High: return [.ah, .ch, .dh, .bh]
        case .gpr16:    return (0..<16).map { X86Reg.gpr16($0) }
        case .gpr32:    return (0..<16).map { X86Reg.gpr32($0) }
        case .gpr64:    return (0..<16).map { X86Reg.gpr64($0) }
        case .xmm:      return (0..<16).map { X86Reg.xmm($0) }
        case .ymm:      return (0..<16).map { X86Reg.ymm($0) }
        case .seg:      return (0..<6).compactMap { X86Reg.seg($0) }
        case .cr:       return (0..<16).map { X86Reg.cr($0) }
        case .dr:       return (0..<16).map { X86Reg.dr($0) }
        case .rip:      return [.rip]
        case .x87:      return (0..<8).map { X86Reg.st($0) }
        }
    }

    /// Default register for slot `n`: distinct per slot, low (no REX/VEX extension bit) or extended.
    static func defaultReg(_ rc: X86RegClass, slot n: Int, extended: Bool) -> X86Reg {
        let lowIdx: [UInt8] = [1, 2, 3, 0]
        let hw = lowIdx[n % 4] + (extended ? 8 : 0)
        switch rc {
        case .seg: return X86Reg.seg(UInt8(n % 6))!
        case .gpr8High: return .ch
        case .x87: return .st(lowIdx[n % 4] + (extended ? 4 : 0)) // no extension bits: a higher stack register
        default: return regs(rc)[Int(hw)]
        }
    }

    /// Memory operands covering ModR/M and SIB special cases in 64-bit mode, then every base register
    /// (no displacement, disp8, disp32), every index register (all four scales), and every segment override.
    static let memForms64: [X86Mem] = specialMemForms64 + sweptMemForms64

    static let sweptMemForms64: [X86Mem] = {
        var forms: [X86Mem] = []
        for hw in UInt8(0)..<16 {
            let base = X86Reg.gpr64(hw)
            forms += [X86Mem(base: base), X86Mem(base: base, disp: -0x40), X86Mem(base: base, disp: 0x400)]
        }
        for hw in UInt8(0)..<16 where hw != 4 {
            forms.append(X86Mem(base: .rbx, index: X86Reg.gpr64(hw), scale: UInt8(1) << (hw % 4), disp: 0x10))
        }
        for scale: UInt8 in [1, 2, 4, 8] {
            forms.append(X86Mem(base: .r10, index: .r9, scale: scale))
        }
        for segment: UInt8 in [0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65] {
            forms.append(X86Mem(segment: segment, base: .rdx, index: .rsi, scale: 2, disp: 4))
        }
        return forms
    }()

    static let specialMemForms64: [X86Mem] = [
        X86Mem(base: .rax),                                  // mod=00
        X86Mem(base: .rsp),                                  // SIB 0x24
        X86Mem(base: .rbp),                                  // mod=01 disp8=0
        X86Mem(base: .r12),                                  // SIB with REX.B
        X86Mem(base: .r13),                                  // mod=01 disp8=0 with REX.B
        X86Mem(base: .r15),
        X86Mem(base: .rcx, disp: 8),                         // disp8
        X86Mem(base: .rdx, disp: -128),                      // disp8 minimum
        X86Mem(base: .rsi, disp: 127),                       // disp8 maximum
        X86Mem(base: .rdi, disp: 128),                       // disp32
        X86Mem(base: .r8, disp: -129),                       // disp32 negative
        X86Mem(base: .r9, disp: 0x1234_5678),
        X86Mem(base: .rsp, disp: -8),                        // SIB 0x24 + disp8
        X86Mem(base: .rax, index: .rbx, scale: 1),
        X86Mem(base: .rsi, index: .r14, scale: 2, disp: 16), // REX.X
        X86Mem(base: .r11, index: .rcx, scale: 4, disp: -8),
        X86Mem(base: .rbp, index: .r12, scale: 8, disp: 0x1000),
        X86Mem(base: .r13, index: .rax, scale: 8),           // SIB base=101 mod=01
        X86Mem(base: .rsp, index: .rbp, scale: 1),
        X86Mem(base: .r12, index: .r15, scale: 2, disp: 1),
        X86Mem(index: .rdx, scale: 8),                       // no base: SIB base=101 disp32
        X86Mem(index: .r15, scale: 2, disp: 0x40),
        .ripRelative(disp: 64),
        .ripRelative(disp: -4),
        .absolute(disp: 0x1000),                             // SIB without base or index
        X86Mem(segment: 0x64, base: .rax, disp: 16),         // %fs:
        .absolute(disp: 0, segment: 0x65),                   // %gs:0
        X86Mem(base: .eax),                                  // 0x67 address size
        X86Mem(base: .r8d, index: .ecx, scale: 4, disp: 8)
    ]

    /// 64-bit absolute addresses of `movabs` (`moffs`), with segment overrides.
    static let moffsForms: [X86Mem] = [
        .absolute(disp: 0x1122_3344_5566_7788), .absolute(disp: 0), .absolute(disp: -1), .absolute(disp: 0x8000_0000),
        .absolute(disp: Int64.min), .absolute(disp: 0x10, segment: 0x64), .absolute(disp: 0x10, segment: 0x65),
    ]

    /// The explicit-operand forms of a string instruction: default registers, 32-bit addressing, and every
    /// segment override of the source (`(%rsi)`, `xlat`'s `(%rbx)`); `%es:` on the destination is optional.
    static func stringOperandLists(_ kinds: [X86StringOperand], size: X86OperandSize) -> [[X86Operand]] {
        func operands(addr32: Bool, segment: UInt8?, explicitES: Bool) -> [X86Operand] {
            kinds.map { kind in
                func pointer(_ hw: UInt8, _ seg: UInt8?) -> X86Operand {
                    .mem(X86Mem(segment: seg, base: addr32 ? X86Reg.gpr32(hw) : X86Reg.gpr64(hw)))
                }
                switch kind {
                case .source:      return pointer(6, segment)
                case .destination: return pointer(7, explicitES ? 0x26 : nil)
                case .table:       return pointer(3, segment)
                case .accumulator: return .reg(accumulator(size))
                case .port:        return .reg(.dx)
                }
            }
        }
        var lists: [[X86Operand]] = []
        for addr32 in [false, true] {
            for explicitES in [false, true] { lists.append(operands(addr32: addr32, segment: nil, explicitES: explicitES)) }
            if kinds.contains(.source) || kinds.contains(.table) {
                for seg: UInt8 in [0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65] { lists.append(operands(addr32: addr32, segment: seg, explicitES: true)) }
            }
        }
        return lists
    }

    /// Memory operands for `.code16` descriptors (absolute and 32-bit addressing only).
    static let memForms16: [X86Mem] = [
        .absolute(disp: 8),
        .absolute(disp: 0x1234),
        X86Mem(base: .eax),
        X86Mem(base: .ebx, index: .ecx, scale: 4, disp: 8)
    ]

    /// VSIB memory operands with a vector index of class `rc`.
    static func vsibForms(_ rc: X86RegClass) -> [X86Mem] {
        var forms: [X86Mem] = []
        for idx in regs(rc) {
            forms.append(X86Mem(base: .rax, index: idx, scale: 4))
        }
        let i3 = regs(rc)[3], i12 = regs(rc)[12]
        forms += [
            X86Mem(base: .rsp, index: i3, scale: 1),
            X86Mem(base: .rbp, index: i3, scale: 2),
            X86Mem(base: .r12, index: i12, scale: 8, disp: 8),
            X86Mem(base: .r13, index: i3, scale: 8, disp: -128),
            X86Mem(base: .r9, index: i12, scale: 1, disp: 0x1000),
            X86Mem(index: i3, scale: 4, disp: 0x40),
            X86Mem(segment: 0x65, base: .rdi, index: i12, scale: 2)
        ]
        return forms
    }

    static let imm8Signed: [Int64] = [1, 0, -1, 0x7F, -0x80]
    static let imm8Unsigned: [Int64] = [1, 0, 0x7F, 0x80, 0xFF]
    static let imm16: [Int64] = [0x1234, 0, 1, 0x7FFF, -0x8000, 0xFFFF]
    static let imm32: [Int64] = [0x1234_5678, 0, 1, 0x7FFF_FFFF, -0x8000_0000, 0xFFFF_FFFF]
    static let imm32SignExtended: [Int64] = [0x1234_5678, 0, 1, -1, 0x7FFF_FFFF, -0x8000_0000]
    static let imm64: [Int64] = [0x1122_3344_5566_7788, 0, -1, Int64.min, Int64.max, 0x8000_0000]

    static func immValues(_ desc: X86InstrDesc, immSize: X86OperandSize, target: X86OperandSize) -> [Int64] {
        switch immSize {
        case .byte:
            return (target == .byte || desc.imm8IsZeroExtended) ? imm8Unsigned : imm8Signed
        case .word:
            return imm16
        case .dword:
            return target == .qword ? imm32SignExtended : imm32
        default:
            return imm64
        }
    }

    static func gprClass(_ size: X86OperandSize) -> X86RegClass? {
        switch size {
        case .byte:  return .gpr8
        case .word:  return .gpr16
        case .dword: return .gpr32
        case .qword: return .gpr64
        default:     return nil
        }
    }

    static func accumulator(_ size: X86OperandSize) -> X86Reg {
        switch size {
        case .byte:  return .al
        case .word:  return .ax
        case .dword: return .eax
        default:     return .rax
        }
    }

    static func codeMode(_ desc: X86InstrDesc) -> X86CodeMode {
        desc.mnemonic == "lgdtl" ? .mode16 : .mode64
    }

    /// The operand slots of `desc`, in AT&T order.
    static func slots(_ desc: X86InstrDesc) -> [Slot] {
        let mode = codeMode(desc)
        let allowReg = desc.rmConstraint != .memOnly
        let allowMem = desc.rmConstraint != .regOnly
        func rm(_ rc: X86RegClass?) -> Slot {
            .rm(rc ?? gprClass(desc.operandSize) ?? .gpr64, allowReg: allowReg, allowMem: allowMem, indirect: false)
        }
        let sizeGPR = gprClass(desc.operandSize) ?? .gpr64
        switch desc.operandFormat {
        case .implied:
            return []
        case .opcodePlusReg(let rc):
            return [.reg(rc)]
        case .opcodePlusRegWithAcc(let rc):
            return [.reg(rc), .fixed(.reg(accumulator(desc.operandSize)))]
        case .immToOpcodePlusReg(let rc, let immSz):
            return [.imm(immValues(desc, immSize: immSz, target: desc.operandSize)), .reg(rc)]
        case .rm(let kind):
            let reg = allowReg && (kind == .gprOrMem || kind == .gprOnly || kind == .indirectRegOrMem)
            let mem = allowMem && kind != .gprOnly
            let indirect = kind == .indirectRegOrMem || kind == .indirectMemOnly
            return [.rm(sizeGPR, allowReg: reg, allowMem: mem, indirect: indirect)]
        case .regToRm(let regClass, let rmClass):
            return [.reg(regClass), rm(rmClass)]
        case .rmToReg(let rmClass, let regClass):
            return [rm(rmClass), .reg(regClass)]
        case .immToRm(let rmClass, let immSz):
            let target: X86OperandSize = (rmClass == .xmm || rmClass == .ymm) ? .byte : desc.operandSize
            return [.imm(immValues(desc, immSize: immSz, target: target)), rm(rmClass)]
        case .immToAcc(let immSz):
            return [.imm(immValues(desc, immSize: immSz, target: desc.operandSize)), .fixed(.reg(accumulator(desc.operandSize)))]
        case .shiftBy1:
            return [.fixed(.imm(1)), rm(sizeGPR)]
        case .shiftByCl:
            return [.fixed(.reg(.cl)), rm(sizeGPR)]
        case .immRmToReg(let rmClass, let regClass, let immSz):
            let target: X86OperandSize = (desc.encodingKind == .vex || rmClass == .xmm || rmClass == .ymm) ? .byte : desc.operandSize
            return [.imm(immValues(desc, immSize: immSz, target: target)), rm(rmClass), .reg(regClass)]
        case .immRegToRm(let regClass, let rmClass, let immSz):
            return [.imm(immValues(desc, immSize: immSz, target: .byte)), .reg(regClass), rm(rmClass)]
        case .clRegToRm(let regClass, let rmClass):
            return [.fixed(.reg(.cl)), .reg(regClass), rm(rmClass)]
        case .vexRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            return [rm(rmClass), .reg(vvvvClass), .reg(regClass)]
        case .vexImmRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            return [.imm(imm8Unsigned), rm(rmClass), .reg(vvvvClass), .reg(regClass)]
        case .vexVvvvRmReg(let vvvvClass, let rmClass, let regClass):
            return [.reg(vvvvClass), rm(rmClass), .reg(regClass)]
        case .vexRmToVvvv(let rmClass, let vvvvClass):
            return [rm(rmClass), .reg(vvvvClass)]
        case .vexImmRmToVvvv(let rmClass, let vvvvClass):
            return [.imm(imm8Unsigned), rm(rmClass), .reg(vvvvClass)]
        case .vexRegVvvvToRm(let regClass, let vvvvClass, let rmClass):
            return [.reg(regClass), .reg(vvvvClass), rm(rmClass)]
        case .vexIs4RmVvvvReg(let rmClass, let vvvvClass, let regClass):
            return [.reg(regClass), rm(rmClass), .reg(vvvvClass), .reg(regClass)]
        case .vexVsib(let vvvvClass, let indexClass, let regClass):
            return [.reg(vvvvClass), .vsib(indexClass), .reg(regClass)]
        case .xmm0RmToReg(let rmClass, let regClass):
            return [.fixed(.reg(.xmm0)), rm(rmClass), .reg(regClass)]
        case .relBranch(let relSz):
            if relSz == .byte { return [.rel([16, 0, 1, 127, -128, -2])] }
            return [.rel([0x1000, -0x1000, 0x7FFF_FFFF, -0x8000_0000, 0x1234_5678])]
        case .immOnly(let immSz):
            let target: X86OperandSize = desc.mnemonic == "push" ? .qword : (desc.mnemonic == "pushw" ? .word : immSz)
            return [.imm(immValues(desc, immSize: immSz, target: target))]
        case .immWordImmByte:
            return [.imm(imm16), .imm(imm8Unsigned)]
        case .fixedReg(let r):
            return [.fixed(.reg(r))]
        case .moffsToAcc:
            return [.moffs(moffsForms), .fixed(.reg(accumulator(desc.operandSize)))]
        case .accToMoffs:
            return [.fixed(.reg(accumulator(desc.operandSize))), .moffs(moffsForms)]
        case .stringOp:
            return []
        case .segToRm:
            return [.reg(.seg), rm(sizeGPR)]
        case .rmToSeg:
            return [rm(sizeGPR), .reg(.seg)]
        case .crToReg:
            return [.reg(.cr), .rm(mode == .mode64 ? .gpr64 : .gpr32, allowReg: true, allowMem: false, indirect: false)]
        case .regToCr:
            return [.rm(mode == .mode64 ? .gpr64 : .gpr32, allowReg: true, allowMem: false, indirect: false), .reg(.cr)]
        case .drToReg:
            return [.reg(.dr), .rm(mode == .mode64 ? .gpr64 : .gpr32, allowReg: true, allowMem: false, indirect: false)]
        case .regToDr:
            return [.rm(mode == .mode64 ? .gpr64 : .gpr32, allowReg: true, allowMem: false, indirect: false), .reg(.dr)]
        case .ioDxToAcc:
            return [.fixed(.reg(.dx)), .fixed(.reg(accumulator(desc.operandSize)))]
        case .ioAccToDx:
            return [.fixed(.reg(accumulator(desc.operandSize))), .fixed(.reg(.dx))]
        case .ioImmToAcc:
            return [.imm([0x60, 0, 0x7F, 0x80, 0xFF]), .fixed(.reg(accumulator(desc.operandSize)))]
        case .ioAccToImm:
            return [.fixed(.reg(accumulator(desc.operandSize))), .imm([0x60, 0, 0x7F, 0x80, 0xFF])]
        case .x87Reg:
            return [.reg(.x87)]
        case .x87RegToSt0:
            return [.reg(.x87), .fixed(.reg(.st))]
        case .x87St0ToReg:
            return [.fixed(.reg(.st)), .reg(.x87)]
        }
    }

    /// True if a high-byte register (%ah..%bh) appears together with something that needs a REX prefix.
    static func hasHighByteConflict(_ ops: [X86Operand], desc: X86InstrDesc) -> Bool {
        var high = false, rex = desc.rexW && desc.encodingKind == .legacy
        func needsRex(_ r: X86Reg) -> Bool { r.needsRexExtension || r.requiresRexByte }
        for op in ops {
            switch op {
            case .reg(let r), .indirectReg(let r):
                if r.regClass == .gpr8High { high = true } else if needsRex(r) { rex = true }
            case .mem(let m), .indirectMem(let m):
                if let b = m.base, b != .rip, needsRex(b) { rex = true }
                if let i = m.index, needsRex(i) { rex = true }
            default:
                break
            }
        }
        return high && rex
    }

    /// All generated instructions for descriptor `index`.
    static func cases(descriptorIndex index: Int) -> [Case] {
        let desc = X86InstructionTable.descriptors[index]
        let mode = codeMode(desc)
        let slots = slots(desc)
        let memForms = mode == .mode16 ? memForms16 : memForms64

        func defaultOperand(_ slot: Slot, _ n: Int, extended: Bool) -> X86Operand {
            switch slot {
            case .reg(let rc):
                return .reg(defaultReg(rc, slot: n, extended: extended))
            case .rm(let rc, let allowReg, _, let indirect):
                guard allowReg else { return indirect ? .indirectMem(memForms[0]) : .mem(memForms[0]) }
                let r = defaultReg(rc, slot: n, extended: extended)
                return indirect ? .indirectReg(r) : .reg(r)
            case .vsib(let rc):
                return .mem(X86Mem(base: .rax, index: defaultReg(rc, slot: n, extended: extended), scale: 4))
            case .imm(let values):
                return .imm(values[0])
            case .fixed(let op):
                return op
            case .rel(let values):
                return .relTarget(values[0])
            case .moffs(let forms):
                return .mem(forms[0])
            }
        }
        func defaults(extended: Bool) -> [X86Operand] {
            slots.enumerated().map { defaultOperand($0.element, $0.offset, extended: extended) }
        }

        var operandLists: [[X86Operand]] = [defaults(extended: false)]

        // 1. Each register slot (and register r/m) over every register of its class.
        for (n, slot) in slots.enumerated() {
            var base = defaults(extended: false)
            switch slot {
            case .reg(let rc):
                for r in regs(rc) { base[n] = .reg(r); operandLists.append(base) }
            case .rm(let rc, let allowReg, _, let indirect) where allowReg:
                for r in regs(rc) { base[n] = indirect ? .indirectReg(r) : .reg(r); operandLists.append(base) }
            case .vsib(let rc):
                for m in vsibForms(rc) { base[n] = .mem(m); operandLists.append(base) }
            case .imm(let values):
                for v in values { base[n] = .imm(v); operandLists.append(base) }
            case .rel(let values):
                for v in values { base[n] = .relTarget(v); operandLists.append(base) }
            case .moffs(let forms):
                for m in forms { base[n] = .mem(m); operandLists.append(base) }
            default:
                break
            }
        }

        // 2. Every low/extended combination of the register slots, with every immediate (the VEX 2-byte
        //    form and the commuted encodings of `vcmpps` depend on both).
        let regSlots = slots.indices.filter { n in
            switch slots[n] {
            case .reg, .vsib: return true
            case .rm(_, let allowReg, _, _): return allowReg
            default: return false
            }
        }
        let immSlot = slots.indices.first { n in
            if case .imm = slots[n] { return true }
            return false
        }
        if regSlots.count > 1 {
            for mask in 0..<(1 << regSlots.count) {
                var ops = defaults(extended: false)
                for (bit, n) in regSlots.enumerated() {
                    ops[n] = defaultOperand(slots[n], n, extended: (mask >> bit) & 1 == 1)
                }
                operandLists.append(ops)
                if let k = immSlot, case .imm(let values) = slots[k] {
                    for v in values.dropFirst() {
                        ops[k] = .imm(v)
                        operandLists.append(ops)
                    }
                }
            }
        }

        // 3. Every memory form for a memory-capable r/m, with the other register slots low and extended.
        for (n, slot) in slots.enumerated() {
            guard case .rm(_, _, let allowMem, let indirect) = slot, allowMem else { continue }
            for extended in [false, true] {
                var base = defaults(extended: extended)
                for m in memForms {
                    base[n] = indirect ? .indirectMem(m) : .mem(m)
                    operandLists.append(base)
                }
            }
        }

        // 4. String instructions: also the explicit-operand forms.
        if case .stringOp(let kinds) = desc.operandFormat, mode == .mode64 {
            operandLists += stringOperandLists(kinds, size: desc.operandSize)
        }

        var seen = Set<[X86Operand]>()
        var out: [Case] = []
        for ops in operandLists where seen.insert(ops).inserted {
            if hasHighByteConflict(ops, desc: desc) { continue }
            let mnemonic = (desc.memMnemonic != nil && ops.contains(where: \.isMemory)) ? desc.memMnemonic! : desc.mnemonic
            let inst = X86Instruction(
                mnemonic: mnemonic,
                sizeSuffix: desc.needsSizeSuffix(operands: ops) ? desc.operandSize : .unsized,
                operands: ops,
                codeMode: mode
            )
            out.append(Case(descriptorIndex: index, inst: inst))
        }
        return out
    }

    static func isBranch(_ desc: X86InstrDesc) -> Bool {
        if case .relBranch = desc.operandFormat { return true }
        return false
    }
}

/// Result of one generated instruction after the self round trip.
private struct X86SweepOutcome {
    let source: X86Sweep.Case
    let text: String
    let bytes: [UInt8]?            // nil: our encoder rejected the instruction
    let descriptorIndex: Int?
    let disassembly: String?
    let isBranch: Bool
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// Assembles `lines` with llvm-mc in one invocation; `nil` for a line LLVM rejects.
private func llvmAssemble(_ lines: [String], mode: X86CodeMode, mc: String) throws -> [(bytes: [UInt8], fixup: Bool)?] {
    try LLVMMC.assemble(lines, mc: mc, args: ["-triple=x86_64"], header: mode == .mode16 ? [".code16"] : [])
}

/// `.text` bytes of `lines` assembled by our own assembler (the AT&T parser in Asm/X86Assembler.swift),
/// and the number of diagnosed errors.
private func ownAssemble(_ lines: [String], mode: X86CodeMode) -> (bytes: [UInt8], errors: Int) {
    let header = mode == .mode16 ? ".code16\n" : ""
    var diags = DiagnosticBag()
    let obj = Assembler.assemble(source: header + lines.joined(separator: "\n") + "\n", arch: .x86_64, diagnostics: &diags)
    return (obj.findSection(name: ".text").map { obj.sectionData($0) } ?? [], diags.errorCount)
}

/// GNU `as` encodings of 64-bit `lines`: each line gets its own label, and its bytes are the `.text` range
/// up to the next label. `nil` for a line GNU `as` rejects.
private func gnuAssemble(_ lines: [String], gas: String) throws -> [[UInt8]?] {
    var rejected = Set<Int>()
    for _ in 0..<2 {
        var src = ""
        src.reserveCapacity(lines.count * 32)
        for (i, line) in lines.enumerated() {
            src += "x\(i):\n" + (rejected.contains(i) ? "" : line) + "\n"
        }
        src += "xend:\n"
        let input = ExternalTool.temporaryPath(".s"), output = ExternalTool.temporaryPath(".o")
        defer {
            try? FileManager.default.removeItem(atPath: input)
            try? FileManager.default.removeItem(atPath: output)
        }
        try src.write(toFile: input, atomically: true, encoding: .utf8)
        let r = try ExternalTool.run(gas, ["--64", "-o", output, input])
        if r.status != 0 {
            // "<file>:<line>: Error: ...": line 2i+2 holds instruction i. Retry once without them.
            let before = rejected.count
            for line in r.stderr.split(separator: "\n") where line.contains(": Error: ") {
                let fields = line.split(separator: ":")
                if fields.count > 2, let n = Int(fields[1]), n >= 2 { rejected.insert((n - 2) / 2) }
            }
            if rejected.count == before { throw TestELF.FormatError(description: "GNU as failed: \(r.stderr.prefix(500))") }
            continue
        }
        let elf = try TestELF(path: output)
        guard let text = elf.sections.first(where: { $0.name == ".text" }) else { break }
        var offsets = [Int](repeating: -1, count: lines.count + 1)
        for sym in elf.symbols where sym.name.hasPrefix("x") {
            if sym.name == "xend" { offsets[lines.count] = Int(sym.value) }
            else if let i = Int(sym.name.dropFirst()), i < lines.count { offsets[i] = Int(sym.value) }
        }
        return lines.indices.map { i in
            guard !rejected.contains(i), offsets[i] >= 0, offsets[i + 1] >= offsets[i] else { return nil }
            return Array(text.data[offsets[i]..<offsets[i + 1]])
        }
    }
    return lines.map { _ in nil }
}

/// True if `gnu` differs from `ours` only in a way 05-assembler.md §4.11 documents (Swift-Stack follows
/// LLVM MC there): GNU `as` does not swap commutable VEX sources to reach the 2-byte VEX prefix, puts the
/// first `xchg` register operand in ModRM.reg, omits REX.W in `mov` to/from a segment register and in
/// `str`/`sldt`/`smsw`/`lar`/`lsl` with a 64-bit register, drops an explicit `%ds:` override that equals the
/// default segment, puts a string instruction's segment override before 0x67, and emits the segment and address
/// size of `xlat`'s operand (LLVM MC ignores them).
/// True for the REX.W far-pointer forms (`lfsq`, `lgsq`, `lssq`, `lcallq`, `ljmpq`), which LLVM MC accepts and GNU
/// `as` rejects (05-assembler.md §4.11, difference 6).
private func isDocumentedGNURejection(_ desc: X86InstrDesc) -> Bool {
    desc.rexW && ["lfs", "lgs", "lss", "lcallq", "ljmpq"].contains(desc.mnemonic)
}

private func isDocumentedGNUDifference(ours: [UInt8], gnu: [UInt8], desc: X86InstrDesc, mode: X86CodeMode, text: String) -> Bool {
    let disassembler = X86Disassembler()
    if desc.mandatoryPrefix == .p9B, ours.first == 0x9B, gnu.first == 0x9B {
        // The waiting x87 forms (`fstcw`): `wait`, then the instruction, which may differ as any other does.
        return isDocumentedGNUDifference(ours: Array(ours.dropFirst()), gnu: Array(gnu.dropFirst()), desc: desc, mode: mode, text: text)
    }
    if text.contains("%ds:"), ours.first == 0x3E {
        // Possibly together with one of the other differences.
        let rest = Array(ours.dropFirst())
        return rest == gnu || isDocumentedGNUDifference(ours: rest, gnu: gnu, desc: desc, mode: mode, text: text.replacingOccurrences(of: "%ds:", with: ""))
    }
    if case .stringOp = desc.operandFormat {
        if desc.mnemonic == "xlatb" { return ours == [0xD7] && gnu.last == 0xD7 }
        guard ours.count >= 2, ours[0] == 0x67 else { return false }
        return [ours[1], ours[0]] + ours.dropFirst(2) == gnu
    }
    if desc.commutable || desc.mnemonic == "xchg" {
        guard let a = try? disassembler.disassembleOne(ours, at: 0, codeMode: mode).instruction,
              let b = try? disassembler.disassembleOne(gnu, at: 0, codeMode: mode).instruction,
              a.mnemonic == b.mnemonic, a.operands.count == b.operands.count else { return false }
        let first = a.operands.count == 4 ? 1 : 0
        var swapped = a.operands
        swapped.swapAt(first, first + 1)
        return swapped == b.operands
    }
    let dropsRexW: Bool
    switch desc.operandFormat {
    case .segToRm, .rmToSeg: dropsRexW = desc.rexW
    default:                 dropsRexW = desc.rexW && ["str", "sldt", "smsw", "lar", "lsl"].contains(desc.mnemonic)
    }
    if dropsRexW, let rex = ours.firstIndex(where: { (0x48...0x4F).contains($0) }) {
        var expected = ours
        if ours[rex] == 0x48 { expected.remove(at: rex) } else { expected[rex] &= ~0x08 }
        return expected == gnu
    }
    return false
}

@Suite("M2 — Exhaustive x86-64 encoder sweep against LLVM MC")
struct M2X86ExhaustiveTests {
    static var llvmMC: String? { ExternalTool.find("llvm-mc") }

    /// GNU `as`, if the `as` on PATH is GNU's (it is skipped otherwise, never assumed to pass).
    static var gnuAs: String? {
        guard let path = ExternalTool.find("as"),
              let r = try? ExternalTool.run(path, ["--version"]), r.stdout.contains("GNU assembler") else { return nil }
        return path
    }

    @Test("Every x86-64 descriptor: all operand forms round-trip and match llvm-mc byte for byte",
          .enabled(if: M2X86ExhaustiveTests.llvmMC != nil))
    func exhaustiveSweep() throws {
        let mc = try #require(Self.llvmMC)
        let encoder = X86TableEncoder()
        let disassembler = X86Disassembler()
        let table = X86InstructionTable.descriptors

        var outcomes: [X86SweepOutcome] = []
        var failures: [String] = []
        var covered = Set<Int>()

        for index in table.indices {
            let branch = X86Sweep.isBranch(table[index])
            for c in X86Sweep.cases(descriptorIndex: index) {
                let text = c.inst.attString
                guard let (encoded, used) = try? encoder.encodeWithDescriptor(c.inst) else {
                    outcomes.append(X86SweepOutcome(source: c, text: text, bytes: nil, descriptorIndex: nil, disassembly: nil, isBranch: branch))
                    continue
                }
                covered.insert(used)
                let bytes = encoded.bytes
                if table[used].mandatoryPrefix == .p9B {
                    // `fstcw` & co. are two instructions, `wait` and the `fn...` form, as LLVM MC encodes and decodes
                    // them; M3X87ExhaustiveTests compares their disassembly with LLVM's. Here: both decode and re-encode.
                    let decoded = try? disassembler.disassemble(bytes, codeMode: c.inst.codeMode)
                    let reencoded = decoded.flatMap { try? $0.flatMap { try encoder.encode($0).bytes } }
                    if decoded?.count != 2 || decoded?.first?.mnemonic != "wait" || reencoded != bytes {
                        failures.append("round trip: \(text) [\(hex(bytes))] -> \(decoded?.map(\.attString).joined(separator: "; ") ?? "?")")
                    }
                    outcomes.append(X86SweepOutcome(source: c, text: text, bytes: bytes, descriptorIndex: used, disassembly: nil, isBranch: branch))
                    continue
                }
                do {
                    let (decoded, length) = try disassembler.disassembleOne(bytes, at: 0, codeMode: c.inst.codeMode)
                    let reencoded = try encoder.encode(decoded)
                    if length != bytes.count || reencoded.bytes != bytes {
                        failures.append("round trip: \(text) [\(hex(bytes))] -> \(decoded.attString) [\(hex(reencoded.bytes))] len \(length)")
                    }
                    outcomes.append(X86SweepOutcome(source: c, text: text, bytes: bytes, descriptorIndex: used, disassembly: decoded.attString, isBranch: branch))
                } catch {
                    failures.append("disassembly: \(text) [\(hex(bytes))]: \(error)")
                }
            }
        }

        // Assemble the generated text and our disassembly with LLVM (one batch per code mode).
        var checked = 0
        func isWaiting(_ o: X86SweepOutcome) -> Bool { table[o.source.descriptorIndex].mandatoryPrefix == .p9B }
        for mode in [X86CodeMode.mode64, .mode16] {
            let group = outcomes.filter { $0.source.inst.codeMode == mode && !$0.isBranch && !isWaiting($0) }
            guard !group.isEmpty else { continue }
            var lines: [String] = []
            lines.reserveCapacity(group.count * 2)
            for o in group {
                lines.append(o.text)
                lines.append(o.disassembly ?? o.text)
            }
            let llvm = try llvmAssemble(lines, mode: mode, mc: mc)
            for (k, o) in group.enumerated() {
                let fromText = llvm[2 * k], fromDisasm = llvm[2 * k + 1]
                guard let ours = o.bytes else {
                    if let l = fromText {
                        failures.append("rejected by us, accepted by llvm-mc: \(o.text) llvm=[\(hex(l.bytes))]")
                    }
                    continue
                }
                if let l = fromText {
                    if l.bytes != ours { failures.append("encoding: \(o.text) ours=[\(hex(ours))] llvm=[\(hex(l.bytes))]") }
                } else {
                    failures.append("llvm-mc rejects generated text: \(o.text) ours=[\(hex(ours))]")
                }
                if let d = o.disassembly {
                    if let l = fromDisasm {
                        if l.bytes != ours { failures.append("disassembly re-assembles differently: \(d) ours=[\(hex(ours))] llvm=[\(hex(l.bytes))]") }
                    } else {
                        failures.append("llvm-mc rejects our disassembly: \(d) (from \(o.text))")
                    }
                }
                checked += 1
            }
        }

        // Waiting x87 forms (`fstcw` = `wait; fnstcw`): LLVM MC prints two encodings for each line, `wait` and the rest.
        let waiting = outcomes.filter(isWaiting)
        if !waiting.isEmpty {
            let r = try ExternalTool.run(mc, ["-triple=x86_64", "-show-encoding"], stdin: waiting.map(\.text).joined(separator: "\n") + "\n")
            var encodings: [[UInt8]] = []
            for line in r.stdout.split(separator: "\n") {
                guard let lb = line.range(of: "encoding: ["), let rb = line[lb.upperBound...].firstIndex(of: "]") else { continue }
                encodings.append(line[lb.upperBound..<rb].split(separator: ",").compactMap { UInt8($0.dropFirst(2), radix: 16) })
            }
            if r.stderr.contains("error") || encodings.count != 2 * waiting.count {
                failures.append("waiting x87 forms: llvm-mc gave \(encodings.count) encodings for \(waiting.count) lines: \(r.stderr.prefix(300))")
            } else {
                for (k, o) in waiting.enumerated() {
                    let theirs = encodings[2 * k] + encodings[2 * k + 1]
                    if encodings[2 * k] != [0x9B] || o.bytes != theirs {
                        failures.append("encoding: \(o.text) ours=[\(o.bytes.map(hex) ?? "rejected")] llvm=[\(hex(theirs))]")
                    } else {
                        checked += 1
                    }
                }
            }
        }

        // Branches: LLVM's disassembly of our bytes must match our disassembly.
        let branches = outcomes.filter { $0.isBranch && $0.bytes != nil }
        if !branches.isEmpty {
            let input = branches.map { o in o.bytes!.map { String(format: "0x%02x", $0) }.joined(separator: " ") }.joined(separator: "\n") + "\n"
            let r = try ExternalTool.run(mc, ["-triple=x86_64", "--disassemble"], stdin: input)
            let decoded = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix(".text") }
            if decoded.count != branches.count || !r.stderr.isEmpty {
                failures.append("branch disassembly: llvm-mc decoded \(decoded.count) of \(branches.count) instructions: \(r.stderr.prefix(300))")
            } else {
                for (o, theirs) in zip(branches, decoded) {
                    // LLVM prints `callq`/`jmpq` where we print `call`/`jmp`; operands must be identical.
                    let t = EncoderOracle.canonical(String(theirs)).split(separator: " ", maxSplits: 1)
                    let u = EncoderOracle.canonical(o.disassembly ?? "").split(separator: " ", maxSplits: 1)
                    if t.count != u.count || !t[0].hasPrefix(u[0]) || t.dropFirst().first != u.dropFirst().first {
                        failures.append("branch: ours=\(o.disassembly ?? "?") [\(hex(o.bytes!))] llvm=\(theirs)")
                    } else {
                        checked += 1
                    }
                }
            }
        }

        // Our own assembler: the generated text and our disassembly must both assemble to our bytes. Lines are
        // checked in chunks; a mismatching chunk is re-assembled line by line to name the culprits.
        var asmChecked = 0
        for mode in [X86CodeMode.mode64, .mode16] {
            let group = outcomes.filter { $0.source.inst.codeMode == mode && $0.bytes != nil }
            for useDisassembly in [false, true] {
                let chunkSize = 4096
                for start in stride(from: 0, to: group.count, by: chunkSize) {
                    let chunk = group[start..<min(start + chunkSize, group.count)]
                    let lines = chunk.map { useDisassembly ? ($0.disassembly ?? $0.text) : $0.text }
                    let (bytes, errors) = ownAssemble(lines, mode: mode)
                    if errors == 0 && bytes == chunk.flatMap({ $0.bytes! }) {
                        asmChecked += chunk.count
                        continue
                    }
                    for (o, line) in zip(chunk, lines) {
                        let (b, e) = ownAssemble([line], mode: mode)
                        if e != 0 || b != o.bytes! {
                            failures.append("assembler: \(line) ours=[\(hex(o.bytes!))] assembled=[\(hex(b))] errors=\(e)")
                        } else {
                            asmChecked += 1
                        }
                    }
                }
            }
        }

        // GNU `as` (when installed): identical bytes, or one of the documented differences.
        var gnuChecked = 0, gnuDocumented = 0
        if let gas = Self.gnuAs {
            let group = outcomes.filter { $0.source.inst.codeMode == .mode64 && !$0.isBranch && $0.bytes != nil }
            let gnu = try gnuAssemble(group.map(\.text), gas: gas)
            for (o, g) in zip(group, gnu) {
                guard let g else {
                    if isDocumentedGNURejection(table[o.descriptorIndex!]) {
                        gnuDocumented += 1
                    } else {
                        failures.append("GNU as rejects: \(o.text)")
                    }
                    continue
                }
                let ours = o.bytes!
                if g == ours {
                    gnuChecked += 1
                } else if isDocumentedGNUDifference(ours: ours, gnu: g, desc: table[o.descriptorIndex!], mode: .mode64, text: o.text) {
                    gnuChecked += 1
                    gnuDocumented += 1
                } else {
                    failures.append("GNU as: \(o.text) ours=[\(hex(ours))] gnu=[\(hex(g))]")
                }
            }
        }

        let missing = table.indices.filter { !covered.contains($0) }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("ss_x86_exhaustive.txt").path
        let summary = "descriptors \(table.count), covered \(covered.count), generated \(outcomes.count), llvm-checked \(checked), assembler-checked \(asmChecked), "
            + "gnu-checked \(gnuChecked) (documented differences \(gnuDocumented)), failures \(failures.count)"
        let lines = [summary] + missing.map { "NOT COVERED: #\($0) \(table[$0].mnemonic) \(table[$0].operandFormat)" } + failures
        try lines.joined(separator: "\n").write(toFile: report, atomically: true, encoding: .utf8)
        print("x86 exhaustive sweep: \(summary) (report: \(report))")

        #expect(covered.count == table.count, Comment(rawValue: "descriptors never selected by the encoder: " + missing.prefix(30).map { "#\($0) \(table[$0].mnemonic)" }.joined(separator: ", ")))
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures (report: \(report)):\n  " + failures.prefix(40).joined(separator: "\n  ")))
    }
    @Test("SSE/AVX compare-predicate pseudo-ops (`cmpltps`, `vcmpeq_uqpd`) match llvm-mc",
          .enabled(if: M2X86ExhaustiveTests.llvmMC != nil))
    func comparePredicatePseudoOps() throws {
        let mc = try #require(Self.llvmMC)
        let predicates = ["eq", "lt", "le", "unord", "neq", "nlt", "nle", "ord",
                          "eq_uq", "nge", "ngt", "false", "neq_oq", "ge", "gt", "true",
                          "eq_os", "lt_oq", "le_oq", "unord_s", "neq_us", "nlt_uq", "nle_uq", "ord_s",
                          "eq_us", "nge_uq", "ngt_uq", "false_os", "neq_os", "ge_oq", "gt_oq", "true_us",
                          "eq_oq", "lt_os", "le_os", "unord_q", "neq_uq", "nlt_us", "nle_us", "ord_q"]
        var lines: [String] = []
        for (i, p) in predicates.enumerated() {
            for t in ["ps", "pd", "ss", "sd"] {
                // Legacy SSE encodes only predicates 0-7.
                if i < 8 { lines += ["cmp\(p)\(t) %xmm9, %xmm2", "cmp\(p)\(t) 8(%rax,%r11,4), %xmm10"] }
                lines += ["vcmp\(p)\(t) %xmm9, %xmm2, %xmm3", "vcmp\(p)\(t) (%r12), %xmm12, %xmm1"]
                if t.hasPrefix("p") { lines += ["vcmp\(p)\(t) %ymm1, %ymm8, %ymm15", "vcmp\(p)\(t) -8(%rbp), %ymm2, %ymm3"] }
            }
        }
        let llvm = try llvmAssemble(lines, mode: .mode64, mc: mc)
        var failures: [String] = []
        for (line, l) in zip(lines, llvm) {
            let (ours, errors) = ownAssemble([line], mode: .mode64)
            guard let l else {
                failures.append("llvm-mc rejects \(line)")
                continue
            }
            if errors != 0 || ours != l.bytes { failures.append("\(line): ours=[\(hex(ours))] llvm=[\(hex(l.bytes))]") }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(40).joined(separator: "\n")))
    }
}
