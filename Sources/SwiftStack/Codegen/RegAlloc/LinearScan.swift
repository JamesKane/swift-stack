// Sources/SwiftStack/Codegen/RegAlloc/LinearScan.swift
//
// Linear scan register allocation on SSA (04-backend.md §4.5; Wimmer & Franz, CGO 2010): liveness by backward
// dataflow, intervals with lifetime holes, the scan with splitting and spilling, and resolution, which places the
// moves for split intervals and phis and sequentializes each parallel move.

import Foundation

final class LinearScan {
    var f: LIRFunction
    var issues: [String] = []

    // Numbering: the global index of each block's first instruction, and the block of each instruction
    var firstInst: [Int] = []
    var blockFrom: [Int] = []
    var blockTo: [Int] = []
    var instCount = 0

    // Liveness (bitsets over virtual registers)
    var words = 0
    var liveIn: [[UInt64]] = []
    var liveOut: [[UInt64]] = []

    var intervals: [LiveInterval?] = []
    var fixed: [LiveInterval] = []

    // The scan
    var unhandled: [LiveInterval] = []  // sorted by start, descending (the next is last)
    var active: [LiveInterval] = []
    var inactive: [LiveInterval] = []

    /// Moves to insert at gap positions inside blocks, for intervals split there.
    var gapMoves: [Int: [(from: LiveLocation, to: LiveLocation, cls: LIRRegClass)]] = [:]

    static let reserved: Set<PhysReg> = [.rsp, .rbp]

    init(_ f: LIRFunction) {
        self.f = f
    }

    func report(_ m: String) { issues.append("\(f.name): register allocation: \(m)") }

    func run() -> LIRFunction {
        splitCriticalEdges()
        number()
        computeLiveness()
        buildIntervals()
        scan()
        rewrite()
        return f
    }

    // MARK: - Critical edges

    func splitCriticalEdges() {
        f.computePredecessors()
        let original = f.blocks.count
        for p in 0..<original where f.blocks[p].successors.count > 1 {
            for s in f.blocks[p].successors where f.blocks[s].predecessors.count > 1 {
                // An indirect jump not through a table names its targets by address: its edges cannot be split
                let last = f.blocks[p].insts.last
                if last?.op == .jmpIndirect && f.blocks[p].jumpTable < 0 { continue }
                let e = f.blocks.count
                var block = LIRBlock()
                block.airBlock = f.blocks[p].airBlock
                block.successors = [s]
                f.blocks.append(block)
                f.append(e, .jmp, size: 8, [.block(s)])
                for k in f.blocks[p].insts.indices {
                    for o in f.blocks[p].insts[k].operandRange where f.operands[o].kind == .block && f.operands[o].value == Int64(s) {
                        f.operands[o].value = Int64(e)
                    }
                }
                for k in f.asmStatements.indices where f.asmStatements[k].block == p {
                    f.asmStatements[k].labels = f.asmStatements[k].labels.map { $0 == s ? e : $0 }
                    f.blocks[e].addressTaken = true
                }
                if f.blocks[p].jumpTable >= 0 {
                    f.jumpTables[f.blocks[p].jumpTable] = f.jumpTables[f.blocks[p].jumpTable].map { $0 == s ? e : $0 }
                    f.blocks[e].addressTaken = true
                }
                f.blocks[p].successors = f.blocks[p].successors.map { $0 == s ? e : $0 }
                for k in f.blocks[s].phis.indices {
                    f.blocks[s].phis[k].incoming = f.blocks[s].phis[k].incoming.map { ($0.block == p ? e : $0.block, $0.reg) }
                }
            }
        }
        f.computePredecessors()
    }

    // MARK: - Numbering and liveness

    func number() {
        var n = 0
        firstInst = []
        blockFrom = []
        blockTo = []
        for b in f.blocks.indices {
            if f.blocks[b].insts.isEmpty { f.append(b, .ud2, size: 0, []) }
            firstInst.append(n)
            blockFrom.append(LivePosition.gap(n))
            n += f.blocks[b].insts.count
            blockTo.append(LivePosition.def(n - 1) + 1)
        }
        instCount = n
    }

    /// Calls `body` with each register operand of `inst`: the register, whether it is read, whether written, whether
    /// early-clobber, and its operand index.
    @inline(__always)
    func forEachRegister(_ inst: LIRInst, _ body: (LIRReg, Bool, Bool, Bool, Int) -> Void) {
        for o in inst.operandRange {
            let op = f.operands[o]
            switch op.kind {
            case .reg:
                body(op.reg, op.isUse, op.isDef, op.flags.contains(.earlyClobber), o)
            case .mem:
                if !op.isBlockAddress {
                    if !op.reg.isNone { body(op.reg, true, false, false, o) }
                    if !op.index.isNone { body(op.index, true, false, false, o) }
                }
            default:
                break
            }
        }
    }

    func computeLiveness() {
        let nb = f.blocks.count
        words = (f.vregCount + 63) / 64
        var gen = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: nb)
        var kill = gen
        for b in 0..<nb {
            for phi in f.blocks[b].phis { set(&kill[b], phi.def.virtualIndex) }
            for inst in f.blocks[b].insts {
                var defs: [Int] = []
                forEachRegister(inst) { r, use, def, _, _ in
                    guard r.isVirtual else { return }
                    if use && !test(kill[b], r.virtualIndex) { set(&gen[b], r.virtualIndex) }
                    if def { defs.append(r.virtualIndex) }
                }
                for d in defs { set(&kill[b], d) }
            }
        }
        liveIn = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: nb)
        liveOut = liveIn
        var changed = true
        while changed {
            changed = false
            for b in stride(from: nb - 1, through: 0, by: -1) {
                var out = [UInt64](repeating: 0, count: words)
                for s in f.blocks[b].successors {
                    for w in 0..<words { out[w] |= liveIn[s][w] }
                    for phi in f.blocks[s].phis {
                        if let r = phi.value(from: b), r.isVirtual { set(&out, r.virtualIndex) }
                    }
                }
                var inn = out
                for w in 0..<words { inn[w] = gen[b][w] | (out[w] & ~kill[b][w]) }
                if out != liveOut[b] || inn != liveIn[b] {
                    liveOut[b] = out
                    liveIn[b] = inn
                    changed = true
                }
            }
        }
        // Nothing may be live into the entry block
        if let entryLive = liveIn.first, entryLive.contains(where: { $0 != 0 }) {
            let regs = (0..<f.vregCount).filter { test(entryLive, $0) }.prefix(5)
            report("used before definition: " + regs.map { "v\($0)" }.joined(separator: ", "))
        }
    }

    @inline(__always) func set(_ bits: inout [UInt64], _ i: Int) { bits[i >> 6] |= 1 << UInt64(i & 63) }
    @inline(__always) func test(_ bits: [UInt64], _ i: Int) -> Bool { bits[i >> 6] & (1 << UInt64(i & 63)) != 0 }

    // MARK: - Intervals

    func interval(_ v: Int) -> LiveInterval {
        if let i = intervals[v] { return i }
        let i = LiveInterval(vreg: v, regClass: f.regClass[v])
        intervals[v] = i
        return i
    }

    func buildIntervals() {
        intervals = [LiveInterval?](repeating: nil, count: f.vregCount)
        fixed = PhysReg.allCases.map { LiveInterval(vreg: 0, regClass: $0.isXMM ? .xmm : .gpr, fixed: $0) }
        for b in stride(from: f.blocks.count - 1, through: 0, by: -1) {
            let from = blockFrom[b], to = blockTo[b]
            var live = liveOut[b]
            for w in 0..<words where live[w] != 0 {
                var bits = live[w]
                while bits != 0 {
                    let v = w * 64 + bits.trailingZeroBitCount
                    bits &= bits - 1
                    interval(v).addRangeBackward(from, to)
                }
            }
            var physEnd = [Int?](repeating: nil, count: PhysReg.count)
            let insts = f.blocks[b].insts
            for k in stride(from: insts.count - 1, through: 0, by: -1) {
                let n = firstInst[b] + k
                let inst = insts[k]
                // Outputs, then inputs
                forEachRegister(inst) { r, _, def, early, _ in
                    guard def else { return }
                    let pos = early ? LivePosition.use(n) : LivePosition.def(n)
                    if r.isVirtual {
                        let it = interval(r.virtualIndex)
                        if test(live, r.virtualIndex), let first = it.ranges.first, first.from <= pos {
                            it.ranges[0].from = pos
                        } else {
                            it.addRangeBackward(pos, pos + 1)
                        }
                        it.uses.append(pos)
                        clear(&live, r.virtualIndex)
                    } else if r.isPhysical, !Self.reserved.contains(r.physical) {
                        let p = Int(r.physical.rawValue)
                        fixed[p].addRangeBackward(pos, physEnd[p] ?? pos + 1)
                        physEnd[p] = nil
                    }
                }
                forEachRegister(inst) { r, use, _, _, _ in
                    guard use else { return }
                    let pos = LivePosition.use(n)
                    if r.isVirtual {
                        let it = interval(r.virtualIndex)
                        it.addRangeBackward(from, pos + 1)
                        it.uses.append(pos)
                        set(&live, r.virtualIndex)
                    } else if r.isPhysical, !Self.reserved.contains(r.physical) {
                        let p = Int(r.physical.rawValue)
                        if physEnd[p] == nil { physEnd[p] = pos + 1 }
                    }
                }
                // Hints: a copy prefers its source's register, and the source its destination's
                if inst.op == .copy, inst.operandCount == 2 {
                    let d = f.operands[Int(inst.firstOperand)].reg, s = f.operands[Int(inst.firstOperand) + 1].reg
                    if d.isVirtual {
                        if s.isVirtual { interval(d.virtualIndex).hint = interval(s.virtualIndex) } else if s.isPhysical {
                            interval(d.virtualIndex).hintReg = s.physical
                        }
                    }
                    if s.isVirtual && d.isPhysical { interval(s.virtualIndex).hintReg = d.physical }
                }
            }
            for phi in f.blocks[b].phis {
                let it = interval(phi.def.virtualIndex)
                if test(live, phi.def.virtualIndex) {
                    it.ranges[0].from = from
                } else {
                    it.addRangeBackward(from, from + 1)
                }
                clear(&live, phi.def.virtualIndex)
                if let input = phi.incoming.first(where: { $0.reg.isVirtual })?.reg { it.hint = interval(input.virtualIndex) }
            }
            for p in 0..<PhysReg.count {
                if let end = physEnd[p] { fixed[p].addRangeBackward(from, end) }
            }
        }
        for case let it? in intervals { it.uses.reverse() }
    }

    @inline(__always) func clear(_ bits: inout [UInt64], _ i: Int) { bits[i >> 6] &= ~(1 << UInt64(i & 63)) }

    // MARK: - The scan

    func addUnhandled(_ it: LiveInterval) {
        // Descending by start: binary search for the insertion point
        var lo = 0, hi = unhandled.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if unhandled[mid].start > it.start || (unhandled[mid].start == it.start && unhandled[mid].vreg > it.vreg) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        unhandled.insert(it, at: lo)
    }

    func scan() {
        unhandled = intervals.compactMap { $0 }.filter { !$0.isEmpty }
        unhandled.sort { $0.start > $1.start || ($0.start == $1.start && $0.vreg > $1.vreg) }
        while let current = unhandled.popLast() {
            let position = current.start
            active.removeAll { it in
                if it.end <= position { return true }
                if !it.covers(position) { inactive.append(it); return true }
                return false
            }
            inactive.removeAll { it in
                if it.end <= position { return true }
                if it.covers(position) { active.append(it); return true }
                return false
            }
            if !tryAllocateFreeRegister(current) { allocateBlockedRegister(current) }
            if current.reg != nil && !current.isSpilled { active.append(current) }
        }
    }

    func hintRegister(_ current: LiveInterval) -> PhysReg? {
        if let r = current.hintReg { return r }
        if let h = current.hint {
            if let c = h.child(at: current.start - 1) ?? h.child(at: current.start), !c.isSpilled, let r = c.reg { return r }
            if !h.isSpilled, let r = h.reg { return r }
        }
        return nil
    }

    func tryAllocateFreeRegister(_ current: LiveInterval) -> Bool {
        let regs = current.regClass.allocatable
        var free = [Int](repeating: Int.max, count: PhysReg.count)
        for it in active where it.regClass == current.regClass { free[Int(it.reg!.rawValue)] = 0 }
        for it in inactive where it.regClass == current.regClass {
            if let x = it.nextIntersection(with: current) { free[Int(it.reg!.rawValue)] = min(free[Int(it.reg!.rawValue)], x) }
        }
        for r in regs {
            if let x = fixed[Int(r.rawValue)].nextIntersection(with: current) { free[Int(r.rawValue)] = min(free[Int(r.rawValue)], x) }
        }
        var chosen = regs[0]
        for r in regs where free[Int(r.rawValue)] > free[Int(chosen.rawValue)] { chosen = r }
        if let h = hintRegister(current), regs.contains(h), free[Int(h.rawValue)] >= current.end { chosen = h }
        let until = free[Int(chosen.rawValue)]
        if until <= current.start { return false }
        if until >= current.end {
            current.reg = chosen
            return true
        }
        // Free for the first part only: split before the register is needed elsewhere
        let split = LivePosition.gapAtOrBefore(until)
        guard split > current.start, current.nextUse(after: current.start).map({ $0 < split }) ?? false else { return false }
        current.reg = chosen
        addUnhandled(current.split(at: split))
        return true
    }

    func allocateBlockedRegister(_ current: LiveInterval) {
        let regs = current.regClass.allocatable
        let start = current.start
        var nextUse = [Int](repeating: Int.max, count: PhysReg.count)
        var blocked = [Int](repeating: Int.max, count: PhysReg.count)
        for it in active where it.regClass == current.regClass {
            let r = Int(it.reg!.rawValue)
            let u = it.nextUse(after: start) ?? Int.max
            // A value that needs the register at this very position cannot give it up
            if u == start { blocked[r] = start }
            nextUse[r] = min(nextUse[r], u)
        }
        for it in inactive where it.regClass == current.regClass {
            guard it.nextIntersection(with: current) != nil else { continue }
            let r = Int(it.reg!.rawValue)
            nextUse[r] = min(nextUse[r], it.nextUse(after: start) ?? Int.max)
        }
        for r in regs {
            if let x = fixed[Int(r.rawValue)].nextIntersection(with: current) {
                blocked[Int(r.rawValue)] = min(blocked[Int(r.rawValue)], x)
                nextUse[Int(r.rawValue)] = min(nextUse[Int(r.rawValue)], x)
            }
        }
        var chosen: PhysReg?
        for r in regs where blocked[Int(r.rawValue)] > start {
            if chosen == nil || nextUse[Int(r.rawValue)] > nextUse[Int(chosen!.rawValue)] { chosen = r }
        }
        let firstUse = current.nextUse(after: start) ?? Int.max
        guard let reg = chosen, nextUse[Int(reg.rawValue)] >= firstUse || firstUse == start else {
            // Every register is needed sooner than this value needs one: it goes to the stack until its first use
            spill(current, from: start)
            return
        }
        if nextUse[Int(reg.rawValue)] < firstUse {
            spill(current, from: start)
            return
        }
        current.reg = reg
        let block = blocked[Int(reg.rawValue)]
        if block < current.end {
            let split = LivePosition.gapAtOrBefore(block)
            if split > start {
                addUnhandled(current.split(at: split))
            } else {
                report("no register for v\(current.vreg) at \(start)")
            }
        }
        // Whatever else holds the register gives it up from here
        for it in active where it.reg == reg && it !== current {
            evict(it, at: start)
        }
        active.removeAll { $0.reg == reg && $0 !== current && $0.end <= start }
        for it in inactive where it.reg == reg {
            guard let x = it.nextIntersection(with: current) else { continue }
            let resume = it.nextRangeStart(after: start) ?? x
            let split = max(LivePosition.gapAtOrBefore(resume), start)
            guard split > it.start else { continue }
            let child = it.split(at: split)
            spillUntilNextUse(child)
        }
        inactive.removeAll { $0.reg == reg && $0.end <= start }
    }

    /// Makes `it` give up its register from `pos`: the rest goes to the stack until its next use.
    func evict(_ it: LiveInterval, at pos: Int) {
        guard pos > it.start else {
            report("cannot evict v\(it.vreg) at its start \(pos)")
            return
        }
        let child = it.split(at: pos)
        if !child.isEmpty { spillUntilNextUse(child) }
    }

    /// Assigns `it` to the stack up to its next use; the part from there is allocated later.
    func spillUntilNextUse(_ it: LiveInterval) {
        guard let use = it.nextUse(after: it.start) else {
            markSpilled(it)
            return
        }
        let split = LivePosition.gapAtOrBefore(use)
        if split > it.start {
            let rest = it.split(at: split)
            markSpilled(it)
            addUnhandled(rest)
        } else {
            // Needed in a register right away
            it.reg = nil
            addUnhandled(it)
        }
    }

    func spill(_ current: LiveInterval, from start: Int) {
        guard let use = current.nextUse(after: start) else {
            markSpilled(current)
            return
        }
        let split = LivePosition.gapAtOrBefore(use)
        guard split > start else {
            report("no register for v\(current.vreg) at \(start) (needed at \(use))")
            current.reg = current.regClass.allocatable[0]
            return
        }
        let rest = current.split(at: split)
        markSpilled(current)
        addUnhandled(rest)
    }

    func markSpilled(_ it: LiveInterval) {
        it.isSpilled = true
        it.reg = nil
        let root = it.root
        if root.spillSlot == 0 {
            root.spillSlot = it.regClass == .gpr ? f.newSlot(size: 8, alignment: 8) : f.newSlot(size: 16, alignment: 16)
        }
    }

    // MARK: - Rewriting and resolution

    func location(_ v: Int, at pos: Int) -> LiveLocation? {
        intervals[v]?.child(at: pos)?.location
    }

    func rewrite() {
        // Moves where split intervals continue in another place inside a block
        let blockStarts = Set(blockFrom)
        for case let root? in intervals where !root.children.isEmpty {
            let all = ([root] + root.children).sorted { $0.start < $1.start }
            for c in all.dropFirst() {
                let s = c.start
                if blockStarts.contains(s) { continue }
                guard let prev = all.first(where: { $0 !== c && $0.covers(s - 1) }) else { continue }
                if prev.location == c.location { continue }
                // A move at a position that is not a gap goes in the gap before (the source still holds the value)
                let gap = LivePosition.gapAtOrBefore(s)
                gapMoves[gap, default: []].append((prev.location, c.location, root.regClass))
            }
        }

        // Edge moves: per block, those at its end and those at its start
        var endMoves = [[(from: LiveLocation, to: LiveLocation, cls: LIRRegClass)]](repeating: [], count: f.blocks.count)
        var startMoves = endMoves
        for p in f.blocks.indices {
            for s in f.blocks[p].successors {
                var moves: [(from: LiveLocation, to: LiveLocation, cls: LIRRegClass)] = []
                let endPos = blockTo[p] - 1, startPos = blockFrom[s]
                for w in 0..<words where liveIn[s][w] != 0 {
                    var bits = liveIn[s][w]
                    while bits != 0 {
                        let v = w * 64 + bits.trailingZeroBitCount
                        bits &= bits - 1
                        guard let from = location(v, at: endPos), let to = location(v, at: startPos) else {
                            report("v\(v) has no location on edge b\(p) -> b\(s)")
                            continue
                        }
                        if from != to { moves.append((from, to, f.regClass[v])) }
                    }
                }
                for phi in f.blocks[s].phis {
                    guard let input = phi.value(from: p), input.isVirtual,
                          let from = location(input.virtualIndex, at: endPos),
                          let to = location(phi.def.virtualIndex, at: startPos) else { continue }
                    if from != to { moves.append((from, to, f.regClass[phi.def.virtualIndex])) }
                }
                guard !moves.isEmpty else { continue }
                let lastOp = f.blocks[p].insts.last?.op
                if f.blocks[p].successors.count == 1 && lastOp != .jmpIndirect {
                    endMoves[p] += moves
                } else if f.blocks[s].predecessors.count == 1 {
                    startMoves[s] += moves
                } else {
                    report("moves needed on the edge b\(p) -> b\(s), which cannot be split")
                }
            }
        }

        var newOperands: [LIROperand] = []
        newOperands.reserveCapacity(f.operands.count)
        var used = Set<PhysReg>()
        for b in f.blocks.indices {
            var out: [LIRInst] = []
            func add(_ op: LIROp, _ size: Int, _ ops: [LIROperand]) {
                out.append(LIRInst(op: op, size: size, firstOperand: UInt32(newOperands.count), operandCount: ops.count))
                newOperands.append(contentsOf: ops)
            }
            func emitMoves(_ moves: [(from: LiveLocation, to: LiveLocation, cls: LIRRegClass)]) {
                for m in sequentialize(moves) { add(m.op, m.size, m.operands) }
            }
            emitMoves(startMoves[b])
            let insts = f.blocks[b].insts
            let firstTerminator = insts.firstIndex { $0.op.isTerminator } ?? insts.count
            for (k, inst) in insts.enumerated() {
                let n = firstInst[b] + k
                if let moves = gapMoves[LivePosition.gap(n)] { emitMoves(moves) }
                if k == firstTerminator { emitMoves(endMoves[b]) }
                var ops = Array(f.operands[inst.operandRange])
                for j in ops.indices {
                    switch ops[j].kind {
                    case .reg:
                        let r = ops[j].reg
                        if r.isVirtual {
                            let pos = ops[j].isDef && !ops[j].isUse
                                ? (ops[j].flags.contains(.earlyClobber) ? LivePosition.use(n) : LivePosition.def(n))
                                : LivePosition.use(n)
                            ops[j].reg = physical(r.virtualIndex, at: pos)
                            if ops[j].isDef && ops[j].isUse {
                                let d = physical(r.virtualIndex, at: LivePosition.def(n))
                                if d != ops[j].reg { report("v\(r.virtualIndex) moves within instruction \(n)") }
                            }
                        }
                        if ops[j].reg.isPhysical { used.insert(ops[j].reg.physical) }
                    case .mem where !ops[j].isBlockAddress:
                        if ops[j].reg.isVirtual { ops[j].reg = physical(ops[j].reg.virtualIndex, at: LivePosition.use(n)) }
                        if ops[j].index.isVirtual { ops[j].index = physical(ops[j].index.virtualIndex, at: LivePosition.use(n)) }
                    default:
                        break
                    }
                }
                if inst.op == .copy, ops.count == 2, ops[0].reg == ops[1].reg { continue }
                var copy = inst
                copy.firstOperand = UInt32(newOperands.count)
                out.append(copy)
                newOperands.append(contentsOf: ops)
            }
            if firstTerminator == insts.count { emitMoves(endMoves[b]) }
            f.blocks[b].insts = out
            f.blocks[b].phis = []
        }
        f.operands = newOperands
        f.usedCalleeSaved = PhysReg.allCases.filter { used.contains($0) && !$0.isCallerSaved && !Self.reserved.contains($0) }
    }

    func physical(_ v: Int, at pos: Int) -> LIRReg {
        guard let c = intervals[v]?.child(at: pos) else {
            report("v\(v) is not live at \(pos)")
            return .physical(.rax)
        }
        guard let r = c.reg, !c.isSpilled else {
            report("v\(v) is on the stack at \(pos), where it needs a register")
            return .physical(.rax)
        }
        return .physical(r)
    }

    // MARK: - Parallel moves

    struct Move {
        var op: LIROp
        var size: Int
        var operands: [LIROperand]
    }

    func operand(_ l: LiveLocation, _ cls: LIRRegClass, def: Bool) -> LIROperand {
        switch l {
        case .reg(let r): return LIROperand(kind: .reg, flags: def ? .def : .use, size: cls == .gpr ? 8 : 16, reg: .physical(r))
        case .stack(let s): return LIRAddress.slot(s).operand(size: cls == .gpr ? 8 : 16)
        }
    }

    func move(_ from: LiveLocation, _ to: LiveLocation, _ cls: LIRRegClass) -> [Move] {
        switch (from, to) {
        case (.stack(let a), .stack(let b)):
            // Through the machine stack, which needs no register
            if cls == .gpr {
                return [Move(op: .push, size: 8, operands: [LIRAddress.slot(a).operand(size: 8)]),
                        Move(op: .pop, size: 8, operands: [LIRAddress.slot(b).operand(size: 8)])]
            }
            return [Move(op: .push, size: 8, operands: [LIRAddress.slot(a, 8).operand(size: 8)]),
                    Move(op: .push, size: 8, operands: [LIRAddress.slot(a).operand(size: 8)]),
                    Move(op: .pop, size: 8, operands: [LIRAddress.slot(b).operand(size: 8)]),
                    Move(op: .pop, size: 8, operands: [LIRAddress.slot(b, 8).operand(size: 8)])]
        default:
            let op: LIROp = cls == .gpr ? .mov : .movaps
            return [Move(op: op, size: cls == .gpr ? 8 : 16, operands: [operand(to, cls, def: true), operand(from, cls, def: false)])]
        }
    }

    /// Orders a parallel move so that no destination is written before it is read, breaking cycles through the
    /// machine stack (or `xchg` for two general-purpose registers).
    func sequentialize(_ input: [(from: LiveLocation, to: LiveLocation, cls: LIRRegClass)]) -> [Move] {
        var pending = input.filter { $0.from != $0.to }
        // Drop duplicate destinations (the same move twice)
        var seen: [LiveLocation] = []
        pending = pending.filter { m in
            if seen.contains(m.to) { return false }
            seen.append(m.to)
            return true
        }
        var out: [Move] = []
        var saved: (to: LiveLocation, cls: LIRRegClass)?
        while !pending.isEmpty {
            if let k = pending.firstIndex(where: { m in !pending.contains { $0.from == m.to } }) {
                let m = pending.remove(at: k)
                out += move(m.from, m.to, m.cls)
                continue
            }
            // A cycle: two GPRs swap with xchg; otherwise one source goes to the machine stack
            let m = pending.removeFirst()
            if case .reg(let a) = m.from, case .reg(let b) = m.to, m.cls == .gpr {
                out.append(Move(op: .xchg, size: 8, operands: [LIROperand(kind: .reg, flags: [.use, .def], size: 8, reg: .physical(b)),
                                                               LIROperand(kind: .reg, flags: [.use, .def], size: 8, reg: .physical(a))]))
                for j in pending.indices {
                    if pending[j].from == m.to { pending[j].from = m.from } else if pending[j].from == m.from { pending[j].from = m.to }
                }
                pending.removeAll { $0.from == $0.to }
                continue
            }
            out += saveToStack(m.from, m.cls)
            saved = (m.to, m.cls)
            // With m removed the cycle is a chain; finish it before restoring
            while let k = pending.firstIndex(where: { mm in !pending.contains { $0.from == mm.to } }) {
                let mm = pending.remove(at: k)
                out += move(mm.from, mm.to, mm.cls)
            }
            if let s = saved {
                out += restoreFromStack(s.to, s.cls)
                saved = nil
            }
        }
        return out
    }

    func saveToStack(_ l: LiveLocation, _ cls: LIRRegClass) -> [Move] {
        switch (l, cls) {
        case (.reg(let r), .gpr): return [Move(op: .push, size: 8, operands: [.use(.physical(r), 8)])]
        case (.stack(let s), .gpr): return [Move(op: .push, size: 8, operands: [LIRAddress.slot(s).operand(size: 8)])]
        case (.reg(let r), _):
            return [Move(op: .lea, size: 8, operands: [.def(.physical(.rsp), 8), LIRAddress(base: .physical(.rsp), disp: -16).operand(size: 8)]),
                    Move(op: .movups, size: 16, operands: [LIRAddress(base: .physical(.rsp)).operand(size: 16), .use(.physical(r), 16)])]
        case (.stack(let s), _):
            return [Move(op: .push, size: 8, operands: [LIRAddress.slot(s, 8).operand(size: 8)]),
                    Move(op: .push, size: 8, operands: [LIRAddress.slot(s).operand(size: 8)])]
        }
    }

    func restoreFromStack(_ l: LiveLocation, _ cls: LIRRegClass) -> [Move] {
        switch (l, cls) {
        case (.reg(let r), .gpr): return [Move(op: .pop, size: 8, operands: [.def(.physical(r), 8)])]
        case (.stack(let s), .gpr): return [Move(op: .pop, size: 8, operands: [LIRAddress.slot(s).operand(size: 8)])]
        case (.reg(let r), _):
            return [Move(op: .movups, size: 16, operands: [.def(.physical(r), 16), LIRAddress(base: .physical(.rsp)).operand(size: 16)]),
                    Move(op: .lea, size: 8, operands: [.def(.physical(.rsp), 8), LIRAddress(base: .physical(.rsp), disp: 16).operand(size: 8)])]
        case (.stack(let s), _):
            return [Move(op: .pop, size: 8, operands: [LIRAddress.slot(s).operand(size: 8)]),
                    Move(op: .pop, size: 8, operands: [LIRAddress.slot(s, 8).operand(size: 8)])]
        }
    }

    // MARK: - Checking

    /// Two intervals holding one register at once, if any (for tests).
    func conflicts() -> [String] {
        var byReg: [PhysReg: [LiveInterval]] = [:]
        for case let root? in intervals {
            for it in [root] + root.children where !it.isSpilled && it.reg != nil && !it.isEmpty { byReg[it.reg!, default: []].append(it) }
        }
        var out: [String] = []
        for (r, list) in byReg {
            for i in list.indices {
                for j in (i + 1)..<list.count where list[i].vreg != list[j].vreg {
                    if let x = list[i].nextIntersection(with: list[j]) { out.append("v\(list[i].vreg) and v\(list[j].vreg) both in \(r) at \(x)") }
                }
                if let x = list[i].nextIntersection(with: fixed[Int(r.rawValue)]) { out.append("v\(list[i].vreg) in fixed \(r) at \(x)") }
            }
        }
        return out
    }
}
