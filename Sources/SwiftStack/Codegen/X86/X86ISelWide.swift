// Sources/SwiftStack/Codegen/X86/X86ISelWide.swift
//
// Integers wider than 128 bits (`_BitInt(N)`, N up to 8192). Each value lives in a stack slot of its own, as 64-bit
// words least significant first; the bits of the top word above N are unspecified, as for narrower integers, and
// are extended where the result depends on them. Addition, subtraction, bitwise operations, shifts and comparisons
// are inline word sequences; multiplication, division and conversions to and from floats call the libgcc routines
// GCC uses for `_BitInt` (`__mulbitint3`, `__divmodbitint4`, `__floatbitint*`, `__fix*bitint`), which take each
// operand's precision: N, negated for a signed one.

import Foundation

extension X86FunctionISel {
    static func words(_ width: Int) -> Int { (width + 63) / 64 }

    func wideSlot(_ width: Int) -> UInt32 { lir.newSlot(size: 8 * Self.words(width), alignment: 16) }

    /// The slot of a wide value.
    func wide(_ v: ValueId) -> UInt32 {
        if case .slot(let s) = value(v) { return s }
        report("no wide integer for \(v.rawIndex)")
        return wideSlot(ty(v).width)
    }

    func word(_ s: UInt32, _ k: Int) -> LIRAddress { .slot(s, Int64(8 * k)) }

    func copyWords(from: UInt32, to: UInt32, _ n: Int) {
        guard from != to else { return }
        copyBytes(to: .slot(to), from: .slot(from), 8 * n)
    }

    /// A copy of `s` with the top word's bits above `width` extended (signed or not).
    func normalizedWide(_ s: UInt32, width: Int, signed: Bool) -> UInt32 {
        let n = Self.words(width)
        let topBits = width - 64 * (n - 1)
        let out = wideSlot(width)
        copyWords(from: s, to: out, n)
        if topBits < 64 {
            let top = loadBytes(word(s, n - 1), 8)
            let x = extendTo64(top, from: topBits, signed: signed)
            emit(.mov, 8, word(out, n - 1).operand(size: 8), .use(x, 8))
        }
        return out
    }

    /// A constant of more than 128 bits.
    func wideConstant(_ words: [UInt64], width: Int) -> X86Val {
        let n = Self.words(width)
        let s = wideSlot(width)
        for k in 0..<n {
            let w = k < words.count ? Int64(bitPattern: words[k]) : 0
            if w >= Int64(Int32.min) && w <= Int64(Int32.max) {
                emit(.mov, 8, word(s, k).operand(size: 8), .imm(w))
            } else {
                emit(.mov, 8, word(s, k).operand(size: 8), .use(materializeInt(w, size: 8), 8))
            }
        }
        return .slot(s)
    }

    /// The value of integer `v` (of any width) as a wide value of `width` bits, extended as `signed` says.
    func widened(_ v: ValueId, to width: Int, signed: Bool) -> UInt32 {
        let t = ty(v)
        let n = Self.words(width)
        if t.width > 128 {
            let m = Self.words(t.width)
            let src = normalizedWide(wide(v), width: t.width, signed: signed)
            if m >= n { return src }
            let out = wideSlot(width)
            copyWords(from: src, to: out, m)
            let fill = signedFill(word(src, m - 1), signed: signed)
            for k in m..<n { emit(.mov, 8, word(out, k).operand(size: 8), .use(fill, 8)) }
            return out
        }
        let out = wideSlot(width)
        var low: [LIRReg]
        if t.width > 64 {
            let (lo, hi) = pair(v)
            low = [lo, extendedHigh(hi, width: t.width, signed: signed)]
        } else {
            low = [t.width == 64 ? gpr(v) : extendTo64(gpr(v), from: t.isPointer ? 64 : t.width, signed: signed)]
        }
        for (k, r) in low.enumerated() { emit(.mov, 8, word(out, k).operand(size: 8), .use(r, 8)) }
        let fill = newGPR()
        if signed {
            copy(fill, low.last!)
            emit(.sar, 8, .useDef(fill, 8), .imm(63))
        } else {
            emit(.zero, 4, .def(fill, 4))
        }
        for k in low.count..<n { emit(.mov, 8, word(out, k).operand(size: 8), .use(fill, 8)) }
        return out
    }

    /// 0, or all ones if the word at `a` is negative (for `signed`).
    func signedFill(_ a: LIRAddress, signed: Bool) -> LIRReg {
        let fill = newGPR()
        if signed {
            emit(.mov, 8, .def(fill, 8), a.operand(size: 8))
            emit(.sar, 8, .useDef(fill, 8), .imm(63))
        } else {
            emit(.zero, 4, .def(fill, 4))
        }
        return fill
    }

    // MARK: - Arithmetic

    func multiwordBinary(_ o: AIROpcode, _ t: AIRType, _ a: ValueId, _ b: ValueId) -> X86Val {
        let w = t.width, n = Self.words(w)
        switch o {
        case .add, .sub, .and, .or, .xor:
            let x = wide(a), y = wide(b)
            let out = wideSlot(w)
            for k in 0..<n {
                let r = loadBytes(word(x, k), 8)
                let op: LIROp
                switch o {
                case .add: op = k == 0 ? .add : .adc
                case .sub: op = k == 0 ? .sub : .sbb
                case .and: op = .and
                case .or: op = .or
                default: op = .xor
                }
                emit(op, 8, .useDef(r, 8), word(y, k).operand(size: 8))
                emit(.mov, 8, word(out, k).operand(size: 8), .use(r, 8))
            }
            return .slot(out)
        case .mul:
            let out = wideSlot(w)
            let x = wide(a), y = wide(b)
            libcallVoid("__mulbitint3", [.gpr(lea(.slot(out)), 8), .gpr(materializeInt(Int64(w), size: 4), 4),
                                          .gpr(lea(.slot(x)), 8), .gpr(materializeInt(Int64(w), size: 4), 4),
                                          .gpr(lea(.slot(y)), 8), .gpr(materializeInt(Int64(w), size: 4), 4)])
            return .slot(out)
        case .sdiv, .udiv, .srem, .urem:
            let signed = o == .sdiv || o == .srem
            let x = normalizedWide(wide(a), width: w, signed: signed), y = normalizedWide(wide(b), width: w, signed: signed)
            let quotient = wideSlot(w), remainder = wideSlot(w)
            // The results' precisions are positive (as GCC passes them); the operands' are negative if signed
            let prec = Int64(signed ? -w : w)
            libcallVoid("__divmodbitint4", [.gpr(lea(.slot(quotient)), 8), .gpr(materializeInt(Int64(w), size: 4), 4),
                                             .gpr(lea(.slot(remainder)), 8), .gpr(materializeInt(Int64(w), size: 4), 4),
                                             .gpr(lea(.slot(x)), 8), .gpr(materializeInt(prec, size: 4), 4),
                                             .gpr(lea(.slot(y)), 8), .gpr(materializeInt(prec, size: 4), 4)])
            return .slot(o == .sdiv || o == .udiv ? quotient : remainder)
        case .shl, .lshr, .ashr:
            let signed = o == .ashr
            let x = o == .shl ? wide(a) : normalizedWide(wide(a), width: w, signed: signed)
            if b.valueTag == .constant { return .slot(wideShift(o, x, Int((constantWords(b).first ?? 0) % UInt64(w)), width: w)) }
            return .slot(wideVariableShift(o, x, count: gpr(b), countWidth: ty(b).width, width: w))
        default:
            report("integer operation \(o.name) on \(t)")
            return .slot(wideSlot(w))
        }
    }

    /// A shift by a constant: whole words move, and the rest shifts with `shld`/`shrd`.
    func wideShift(_ o: AIROpcode, _ x: UInt32, _ c: Int, width w: Int) -> UInt32 {
        let n = Self.words(w)
        let q = c / 64, r = c % 64
        let out = wideSlot(w)
        let fill = o == .ashr ? signedFill(word(x, n - 1), signed: true) : nil
        func source(_ k: Int) -> LIRReg {
            if k >= 0 && k < n { return loadBytes(word(x, k), 8) }
            if let fill { return fill }
            let z = newGPR()
            emit(.zero, 4, .def(z, 4))
            return z
        }
        for k in 0..<n {
            let result: LIRReg
            if o == .shl {
                // word k = (x[k-q] << r) | (x[k-q-1] >> (64 - r))
                result = source(k - q)
                if r != 0 { emit(.shld, 8, .useDef(result, 8), .use(source(k - q - 1), 8), .imm(Int64(r))) }
            } else {
                // word k = (x[k+q] >> r) | (x[k+q+1] << (64 - r))
                result = source(k + q)
                if r != 0 { emit(.shrd, 8, .useDef(result, 8), .use(source(k + q + 1), 8), .imm(Int64(r))) }
            }
            emit(.mov, 8, word(out, k).operand(size: 8), .use(result, 8))
        }
        return out
    }

    /// A shift by a register count: the value is placed in a buffer padded with zero (or sign) words on the side
    /// that shifts in, and each result word is read from the buffer at an index the count gives.
    func wideVariableShift(_ o: AIROpcode, _ x: UInt32, count: LIRReg, countWidth: Int, width w: Int) -> UInt32 {
        let n = Self.words(w)
        let buffer = lir.newSlot(size: 8 * (2 * n + 2), alignment: 16)
        let fill = o == .ashr ? signedFill(word(x, n - 1), signed: true) : {
            let z = newGPR()
            emit(.zero, 4, .def(z, 4))
            return z
        }()
        // shl: [pad (n + 1 words)][x]; shr: [x][pad (n + 1 words)]
        let valueAt = o == .shl ? n + 1 : 0
        let padAt = o == .shl ? 0 : n
        for k in 0..<(n + 1) { emit(.mov, 8, word(buffer, padAt + k).operand(size: 8), .use(fill, 8)) }
        for k in 0..<n { emit(.mov, 8, word(buffer, valueAt + k).operand(size: 8), .use(loadBytes(word(x, k), 8), 8)) }
        // q = count / 64 (as a word index), r = count % 64 in %cl
        let c = extendTo64(count, from: min(countWidth, 64), signed: false)
        let q = copied(c)
        emit(.shr, 8, .useDef(q, 8), .imm(6))
        if o == .shl { emit(.neg, 8, .useDef(q, 8)) }
        let base = lea(.slot(buffer))
        let out = wideSlot(w)
        for k in 0..<n {
            let lo = newGPR(), hi = newGPR()
            if o == .shl {
                // word k = shld(buf[n + 1 + k - q], buf[n + k - q], r)
                emit(.mov, 8, .def(lo, 8), LIRAddress(base: base, index: q, scale: 8, disp: Int64(8 * (n + 1 + k))).operand(size: 8))
                emit(.mov, 8, .def(hi, 8), LIRAddress(base: base, index: q, scale: 8, disp: Int64(8 * (n + k))).operand(size: 8))
                emit(.copy, 4, .def(.physical(.rcx), 4), .use(c, 4))
                emit(.shld, 8, .useDef(lo, 8), .use(hi, 8), .use(.physical(.rcx), 1))
            } else {
                // word k = shrd(buf[k + q], buf[k + q + 1], r)
                emit(.mov, 8, .def(lo, 8), LIRAddress(base: base, index: q, scale: 8, disp: Int64(8 * k)).operand(size: 8))
                emit(.mov, 8, .def(hi, 8), LIRAddress(base: base, index: q, scale: 8, disp: Int64(8 * (k + 1))).operand(size: 8))
                emit(.copy, 4, .def(.physical(.rcx), 4), .use(c, 4))
                emit(.shrd, 8, .useDef(lo, 8), .use(hi, 8), .use(.physical(.rcx), 1))
            }
            emit(.mov, 8, word(out, k).operand(size: 8), .use(lo, 8))
        }
        return out
    }

    /// The flags of a comparison of two wide values.
    func multiwordCondition(_ p: AIRICmp, _ a: ValueId, _ b: ValueId) -> X86Condition {
        let t = ty(a)
        let w = t.width, n = Self.words(w)
        let signed = p == .slt || p == .sle || p == .sgt || p == .sge
        let x = normalizedWide(wide(a), width: w, signed: signed), y = normalizedWide(wide(b), width: w, signed: signed)
        if p == .eq || p == .ne {
            let acc = loadBytes(word(x, 0), 8)
            emit(.xor, 8, .useDef(acc, 8), word(y, 0).operand(size: 8))
            for k in 1..<n {
                let r = loadBytes(word(x, k), 8)
                emit(.xor, 8, .useDef(r, 8), word(y, k).operand(size: 8))
                emit(.or, 8, .useDef(acc, 8), .use(r, 8))
            }
            return .single(p == .eq ? .e : .ne)
        }
        let swap = p == .ugt || p == .ule || p == .sgt || p == .sle
        let (l, r) = swap ? (y, x) : (x, y)
        for k in 0..<n {
            let v = loadBytes(word(l, k), 8)
            emit(k == 0 ? .cmp : .sbb, 8, k == 0 ? .use(v, 8) : .useDef(v, 8), word(r, k).operand(size: 8))
        }
        switch p {
        case .ult, .ugt: return .single(.b)
        case .uge, .ule: return .single(.ae)
        case .slt, .sgt: return .single(.l)
        default: return .single(.ge)
        }
    }

    func multiwordBitOperation(_ o: AIROpcode, _ t: AIRType, _ a: ValueId) -> X86Val {
        let w = t.width, n = Self.words(w)
        let x = normalizedWide(wide(a), width: w, signed: false)
        let total = newGPR()
        switch o {
        case .popcount:
            emit(.zero, 4, .def(total, 4))
            for k in 0..<n {
                let c = newGPR()
                emit(.popcnt, 8, .def(c, 8), word(x, k).operand(size: 8))
                emit(.add, 8, .useDef(total, 8), .use(c, 8))
            }
        case .clz, .ctz:
            // Scanning from the far end, each nonzero word replaces the count
            let order = o == .clz ? Array(0..<n) : Array((0..<n).reversed())
            materializeIntInto(total, Int64(64 * n))
            for k in order {
                let v = loadBytes(word(x, k), 8)
                let c = newGPR()
                if o == .clz {
                    emit(.bsr, 8, .def(c, 8), .use(v, 8))
                    emit(.xor, 8, .useDef(c, 8), .imm(63))
                    emit(.add, 8, .useDef(c, 8), .imm(Int64(64 * (n - 1 - k))))
                } else {
                    emit(.bsf, 8, .def(c, 8), .use(v, 8))
                    emit(.add, 8, .useDef(c, 8), .imm(Int64(64 * k)))
                }
                emit(.test, 8, .use(v, 8), .use(v, 8))
                emit(.cmovcc, 8, cond: .ne, .useDef(total, 8), .use(c, 8))
            }
            if o == .clz { emit(.sub, 8, .useDef(total, 8), .imm(Int64(64 * n - w))) }
        default:
            report("bit operation \(o.name) on \(t)")
        }
        let out = wideSlot(w)
        emit(.mov, 8, word(out, 0).operand(size: 8), .use(total, 8))
        for k in 1..<n { emit(.mov, 8, word(out, k).operand(size: 8), .imm(0)) }
        return .slot(out)
    }

    func materializeIntInto(_ r: LIRReg, _ c: Int64) {
        emit(.mov, 8, .def(r, 8), .imm(c))
    }

    // MARK: - Conversions

    func multiwordConvert(_ o: AIROpcode, from ft: AIRType, to tt: AIRType, _ v: ValueId) -> X86Val {
        switch o {
        case .trunc:
            let s = wide(v)
            if tt.width > 128 {
                let out = wideSlot(tt.width)
                copyWords(from: s, to: out, Self.words(tt.width))
                return .slot(out)
            }
            if tt.width > 64 { return .pair(loadBytes(word(s, 0), 8), loadBytes(word(s, 1), 8)) }
            return .reg(loadBytes(word(s, 0), 8))
        case .zext, .sext:
            return .slot(widened(v, to: tt.width, signed: o == .sext))
        case .sitofp, .uitofp:
            let signed = o == .sitofp
            let x = ft.width > 128 ? normalizedWide(wide(v), width: ft.width, signed: signed) : widened(v, to: ft.width, signed: signed)
            let prec = materializeInt(Int64(signed ? -ft.width : ft.width), size: 4)
            let suffix = tt.width == 32 ? "sf" : tt.width == 64 ? "df" : tt.width == 80 ? "xf" : tt.width == 128 ? "tf" : "hf"
            let name = "__floatbitint" + suffix
            if tt.width == 80 { return libcall(name, [.gpr(lea(.slot(x)), 8), .gpr(prec, 4)], result: .x87) }
            return .reg(libcallXMM(name, [.gpr(lea(.slot(x)), 8), .gpr(prec, 4)]))
        case .fptosi, .fptoui:
            let out = wideSlot(tt.width)
            let prec = materializeInt(Int64(o == .fptosi ? -tt.width : tt.width), size: 4)
            let suffix = ft.width == 32 ? "sf" : ft.width == 64 ? "df" : ft.width == 80 ? "xf" : ft.width == 128 ? "tf" : "hf"
            let arg: X86LibArg = ft.width == 80 ? .x87(slot(v)) : .xmm(xmm(v))
            libcallVoid("__fix\(suffix)bitint", [.gpr(lea(.slot(out)), 8), .gpr(prec, 4), arg])
            return .slot(out)
        case .bitcast:
            report("bitcast of \(ft) to \(tt)")
            return .none
        default:
            report("conversion \(o.name) of \(ft) to \(tt)")
            return .none
        }
    }

    func libcallVoid(_ name: String, _ args: [X86LibArg]) {
        _ = libcall(name, args, result: .none)
    }
}
