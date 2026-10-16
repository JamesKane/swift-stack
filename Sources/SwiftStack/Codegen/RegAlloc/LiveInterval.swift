// Sources/SwiftStack/Codegen/RegAlloc/LiveInterval.swift
//
// Live intervals for linear scan (04-backend.md §4.5.2): sorted ranges with lifetime holes between them, and the
// positions where the value is used.
//
// Positions. Instruction n (in layout order) has four: 4n+3 is the gap before it, where moves the allocator adds go;
// 4n+4 is where it reads its inputs; 4n+5 is where it clobbers registers (a call's caller-saved registers); 4n+6 is
// where it writes its outputs. An input's range ends at 4n+5 (exclusive) and an output's starts at 4n+6, so an
// instruction's inputs and outputs may share a register; a clobber conflicts only with values live across.

import Foundation

enum LivePosition {
    @inline(__always) static func gap(_ n: Int) -> Int { 4 * n + 3 }
    @inline(__always) static func use(_ n: Int) -> Int { 4 * n + 4 }
    @inline(__always) static func clobber(_ n: Int) -> Int { 4 * n + 5 }
    @inline(__always) static func def(_ n: Int) -> Int { 4 * n + 6 }
    /// The latest gap at or before `pos`.
    @inline(__always) static func gapAtOrBefore(_ pos: Int) -> Int { (pos - 3) / 4 * 4 + 3 }
    @inline(__always) static func isGap(_ pos: Int) -> Bool { pos & 3 == 3 }
    /// The instruction whose gap, use, clobber or def `pos` is.
    @inline(__always) static func instruction(_ pos: Int) -> Int { (pos - 3) / 4 }
}

/// Where a value is: a register, or a stack slot of the frame.
enum LiveLocation: Equatable {
    case reg(PhysReg)
    case stack(UInt32)
}

final class LiveInterval {
    /// The virtual register (0 for a fixed interval of a physical register).
    let vreg: Int
    let regClass: LIRRegClass
    /// For a fixed interval, its register.
    let fixed: PhysReg?
    /// Sorted, disjoint ranges [from, to).
    var ranges: [(from: Int, to: Int)] = []
    /// Positions where the value must be in a register, sorted.
    var uses: [Int] = []
    var reg: PhysReg?
    var isSpilled = false
    /// The interval this one was split from (its own `splitParent` for an unsplit one), and the children of a parent.
    unowned(unsafe) var parent: LiveInterval!
    var children: [LiveInterval] = []
    var spillSlot: UInt32 = 0
    /// A register to prefer: one it is copied to or from.
    var hint: LiveInterval?
    var hintReg: PhysReg?

    init(vreg: Int, regClass: LIRRegClass, fixed: PhysReg? = nil) {
        self.vreg = vreg
        self.regClass = regClass
        self.fixed = fixed
        self.reg = fixed
    }

    var start: Int { ranges.first!.from }
    var end: Int { ranges.last!.to }
    var isEmpty: Bool { ranges.isEmpty }

    /// The unsplit interval of the value.
    var root: LiveInterval { parent ?? self }

    var location: LiveLocation { isSpilled ? .stack(root.spillSlot) : .reg(reg!) }

    func covers(_ pos: Int) -> Bool {
        // Binary search for the last range starting at or before pos
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ranges[mid].from <= pos {
                if pos < ranges[mid].to { return true }
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return false
    }

    /// The first position at or after `from` both intervals cover, or nil.
    func nextIntersection(with other: LiveInterval, from: Int = 0) -> Int? {
        var i = 0, j = 0
        let a = ranges, b = other.ranges
        while i < a.count && j < b.count {
            let lo = max(a[i].from, b[j].from, from)
            let hi = min(a[i].to, b[j].to)
            if lo < hi { return lo }
            if a[i].to <= b[j].to { i += 1 } else { j += 1 }
        }
        return nil
    }

    /// The first position at or after `pos` where it must be in a register.
    func nextUse(after pos: Int) -> Int? {
        var lo = 0, hi = uses.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if uses[mid] < pos { lo = mid + 1 } else { hi = mid }
        }
        return lo < uses.count ? uses[lo] : nil
    }

    /// The start of the first range at or after `pos` (where the interval resumes after a hole).
    func nextRangeStart(after pos: Int) -> Int? {
        ranges.first { $0.from >= pos }?.from
    }

    /// Adds [from, to) while ranges are built backwards (the new range starts at or before every existing one).
    func addRangeBackward(_ from: Int, _ to: Int) {
        if let first = ranges.first, to + 1 >= first.from {
            ranges[0].from = min(first.from, from)
            ranges[0].to = max(first.to, to)
        } else {
            ranges.insert((from, to), at: 0)
        }
    }

    /// Splits at `pos` (after the start): this interval keeps what is before it, and the returned child the rest.
    func split(at pos: Int) -> LiveInterval {
        let child = LiveInterval(vreg: vreg, regClass: regClass)
        let p = root
        child.parent = p
        child.hint = self
        var keep: [(from: Int, to: Int)] = [], rest: [(from: Int, to: Int)] = []
        for r in ranges {
            if r.to <= pos { keep.append(r) } else if r.from >= pos { rest.append(r) } else {
                keep.append((r.from, pos))
                rest.append((pos, r.to))
            }
        }
        ranges = keep
        child.ranges = rest
        child.uses = uses.filter { $0 >= pos }
        uses = uses.filter { $0 < pos }
        p.children.append(child)
        p.children.sort { $0.start < $1.start }
        return child
    }

    /// The interval of this value (the parent or one of its children) that covers `pos`.
    func child(at pos: Int) -> LiveInterval? {
        let p = root
        if p.covers(pos) { return p }
        for c in p.children where c.covers(pos) { return c }
        return nil
    }
}
