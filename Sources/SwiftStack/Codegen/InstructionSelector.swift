// Sources/SwiftStack/Codegen/InstructionSelector.swift
import Foundation

/// Lowers AIR instructions to target-specific x86-64 LIR instructions (04-backend.md §4.4).
public struct InstructionSelector {
    private var vregCounter: UInt32 = 1

    public init() {}

    private mutating func nextVreg() -> Operand {
        let v = vregCounter
        vregCounter += 1
        return Operand.vreg(v)
    }

    public mutating func select(function airFn: borrowing SliceAIRFunction) -> LIRFunctionSoA {
        var lir = LIRFunctionSoA(name: airFn.name, stackFrameSize: UInt32(max(0, airFn.stackFrameSize)))
        var airToLirVreg: [InstId: Operand] = [:]

        // Pre-scan alloca instructions so load/store can fold them directly
        var allocaOffsets: [InstId: Int64] = [:]
        for i in 1..<airFn.instructionCount {
            let id = InstId(i)
            if SliceAIROpcode(rawValue: airFn.opcode[id]) == .alloca {
                allocaOffsets[id] = Int64(airFn.aux[id])
            }
        }

        // Emit instructions
        let instCount = airFn.instructionCount
        var currentBlock: UInt32 = 0
        for i in 1..<instCount {
            let id = InstId(i)
            let blk = airFn.instBlock[id]
            if blk != currentBlock && blk != 0 {
                currentBlock = blk
                lir.append(opcode: .label, imm: Int64(currentBlock))
            }

            let op = SliceAIROpcode(rawValue: airFn.opcode[id]) ?? .nilOp
            let v0 = ValueId(airFn.op0[id])
            let v1 = ValueId(airFn.op1[id])
            let aux = airFn.aux[id]

            switch op {
            case .nilOp:
                break

            case .iconst:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let immVal = Int64(Int32(bitPattern: aux))
                lir.append(opcode: .mov_ri, dst: dst, imm: immVal)

            case .iconst64:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let high = UInt64(v0.rawIndex)
                let low = UInt64(aux)
                let immVal = Int64(bitPattern: (high << 32) | low)
                lir.append(opcode: .mov_ri, dst: dst, imm: immVal)

            case .stringConst:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                lir.append(opcode: .lea_string, dst: dst, imm: Int64(aux))

            case .alloca:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                lir.append(opcode: .lea_stack, dst: dst, imm: Int64(aux))

            case .load:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let ptrInst = InstId(v0.index)
                if let off = allocaOffsets[ptrInst] {
                    // Folded alloca load: mov dst, [rbp - off]
                    lir.append(opcode: .mov_rm, dst: dst, imm: off)
                } else {
                    let ptrReg = resolveOperand(v0, airToLirVreg: airToLirVreg)
                    lir.append(opcode: .mov_load, dst: dst, src1: ptrReg)
                }

            case .store:
                let valReg = resolveOperand(v0, airToLirVreg: airToLirVreg)
                let ptrInst = InstId(v1.index)
                if let off = allocaOffsets[ptrInst] {
                    // Folded alloca store: mov [rbp - off], val
                    lir.append(opcode: .mov_mr, src1: valReg, imm: off)
                } else {
                    let ptrReg = resolveOperand(v1, airToLirVreg: airToLirVreg)
                    lir.append(opcode: .mov_store, src1: ptrReg, src2: valReg)
                }

            case .add, .sub, .mul, .band, .bor, .bxor:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let r0 = resolveOperand(v0, airToLirVreg: airToLirVreg)
                let r1 = resolveOperand(v1, airToLirVreg: airToLirVreg)

                lir.append(opcode: .mov_rr, dst: dst, src1: r0)
                let lirOp: X86Opcode
                switch op {
                case .add: lirOp = .add_rr
                case .sub: lirOp = .sub_rr
                case .mul: lirOp = .imul_rr
                case .band: lirOp = .and_rr
                case .bor: lirOp = .or_rr
                case .bxor: lirOp = .xor_rr
                default: lirOp = .add_rr
                }
                lir.append(opcode: lirOp, dst: dst, src1: r1)

            case .sdiv, .srem:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let r0 = resolveOperand(v0, airToLirVreg: airToLirVreg)
                let r1 = resolveOperand(v1, airToLirVreg: airToLirVreg)

                // SysV: dividend in rax, divisor in r1, quotient in rax, remainder in rdx
                lir.append(opcode: .mov_rr, dst: .preg(.rax), src1: r0)
                lir.append(opcode: .idiv_r, src1: r1)
                if op == .sdiv {
                    lir.append(opcode: .mov_rr, dst: dst, src1: .preg(.rax))
                } else {
                    lir.append(opcode: .mov_rr, dst: dst, src1: .preg(.rdx))
                }

            case .shl, .shr:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let r0 = resolveOperand(v0, airToLirVreg: airToLirVreg)
                let r1 = resolveOperand(v1, airToLirVreg: airToLirVreg)

                lir.append(opcode: .mov_rr, dst: .preg(.rcx), src1: r1)
                lir.append(opcode: .mov_rr, dst: dst, src1: r0)
                let lirOp: X86Opcode = (op == .shl) ? .shl_rr : .sar_rr
                lir.append(opcode: lirOp, dst: dst, src1: .preg(.rcx))

            case .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge:
                let dst = nextVreg()
                airToLirVreg[id] = dst
                let r0 = resolveOperand(v0, airToLirVreg: airToLirVreg)
                let r1 = resolveOperand(v1, airToLirVreg: airToLirVreg)

                lir.append(opcode: .cmp_rr, src1: r0, src2: r1)
                let cond: ConditionCode
                switch op {
                case .icmp_eq: cond = .eq
                case .icmp_ne: cond = .ne
                case .icmp_slt: cond = .lt
                case .icmp_sle: cond = .le
                case .icmp_sgt: cond = .gt
                case .icmp_sge: cond = .ge
                default: cond = .eq
                }
                lir.append(opcode: .setcc, dst: dst, flags: cond.rawValue)

            case .br:
                lir.append(opcode: .jmp, imm: Int64(aux))

            case .cond_br:
                let condReg = resolveOperand(v0, airToLirVreg: airToLirVreg)
                let thenBlock = aux
                let elseBlock = v1.index
                lir.append(opcode: .cmp_ri, src1: condReg, imm: 0)
                lir.append(opcode: .jcc, imm: Int64(thenBlock), flags: ConditionCode.ne.rawValue)
                lir.append(opcode: .jmp, imm: Int64(elseBlock))

            case .ret:
                if v0.isValid {
                    let retVal = resolveOperand(v0, airToLirVreg: airToLirVreg)
                    lir.append(opcode: .mov_rr, dst: .preg(.rax), src1: retVal)
                }
                lir.append(opcode: .ret)

            case .call:
                let argCount = Int((aux >> 16) & 0xFFFF)
                let extraStart = Int(v0.rawIndex)
                let calleeId = Int64(aux & 0xFFFF)

                // Pass first 6 args in rdi, rsi, rdx, rcx, r8, r9
                let argRegs: [X86Register] = [.rdi, .rsi, .rdx, .rcx, .r8, .r9]
                for argIdx in 0..<min(argCount, argRegs.count) {
                    let extraIdx = ExtraId(UInt32(extraStart + argIdx))
                    let argVal = ValueId(airFn.extra[extraIdx])
                    let argReg = resolveOperand(argVal, airToLirVreg: airToLirVreg)
                    lir.append(opcode: .mov_rr, dst: .preg(argRegs[argIdx]), src1: argReg)
                }

                // If argCount > 6, pass on stack (16-byte aligned)
                var stackSpace: Int64 = 0
                if argCount > argRegs.count {
                    let stackArgCount = argCount - argRegs.count
                    stackSpace = Int64(((stackArgCount * 8) + 15) & ~15)
                    lir.append(opcode: .sub_rsp, imm: stackSpace)
                    for i in 0..<stackArgCount {
                        let argIdx = argRegs.count + i
                        let extraIdx = ExtraId(UInt32(extraStart + argIdx))
                        let argVal = ValueId(airFn.extra[extraIdx])
                        let argReg = resolveOperand(argVal, airToLirVreg: airToLirVreg)
                        lir.append(opcode: .store_stack_arg, src1: argReg, imm: Int64(i * 8))
                    }
                }

                lir.append(opcode: .call, imm: calleeId)
                if stackSpace > 0 {
                    lir.append(opcode: .add_rsp, imm: stackSpace)
                }
                let dst = nextVreg()
                airToLirVreg[id] = dst
                lir.append(opcode: .mov_rr, dst: dst, src1: .preg(.rax))

            case .param:
                let paramIdx = Int(aux)
                let argRegs: [X86Register] = [.rdi, .rsi, .rdx, .rcx, .r8, .r9]
                let dst = nextVreg()
                airToLirVreg[id] = dst
                if paramIdx < argRegs.count {
                    lir.append(opcode: .mov_rr, dst: dst, src1: .preg(argRegs[paramIdx]))
                } else {
                    let offset = Int64(16 + (paramIdx - argRegs.count) * 8)
                    lir.append(opcode: .mov_stack_arg, dst: dst, imm: offset)
                }
            }
        }

        return lir
    }

    private func resolveOperand(_ val: ValueId, airToLirVreg: [InstId: Operand]) -> Operand {
        guard val.isValid else { return .none }
        if val.tag == 0 { // instResult
            let inst = InstId(val.index)
            return airToLirVreg[inst] ?? .none
        }
        return .none
    }
}
