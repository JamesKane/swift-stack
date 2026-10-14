// Sources/SwiftStack/Encode/X86Encoder.swift
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

/// Machine code encoder for x86-64 instructions (04-backend.md §4.1).
public struct X86Encoder {
    private var code: [UInt8] = []
    private var relocations: [RelocationRecord] = []
    private var blockOffsets: [Int64: Int] = [:]
    private var jumpFixups: [(codeOffset: Int, targetBlock: Int64)] = []

    public init() {}

    private mutating func emitByte(_ b: UInt8) {
        code.append(b)
    }

    private mutating func emitInt32(_ val: Int32) {
        var v = val.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            code.append(contentsOf: bytes)
        }
    }

    private mutating func emitInt64(_ val: Int64) {
        var v = val.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            code.append(contentsOf: bytes)
        }
    }

    private func rex(w: Int = 1, r: X86Register? = nil, b: X86Register? = nil) -> UInt8 {
        var prefix: UInt8 = 0x40
        if w != 0 { prefix |= 0x08 }
        if let reg = r, reg.rawValue >= 8 { prefix |= 0x04 }
        if let base = b, base.rawValue >= 8 { prefix |= 0x01 }
        return prefix
    }

    private func modrm(mod: UInt8, reg: UInt8, rm: UInt8) -> UInt8 {
        ((mod & 3) << 6) | ((reg & 7) << 3) | (rm & 7)
    }

    private func modrm(mod: UInt8, reg: X86Register, rm: X86Register) -> UInt8 {
        modrm(mod: mod, reg: reg.rawValue, rm: rm.rawValue)
    }

    private func modrm(mod: UInt8, reg: UInt8, rm: X86Register) -> UInt8 {
        modrm(mod: mod, reg: reg, rm: rm.rawValue)
    }

    private func modrm(mod: UInt8, reg: X86Register, rm: UInt8) -> UInt8 {
        modrm(mod: mod, reg: reg.rawValue, rm: rm)
    }

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
        // push rbp
        emitByte(0x55)
        // mov rbp, rsp
        emitByte(0x48); emitByte(0x89); emitByte(0xE5)

        // Allocate total frame size = local/spill frameSize + callee-saved slots, 16-byte aligned
        let calleeSize = UInt32(usedCallee.count * 8)
        let totalAlloc = UInt32(((frameSize + calleeSize) + 15) & ~15)
        if totalAlloc > 0 {
            emitByte(0x48); emitByte(0x81); emitByte(0xEC)
            emitInt32(Int32(totalAlloc))
        }

        // Save callee-saved registers into dedicated slots below frameSize
        for (idx, reg) in usedCallee.enumerated() {
            let offset = Int32(frameSize + UInt32((idx + 1) * 8))
            emitByte(rex(w: 1, r: reg, b: .rbp))
            emitByte(0x89)
            emitByte(modrm(mod: 2, reg: reg, rm: .rbp))
            emitInt32(-offset)
        }

        // --- Body Instructions ---
        let count = Int(lir.instructionCount)
        for i in 1..<count {
            let id = LIRInstId(UInt32(i))
            let op = X86Opcode(rawValue: lir.opcodes[id]) ?? .nilOp
            let dst = Operand(raw: lir.dst[id]).physicalReg
            let s1 = Operand(raw: lir.src1[id]).physicalReg
            let s2 = Operand(raw: lir.src2[id]).physicalReg
            let imm = lir.imm[id]
            let flags = lir.flags[id]

            switch op {
            case .nilOp:
                break

            case .mov_rr:
                guard let d = dst, let s = s1 else { break }
                if d != s {
                    emitByte(rex(w: 1, r: s, b: d))
                    emitByte(0x89)
                    emitByte(modrm(mod: 3, reg: s, rm: d))
                }

            case .mov_ri:
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: nil, b: d))
                emitByte(0xB8 + (d.rawValue & 7))
                emitInt64(imm)

            case .mov_rm: // mov dst, [rbp - imm]
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: d, b: .rbp))
                emitByte(0x8B)
                emitByte(modrm(mod: 2, reg: d, rm: .rbp))
                emitInt32(-Int32(imm))

            case .mov_mr: // mov [rbp - imm], src1
                guard let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: .rbp))
                emitByte(0x89)
                emitByte(modrm(mod: 2, reg: s, rm: .rbp))
                emitInt32(-Int32(imm))

            case .mov_load: // mov dst, [src1]
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: d, b: s))
                emitByte(0x8B)
                if s == .rsp || s == .r12 {
                    emitByte(modrm(mod: 0, reg: d, rm: .rsp))
                    emitByte(0x24) // SIB
                } else if s == .rbp || s == .r13 {
                    emitByte(modrm(mod: 1, reg: d, rm: .rbp))
                    emitByte(0x00) // disp8
                } else {
                    emitByte(modrm(mod: 0, reg: d, rm: s))
                }

            case .mov_store: // mov [src1], src2 (both read operands)
                guard let ptr = s1, let val = s2 else { break }
                emitByte(rex(w: 1, r: val, b: ptr))
                emitByte(0x89)
                if ptr == .rsp || ptr == .r12 {
                    emitByte(modrm(mod: 0, reg: val, rm: .rsp))
                    emitByte(0x24)
                } else if ptr == .rbp || ptr == .r13 {
                    emitByte(modrm(mod: 1, reg: val, rm: .rbp))
                    emitByte(0x00)
                } else {
                    emitByte(modrm(mod: 0, reg: val, rm: ptr))
                }

            case .mov_stack_arg: // mov dst, [rbp + imm]
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: d, b: .rbp))
                emitByte(0x8B)
                emitByte(modrm(mod: 2, reg: d, rm: .rbp))
                emitInt32(Int32(imm))

            case .store_stack_arg: // mov [rsp + imm], src1
                guard let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: .rsp))
                emitByte(0x89)
                emitByte(modrm(mod: 2, reg: s, rm: .rsp))
                emitByte(0x24) // SIB
                emitInt32(Int32(imm))

            case .sub_rsp:
                emitByte(0x48); emitByte(0x81); emitByte(0xEC)
                emitInt32(Int32(imm))

            case .add_rsp:
                emitByte(0x48); emitByte(0x81); emitByte(0xC4)
                emitInt32(Int32(imm))

            case .lea_stack: // lea dst, [rbp - imm]
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: d, b: .rbp))
                emitByte(0x8D)
                emitByte(modrm(mod: 2, reg: d, rm: .rbp))
                emitInt32(-Int32(imm))

            case .lea_string: // lea dst, [rip + str_offset]
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: d, b: nil))
                emitByte(0x8D)
                emitByte(modrm(mod: 0, reg: d.rawValue, rm: 5)) // RIP-relative
                relocations.append(RelocationRecord(
                    offset: code.count,
                    symbol: ".rodata",
                    isStringRef: true,
                    stringIndex: Int(imm)
                ))
                emitInt32(0) // patched during linking

            case .add_rr:
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: d))
                emitByte(0x01)
                emitByte(modrm(mod: 3, reg: s, rm: d))

            case .sub_rr:
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: d))
                emitByte(0x29)
                emitByte(modrm(mod: 3, reg: s, rm: d))

            case .imul_rr:
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: d, b: s))
                emitByte(0x0F); emitByte(0xAF)
                emitByte(modrm(mod: 3, reg: d, rm: s))

            case .idiv_r:
                guard let s = s1 else { break }
                // cqo (sign-extend rax into rdx:rax)
                emitByte(0x48); emitByte(0x99)
                emitByte(rex(w: 1, r: nil, b: s))
                emitByte(0xF7)
                emitByte(modrm(mod: 3, reg: 7, rm: s))

            case .and_rr:
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: d))
                emitByte(0x21)
                emitByte(modrm(mod: 3, reg: s, rm: d))

            case .or_rr:
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: d))
                emitByte(0x09)
                emitByte(modrm(mod: 3, reg: s, rm: d))

            case .xor_rr:
                guard let d = dst, let s = s1 else { break }
                emitByte(rex(w: 1, r: s, b: d))
                emitByte(0x31)
                emitByte(modrm(mod: 3, reg: s, rm: d))

            case .shl_rr:
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: nil, b: d))
                emitByte(0xD3)
                emitByte(modrm(mod: 3, reg: 4, rm: d))

            case .sar_rr:
                guard let d = dst else { break }
                emitByte(rex(w: 1, r: nil, b: d))
                emitByte(0xD3)
                emitByte(modrm(mod: 3, reg: 7, rm: d))

            case .cmp_rr:
                guard let s1 = s1, let s2 = s2 else { break }
                emitByte(rex(w: 1, r: s2, b: s1))
                emitByte(0x39)
                emitByte(modrm(mod: 3, reg: s2, rm: s1))

            case .cmp_ri:
                guard let s1 = s1 else { break }
                emitByte(rex(w: 1, r: nil, b: s1))
                emitByte(0x81)
                emitByte(modrm(mod: 3, reg: 7, rm: s1))
                emitInt32(Int32(truncatingIfNeeded: imm))

            case .setcc:
                guard let d = dst else { break }
                let condCode = ConditionCode(rawValue: flags) ?? .eq
                var setccOp: UInt8 = 0x94 // sete
                switch condCode {
                case .eq: setccOp = 0x94
                case .ne: setccOp = 0x95
                case .lt: setccOp = 0x9C
                case .le: setccOp = 0x9E
                case .gt: setccOp = 0x9F
                case .ge: setccOp = 0x9D
                }
                emitByte(0x0F); emitByte(setccOp); emitByte(0xC0) // setcc al
                // movzx eax, al
                emitByte(0x0F); emitByte(0xB6); emitByte(0xC0)
                if d != .rax {
                    emitByte(rex(w: 1, r: .rax, b: d))
                    emitByte(0x89)
                    emitByte(modrm(mod: 3, reg: .rax, rm: d))
                }

            case .jmp:
                emitByte(0xE9)
                jumpFixups.append((codeOffset: code.count, targetBlock: imm))
                emitInt32(0) // patched below

            case .jcc:
                let condCode = ConditionCode(rawValue: flags) ?? .ne
                var jccOp: UInt8 = 0x85 // jne
                switch condCode {
                case .eq: jccOp = 0x84
                case .ne: jccOp = 0x85
                case .lt: jccOp = 0x8C
                case .le: jccOp = 0x8E
                case .gt: jccOp = 0x8F
                case .ge: jccOp = 0x8D
                }
                emitByte(0x0F); emitByte(jccOp)
                jumpFixups.append((codeOffset: code.count, targetBlock: imm))
                emitInt32(0) // patched below

            case .call:
                emitByte(0xE8)
                let calleeId = UInt32(imm & 0xFFFF)
                guard let calleeName = calleeNames[calleeId] else {
                    fatalError("Unknown callee ID \(calleeId) in function \(fnName). Known: \(calleeNames)")
                }
                relocations.append(RelocationRecord(
                    offset: code.count,
                    symbol: calleeName,
                    isStringRef: false,
                    stringIndex: 0
                ))
                emitInt32(0) // patched during linking

            case .ret:
                emitEpilogue(frameSize: frameSize, usedCallee: usedCallee)

            case .push_r:
                if let s = s1 { emitPush(s) }

            case .pop_r:
                if let d = dst { emitPop(d) }

            case .label:
                blockOffsets[imm] = code.count

            case .syscall:
                emitByte(0x0F); emitByte(0x05)

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
            patchInt32(at: fixup.codeOffset, value: rel32)
        }

        return EncodedFunction(name: fnName, code: code, relocations: relocations)
    }

    private mutating func patchInt32(at offset: Int, value: Int32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            for (i, b) in bytes.enumerated() {
                code[offset + i] = b
            }
        }
    }

    private mutating func emitEpilogue(frameSize: UInt32, usedCallee: [X86Register]) {
        for (idx, reg) in usedCallee.enumerated() {
            let offset = Int32(frameSize + UInt32((idx + 1) * 8))
            emitByte(rex(w: 1, r: reg, b: .rbp))
            emitByte(0x8B)
            emitByte(modrm(mod: 2, reg: reg, rm: .rbp))
            emitInt32(-offset)
        }
        emitByte(0xC9) // leave (mov rsp, rbp; pop rbp)
        emitByte(0xC3) // ret
    }

    private mutating func emitPush(_ reg: X86Register) {
        if reg.rawValue < 8 {
            emitByte(0x50 + reg.rawValue)
        } else {
            emitByte(0x41)
            emitByte(0x50 + (reg.rawValue - 8))
        }
    }

    private mutating func emitPop(_ reg: X86Register) {
        if reg.rawValue < 8 {
            emitByte(0x58 + reg.rawValue)
        } else {
            emitByte(0x41)
            emitByte(0x58 + (reg.rawValue - 8))
        }
    }
}
