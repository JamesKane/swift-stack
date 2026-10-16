// Sources/SwiftStack/Codegen/X86/X86FrameLowering.swift
//
// Frame layout (04-backend.md §4.6): every function keeps the frame pointer. From the frame pointer down: the saved
// callee-saved registers, then the stack slots (allocas, spill slots, temporaries), with the stack pointer 16-byte
// aligned below them. Calls that pass arguments in memory move the stack pointer around themselves, so dynamic
// allocations need no special treatment. No red zone is used.

import Foundation

struct X86FrameLowering {
    var issues: [String] = []

    /// Lays out the frame, resolves stack slot operands to frame-pointer offsets, and expands the entry, return and
    /// call-frame pseudo-instructions.
    mutating func run(_ f: inout LIRFunction) {
        let saved = f.usedCalleeSaved
        let savedBytes = 8 * saved.count
        var offset = savedBytes
        for s in 1..<f.slots.count where !f.slots[s].isFixed {
            let slot = f.slots[s]
            if slot.alignment > 16 {
                issues.append("\(f.name): a stack object aligned to \(slot.alignment) bytes (above the frame's 16)")
            }
            let a = min(slot.alignment, 16)
            offset = (offset + slot.size + a - 1) / a * a
            f.slots[s].offset = -offset
        }
        // The stack pointer below the slots, 16-byte aligned (the return address and saved frame pointer make 16)
        let frameBytes = (offset + 15) / 16 * 16 - savedBytes

        var operands: [LIROperand] = []
        operands.reserveCapacity(f.operands.count + 64)
        for b in f.blocks.indices {
            var out: [LIRInst] = []
            func add(_ op: LIROp, _ size: Int, _ ops: [LIROperand]) {
                out.append(LIRInst(op: op, size: size, firstOperand: UInt32(operands.count), operandCount: ops.count))
                operands.append(contentsOf: ops)
            }
            let rsp = LIROperand.def(.physical(.rsp), 8)
            for inst in f.blocks[b].insts {
                switch inst.op {
                case .entry:
                    add(.push, 8, [.use(.physical(.rbp), 8)])
                    add(.cfi, 0, [.imm(0), .imm(0), .imm(16)])
                    add(.cfi, 0, [.imm(1), .imm(Int64(PhysReg.rbp.rawValue)), .imm(-16)])
                    add(.mov, 8, [.def(.physical(.rbp), 8), .use(.physical(.rsp), 8)])
                    add(.cfi, 0, [.imm(2), .imm(Int64(PhysReg.rbp.rawValue)), .imm(0)])
                    for (k, r) in saved.enumerated() {
                        add(.push, 8, [.use(.physical(r), 8)])
                        add(.cfi, 0, [.imm(1), .imm(Int64(r.rawValue)), .imm(Int64(-24 - 8 * k))])
                    }
                    if frameBytes > 0 { add(.sub, 8, [rsp, .imm(Int64(frameBytes))]) }
                    continue
                case .ret:
                    if saved.isEmpty {
                        add(.mov, 8, [rsp, .use(.physical(.rbp), 8)])
                    } else {
                        add(.lea, 8, [rsp, LIRAddress(base: .physical(.rbp), disp: Int64(-savedBytes)).operand(size: 8)])
                        for r in saved.reversed() { add(.pop, 8, [.def(.physical(r), 8)]) }
                    }
                    add(.pop, 8, [.def(.physical(.rbp), 8)])
                case .callFrameSetup:
                    add(.sub, 8, [rsp, .imm(f.operands[Int(inst.firstOperand)].value)])
                    continue
                case .callFrameDestroy:
                    add(.add, 8, [rsp, .imm(f.operands[Int(inst.firstOperand)].value)])
                    continue
                default:
                    break
                }
                var ops = Array(f.operands[inst.operandRange])
                for j in ops.indices where ops[j].kind == .mem && ops[j].slot != 0 && !ops[j].isBlockAddress {
                    let slot = f.slots[Int(ops[j].slot)]
                    if !ops[j].reg.isNone { issues.append("\(f.name): a stack slot operand with a base register") }
                    ops[j].reg = .physical(.rbp)
                    ops[j].value += Int64(slot.offset)
                    ops[j].slot = 0
                }
                var copy = inst
                copy.firstOperand = UInt32(operands.count)
                out.append(copy)
                operands.append(contentsOf: ops)
            }
            f.blocks[b].insts = out
        }
        f.operands = operands
        f.frameSize = frameBytes + savedBytes
    }
}
