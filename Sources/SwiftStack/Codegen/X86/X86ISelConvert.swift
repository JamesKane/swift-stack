// Sources/SwiftStack/Codegen/X86/X86ISelConvert.swift
//
// Instruction selection of conversions, and of integers of 65 to 128 bits (pairs of GPRs).

import Foundation

extension X86FunctionISel {
    // MARK: - Conversions

    func convert(_ o: AIROpcode, from ft: AIRType, to tt: AIRType, _ v: ValueId) -> X86Val {
        if (ft.isInt && ft.width > 128) || (tt.isInt && tt.width > 128) { return multiwordConvert(o, from: ft, to: tt, v) }
        switch o {
        case .trunc:
            if ft.width > 64 {
                let (lo, hi) = pair(v)
                return tt.width > 64 ? .pair(lo, hi) : .reg(lo)
            }
            return .reg(gpr(v))
        case .zext, .sext:
            let signed = o == .sext
            if ft.width > 64 {
                let (lo, hi) = pair(v)
                return .pair(lo, extendTo64(hi, from: ft.width - 64, signed: signed))
            }
            if tt.width > 64 {
                let lo = ft.width == 64 ? gpr(v) : extendTo64(gpr(v), from: ft.width, signed: signed)
                let hi = newGPR()
                if signed {
                    copy(hi, lo)
                    emit(.sar, 8, .useDef(hi, 8), .imm(63))
                } else {
                    emit(.zero, 4, .def(hi, 4))
                }
                return .pair(lo, hi)
            }
            if tt.width > 32 || (ft.width < 32 && tt.width <= 32 && ft.width != 8 && ft.width != 16) {
                if tt.width > 32 { return .reg(extendTo64(gpr(v), from: ft.width, signed: signed)) }
            }
            let r = extend(gpr(v), from: ft.width, signed: signed)
            return .reg(r)
        case .ptrtoint, .inttoptr:
            return .reg(gpr(v))
        case .bitcast:
            return bitcast(v, from: ft, to: tt)
        case .fptrunc, .fpext:
            return floatResize(v, from: ft, to: tt)
        case .sitofp, .uitofp:
            return intToFloat(v, from: ft, to: tt, signed: o == .sitofp)
        case .fptosi, .fptoui:
            return floatToInt(v, from: ft, to: tt, signed: o == .fptosi)
        default:
            report("conversion \(o.name)")
            return .none
        }
    }

    func bitcast(_ v: ValueId, from ft: AIRType, to tt: AIRType) -> X86Val {
        if ft.isInt && tt.isFloat {
            switch tt.width {
            case 16, 32:
                let r = newXMM()
                emit(.movd, 4, .def(r, 16), .use(gpr(v), 4))
                return .reg(r)
            case 64:
                let r = newXMM()
                emit(.movq, 8, .def(r, 16), .use(gpr(v), 8))
                return .reg(r)
            case 80:
                let (lo, hi) = pair(v)
                let s = newValueSlot(tt)
                emit(.mov, 8, LIRAddress.slot(s).operand(size: 8), .use(lo, 8))
                emit(.mov, 2, LIRAddress.slot(s, 8).operand(size: 2), .use(hi, 2))
                return .slot(s)
            default:
                let (lo, hi) = pair(v)
                let s = scratchSlot()
                emit(.mov, 8, LIRAddress.slot(s).operand(size: 8), .use(lo, 8))
                emit(.mov, 8, LIRAddress.slot(s, 8).operand(size: 8), .use(hi, 8))
                let r = newXMM()
                emit(.movaps, 16, .def(r, 16), LIRAddress.slot(s).operand(size: 16))
                return .reg(r)
            }
        }
        switch ft.width {
        case 16, 32:
            let r = newGPR()
            emit(.movd, 4, .def(r, 4), .use(xmm(v), 16))
            return .reg(r)
        case 64:
            let r = newGPR()
            emit(.movq, 8, .def(r, 8), .use(xmm(v), 16))
            return .reg(r)
        case 80:
            let s = slot(v)
            let lo = newGPR(), hi = newGPR()
            emit(.mov, 8, .def(lo, 8), LIRAddress.slot(s).operand(size: 8))
            emit(.movzw, 4, .def(hi, 4), LIRAddress.slot(s, 8).operand(size: 2))
            return .pair(lo, hi)
        default:
            let s = scratchSlot()
            emit(.movaps, 16, LIRAddress.slot(s).operand(size: 16), .use(xmm(v), 16))
            let lo = newGPR(), hi = newGPR()
            emit(.mov, 8, .def(lo, 8), LIRAddress.slot(s).operand(size: 8))
            emit(.mov, 8, .def(hi, 8), LIRAddress.slot(s, 8).operand(size: 8))
            return .pair(lo, hi)
        }
    }

    /// Stores an XMM float to a scratch slot and loads it on the x87 stack.
    func loadX87(fromXMM r: LIRReg, width: Int) {
        let s = scratchSlot()
        emit(width == 32 ? .movss : .movsd, width / 8, LIRAddress.slot(s).operand(size: width / 8), .use(r, 16))
        emit(width == 32 ? .flds : .fldl, width / 8, LIRAddress.slot(s).operand(size: width / 8))
    }

    /// Pops the x87 stack top into an XMM register as a float of `width` bits.
    func storeX87(toXMMWidth width: Int) -> LIRReg {
        let s = scratchSlot()
        emit(width == 32 ? .fstps : .fstpl, width / 8, LIRAddress.slot(s).operand(size: width / 8))
        let r = newXMM()
        emit(width == 32 ? .movss : .movsd, width / 8, .def(r, 16), LIRAddress.slot(s).operand(size: width / 8))
        return r
    }

    func floatResize(_ v: ValueId, from ft: AIRType, to tt: AIRType) -> X86Val {
        switch (ft.width, tt.width) {
        case (32, 64), (64, 32):
            let r = newXMM()
            emit(ft.width == 32 ? .cvtss2sd : .cvtsd2ss, 8, .def(r, 16), .use(xmm(v), 16))
            return .reg(r)
        case (32, 80), (64, 80):
            loadX87(fromXMM: xmm(v), width: ft.width)
            let s = newValueSlot(tt)
            emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
            return .slot(s)
        case (80, 32), (80, 64):
            emit(.fldt, 10, LIRAddress.slot(slot(v)).operand(size: 10))
            return .reg(storeX87(toXMMWidth: tt.width))
        case (16, _):
            let f = halfToFloat(xmm(v))
            if tt.width == 32 { return .reg(f) }
            let r = newXMM()
            if tt.width == 64 {
                emit(.cvtss2sd, 8, .def(r, 16), .use(f, 16))
                return .reg(r)
            }
            return floatResizeReg(f, from: 32, to: tt)
        case (_, 16):
            if ft.width == 32 { return .reg(floatToHalf(xmm(v))) }
            // Directly, so that the value is rounded once
            switch ft.width {
            case 64: return .reg(libcallXMM("__truncdfhf2", [.xmm(xmm(v))]))
            case 80: return .reg(libcallXMM("__truncxfhf2", [.x87(slot(v))]))
            default: return .reg(libcallXMM("__trunctfhf2", [.xmm(xmm(v))]))
            }
        case (_, 128):
            switch ft.width {
            case 32: return .reg(libcallXMM("__extendsftf2", [.xmm(xmm(v))]))
            case 64: return .reg(libcallXMM("__extenddftf2", [.xmm(xmm(v))]))
            default: return .reg(libcallXMM("__extendxftf2", [.x87(slot(v))]))
            }
        case (128, _):
            switch tt.width {
            case 32: return .reg(libcallXMM("__trunctfsf2", [.xmm(xmm(v))]))
            case 64: return .reg(libcallXMM("__trunctfdf2", [.xmm(xmm(v))]))
            default: return libcall("__trunctfxf2", [.xmm(xmm(v))], result: .x87)
            }
        default:
            report("float conversion \(ft) to \(tt)")
            return .none
        }
    }

    func floatResizeReg(_ r: LIRReg, from width: Int, to tt: AIRType) -> X86Val {
        switch tt.width {
        case 80:
            loadX87(fromXMM: r, width: width)
            let s = newValueSlot(tt)
            emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
            return .slot(s)
        default:
            return .reg(libcallXMM(width == 32 ? "__extendsftf2" : "__extenddftf2", [.xmm(r)]))
        }
    }

    func intToFloat(_ v: ValueId, from ft: AIRType, to tt: AIRType, signed: Bool) -> X86Val {
        if ft.width > 64 {
            let (lo, hi0) = pair(v)
            let hi = ft.width < 128 ? extendTo64(hi0, from: ft.width - 64, signed: signed) : hi0
            let suffix = tt.width == 32 ? "sf" : tt.width == 64 ? "df" : tt.width == 80 ? "xf" : tt.width == 128 ? "tf" : "hf"
            let name = (signed ? "__floatti" : "__floatunti") + suffix
            if tt.width == 80 { return libcall(name, [.pair(lo, hi)], result: .x87) }
            return .reg(libcallXMM(name, [.pair(lo, hi)]))
        }
        // The operand as a 64-bit integer: exact for every signed value and every unsigned value below 2^63
        let x = extendTo64(gpr(v), from: ft.width, signed: signed)
        let unsigned64 = !signed && ft.width == 64
        switch tt.width {
        case 32, 64:
            let cvt: LIROp = tt.width == 32 ? .cvtsi2ss : .cvtsi2sd
            if !unsigned64 {
                let r = newXMM()
                emit(.zero, 16, .def(r, 16))
                emit(cvt, 8, .useDef(r, 16), .use(x, 8))
                return .reg(r)
            }
            // An unsigned value with the top bit set: halve it (keeping the low bit for rounding), convert, double
            let from = cur
            let big = newBlock(after: cur), join = newBlock(after: big)
            let small = newXMM()
            emit(.zero, 16, .def(small, 16))
            emit(cvt, 8, .useDef(small, 16), .use(x, 8))
            emit(.test, 8, .use(x, 8), .use(x, 8))
            branch(.single(.s), big, join)
            cur = big
            let h = copied(x), low = copied(x)
            emit(.shr, 8, .useDef(h, 8), .imm(1))
            emit(.and, 4, .useDef(low, 4), .imm(1))
            emit(.or, 8, .useDef(h, 8), .use(low, 8))
            let half = newXMM()
            emit(.zero, 16, .def(half, 16))
            emit(cvt, 8, .useDef(half, 16), .use(h, 8))
            emit(tt.width == 32 ? .addss : .addsd, tt.width / 8, .useDef(half, 16), .use(half, 16))
            jump(join)
            cur = join
            let r = newXMM()
            lir.blocks[join].phis.append(LIRPhi(def: r, incoming: [(from, small), (big, half)]))
            return .reg(r)
        case 80:
            let s = newValueSlot(tt)
            let tmp = scratchSlot()
            emit(.mov, 8, LIRAddress.slot(tmp).operand(size: 8), .use(x, 8))
            emit(.fild, 8, LIRAddress.slot(tmp).operand(size: 8))
            emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
            if unsigned64 {
                // fild read it as signed: add 2^64 if the top bit was set
                let fix = newBlock(after: cur), join = newBlock(after: fix)
                emit(.test, 8, .use(x, 8), .use(x, 8))
                branch(.single(.s), fix, join)
                cur = fix
                let twoTo64 = constantLabel([0x00, 0x00, 0x80, 0x5F], alignment: 4)
                emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
                emit(.fadds, 4, LIRAddress.symbol(twoTo64).operand(size: 4))
                emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
                jump(join)
                cur = join
            }
            return .slot(s)
        case 16:
            let f = intToFloat(v, from: ft, to: .f32, signed: signed)
            guard case .reg(let r) = f else { return f }
            return .reg(floatToHalf(r))
        default:
            let name: String
            switch (signed, ft.width > 32) {
            case (true, false): name = "__floatsitf"
            case (true, true): name = "__floatditf"
            case (false, false): name = "__floatunsitf"
            case (false, true): name = "__floatunditf"
            }
            return .reg(libcallXMM(name, [.gpr(x, 8)]))
        }
    }

    func floatToInt(_ v: ValueId, from ft: AIRType, to tt: AIRType, signed: Bool) -> X86Val {
        if tt.width > 64 {
            let suffix = ft.width == 32 ? "sfti" : ft.width == 64 ? "dfti" : ft.width == 80 ? "xfti" : "tfti"
            let name = (signed ? "__fix" : "__fixuns") + suffix
            if ft.width == 16 { return floatToIntFromHalf(v, to: tt, signed: signed) }
            return libcall(name, [ft.width == 80 ? .x87(slot(v)) : .xmm(xmm(v))], result: .pair)
        }
        // A result of at most 63 bits (unsigned) or 64 (signed) comes from a signed 64-bit conversion
        let direct = signed || tt.width < 64
        switch ft.width {
        case 32, 64:
            let cvt: LIROp = ft.width == 32 ? .cvttss2si : .cvttsd2si
            let x = xmm(v)
            let size = tt.width > 32 || !signed ? 8 : 4
            if direct {
                let r = newGPR()
                emit(cvt, size, .def(r, size), .use(x, 16))
                return .reg(r)
            }
            // Unsigned 64-bit: values of 2^63 and above are converted less 2^63, and the top bit set
            let limitBytes: [UInt8] = ft.width == 32 ? [0x00, 0x00, 0x00, 0x5F] : [0, 0, 0, 0, 0, 0, 0xE0, 0x43]
            let limitLabel = constantLabel(limitBytes, alignment: ft.width / 8)
            let limit = newXMM()
            emit(ft.width == 32 ? .movss : .movsd, ft.width / 8, .def(limit, 16), LIRAddress.symbol(limitLabel).operand(size: ft.width / 8))
            let from = cur
            let big = newBlock(after: cur), join = newBlock(after: big)
            let small = newGPR()
            emit(cvt, 8, .def(small, 8), .use(x, 16))
            emit(ft.width == 32 ? .ucomiss : .ucomisd, ft.width / 8, .use(x, 16), .use(limit, 16))
            branch(.single(.ae), big, join)
            cur = big
            let d = copied(x, 16)
            emit(ft.width == 32 ? .subss : .subsd, ft.width / 8, .useDef(d, 16), .use(limit, 16))
            let r2 = newGPR()
            emit(cvt, 8, .def(r2, 8), .use(d, 16))
            let top = materializeInt(Int64.min, size: 8)
            emit(.xor, 8, .useDef(r2, 8), .use(top, 8))
            jump(join)
            cur = join
            let r = newGPR()
            lir.blocks[join].phis.append(LIRPhi(def: r, incoming: [(from, small), (big, r2)]))
            return .reg(r)
        case 80:
            let s = slot(v)
            let tmp = scratchSlot()
            if direct {
                emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
                emit(.fisttp, 8, LIRAddress.slot(tmp).operand(size: 8))
                let r = newGPR()
                emit(.mov, 8, .def(r, 8), LIRAddress.slot(tmp).operand(size: 8))
                return .reg(r)
            }
            // Unsigned 64-bit: as for SSE, against 2^63
            let limit = constantLabel([0x00, 0x00, 0x00, 0x5F], alignment: 4)
            let from = cur
            let big = newBlock(after: cur), join = newBlock(after: big)
            emit(.flds, 4, LIRAddress.symbol(limit).operand(size: 4))
            emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
            emit(.fucomip, 10)
            emit(.fstp, 10, .imm(0))
            emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
            emit(.fisttp, 8, LIRAddress.slot(tmp).operand(size: 8))
            let small = newGPR()
            emit(.mov, 8, .def(small, 8), LIRAddress.slot(tmp).operand(size: 8))
            branch(.single(.ae), big, join)
            cur = big
            emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
            emit(.fsubs, 4, LIRAddress.symbol(limit).operand(size: 4))
            emit(.fisttp, 8, LIRAddress.slot(tmp).operand(size: 8))
            let r2 = newGPR()
            emit(.mov, 8, .def(r2, 8), LIRAddress.slot(tmp).operand(size: 8))
            let top = materializeInt(Int64.min, size: 8)
            emit(.xor, 8, .useDef(r2, 8), .use(top, 8))
            jump(join)
            cur = join
            let r = newGPR()
            lir.blocks[join].phis.append(LIRPhi(def: r, incoming: [(from, small), (big, r2)]))
            return .reg(r)
        case 16:
            return floatToIntFromHalf(v, to: tt, signed: signed)
        default:
            let name: String
            switch (signed, tt.width > 32) {
            case (true, false): name = "__fixtfsi"
            case (true, true): name = "__fixtfdi"
            case (false, false): name = "__fixunstfsi"
            case (false, true): name = "__fixunstfdi"
            }
            return .reg(libcallGPR(name, [.xmm(xmm(v))], size: tt.width > 32 ? 8 : 4))
        }
    }

    func floatToIntFromHalf(_ v: ValueId, to tt: AIRType, signed: Bool) -> X86Val {
        let f = halfToFloat(xmm(v))
        if tt.width > 64 { return libcall(signed ? "__fixsfti" : "__fixunssfti", [.xmm(f)], result: .pair) }
        let r = newGPR()
        emit(.cvttss2si, 8, .def(r, 8), .use(f, 16))
        return .reg(r)
    }

    // MARK: - Integers of 65 to 128 bits

    /// The high word of a pair extended from the value's width.
    func extendedHigh(_ hi: LIRReg, width: Int, signed: Bool) -> LIRReg {
        width >= 128 ? hi : extendTo64(hi, from: width - 64, signed: signed)
    }

    func wideBinary(_ o: AIROpcode, _ t: AIRType, _ a: ValueId, _ b: ValueId) -> X86Val {
        if t.width > 128 { return multiwordBinary(o, t, a, b) }
        switch o {
        case .add, .sub:
            let (alo, ahi) = pair(a), (blo, bhi) = pair(b)
            let lo = copied(alo), hi = copied(ahi)
            emit(o == .add ? .add : .sub, 8, .useDef(lo, 8), .use(blo, 8))
            emit(o == .add ? .adc : .sbb, 8, .useDef(hi, 8), .use(bhi, 8))
            return .pair(lo, hi)
        case .and, .or, .xor:
            let (alo, ahi) = pair(a), (blo, bhi) = pair(b)
            let lir: LIROp = o == .and ? .and : o == .or ? .or : .xor
            let lo = copied(alo), hi = copied(ahi)
            emit(lir, 8, .useDef(lo, 8), .use(blo, 8))
            emit(lir, 8, .useDef(hi, 8), .use(bhi, 8))
            return .pair(lo, hi)
        case .mul:
            let (alo, ahi) = pair(a), (blo, bhi) = pair(b)
            let cross1 = copied(alo), cross2 = copied(ahi)
            emit(.imul, 8, .useDef(cross1, 8), .use(bhi, 8))
            emit(.imul, 8, .useDef(cross2, 8), .use(blo, 8))
            emit(.copy, 8, .def(.physical(.rax), 8), .use(alo, 8))
            emit(.mul, 8, .use(blo, 8), .implicitUse(.rax), .implicitDef(.rax), .implicitDef(.rdx))
            let lo = newGPR(), hi = newGPR()
            copy(lo, .physical(.rax))
            copy(hi, .physical(.rdx))
            emit(.add, 8, .useDef(hi, 8), .use(cross1, 8))
            emit(.add, 8, .useDef(hi, 8), .use(cross2, 8))
            return .pair(lo, hi)
        case .sdiv, .srem, .udiv, .urem:
            let signed = o == .sdiv || o == .srem
            let (alo, ahi) = pair(a), (blo, bhi) = pair(b)
            let x = (alo, extendedHigh(ahi, width: t.width, signed: signed))
            let y = (blo, extendedHigh(bhi, width: t.width, signed: signed))
            let name = o == .sdiv ? "__divti3" : o == .udiv ? "__udivti3" : o == .srem ? "__modti3" : "__umodti3"
            return libcall(name, [.pair(x.0, x.1), .pair(y.0, y.1)], result: .pair)
        case .shl, .lshr, .ashr:
            let (alo, ahi0) = pair(a)
            let ahi = o == .shl ? ahi0 : extendedHigh(ahi0, width: t.width, signed: o == .ashr)
            if let c0 = constantInt(b) {
                let c = Int(c0 & 127)
                if c == 0 { return .pair(alo, ahi) }
                let lo = newGPR(), hi = newGPR()
                if c < 64 {
                    copy(lo, alo)
                    copy(hi, ahi)
                    switch o {
                    case .shl:
                        emit(.shld, 8, .useDef(hi, 8), .use(alo, 8), .imm(Int64(c)))
                        emit(.shl, 8, .useDef(lo, 8), .imm(Int64(c)))
                    default:
                        emit(.shrd, 8, .useDef(lo, 8), .use(ahi, 8), .imm(Int64(c)))
                        emit(o == .lshr ? .shr : .sar, 8, .useDef(hi, 8), .imm(Int64(c)))
                    }
                } else {
                    switch o {
                    case .shl:
                        copy(hi, alo)
                        if c > 64 { emit(.shl, 8, .useDef(hi, 8), .imm(Int64(c - 64))) }
                        emit(.zero, 4, .def(lo, 4))
                    case .lshr:
                        copy(lo, ahi)
                        if c > 64 { emit(.shr, 8, .useDef(lo, 8), .imm(Int64(c - 64))) }
                        emit(.zero, 4, .def(hi, 4))
                    default:
                        copy(lo, ahi)
                        if c > 64 { emit(.sar, 8, .useDef(lo, 8), .imm(Int64(c - 64))) }
                        copy(hi, ahi)
                        emit(.sar, 8, .useDef(hi, 8), .imm(63))
                    }
                }
                return .pair(lo, hi)
            }
            let count = gpr(b)
            let name = o == .shl ? "__ashlti3" : o == .lshr ? "__lshrti3" : "__ashrti3"
            return libcall(name, [.pair(alo, ahi), .gpr(count, 4)], result: .pair)
        default:
            report("integer operation \(o.name) on \(t)")
            return .pair(newGPR(), newGPR())
        }
    }

    func wideCondition(_ p: AIRICmp, _ a: ValueId, _ b: ValueId) -> X86Condition {
        let t = ty(a)
        if t.width > 128 { return multiwordCondition(p, a, b) }
        let signed = p == .slt || p == .sle || p == .sgt || p == .sge
        let (alo, ahi0) = pair(a), (blo, bhi0) = pair(b)
        let ahi = extendedHigh(ahi0, width: t.width, signed: signed), bhi = extendedHigh(bhi0, width: t.width, signed: signed)
        if p == .eq || p == .ne {
            let lo = copied(alo), hi = copied(ahi)
            emit(.xor, 8, .useDef(lo, 8), .use(blo, 8))
            emit(.xor, 8, .useDef(hi, 8), .use(bhi, 8))
            emit(.or, 8, .useDef(lo, 8), .use(hi, 8))
            return .single(p == .eq ? .e : .ne)
        }
        // The flags of x - y over both words, with x < y as the condition (swapped for > and <=)
        let swap = p == .ugt || p == .ule || p == .sgt || p == .sle
        let (xlo, xhi, ylo, yhi) = swap ? (blo, bhi, alo, ahi) : (alo, ahi, blo, bhi)
        emit(.cmp, 8, .use(xlo, 8), .use(ylo, 8))
        let t2 = copied(xhi)
        emit(.sbb, 8, .useDef(t2, 8), .use(yhi, 8))
        switch p {
        case .ult, .ugt: return .single(.b)
        case .uge, .ule: return .single(.ae)
        case .slt, .sgt: return .single(.l)
        default: return .single(.ge)
        }
    }

    func wideBitOperation(_ o: AIROpcode, _ t: AIRType, _ a: ValueId) -> X86Val {
        if t.width > 128 { return multiwordBitOperation(o, t, a) }
        let (lo, hi0) = pair(a)
        let zeroHi = newGPR()
        switch o {
        case .popcount:
            let hi = extendedHigh(hi0, width: t.width, signed: false)
            let r = newGPR(), s = newGPR()
            emit(.popcnt, 8, .def(r, 8), .use(lo, 8))
            emit(.popcnt, 8, .def(s, 8), .use(hi, 8))
            emit(.add, 8, .useDef(r, 8), .use(s, 8))
            emit(.zero, 4, .def(zeroHi, 4))
            return .pair(r, zeroHi)
        case .bswap:
            // Of 128 bits: the words swapped and each byte-swapped (narrower widths shift down after)
            let nlo = copied(hi0), nhi = copied(lo)
            emit(.bswap, 8, .useDef(nlo, 8))
            emit(.bswap, 8, .useDef(nhi, 8))
            if t.width < 128 {
                let k = Int64(128 - t.width)
                emit(.shrd, 8, .useDef(nlo, 8), .use(nhi, 8), .imm(k))
                emit(.shr, 8, .useDef(nhi, 8), .imm(k))
            }
            return .pair(nlo, nhi)
        case .clz:
            let hi = extendedHigh(hi0, width: t.width, signed: false)
            let r = newGPR(), s = newGPR()
            emit(.bsr, 8, .def(r, 8), .use(hi, 8))
            emit(.xor, 8, .useDef(r, 8), .imm(63))
            emit(.bsr, 8, .def(s, 8), .use(lo, 8))
            emit(.xor, 8, .useDef(s, 8), .imm(127))
            emit(.test, 8, .use(hi, 8), .use(hi, 8))
            emit(.cmovcc, 8, cond: .e, .useDef(r, 8), .use(s, 8))
            if t.width < 128 { emit(.sub, 8, .useDef(r, 8), .imm(Int64(128 - t.width))) }
            emit(.zero, 4, .def(zeroHi, 4))
            return .pair(r, zeroHi)
        case .ctz:
            let r = newGPR(), s = newGPR()
            emit(.bsf, 8, .def(r, 8), .use(lo, 8))
            emit(.bsf, 8, .def(s, 8), .use(hi0, 8))
            emit(.add, 8, .useDef(s, 8), .imm(64))
            emit(.test, 8, .use(lo, 8), .use(lo, 8))
            emit(.cmovcc, 8, cond: .e, .useDef(r, 8), .use(s, 8))
            emit(.zero, 4, .def(zeroHi, 4))
            return .pair(r, zeroHi)
        default:
            report("bit operation \(o.name) on \(t)")
            return .pair(newGPR(), newGPR())
        }
    }
}
