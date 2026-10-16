// Sources/SwiftStack/Codegen/X86/X86ISelControl.swift
//
// Instruction selection of `switch` (04 §4.8.1: jump tables for dense case ranges, a binary tree of compares
// otherwise) and of atomic operations.

import Foundation

extension X86FunctionISel {
    // MARK: - Switch

    func lowerSwitch(_ i: InstId) {
        let items = list(i)
        let t = ty(o0(i))
        guard t.width <= 64 else {
            report("switch on \(t)")
            emit(.ud2, 0)
            return
        }
        let defaultBlock = blockOf[Int(items[0])]
        var cases: [(value: Int64, block: Int)] = []
        let constants = box.function.constants
        for k in stride(from: 1, to: items.count - 1, by: 2) {
            let c = ValueId(items[k])
            let v = c.valueTag == .constant ? constants.int64(c.index, signed: true) : 0
            cases.append((v, blockOf[Int(items[k + 1])]))
        }
        cases.sort { $0.value < $1.value }
        // The value sign-extended to 64 bits, so that case values compare as signed 64-bit numbers
        let x = t.width == 64 ? gpr(o0(i)) : extendTo64(gpr(o0(i)), from: t.width, signed: true)
        switchTree(x, cases[...], defaultBlock)
    }

    /// The compares (or table) choosing among `cases` (sorted), ending the current block.
    func switchTree(_ x: LIRReg, _ cases: ArraySlice<(value: Int64, block: Int)>, _ defaultBlock: Int) {
        guard let first = cases.first, let last = cases.last else {
            jump(defaultBlock)
            return
        }
        let range = UInt64(bitPattern: last.value &- first.value) &+ 1
        if cases.count >= 4 && range <= 1 << 16 && Double(cases.count) / Double(range) >= 0.4 {
            jumpTable(x, cases, defaultBlock, range: Int(range))
            return
        }
        func compare(_ v: Int64) {
            if v >= Int64(Int32.min) && v <= Int64(Int32.max) {
                emit(.cmp, 8, .use(x, 8), .imm(v))
            } else {
                emit(.cmp, 8, .use(x, 8), .use(materializeInt(v, size: 8), 8))
            }
        }
        if cases.count <= 3 {
            for c in cases {
                compare(c.value)
                branch(.e, c.block)
            }
            jump(defaultBlock)
            return
        }
        // Split at the middle case: below it on the left, the rest on the right
        let mid = cases.startIndex + cases.count / 2
        let right = newBlock(after: cur)
        compare(cases[mid].value)
        branch(.ge, right)
        let left = newBlock(after: cur)
        jump(left)
        cur = left
        switchTree(x, cases[cases.startIndex..<mid], defaultBlock)
        cur = right
        switchTree(x, cases[mid...], defaultBlock)
    }

    func jumpTable(_ x: LIRReg, _ cases: ArraySlice<(value: Int64, block: Int)>, _ defaultBlock: Int, range: Int) {
        let low = cases.first!.value
        let index = copied(x)
        if low != 0 {
            if low >= Int64(Int32.min) && low <= Int64(Int32.max) {
                emit(.sub, 8, .useDef(index, 8), .imm(low))
            } else {
                emit(.sub, 8, .useDef(index, 8), .use(materializeInt(low, size: 8), 8))
            }
        }
        emit(.cmp, 8, .use(index, 8), .imm(Int64(range - 1)))
        branch(.a, defaultBlock)
        var targets = [Int](repeating: defaultBlock, count: range)
        for c in cases { targets[Int(c.value &- low)] = c.block }
        let k = lir.jumpTables.count
        lir.jumpTables.append(targets)
        let table = ctx.symbols.intern(".LJTI\(functionIndex)_\(k)")
        let base = newGPR(), offset = newGPR()
        emit(.lea, 8, .def(base, 8), LIRAddress.symbol(table).operand(size: 8))
        emit(.movslq, 8, .def(offset, 8), LIRAddress(base: base, index: index, scale: 4).operand(size: 4))
        emit(.add, 8, .useDef(offset, 8), .use(base, 8))
        emit(.jmpIndirect, 8, .use(offset, 8))
        lir.blocks[cur].jumpTable = k
        for t in Set(targets).sorted() {
            lir.blocks[t].addressTaken = true
            if !lir.blocks[cur].successors.contains(t) { lir.blocks[cur].successors.append(t) }
        }
    }

    // MARK: - Atomics

    func atomic(_ i: InstId) -> X86Val {
        let o = op(i)
        switch o {
        case .fence:
            let raw = aux(i)
            if raw & 0x100 == 0, AIRAtomicOrdering(rawValue: raw & 0xFF) == .seqCst { emit(.mfence, 0) }
            return .none
        case .atomicLoad:
            let t = resultType(i)
            if t.width > 64 { return cmpxchg16(addressOf(o0(i)), expected: nil, desired: nil) }
            return load(o0(i), type: t, flags: AIRMemFlags(rawValue: aux(i) >> 8))
        case .atomicStore:
            let t = ty(o0(i))
            let ordering = AIRAtomicOrdering(rawValue: aux(i) & 0xFF) ?? .seqCst
            if t.width > 64 {
                // A compare-exchange loop until the store happens
                let a = addressOf(o1(i))
                let desired = pair(o0(i))
                let old = cmpxchg16(a, expected: nil, desired: nil)
                guard case .pair(let lo0, let hi0) = old else { return .none }
                atomicLoop(a, start: (lo0, hi0), wide: true) { _ in desired }
                return .none
            }
            guard ordering == .seqCst else {
                store(o0(i), to: o1(i), flags: AIRMemFlags(rawValue: aux(i) >> 8))
                return .none
            }
            let size = t.width / 8
            let r = copied(gpr(o0(i)), max(size, 4))
            emit(.xchg, size, .useDef(r, size), addressOf(o1(i)).operand(size: size))
            return .none
        case .atomicRMW:
            let t = resultType(i)
            let size = t.width / 8
            let a = addressOf(o0(i))
            let operation = AIRAtomicOp(rawValue: aux(i) >> 8) ?? .xchg
            if t.width > 64 {
                let old = cmpxchg16(a, expected: nil, desired: nil)
                guard case .pair(let lo0, let hi0) = old else { return .none }
                let (vlo, vhi) = pair(o1(i))
                return atomicLoop(a, start: (lo0, hi0), wide: true) { cur in
                    let (lo, hi) = (self.copied(cur.0), self.copied(cur.1))
                    switch operation {
                    case .xchg: return (vlo, vhi)
                    case .add:
                        self.emit(.add, 8, .useDef(lo, 8), .use(vlo, 8))
                        self.emit(.adc, 8, .useDef(hi, 8), .use(vhi, 8))
                    case .sub:
                        self.emit(.sub, 8, .useDef(lo, 8), .use(vlo, 8))
                        self.emit(.sbb, 8, .useDef(hi, 8), .use(vhi, 8))
                    case .and, .nand:
                        self.emit(.and, 8, .useDef(lo, 8), .use(vlo, 8))
                        self.emit(.and, 8, .useDef(hi, 8), .use(vhi, 8))
                        if operation == .nand {
                            self.emit(.not, 8, .useDef(lo, 8))
                            self.emit(.not, 8, .useDef(hi, 8))
                        }
                    case .or:
                        self.emit(.or, 8, .useDef(lo, 8), .use(vlo, 8))
                        self.emit(.or, 8, .useDef(hi, 8), .use(vhi, 8))
                    case .xor:
                        self.emit(.xor, 8, .useDef(lo, 8), .use(vlo, 8))
                        self.emit(.xor, 8, .useDef(hi, 8), .use(vhi, 8))
                    }
                    return (lo, hi)
                }
            }
            let v = gpr(o1(i))
            switch operation {
            case .xchg:
                let r = copied(v, max(size, 4))
                emit(.xchg, size, .useDef(r, size), a.operand(size: size))
                return .reg(r)
            case .add, .sub:
                let r = copied(v, max(size, 4))
                if operation == .sub { emit(.neg, max(size, 4), .useDef(r, max(size, 4))) }
                emit(.xadd, size, lock: true, a.operand(size: size), .useDef(r, size))
                return .reg(r)
            default:
                let start = loadBytes(a, size)
                let result = atomicLoop(a, start: (start, .none), wide: false, size: size) { cur in
                    let n = self.copied(cur.0, 8)
                    self.emit(operation == .or ? .or : operation == .xor ? .xor : .and, max(size, 4), .useDef(n, max(size, 4)),
                              .use(v, max(size, 4)))
                    if operation == .nand { self.emit(.not, max(size, 4), .useDef(n, max(size, 4))) }
                    return (n, .none)
                }
                return result
            }
        case .cmpxchg:
            let t = resultType(i)
            let items = list(i)
            let a = addressOf(o0(i))
            if t.width > 64 { return cmpxchg16(a, expected: pair(o1(i)), desired: pair(ValueId(items[0]))) }
            let size = t.width / 8
            let expected = gpr(o1(i)), desired = gpr(ValueId(items[0]))
            emit(.copy, 8, .def(.physical(.rax), 8), .use(expected, 8))
            emit(.cmpxchg, size, lock: true, a.operand(size: size), .use(desired, size), .implicitUse(.rax), .implicitDef(.rax))
            let r = newGPR()
            copy(r, .physical(.rax))
            return .reg(r)
        default:
            return .none
        }
    }

    /// `lock cmpxchg16b`: exchanges if the 16 bytes at `a` equal `expected` (by default 0, which with `desired` 0
    /// leaves memory as it was); returns the old value.
    @discardableResult
    func cmpxchg16(_ a: LIRAddress, expected: (LIRReg, LIRReg)?, desired: (LIRReg, LIRReg)?) -> X86Val {
        let address = lea(a)
        let e = expected ?? (materializeInt(0, size: 4), materializeInt(0, size: 4))
        let d = desired ?? e
        emit(.copy, 8, .def(.physical(.rax), 8), .use(e.0, 8))
        emit(.copy, 8, .def(.physical(.rdx), 8), .use(e.1, 8))
        emit(.copy, 8, .def(.physical(.rbx), 8), .use(d.0, 8))
        emit(.copy, 8, .def(.physical(.rcx), 8), .use(d.1, 8))
        emit(.cmpxchg16b, 16, lock: true, LIRAddress(base: address).operand(size: 16), .implicitUse(.rax), .implicitUse(.rdx),
             .implicitUse(.rbx), .implicitUse(.rcx), .implicitDef(.rax), .implicitDef(.rdx))
        let lo = newGPR(), hi = newGPR()
        copy(lo, .physical(.rax))
        copy(hi, .physical(.rdx))
        return .pair(lo, hi)
    }

    /// A compare-exchange loop: from the value `start` read at `a`, computes the new value with `next` and retries
    /// until the exchange succeeds. Returns the value replaced.
    @discardableResult
    func atomicLoop(_ a: LIRAddress, start: (LIRReg, LIRReg), wide: Bool, size: Int = 8,
                    _ next: ((LIRReg, LIRReg)) -> (LIRReg, LIRReg)) -> X86Val {
        // The address is computed once, before the loop
        let address = lea(a)
        let entry = cur
        let loop = newBlock(after: cur), after = newBlock(after: loop)
        jump(loop)
        cur = loop
        let oldLo = newGPR(), oldHi = wide ? newGPR() : LIRReg.none
        let (newLo, newHi) = next((oldLo, oldHi))
        let lo = newGPR(), hi = newGPR()
        if wide {
            emit(.copy, 8, .def(.physical(.rax), 8), .use(oldLo, 8))
            emit(.copy, 8, .def(.physical(.rdx), 8), .use(oldHi, 8))
            emit(.copy, 8, .def(.physical(.rbx), 8), .use(newLo, 8))
            emit(.copy, 8, .def(.physical(.rcx), 8), .use(newHi, 8))
            emit(.cmpxchg16b, 16, lock: true, LIRAddress(base: address).operand(size: 16), .implicitUse(.rax), .implicitUse(.rdx),
                 .implicitUse(.rbx), .implicitUse(.rcx), .implicitDef(.rax), .implicitDef(.rdx))
            copy(lo, .physical(.rax))
            copy(hi, .physical(.rdx))
        } else {
            emit(.copy, 8, .def(.physical(.rax), 8), .use(oldLo, 8))
            emit(.cmpxchg, size, lock: true, LIRAddress(base: address).operand(size: size), .use(newLo, size), .implicitUse(.rax),
                 .implicitDef(.rax))
            copy(lo, .physical(.rax))
        }
        branch(.ne, loop)
        jump(after)
        lir.blocks[loop].phis.append(LIRPhi(def: oldLo, incoming: [(entry, start.0), (loop, lo)]))
        if wide { lir.blocks[loop].phis.append(LIRPhi(def: oldHi, incoming: [(entry, start.1), (loop, hi)])) }
        cur = after
        return wide ? .pair(lo, hi) : .reg(lo)
    }

    // MARK: - Inline assembly

    func inlineAsm(_ i: InstId) {
        X86InlineAsm(isel: self).lower(i)
    }
}
