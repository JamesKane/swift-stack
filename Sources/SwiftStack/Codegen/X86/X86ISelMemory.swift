// Sources/SwiftStack/Codegen/X86/X86ISelMemory.swift
//
// Instruction selection of loads, stores, block copies and fills.

import Foundation

extension X86FunctionISel {
    /// Loads `bytes` (1 to 8) bytes at `a` into a new GPR, zero-extended: in pieces of 4, 2 and 1 for 3, 5, 6 and 7.
    func loadBytes(_ a: LIRAddress, _ bytes: Int) -> LIRReg {
        let r = newGPR()
        switch bytes {
        case 1: emit(.movzb, 4, .def(r, 4), a.operand(size: 1))
        case 2: emit(.movzw, 4, .def(r, 4), a.operand(size: 2))
        case 4: emit(.mov, 4, .def(r, 4), a.operand(size: 4))
        case 8: emit(.mov, 8, .def(r, 8), a.operand(size: 8))
        default:
            let low = bytes >= 4 ? 4 : 2
            emit(low == 4 ? .mov : .movzw, 4, .def(r, 4), a.operand(size: low))
            var done = low
            while done < bytes {
                let piece = bytes - done >= 2 ? 2 : 1
                let p = newGPR()
                emit(piece == 2 ? .movzw : .movzb, 4, .def(p, 4), a.adding(Int64(done)).operand(size: piece))
                emit(.shl, 8, .useDef(p, 8), .imm(Int64(done * 8)))
                emit(.or, 8, .useDef(r, 8), .use(p, 8))
                done += piece
            }
        }
        return r
    }

    /// Stores the low `bytes` (1 to 8) bytes of `r` at `a`.
    func storeBytes(_ r: LIRReg, _ a: LIRAddress, _ bytes: Int) {
        switch bytes {
        case 1, 2, 4, 8: emit(.mov, bytes, a.operand(size: bytes), .use(r, bytes))
        default:
            let low = bytes >= 4 ? 4 : 2
            emit(.mov, low, a.operand(size: low), .use(r, low))
            var done = low
            let rest = copied(r)
            emit(.shr, 8, .useDef(rest, 8), .imm(Int64(low * 8)))
            while done < bytes {
                let piece = bytes - done >= 2 ? 2 : 1
                emit(.mov, piece, a.adding(Int64(done)).operand(size: piece), .use(rest, piece))
                if done + piece < bytes { emit(.shr, 8, .useDef(rest, 8), .imm(Int64(piece * 8))) }
                done += piece
            }
        }
    }

    func load(_ address: ValueId, type t: AIRType, flags: AIRMemFlags) -> X86Val {
        let a = addressOf(address)
        switch t.kind {
        case .int, .pointer:
            let bytes = t.isPointer ? 8 : (t.width + 7) / 8
            if bytes <= 8 { return .reg(loadBytes(a, bytes)) }
            if bytes > 16 {
                let s = wideSlot(t.width)
                copyBytes(to: .slot(s), from: a, bytes)
                return .slot(s)
            }
            let lo = loadBytes(a, 8)
            return .pair(lo, loadBytes(a.adding(8), bytes - 8))
        case .float:
            switch t.width {
            case 80:
                let s = newValueSlot(t)
                emit(.fldt, 10, a.operand(size: 10))
                emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
                return .slot(s)
            case 16:
                let g = loadBytes(a, 2)
                let r = newXMM()
                emit(.movd, 4, .def(r, 16), .use(g, 4))
                return .reg(r)
            default:
                let r = newXMM()
                let op: LIROp = t.width == 32 ? .movss : t.width == 64 ? .movsd : .movups
                emit(op, t.width / 8, .def(r, 16), a.operand(size: t.width / 8))
                return .reg(r)
            }
        case .void:
            return .none
        }
    }

    func store(_ v: ValueId, to address: ValueId, flags: AIRMemFlags) {
        let t = ty(v)
        switch t.kind {
        case .int, .pointer:
            let bytes = t.isPointer ? 8 : (t.width + 7) / 8
            if bytes == 1 || bytes == 2 || bytes == 4 || bytes == 8, let c = constantInt(v) {
                var value = c
                if bytes == 1 { value = Int64(Int8(truncatingIfNeeded: c)) }
                if bytes == 2 { value = Int64(Int16(truncatingIfNeeded: c)) }
                if bytes == 4 { value = Int64(Int32(truncatingIfNeeded: c)) }
                if value >= Int64(Int32.min) && value <= Int64(Int32.max) {
                    let a = addressOf(address)
                    emit(.mov, bytes, a.operand(size: bytes), .imm(value))
                    return
                }
            }
            if bytes <= 8 {
                let r = gpr(v)
                storeBytes(r, addressOf(address), bytes)
                return
            }
            if bytes > 16 {
                let s = wide(v)
                copyBytes(to: addressOf(address), from: .slot(s), bytes)
                return
            }
            let (lo, hi) = pair(v)
            let a = addressOf(address)
            storeBytes(lo, a, 8)
            storeBytes(hi, a.adding(8), min(bytes - 8, 8))
        case .float:
            switch t.width {
            case 80:
                let s = slot(v)
                let a = addressOf(address)
                emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
                emit(.fstpt, 10, a.operand(size: 10))
            case 16:
                let g = newGPR()
                emit(.movd, 4, .def(g, 4), .use(xmm(v), 16))
                emit(.mov, 2, addressOf(address).operand(size: 2), .use(g, 2))
            default:
                let r = xmm(v)
                let op: LIROp = t.width == 32 ? .movss : t.width == 64 ? .movsd : .movups
                emit(op, t.width / 8, addressOf(address).operand(size: t.width / 8), .use(r, 16))
            }
        case .void:
            break
        }
    }

    // MARK: - Block copies and fills

    func copyMemory(to dst: ValueId, from src: ValueId, size: ValueId) {
        if let n = constantInt(size), n >= 0, n <= 128 {
            copyMemory(to: dst, from: src, constantSize: Int(n), alignment: 1)
            return
        }
        let d = lea(addressOf(dst)), s = lea(addressOf(src)), n = gpr(size)
        repMovs(d, s, n)
    }

    func copyMemory(to dst: ValueId, from src: ValueId, constantSize n: Int, alignment: Int) {
        copyBytes(to: addressOf(dst), from: addressOf(src), n)
    }

    /// Copies `n` bytes from `src` to `dst` through a GPR, 8 bytes at a time (larger copies use `rep movsb`).
    func copyBytes(to dst: LIRAddress, from src: LIRAddress, _ n: Int) {
        if n > 128 {
            let count = materializeInt(Int64(n), size: 8)
            repMovs(lea(dst), lea(src), count)
            return
        }
        var done = 0
        while done < n {
            let piece = n - done >= 8 ? 8 : n - done >= 4 ? 4 : n - done >= 2 ? 2 : 1
            let r = loadBytes(src.adding(Int64(done)), piece)
            emit(.mov, piece, dst.adding(Int64(done)).operand(size: piece), .use(r, piece))
            done += piece
        }
    }

    func repMovs(_ d: LIRReg, _ s: LIRReg, _ n: LIRReg) {
        emit(.copy, 8, .def(.physical(.rdi), 8), .use(d, 8))
        emit(.copy, 8, .def(.physical(.rsi), 8), .use(s, 8))
        emit(.copy, 8, .def(.physical(.rcx), 8), .use(n, 8))
        emit(.repMovsb, 1, .implicitUse(.rdi), .implicitUse(.rsi), .implicitUse(.rcx),
             .implicitDef(.rdi), .implicitDef(.rsi), .implicitDef(.rcx))
    }

    func fillMemory(_ dst: ValueId, byte: ValueId, size: ValueId) {
        if let n = constantInt(size), n >= 0, n <= 128, let c = constantInt(byte) {
            let a = addressOf(dst)
            let b = UInt64(UInt8(truncatingIfNeeded: c))
            let pattern = b &* 0x0101_0101_0101_0101
            var done = 0
            var wide: LIRReg?
            while done < Int(n) {
                let piece = Int(n) - done >= 8 ? 8 : Int(n) - done >= 4 ? 4 : Int(n) - done >= 2 ? 2 : 1
                let value = Int64(bitPattern: pattern) >> Int64(64 - piece * 8)
                if piece == 8 && b != 0 {
                    if wide == nil { wide = materializeInt(Int64(bitPattern: pattern), size: 8) }
                    emit(.mov, 8, a.adding(Int64(done)).operand(size: 8), .use(wide!, 8))
                } else {
                    let imm = piece == 8 ? 0 : value
                    emit(.mov, piece, a.adding(Int64(done)).operand(size: piece), .imm(imm))
                }
                done += piece
            }
            return
        }
        let d = lea(addressOf(dst)), v = gpr(byte), n = gpr(size)
        emit(.copy, 8, .def(.physical(.rdi), 8), .use(d, 8))
        emit(.copy, 4, .def(.physical(.rax), 4), .use(v, 4))
        emit(.copy, 8, .def(.physical(.rcx), 8), .use(n, 8))
        emit(.repStosb, 1, .implicitUse(.rdi), .implicitUse(.rax), .implicitUse(.rcx), .implicitDef(.rdi), .implicitDef(.rcx))
    }
}
