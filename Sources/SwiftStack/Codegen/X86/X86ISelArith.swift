// Sources/SwiftStack/Codegen/X86/X86ISelArith.swift
//
// Instruction selection of arithmetic, comparisons, `select` and conversions.

import Foundation

extension X86FunctionISel {
    /// The operation size for an integer of `width` bits held in a GPR: 32-bit operations up to 32 bits.
    func opSize(_ width: Int) -> Int { width > 32 ? 8 : 4 }

    /// `r` with its low `width` bits extended (signed or not) to the operation size; `r` itself if no instruction is
    /// needed. The result is a new register whenever an instruction is emitted.
    func extend(_ r: LIRReg, from width: Int, signed: Bool) -> LIRReg {
        switch width {
        case 32, 64:
            return r
        case 8, 16:
            let x = newGPR()
            let op: LIROp = width == 8 ? (signed ? .movsb : .movzb) : (signed ? .movsw : .movzw)
            emit(op, 4, .def(x, 4), .use(r, width / 8))
            return x
        default:
            let size = opSize(width)
            let x = copied(r, size)
            if !signed && width < 32 {
                emit(.and, 4, .useDef(x, 4), .imm(Int64((1 << width) - 1)))
            } else {
                let shift = Int64(size * 8 - width)
                emit(.shl, size, .useDef(x, size), .imm(shift))
                emit(signed ? .sar : .shr, size, .useDef(x, size), .imm(shift))
            }
            return x
        }
    }

    /// `r` (the low `from` bits of it) extended to a full 64-bit register, always as a new register.
    func extendTo64(_ r: LIRReg, from width: Int, signed: Bool) -> LIRReg {
        let x = newGPR()
        switch (width, signed) {
        case (8, false): emit(.movzb, 4, .def(x, 4), .use(r, 1))
        case (16, false): emit(.movzw, 4, .def(x, 4), .use(r, 2))
        case (32, false): emit(.mov, 4, .def(x, 4), .use(r, 4))
        case (8, true): emit(.movsbq, 8, .def(x, 8), .use(r, 1))
        case (16, true): emit(.movswq, 8, .def(x, 8), .use(r, 2))
        case (32, true): emit(.movslq, 8, .def(x, 8), .use(r, 4))
        case (64, _): copy(x, r)
        default:
            if !signed && width < 32 {
                copy(x, r, 4)
                emit(.and, 4, .useDef(x, 4), .imm(Int64((1 << width) - 1)))
            } else {
                copy(x, r)
                emit(.shl, 8, .useDef(x, 8), .imm(Int64(64 - width)))
                emit(signed ? .sar : .shr, 8, .useDef(x, 8), .imm(Int64(64 - width)))
            }
        }
        return x
    }

    /// The right-hand operand of a two-operand instruction: an immediate if `v` is a small constant.
    func rhs(_ v: ValueId, size: Int) -> LIROperand {
        if let c = immediate(v, size: size) { return .imm(c) }
        return .use(gpr(v), size)
    }

    // MARK: - Integer arithmetic

    func integerBinary(_ o: AIROpcode, _ t: AIRType, _ a: ValueId, _ b: ValueId) -> X86Val {
        if t.width > 64 { return wideBinary(o, t, a, b) }
        let w = t.width, size = opSize(w)
        switch o {
        case .add, .sub, .and, .or, .xor:
            let lir: LIROp = o == .add ? .add : o == .sub ? .sub : o == .and ? .and : o == .or ? .or : .xor
            var (x, y) = (a, b)
            if o != .sub, x.valueTag == .constant, y.valueTag != .constant { swap(&x, &y) }
            let r = copied(gpr(x), size)
            emit(lir, size, .useDef(r, size), rhs(y, size: size))
            return .reg(r)
        case .mul:
            var (x, y) = (a, b)
            if x.valueTag == .constant, y.valueTag != .constant { swap(&x, &y) }
            let r = newGPR()
            if let c = immediate(y, size: size) {
                emit(.imul3, size, .def(r, size), .use(gpr(x), size), .imm(c))
            } else {
                copy(r, gpr(x), size)
                emit(.imul, size, .useDef(r, size), .use(gpr(y), size))
            }
            return .reg(r)
        case .shl, .lshr, .ashr:
            let g = gpr(a)
            let e = o == .shl ? g : extend(g, from: w, signed: o == .ashr)
            let r = e == g ? copied(g, size) : e
            let lir: LIROp = o == .shl ? .shl : o == .lshr ? .shr : .sar
            if let c = constantInt(b) {
                emit(lir, size, .useDef(r, size), .imm(c & Int64(size * 8 - 1)))
            } else {
                let count = gpr(b)
                emit(.copy, 4, .def(.physical(.rcx), 4), .use(count, 4))
                emit(lir, size, .useDef(r, size), .use(.physical(.rcx), 1))
            }
            return .reg(r)
        case .sdiv, .srem, .udiv, .urem:
            let signed = o == .sdiv || o == .srem
            let x = extend(gpr(a), from: w, signed: signed)
            let y = extend(gpr(b), from: w, signed: signed)
            emit(.copy, size, .def(.physical(.rax), size), .use(x, size))
            if signed {
                emit(size == 8 ? .cqto : .cltd, size, .implicitDef(.rdx), .implicitUse(.rax))
            } else {
                emit(.zero, 4, .def(.physical(.rdx), 4))
            }
            emit(signed ? .idiv : .div, size, .use(y, size), .implicitUse(.rax), .implicitUse(.rdx), .implicitDef(.rax), .implicitDef(.rdx))
            let r = newGPR()
            copy(r, .physical(o == .sdiv || o == .udiv ? .rax : .rdx), size)
            return .reg(r)
        default:
            report("integer operation \(o.name)")
            return .reg(newGPR())
        }
    }

    // MARK: - Floating arithmetic

    func floatBinary(_ o: AIROpcode, _ t: AIRType, _ a: ValueId, _ b: ValueId) -> X86Val {
        switch t.width {
        case 32, 64:
            let single = t.width == 32
            let lir: LIROp
            switch o {
            case .fadd: lir = single ? .addss : .addsd
            case .fsub: lir = single ? .subss : .subsd
            case .fmul: lir = single ? .mulss : .mulsd
            default: lir = single ? .divss : .divsd
            }
            let r = copied(xmm(a), 16)
            emit(lir, t.width / 8, .useDef(r, 16), .use(xmm(b), 16))
            return .reg(r)
        case 80:
            let s = newValueSlot(t)
            emit(.fldt, 10, LIRAddress.slot(slot(a)).operand(size: 10))
            emit(.fldt, 10, LIRAddress.slot(slot(b)).operand(size: 10))
            // st(1) = st(1) op st(0) and pop; AT&T spells the subtract and divide forms with an `r`
            let lir: LIROp = o == .fadd ? .faddp : o == .fsub ? .fsubrp : o == .fmul ? .fmulp : .fdivrp
            emit(lir, 10)
            emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
            return .slot(s)
        case 128:
            let name = o == .fadd ? "__addtf3" : o == .fsub ? "__subtf3" : o == .fmul ? "__multf3" : "__divtf3"
            return .reg(libcallXMM(name, [.xmm(xmm(a)), .xmm(xmm(b))]))
        case 16:
            let x = halfToFloat(xmm(a)), y = halfToFloat(xmm(b))
            let lir: LIROp = o == .fadd ? .addss : o == .fsub ? .subss : o == .fmul ? .mulss : .divss
            let r = copied(x, 16)
            emit(lir, 4, .useDef(r, 16), .use(y, 16))
            return .reg(floatToHalf(r))
        default:
            report("float operation on \(t)")
            return .reg(newXMM())
        }
    }

    func halfToFloat(_ h: LIRReg) -> LIRReg { libcallXMM("__extendhfsf2", [.xmm(h)]) }
    func floatToHalf(_ f: LIRReg) -> LIRReg { libcallXMM("__truncsfhf2", [.xmm(f)]) }

    /// The 16-byte constant with the sign bit of each element of `width` bits set (or, for `abs`, all other bits).
    func signMask(width: Int, abs: Bool) -> UInt32 {
        var bytes = [UInt8](repeating: 0, count: 16)
        let elementBytes = width / 8
        for e in 0..<(16 / elementBytes) {
            for k in 0..<elementBytes {
                let isTop = k == elementBytes - 1
                bytes[e * elementBytes + k] = abs ? (isTop ? 0x7F : 0xFF) : (isTop ? 0x80 : 0)
            }
        }
        if width == 128 {
            bytes = [UInt8](repeating: abs ? 0xFF : 0, count: 16)
            bytes[15] = abs ? 0x7F : 0x80
        }
        return constantLabel(bytes, alignment: 16)
    }

    func floatUnary(_ o: AIROpcode, _ t: AIRType, _ a: ValueId) -> X86Val {
        switch t.width {
        case 32, 64, 128, 16:
            if t.width == 16 {
                // Integer operations on the bits
                let g = newGPR()
                emit(.movd, 4, .def(g, 4), .use(xmm(a), 16))
                emit(o == .fneg ? .xor : .and, 4, .useDef(g, 4), .imm(o == .fneg ? 0x8000 : 0x7FFF))
                let r = newXMM()
                emit(.movd, 4, .def(r, 16), .use(g, 4))
                return .reg(r)
            }
            let r = copied(xmm(a), 16)
            let mask = signMask(width: t.width, abs: o == .fabs)
            emit(o == .fneg ? .xorps : .andps, 16, .useDef(r, 16), LIRAddress.symbol(mask).operand(size: 16))
            return .reg(r)
        case 80:
            let s = newValueSlot(t)
            emit(.fldt, 10, LIRAddress.slot(slot(a)).operand(size: 10))
            emit(o == .fneg ? .fchs : .fabs, 10)
            emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
            return .slot(s)
        default:
            report("float operation on \(t)")
            return .reg(newXMM())
        }
    }

    // MARK: - Bit operations

    func bitOperation(_ o: AIROpcode, _ t: AIRType, _ a: ValueId) -> X86Val {
        let w = t.width
        if w > 64 { return wideBitOperation(o, t, a) }
        let size = opSize(w)
        switch o {
        case .bswap:
            let r = copied(gpr(a), size)
            if w == 16 {
                emit(.rol, 2, .useDef(r, 2), .imm(8))
            } else if w == 32 || w == 64 {
                emit(.bswap, size, .useDef(r, size))
            } else {
                // A byte swap of an odd number of bytes: swap the containing size and shift the result down
                emit(.bswap, size, .useDef(r, size))
                emit(.shr, size, .useDef(r, size), .imm(Int64(size * 8 - w)))
            }
            return .reg(r)
        case .popcount:
            let x = extend(gpr(a), from: w, signed: false)
            let r = newGPR()
            emit(.popcnt, size, .def(r, size), .use(x, size))
            return .reg(r)
        case .clz:
            // bsr gives the index of the highest set bit; clz = (size bits - 1 - index) - (size bits - w)
            let x = extend(gpr(a), from: w, signed: false)
            let r = newGPR()
            emit(.bsr, size, .def(r, size), .use(x, size))
            emit(.xor, size, .useDef(r, size), .imm(Int64(size * 8 - 1)))
            if size * 8 != w { emit(.sub, size, .useDef(r, size), .imm(Int64(size * 8 - w))) }
            return .reg(r)
        case .ctz:
            let r = newGPR()
            emit(.bsf, size, .def(r, size), .use(gpr(a), size))
            return .reg(r)
        default:
            report("bit operation \(o.name)")
            return .reg(newGPR())
        }
    }

    // MARK: - Comparisons

    static func condition(_ p: AIRICmp) -> X86Cond {
        switch p {
        case .eq: return .e
        case .ne: return .ne
        case .slt: return .l
        case .sle: return .le
        case .sgt: return .g
        case .sge: return .ge
        case .ult: return .b
        case .ule: return .be
        case .ugt: return .a
        case .uge: return .ae
        }
    }

    static func swapped(_ p: AIRICmp) -> AIRICmp {
        switch p {
        case .slt: return .sgt
        case .sle: return .sge
        case .sgt: return .slt
        case .sge: return .sle
        case .ult: return .ugt
        case .ule: return .uge
        case .ugt: return .ult
        case .uge: return .ule
        default: return p
        }
    }

    /// Emits the compare of comparison instruction `i` and returns the condition that holds when it is true.
    func condition(_ i: InstId) -> X86Condition {
        if op(i) == .fcmp { return floatCondition(AIRFCmp(rawValue: aux(i)) ?? .oeq, o0(i), o1(i)) }
        return integerCondition(AIRICmp(rawValue: aux(i)) ?? .eq, o0(i), o1(i))
    }

    func integerCondition(_ predicate: AIRICmp, _ a: ValueId, _ b: ValueId) -> X86Condition {
        var (x, y, p) = (a, b, predicate)
        if x.valueTag == .constant, y.valueTag != .constant { swap(&x, &y); p = Self.swapped(p) }
        let t = ty(x)
        let w = t.isPointer ? 64 : t.width
        if w > 64 { return wideCondition(p, x, y) }
        let signed = p == .slt || p == .sle || p == .sgt || p == .sge
        let native = w == 8 || w == 16 || w == 32 || w == 64
        let size = native ? w / 8 : opSize(w)
        let lhs = native ? gpr(x) : extend(gpr(x), from: w, signed: signed)
        var right: LIROperand
        if let c = constantInt(y) {
            var value = c
            if !native && !signed { value = Int64(bitPattern: UInt64(bitPattern: c) & ((1 << UInt64(w)) - 1)) }
            if size == 1 { value = Int64(Int8(truncatingIfNeeded: value)) }
            if size == 2 { value = Int64(Int16(truncatingIfNeeded: value)) }
            if size == 4 { value = Int64(Int32(truncatingIfNeeded: value)) }
            // A constant too wide for an immediate is materialized as the extended value the compare needs
            right = value >= Int64(Int32.min) && value <= Int64(Int32.max) ? .imm(value) : .use(materializeInt(value, size: 8), size)
        } else {
            right = .use(native ? gpr(y) : extend(gpr(y), from: w, signed: signed), size)
        }
        if right.kind == .imm && right.value == 0 {
            emit(.test, size, .use(lhs, size), .use(lhs, size))
        } else {
            emit(.cmp, size, .use(lhs, size), right)
        }
        return .single(Self.condition(p))
    }

    func floatCondition(_ p: AIRFCmp, _ a: ValueId, _ b: ValueId) -> X86Condition {
        let t = ty(a)
        // The swap that turns `<`-style predicates into `>`-style ones (CF and ZF give `above` without a NaN check)
        var swap = false
        let cond: X86Condition
        switch p {
        case .ogt: cond = .single(.a)
        case .oge: cond = .single(.ae)
        case .olt: swap = true; cond = .single(.a)
        case .ole: swap = true; cond = .single(.ae)
        case .ugt: swap = true; cond = .single(.b)
        case .uge: swap = true; cond = .single(.be)
        case .ult: cond = .single(.b)
        case .ule: cond = .single(.be)
        case .oeq: cond = .both(.e, .np)
        case .une: cond = .either(.ne, .p)
        case .one: cond = .single(.ne)
        case .ueq: cond = .single(.e)
        case .ord: cond = .single(.np)
        case .uno: cond = .single(.p)
        }
        let (x, y) = swap ? (b, a) : (a, b)
        switch t.width {
        case 32, 64:
            emit(t.width == 32 ? .ucomiss : .ucomisd, t.width / 8, .use(xmm(x), 16), .use(xmm(y), 16))
        case 16:
            let fx = halfToFloat(xmm(x)), fy = halfToFloat(xmm(y))
            emit(.ucomiss, 4, .use(fx, 16), .use(fy, 16))
        case 80:
            emit(.fldt, 10, LIRAddress.slot(slot(y)).operand(size: 10))
            emit(.fldt, 10, LIRAddress.slot(slot(x)).operand(size: 10))
            emit(.fucomip, 10)
            emit(.fstp, 10, .imm(0))
        case 128:
            return quadCondition(p, xmm(a), xmm(b))
        default:
            report("float comparison of \(t)")
        }
        return cond
    }

    /// A `_Float128` comparison through the soft-float routines, which return an int that compares with 0 as the
    /// operands do (each one's result for a NaN makes its own predicate false).
    func quadCondition(_ p: AIRFCmp, _ x: LIRReg, _ y: LIRReg) -> X86Condition {
        func call(_ name: String) -> LIRReg { libcallGPR(name, [.xmm(x), .xmm(y)], size: 4) }
        let (name, cc): (String, X86Cond)
        switch p {
        case .oeq: (name, cc) = ("__eqtf2", .e)
        case .une: (name, cc) = ("__netf2", .ne)
        case .ogt: (name, cc) = ("__gttf2", .g)
        case .oge: (name, cc) = ("__getf2", .ge)
        case .olt: (name, cc) = ("__lttf2", .l)
        case .ole: (name, cc) = ("__letf2", .le)
        case .ugt: (name, cc) = ("__letf2", .g)
        case .uge: (name, cc) = ("__lttf2", .ge)
        case .ult: (name, cc) = ("__getf2", .l)
        case .ule: (name, cc) = ("__gttf2", .le)
        case .uno: (name, cc) = ("__unordtf2", .ne)
        case .ord: (name, cc) = ("__unordtf2", .e)
        case .one, .ueq:
            // one: not equal and ordered; ueq: equal or unordered
            let eq = call("__eqtf2"), un = call("__unordtf2")
            let r = newGPR(), s = newGPR()
            emit(.test, 4, .use(eq, 4), .use(eq, 4))
            emit(.setcc, 1, cond: p == .one ? .ne : .e, .def(r, 1))
            emit(.test, 4, .use(un, 4), .use(un, 4))
            emit(.setcc, 1, cond: p == .one ? .e : .ne, .def(s, 1))
            emit(p == .one ? .and : .or, 1, .useDef(r, 1), .use(s, 1))
            emit(.test, 1, .use(r, 1), .use(r, 1))
            return .single(.ne)
        }
        let r = call(name)
        emit(.test, 4, .use(r, 4), .use(r, 4))
        return .single(cc)
    }

    /// The condition register (an `i1` in the low byte) of a condition.
    func materialize(_ c: X86Condition) -> LIRReg {
        let r = newGPR()
        switch c {
        case .single(let cc):
            emit(.setcc, 1, cond: cc, .def(r, 1))
        case .both(let c1, let c2), .either(let c1, let c2):
            let s = newGPR()
            emit(.setcc, 1, cond: c1, .def(r, 1))
            emit(.setcc, 1, cond: c2, .def(s, 1))
            if case .both = c { emit(.and, 1, .useDef(r, 1), .use(s, 1)) } else { emit(.or, 1, .useDef(r, 1), .use(s, 1)) }
        }
        return r
    }

    /// The condition for a branch on `i1` value `v`: its compare if the compare was folded into the branch.
    func branchCondition(_ v: ValueId) -> X86Condition {
        if v.valueTag == .inst, folded[Int(v.index)], op(v.inst) == .icmp || op(v.inst) == .fcmp {
            return condition(v.inst)
        }
        let r = gpr(v)
        emit(.test, 1, .use(r, 1), .imm(1))
        return .single(.ne)
    }

    // MARK: - Select

    func selectValue(_ i: InstId) -> X86Val {
        let c = o0(i), tv = o1(i), fv = ValueId(aux(i))
        let t = resultType(i)
        if t.isInt && t.width <= 64 || t.isPointer {
            let size = t.isPointer ? 8 : opSize(t.width)
            let a = gpr(tv), r = copied(gpr(fv), size)
            let cc = flagCondition(branchCondition(c))
            emit(.cmovcc, size, cond: cc, .useDef(r, size), .use(a, size))
            return .reg(r)
        }
        if t.isInt && t.width <= 128 {
            let (alo, ahi) = pair(tv)
            let (flo, fhi) = pair(fv)
            let lo = copied(flo), hi = copied(fhi)
            let cc = flagCondition(branchCondition(c))
            emit(.cmovcc, 8, cond: cc, .useDef(lo, 8), .use(alo, 8))
            emit(.cmovcc, 8, cond: cc, .useDef(hi, 8), .use(ahi, 8))
            return .pair(lo, hi)
        }
        if isSlotType(t) {
            let s = t.isInt ? wideSlot(t.width) : newValueSlot(t)
            let ts = slot(tv), fs = slot(fv)
            copySlotValue(from: fs, to: s, t)
            let cond = branchCondition(c)
            let then = newBlock(after: cur), join = newBlock(after: then)
            branch(cond, then, join)
            cur = then
            copySlotValue(from: ts, to: s, t)
            jump(join)
            cur = join
            return .slot(s)
        }
        // XMM values: a diamond with a phi
        let a = xmm(tv), f = xmm(fv)
        let cond = branchCondition(c)
        let from = cur
        let then = newBlock(after: cur), join = newBlock(after: then)
        branch(cond, then, join)
        cur = then
        jump(join)
        cur = join
        let r = newXMM()
        lir.blocks[join].phis.append(LIRPhi(def: r, incoming: [(from, f), (then, a)]))
        return .reg(r)
    }

    /// A single condition code for `c`, materializing a two-flag condition into a register and testing it.
    func flagCondition(_ c: X86Condition) -> X86Cond {
        if case .single(let cc) = c { return cc }
        let r = materialize(c)
        emit(.test, 1, .use(r, 1), .use(r, 1))
        return .ne
    }

    // MARK: - Values in slots

    /// Whether values of type `t` live in stack slots (`f80`, integers of more than 128 bits).
    func isSlotType(_ t: AIRType) -> Bool { (t.isFloat && t.width == 80) || (t.isInt && t.width > 128) }

    func copySlotValue(from: UInt32, to: UInt32, _ t: AIRType) {
        if t.isFloat { copyF80(from: from, to: to) } else { copyWords(from: from, to: to, Self.words(t.width)) }
    }

    // MARK: - x87 helpers

    func copyF80(from: UInt32, to: UInt32) {
        guard from != to else { return }
        emit(.fldt, 10, LIRAddress.slot(from).operand(size: 10))
        emit(.fstpt, 10, LIRAddress.slot(to).operand(size: 10))
    }

    /// A scratch slot of `size` bytes.
    func scratchSlot(_ size: Int = 16) -> UInt32 { lir.newSlot(size: size, alignment: 16) }
}

