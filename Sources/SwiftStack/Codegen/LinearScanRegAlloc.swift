// Sources/SwiftStack/Codegen/LinearScanRegAlloc.swift
import Foundation

public struct AllocatedFunction: ~Copyable {
    public var lir: LIRFunctionSoA
    public var stackFrameSize: UInt32
    public var usedCalleeSaved: [X86Register]
}

struct LiveInterval {
    let vreg: UInt32
    var start: Int
    var end: Int
}

/// A linear scan register allocator for x86-64 LIR (04-backend.md §4.5).
public struct LinearScanRegAlloc {
    private let availablePool: [X86Register] = [.r10, .r11, .rbx, .r12, .r13, .r14, .r15]

    public init() {}

    public func allocate(function inLir: consuming LIRFunctionSoA) -> AllocatedFunction {
        let lir = inLir
        let count = Int(lir.instructionCount)

        // 1. Compute live ranges for each virtual register
        var intervals: [UInt32: LiveInterval] = [:]
        for i in 1..<count {
            let id = LIRInstId(UInt32(i))
            let dst = Operand(raw: lir.dst[id])
            let s1 = Operand(raw: lir.src1[id])
            let s2 = Operand(raw: lir.src2[id])

            for op in [dst, s1, s2] where op.isVirtual {
                let v = op.regIndex
                if var cur = intervals[v] {
                    cur.end = i
                    intervals[v] = cur
                } else {
                    intervals[v] = LiveInterval(vreg: v, start: i, end: i)
                }
            }
        }

        let sortedIntervals = intervals.values.sorted { $0.start < $1.start }

        // 2. Linear scan allocation
        var freePool = availablePool
        var active: [(interval: LiveInterval, reg: X86Register)] = []
        var regMap: [UInt32: X86Register] = [:]
        var spillMap: [UInt32: Int64] = [:]
        var spillOffset: Int64 = Int64(lir.stackFrameSize)
        var usedCalleeSaved: Set<X86Register> = []

        let calleeSavedSet: Set<X86Register> = [.rbx, .r12, .r13, .r14, .r15]

        var callSites: [Int] = []
        for i in 1..<count {
            let id = LIRInstId(UInt32(i))
            if X86Opcode(rawValue: lir.opcodes[id]) == .call {
                callSites.append(i)
            }
        }

        for cur in sortedIntervals {
            // Expire old intervals
            active.removeAll { item in
                if item.interval.end < cur.start {
                    freePool.append(item.reg)
                    return true
                }
                return false
            }

            let crossesCall = callSites.contains { $0 >= cur.start && $0 <= cur.end }
            var chosenRegIndex: Int? = nil
            if crossesCall {
                // Only callee-saved registers can survive across calls
                if let idx = freePool.lastIndex(where: { calleeSavedSet.contains($0) }) {
                    chosenRegIndex = idx
                }
            } else {
                chosenRegIndex = freePool.indices.last
            }

            if let idx = chosenRegIndex {
                let reg = freePool.remove(at: idx)
                regMap[cur.vreg] = reg
                active.append((interval: cur, reg: reg))
                if calleeSavedSet.contains(reg) {
                    usedCalleeSaved.insert(reg)
                }
            } else {
                // Spill to stack slot
                spillOffset += 8
                spillMap[cur.vreg] = spillOffset
            }
        }

        // 3. Rewrite LIR instructions with physical registers or spill loads/stores
        var newLir = LIRFunctionSoA(name: lir.name, stackFrameSize: UInt32(spillOffset))

        for i in 1..<count {
            let id = LIRInstId(UInt32(i))
            let op = X86Opcode(rawValue: lir.opcodes[id]) ?? .nilOp
            let dst = Operand(raw: lir.dst[id])
            let s1 = Operand(raw: lir.src1[id])
            let s2 = Operand(raw: lir.src2[id])
            let imm = lir.imm[id]
            let flags = lir.flags[id]
            let extra = lir.extra[id]

            var finalDst = dst
            var finalS1 = s1
            var finalS2 = s2

            // Handle src1 spill load if needed
            if s1.isVirtual {
                if let preg = regMap[s1.regIndex] {
                    finalS1 = .preg(preg)
                } else if let off = spillMap[s1.regIndex] {
                    finalS1 = .preg(.rax) // temp scratch
                    newLir.append(opcode: .mov_rm, dst: .preg(.rax), imm: off)
                }
            }

            // Handle src2 spill load if needed
            if s2.isVirtual {
                if let preg = regMap[s2.regIndex] {
                    finalS2 = .preg(preg)
                } else if let off = spillMap[s2.regIndex] {
                    finalS2 = .preg(.rdx) // temp scratch
                    newLir.append(opcode: .mov_rm, dst: .preg(.rdx), imm: off)
                }
            }

            var needsSpillStore: Int64? = nil
            if dst.isVirtual {
                if let preg = regMap[dst.regIndex] {
                    finalDst = .preg(preg)
                } else if let off = spillMap[dst.regIndex] {
                    finalDst = .preg(.rax)
                    needsSpillStore = off
                }
            }

            newLir.append(
                opcode: op,
                dst: finalDst,
                src1: finalS1,
                src2: finalS2,
                imm: imm,
                flags: flags,
                extra: extra
            )

            // Emit spill store if dst spilled
            if let off = needsSpillStore {
                newLir.append(opcode: .mov_mr, src1: .preg(.rax), imm: off)
            }
        }

        let alignedFrame = UInt32((spillOffset + 15) & ~15)
        return AllocatedFunction(
            lir: newLir,
            stackFrameSize: alignedFrame,
            usedCalleeSaved: usedCalleeSaved.sorted { $0.rawValue < $1.rawValue }
        )
    }
}
