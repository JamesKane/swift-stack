// Sources/SwiftStack/Codegen/X86CodeEmitter.swift
import Foundation

public struct RelocationRecord {
    public let offset: Int // offset in code buffer
    public let symbol: String
    public let isStringRef: Bool
    public let stringIndex: Int
}

public struct EncodedFunction {
    public let name: String
    public let code: [UInt8]
    public let relocations: [RelocationRecord]
}

/// Lowers register-allocated LIR to x86-64 machine code (04-backend.md §4.1). Every instruction is
/// encoded by the shared `X86TableEncoder`, the same tables the assembler and disassembler use.
public struct X86CodeEmitter {
    private let encoder = X86TableEncoder()
    private var code: [UInt8] = []
    private var relocations: [RelocationRecord] = []
    private var blockOffsets: [Int64: Int] = [:]
    private var jumpFixups: [(codeOffset: Int, targetBlock: Int64)] = []

    public init() {}

    public mutating func encode(
        function allocFn: consuming AllocatedFunction,
        stringTable: [String: Int],
        calleeNames: [UInt32: String]
    ) -> EncodedFunction {
        code.removeAll(keepingCapacity: true)
        relocations.removeAll(keepingCapacity: true)
        blockOffsets.removeAll(keepingCapacity: true)
        jumpFixups.removeAll(keepingCapacity: true)

        let fnName = allocFn.lir.name
        let frameSize = allocFn.stackFrameSize
        let usedCallee = allocFn.usedCalleeSaved
        let lir = allocFn.lir

        // --- Prologue ---
        emit("push", .reg(.rbp))
        emit("mov", .reg(.rsp), .reg(.rbp))
        // Allocate total frame size = local/spill frameSize + callee-saved slots, 16-byte aligned
        let calleeSize = UInt32(usedCallee.count * 8)
        let totalAlloc = Int64(((frameSize + calleeSize) + 15) & ~15)
        if totalAlloc > 0 {
            emit("sub", .imm(totalAlloc), .reg(.rsp))
        }
        // Save callee-saved registers into dedicated slots below frameSize
        for (idx, reg) in usedCallee.enumerated() {
            emit("mov", .reg(Self.gpr(reg)), frameSlot(-Int64(frameSize) - Int64((idx + 1) * 8)))
        }

        // --- Body Instructions ---
        let count = Int(lir.instructionCount)
        for i in 1..<count {
            let id = LIRInstId(UInt32(i))
            let op = X86Opcode(rawValue: lir.opcodes[id]) ?? .nilOp
            let dst = Operand(raw: lir.dst[id]).physicalReg.map(Self.gpr)
            let s1 = Operand(raw: lir.src1[id]).physicalReg.map(Self.gpr)
            let s2 = Operand(raw: lir.src2[id]).physicalReg.map(Self.gpr)
            let imm = lir.imm[id]
            let flags = lir.flags[id]

            switch op {
            case .nilOp:
                break

            case .mov_rr:
                guard let d = dst, let s = s1, d != s else { break }
                emit("mov", .reg(s), .reg(d))

            case .mov_ri:
                guard let d = dst else { break }
                emit("mov", .imm(imm), .reg(d))

            case .mov_rm: // mov dst, [rbp - imm]
                guard let d = dst else { break }
                emit("mov", frameSlot(-imm), .reg(d))

            case .mov_mr: // mov [rbp - imm], src1
                guard let s = s1 else { break }
                emit("mov", .reg(s), frameSlot(-imm))

            case .mov_load: // mov dst, [src1]
                guard let d = dst, let s = s1 else { break }
                emit("mov", .mem(.baseDisp(s)), .reg(d))

            case .mov_store: // mov [src1], src2 (both read operands)
                guard let ptr = s1, let val = s2 else { break }
                emit("mov", .reg(val), .mem(.baseDisp(ptr)))

            case .mov_stack_arg: // mov dst, [rbp + imm]
                guard let d = dst else { break }
                emit("mov", frameSlot(imm), .reg(d))

            case .store_stack_arg: // mov [rsp + imm], src1
                guard let s = s1 else { break }
                emit("mov", .reg(s), .mem(.baseDisp(.rsp, disp: imm)))

            case .sub_rsp:
                emit("sub", .imm(imm), .reg(.rsp))

            case .add_rsp:
                emit("add", .imm(imm), .reg(.rsp))

            case .lea_stack: // lea dst, [rbp - imm]
                guard let d = dst else { break }
                emit("lea", frameSlot(-imm), .reg(d))

            case .lea_string: // lea dst, [rip + str_offset]
                guard let d = dst else { break }
                let start = code.count
                let enc = emit("lea", .mem(.ripRelative(symbol: ".rodata")), .reg(d))
                for r in enc.relocations {
                    relocations.append(RelocationRecord(offset: start + r.offset, symbol: ".rodata", isStringRef: true, stringIndex: Int(imm)))
                }

            case .add_rr:
                guard let d = dst, let s = s1 else { break }
                emit("add", .reg(s), .reg(d))

            case .sub_rr:
                guard let d = dst, let s = s1 else { break }
                emit("sub", .reg(s), .reg(d))

            case .imul_rr:
                guard let d = dst, let s = s1 else { break }
                emit("imul", .reg(s), .reg(d))

            case .idiv_r:
                guard let s = s1 else { break }
                emit("cqo")
                emit("idiv", .reg(s))

            case .and_rr:
                guard let d = dst, let s = s1 else { break }
                emit("and", .reg(s), .reg(d))

            case .or_rr:
                guard let d = dst, let s = s1 else { break }
                emit("or", .reg(s), .reg(d))

            case .xor_rr:
                guard let d = dst, let s = s1 else { break }
                emit("xor", .reg(s), .reg(d))

            case .shl_rr: // count is pinned to %cl by instruction selection
                guard let d = dst else { break }
                emit("shl", .reg(.cl), .reg(d))

            case .sar_rr:
                guard let d = dst else { break }
                emit("sar", .reg(.cl), .reg(d))

            case .cmp_rr:
                guard let a = s1, let b = s2 else { break }
                emit("cmp", .reg(b), .reg(a))

            case .cmp_ri:
                guard let a = s1 else { break }
                emit("cmp", .imm(Int64(Int32(truncatingIfNeeded: imm))), .reg(a))

            case .setcc:
                // set<cc> writes the destination's low byte directly, so no other register is clobbered
                guard let d = dst else { break }
                let cond = Self.conditionSuffix(ConditionCode(rawValue: flags) ?? .eq)
                let hw = d.rawValue
                emit("set" + cond, .reg(X86Reg.gpr8(hw)))
                emit("movzbl", .reg(X86Reg.gpr8(hw)), .reg(X86Reg.gpr32(hw)))

            case .jmp:
                emitBranch("jmp", targetBlock: imm)

            case .jcc:
                emitBranch("j" + Self.conditionSuffix(ConditionCode(rawValue: flags) ?? .ne), targetBlock: imm)

            case .call:
                let calleeId = UInt32(imm & 0xFFFF)
                guard let calleeName = calleeNames[calleeId] else {
                    fatalError("Unknown callee ID \(calleeId) in function \(fnName). Known: \(calleeNames)")
                }
                let start = code.count
                let enc = emit("call", .relTarget(0, symbol: calleeName))
                for r in enc.relocations {
                    relocations.append(RelocationRecord(offset: start + r.offset, symbol: calleeName, isStringRef: false, stringIndex: 0))
                }

            case .ret:
                emitEpilogue(frameSize: frameSize, usedCallee: usedCallee)

            case .push_r:
                if let s = s1 { emit("push", .reg(s)) }

            case .pop_r:
                if let d = dst { emit("pop", .reg(d)) }

            case .label:
                blockOffsets[imm] = code.count

            case .syscall:
                emit("syscall")

            default:
                break
            }
        }

        // Always end function with epilogue if not ended
        if code.last != 0xC3 {
            emitEpilogue(frameSize: frameSize, usedCallee: usedCallee)
        }

        // Patch jump displacements
        for fixup in jumpFixups {
            guard let target = blockOffsets[fixup.targetBlock] else {
                fatalError("Target block \(fixup.targetBlock) not found in function \(fnName). Known blocks: \(blockOffsets.keys.sorted())")
            }
            let rel32 = Int32(target - (fixup.codeOffset + 4))
            withUnsafeBytes(of: rel32.littleEndian) { bytes in
                for (i, b) in bytes.enumerated() { code[fixup.codeOffset + i] = b }
            }
        }

        return EncodedFunction(name: fnName, code: code, relocations: relocations)
    }

    /// Encodes one instruction (AT&T operand order; size inferred from register operands) and appends it.
    @discardableResult
    private mutating func emit(_ mnemonic: String, _ operands: X86Operand...) -> X86EncodedInstruction {
        let inst = X86Instruction(mnemonic: mnemonic, operands: operands)
        do {
            let enc = try encoder.encode(inst)
            code.append(contentsOf: enc.bytes)
            return enc
        } catch {
            fatalError("x86-64 code emission failed for `\(inst.attString)`: \(error)")
        }
    }

    /// Emits a rel32 branch to a block of this function; the displacement is patched once all blocks are placed.
    private mutating func emitBranch(_ mnemonic: String, targetBlock: Int64) {
        let start = code.count
        let enc = emit(mnemonic, .relTarget(0, symbol: ".Lbb\(targetBlock)"))
        guard let reloc = enc.relocations.first else {
            fatalError("x86-64 code emission: `\(mnemonic)` to a block produced no rel32 field")
        }
        jumpFixups.append((codeOffset: start + reloc.offset, targetBlock: targetBlock))
    }

    private mutating func emitEpilogue(frameSize: UInt32, usedCallee: [X86Register]) {
        for (idx, reg) in usedCallee.enumerated() {
            emit("mov", frameSlot(-Int64(frameSize) - Int64((idx + 1) * 8)), .reg(Self.gpr(reg)))
        }
        emit("leave")
        emit("ret")
    }

    private func frameSlot(_ disp: Int64) -> X86Operand {
        .mem(.baseDisp(.rbp, disp: disp))
    }

    private static func gpr(_ reg: X86Register) -> X86Reg {
        X86Reg.gpr64(reg.rawValue)
    }

    private static func conditionSuffix(_ cond: ConditionCode) -> String {
        switch cond {
        case .eq: return "e"
        case .ne: return "ne"
        case .lt: return "l"
        case .le: return "le"
        case .gt: return "g"
        case .ge: return "ge"
        }
    }
}
