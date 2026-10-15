// Sources/SwiftStack/Asm/AArch64Assembler.swift
//
// AArch64 (GNU Unified A64 Syntax) Assembler (05-assembler.md §4.7).
// Parses A64 instructions, aliases, addressing modes, system registers,
// SIMD/FP/SVE forms, literal pools (`ldr xN, =expr`), and relocation modifiers
// (`:lo12:`, `:got:`, `:got_lo12:`, `:tprel_hi12:`, `:tprel_lo12_nc:`),
// encoding via `A64Encoder` and `A64InstructionTable`.

import Foundation

internal enum A64Asm {

    // MARK: - Top-Level Instruction Parser

    static func parseInstruction(
        mnemonic rawMnemonic: String,
        args: String,
        loc: AsmLoc,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let sec = session.currentSection
        let fragmentsBefore = sec.fragments.count
        let errorsBefore = diagnostics.errorCount
        parseInstructionForms(mnemonic: rawMnemonic, args: args, loc: loc, session: session, diagnostics: &diagnostics)
        // A form that parsed but does not encode (an out-of-range immediate or lane, a register or arrangement the
        // instruction does not take) emits nothing: report it instead of dropping the instruction silently.
        if sec.fragments.count == fragmentsBefore && diagnostics.errorCount == errorsBefore {
            diagnostics.report(.asmInvalidOperands, at: loc, args: [rawMnemonic])
        }
    }

    /// Parses and emits one instruction. A form that is recognized but invalid returns without emitting anything
    /// (`parseInstruction` reports it); an unknown mnemonic or operand shape reports `asmInvalidInstruction`.
    private static func parseInstructionForms(
        mnemonic rawMnemonic: String,
        args: String,
        loc: AsmLoc,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let mnem = rawMnemonic.lowercased()
        let ops = splitCommaSeparated(args)
        let sec = session.currentSection
        func emit(_ inst: A64Instruction) { emitInst(inst, into: sec, loc: loc) }

        // 1. Fixed system instructions, barriers, hints, and exception generation
        let fixed: [String: A64OpcodeId] = ["nop": .nop, "eret": .eret, "yield": .yield, "wfe": .wfe, "wfi": .wfi, "sev": .sev, "sevl": .sevl]
        if let op = fixed[mnem] {
            if ops.isEmpty { emit(A64Instruction(opcode: op)) }
            return
        }
        switch mnem {
        case "ret":
            if ops.isEmpty {
                emit(A64Instruction(opcode: .ret, rn: .lr))
            } else if ops.count == 1, case (let rn, true)? = gpr(ops[0]) {
                emit(A64Instruction(opcode: .ret, rn: rn))
            }
            return
        case "clrex", "isb", "dsb", "dmb":
            // A named option (`ish`, `sy`, ...) or a raw `#imm4` `CRm`; `clrex`/`isb` default to 15.
            let op: A64OpcodeId = mnem == "clrex" ? .clrex : (mnem == "isb" ? .isb : (mnem == "dsb" ? .dsb : .dmb))
            var opt = A64BarrierOption.sy
            if let first = ops.first {
                guard ops.count == 1 else { return }
                if let named = A64BarrierOption.parse(Substring(first)), op == .dsb || op == .dmb {
                    opt = named
                } else if first.hasPrefix("#") || Int64(first) != nil, let crm = parseImmediateValue(first, session: session), (0...15).contains(crm) {
                    opt = A64BarrierOption(rawValue: UInt8(crm))
                } else if op == .isb && first.lowercased() == "sy" {
                    opt = .sy
                } else {
                    return
                }
            } else if op == .dsb || op == .dmb {
                return
            }
            emit(A64Instruction(opcode: op, barrierOption: opt))
            return
        case "ssbb", "pssbb":
            if ops.isEmpty { emit(A64Instruction(opcode: .dsb, barrierOption: A64BarrierOption(rawValue: mnem == "ssbb" ? 0 : 4))) }
            return
        case "hint":
            if ops.count == 1, let imm = parseImmediateValue(ops[0], session: session) { emit(A64Instruction(opcode: .hint, imm: imm)) }
            return
        case "svc", "hvc", "smc", "brk", "hlt", "udf":
            let opcodes: [String: A64OpcodeId] = ["svc": .svc, "hvc": .hvc, "smc": .smc, "brk": .brk, "hlt": .hlt, "udf": .udf]
            if ops.count == 1, let imm = parseImmediateValue(ops[0], session: session) { emit(A64Instruction(opcode: opcodes[mnem]!, imm: imm)) }
            return
        default:
            break
        }
        // PAC/BTI/CSDB hint aliases (`paciasp`, `bti c`, ...).
        let hintName = ops.count == 1 && mnem == "bti" ? "bti \(ops[0].lowercased())" : mnem
        if ops.count <= (mnem == "bti" ? 1 : 0), let imm7 = A64HintAlias.byName[hintName] {
            emit(A64Instruction(opcode: .hint, imm: imm7))
            return
        }
        if mnem == "bti" { return }

        // 2. System maintenance (`tlbi`, `ic`, `dc`, `at`): an X register exactly when the operation takes one
        if let kind = Self.maintKinds[mnem] {
            guard let opName = ops.first, let maintOp = A64SysMaintOp.parse(kind: kind, name: Substring(opName)) else {
                diagnostics.report(.asmInvalidInstruction, at: loc, args: [rawMnemonic])
                return
            }
            if !maintOp.takesRegister {
                if ops.count == 1 { emit(A64Instruction(opcode: .sysMaint, rd: .xzr, sysMaintOp: maintOp)) }
            } else if ops.count == 2, case (let rt, true)? = gpr(ops[1]) {
                emit(A64Instruction(opcode: .sysMaint, rd: rt, sysMaintOp: maintOp))
            }
            return
        }

        // 3. System register moves (`mrs Xt, <sysreg>`, `msr <sysreg>, Xt`, `msr <pstatefield>, #imm`)
        if mnem == "mrs" || mnem == "msr" {
            guard ops.count == 2 else { return }
            if mnem == "mrs" {
                if case (let rd, true)? = gpr(ops[0]), let sysReg = A64SysReg.parse(ops[1]) {
                    emit(A64Instruction(opcode: .mrs, rd: rd, sysReg: sysReg))
                }
                return
            }
            // `spsel` names both a PSTATE field (`msr spsel, #imm`) and a system register (`msr spsel, xN`).
            if let pfield = A64PStateField.parse(Substring(ops[0])), A64GPR.parse(ops[1]) == nil {
                if let imm = parseImmediateValue(ops[1], session: session) {
                    emit(A64Instruction(opcode: .msrPState, imm: imm, pstateField: pfield))
                }
                return
            }
            if let sysReg = A64SysReg.parse(ops[0]), case (let rt, true)? = gpr(ops[1]) {
                emit(A64Instruction(opcode: .msrReg, rd: rt, sysReg: sysReg))
            }
            return
        }

        // 4. Branches (`b`, `bl`, `b.cond`, `b<cond>`, `br`, `blr`, `cbz`, `cbnz`, `tbz`, `tbnz`)
        if mnem == "b" || mnem == "bl" {
            if ops.count == 1 { emitBranchTarget(baseInst: A64Instruction(opcode: mnem == "bl" ? .bl : .b), targetExpr: ops[0], session: session, loc: loc) }
            return
        }
        if mnem.hasPrefix("b.") {
            if let cond = A64Cond.parse(String(mnem.dropFirst(2))), ops.count == 1 {
                emitBranchTarget(baseInst: A64Instruction(opcode: .bCond, cond: cond), targetExpr: ops[0], session: session, loc: loc)
                return
            }
        }
        if mnem.count == 3 && mnem.hasPrefix("b") && !["bic", "bfi", "bfm", "brk", "bti", "blr", "bfc", "bif", "bit", "bsl"].contains(mnem) {
            if let cond = A64Cond.parse(String(mnem.dropFirst(1))), ops.count == 1 {
                emitBranchTarget(baseInst: A64Instruction(opcode: .bCond, cond: cond), targetExpr: ops[0], session: session, loc: loc)
                return
            }
        }
        if mnem == "br" || mnem == "blr" {
            if ops.count == 1, case (let rn, true)? = gpr(ops[0]) { emit(A64Instruction(opcode: mnem == "br" ? .br : .blr, rn: rn)) }
            return
        }
        if mnem == "cbz" || mnem == "cbnz" {
            if ops.count == 2, let (rt, is64) = gpr(ops[0]) {
                let base = A64Instruction(opcode: mnem == "cbz" ? .cbz : .cbnz, is64Bit: is64, rd: rt)
                emitBranchTarget(baseInst: base, targetExpr: ops[1], session: session, loc: loc)
            }
            return
        }
        if mnem == "tbz" || mnem == "tbnz" {
            // The tested bit is 0-31 for a W register and 0-63 for an X register.
            if ops.count == 3, let (rt, is64) = gpr(ops[0]), let bit = parseImmediateValue(ops[1], session: session),
               (0...(is64 ? 63 : 31)).contains(bit) {
                let base = A64Instruction(opcode: mnem == "tbz" ? .tbz : .tbnz, is64Bit: is64, rd: rt, amount: UInt8(bit))
                emitBranchTarget(baseInst: base, targetExpr: ops[2], session: session, loc: loc)
            }
            return
        }

        // 5. PC-relative address formation (`adr`, `adrp`)
        if mnem == "adr" || mnem == "adrp" {
            guard ops.count == 2, case (let rd, true)? = gpr(ops[0]) else { return }
            let isPage = (mnem == "adrp")
            let base = A64Instruction(opcode: isPage ? .adrp : .adr, is64Bit: true, rd: rd, imm: 0)
            guard let bytes = A64Encoder.encodeBytes(base) else { return }
            switch evalExpr(ops[1], session: session) {
            case .constant(let v):
                // An `adrp` displacement is a whole number of 4 KiB pages.
                if isPage && v & 0xFFF != 0 { return }
                var instWithImm = base
                instWithImm.imm = v
                emit(instWithImm)
            case .symbolOffset(let sym, let addend, let mod):
                let rKind: RelocKind
                if mod == .a64Got {
                    rKind = .aarch64_adr_got_page
                } else if isPage {
                    rKind = .aarch64_adr_prel_pg_hi21
                } else {
                    rKind = .aarch64_adr_prel_lo21
                }
                let fixup = AsmInstFixup(
                    offsetInInst: 0,
                    kind: rKind,
                    symbol: sym,
                    addend: addend,
                    width: 4,
                    resolveIfSameSection: !isPage && mod == .none
                )
                sec.emitBytes(bytes, fixups: [fixup], loc: loc)
            default:
                break
            }
            return
        }

        // 6. SVE instructions (`addvl`, `addpl`, `rdvl`, `rdsvl`, `rdffr`, `wrffr`, `ldr`/`str` zN/pN)
        if mnem == "addvl" || mnem == "addpl" {
            if ops.count == 3, case (let rd, true, _)? = A64GPR.parse(ops[0]), case (let rn, true, _)? = A64GPR.parse(ops[1]),
               ops[0].lowercased() != "xzr", ops[1].lowercased() != "xzr", let imm = parseImmediateValue(ops[2], session: session) {
                emit(A64Instruction(opcode: mnem == "addvl" ? .sveAddvl : .sveAddpl, rd: rd, rn: rn, imm: imm))
            }
            return
        }
        if mnem == "rdvl" || mnem == "rdsvl" {
            if ops.count == 2, case (let rd, true)? = gpr(ops[0]), let imm = parseImmediateValue(ops[1], session: session), (-32...31).contains(imm) {
                let imm6 = UInt32(bitPattern: Int32(imm)) & 0x3F
                let word: UInt32 = (mnem == "rdvl" ? 0x04BF_5000 : 0x04BF_5800) | (imm6 << 5) | UInt32(rd.rawValue)
                sec.emitBytes((0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }, loc: loc)
            }
            return
        }
        if mnem == "rdffr" || mnem == "wrffr" {
            if ops.count == 1, ops[0].lowercased().hasSuffix(".b"), let pd = A64PReg.parse(Substring(ops[0])) {
                emit(A64Instruction(opcode: mnem == "rdffr" ? .sveRdffr : .sveWrffr, pd: pd))
            }
            return
        }

        // 7. Loads and stores
        if isLoadStoreMnemonic(mnem) {
            parseLoadStore(mnemonic: mnem, ops: ops, loc: loc, session: session, diagnostics: &diagnostics)
            return
        }

        // 8. Move wide & `mov` alias (`movz`, `movk`, `movn`, `mov`, `mvn`)
        if mnem == "movz" || mnem == "movk" || mnem == "movn" {
            guard ops.count == 2 || ops.count == 3, let (rd, is64) = gpr(ops[0]) else { return }
            let op: A64OpcodeId = (mnem == "movz") ? .movz : ((mnem == "movk") ? .movk : .movn)
            var shiftAmt: Int64 = 0
            if ops.count == 3 {
                guard let (kind, amount) = shiftOperand(ops[2], session: session), kind == .lsl else { return }
                shiftAmt = amount
            }
            guard (0...48).contains(shiftAmt) else { return }
            switch evalExpr(ops[1], session: session) {
            case .constant(let imm):
                emit(A64Instruction(opcode: op, is64Bit: is64, rd: rd, amount: UInt8(shiftAmt), imm: imm))
            case .symbolOffset(let sym, let addend, let mod) where mod == .a64TprelHi12 || mod == .a64TprelLo12Nc:
                if let bytes = A64Encoder.encodeBytes(A64Instruction(opcode: op, is64Bit: is64, rd: rd, amount: UInt8(shiftAmt), imm: 0)) {
                    let rKind: RelocKind = (mod == .a64TprelHi12) ? .aarch64_tlsle_add_tprel_hi12 : .aarch64_tlsle_add_tprel_lo12_nc
                    sec.emitBytes(bytes, fixups: [AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: sym, addend: addend)], loc: loc)
                }
            default:
                break
            }
            return
        }
        if mnem == "mov" && ops.count == 2, let (rd, is64, rdIsSP) = A64GPR.parse(ops[0]) {
            if let (rn, rnIs64, rnIsSP) = A64GPR.parse(ops[1]) {
                // `mov` to or from SP is `add Rd, Rn, #0`; between other registers `orr Rd, zr, Rm`.
                guard rnIs64 == is64, !(rdIsSP || rnIsSP) || (rd.rawValue != 31 || rdIsSP) && (rn.rawValue != 31 || rnIsSP) else { return }
                emit(.movReg(is64Bit: is64, rd: rd, rn: rn, involvesSP: rdIsSP || rnIsSP))
                return
            }
            switch evalExpr(ops[1], session: session) {
            case nil:
                // `mov Wd, Vn.s[i]` / `mov Xd, Vn.d[i]` (`umov`)
                _ = parseFpOrSimd(mnemonic: mnem, ops: ops, loc: loc, session: session)
            case .constant(let imm):
                // A W destination takes a 32-bit value (zero- or sign-extended spelling).
                guard is64 || imm >> 32 == 0 || imm >> 31 == -1,
                      let movInst = encodeMovImmediate(rd: rd, is64Bit: is64, imm: imm) else { return }
                if rdIsSP && movInst.opcode != .orrImm { return }
                emit(movInst)
            case .symbolDiff(let plusSym, let minusSym, let addend):
                guard !rdIsSP, let bytes = A64Encoder.encodeBytes(A64Instruction(opcode: .movz, is64Bit: is64, rd: rd, amount: 0, imm: 0)) else { return }
                let fixup = AsmInstFixup(offsetInInst: 0, kind: .aarch64_abs16, symbol: plusSym, minusSymbol: minusSym, addend: addend, width: 4)
                sec.emitBytes(bytes, fixups: [fixup], loc: loc)
            default:
                break
            }
            return
        }
        if mnem == "mvn" || mnem == "neg" || mnem == "negs" {
            if ops.count == 2 || ops.count == 3, let (regs, is64) = sameWidthGPRs(ops.prefix(2)) {
                let (shift, amt) = ops.count == 3 ? (shiftOperand(ops[2], session: session) ?? (.msl, 0)) : (.lsl, 0)
                if shift != .msl, let amount = UInt8(exactly: amt) {
                    switch mnem {
                    case "mvn":  emit(.mvn(is64Bit: is64, rd: regs[0], rm: regs[1], shift: shift, amount: amount))
                    case "neg":  emit(.neg(is64Bit: is64, rd: regs[0], rm: regs[1], shift: shift, amount: amount))
                    default:     emit(.negs(is64Bit: is64, rd: regs[0], rm: regs[1], shift: shift, amount: amount))
                    }
                    return
                }
            }
            _ = parseFpOrSimd(mnemonic: mnem, ops: ops, loc: loc, session: session)
            return
        }

        // 9. Compare & test aliases (`cmp`, `cmn` -> `subs`/`adds` with Rd = zr; `tst` -> `ands`)
        if mnem == "cmp" || mnem == "cmn" {
            _ = parseAddSub(mnemonic: mnem == "cmp" ? "subs" : "adds", ops: ["xzr"] + ops, loc: loc, session: session, compareAlias: true)
            return
        }
        if mnem == "tst" {
            if let (_, is64) = gpr(ops.first ?? "") {
                _ = parseLogical(mnemonic: "ands", ops: [is64 ? "xzr" : "wzr"] + ops, loc: loc, session: session)
            }
            return
        }

        // 10. Arithmetic & logical (`add`, `adds`, `sub`, `subs`, `and`, `ands`, `orr`, `orn`, `eor`, `eon`, `bic`, `bics`)
        if mnem == "add" || mnem == "adds" || mnem == "sub" || mnem == "subs" {
            if parseAddSub(mnemonic: mnem, ops: ops, loc: loc, session: session, compareAlias: false) { return }
            if (mnem == "add" || mnem == "sub"), parseFpOrSimd(mnemonic: mnem, ops: ops, loc: loc, session: session) { return }
            return
        }
        if ["and", "ands", "orr", "orn", "eor", "eon", "bic", "bics"].contains(mnem) {
            if parseLogical(mnemonic: mnem, ops: ops, loc: loc, session: session) { return }
            if mnem != "ands" && mnem != "bics", parseFpOrSimd(mnemonic: mnem, ops: ops, loc: loc, session: session) { return }
            return
        }

        // 11. Shifts, Bitfields, Multiply/Divide, Conditional Select
        if parseBitfieldOrShiftOrMulOrCond(mnemonic: mnem, ops: ops, loc: loc, session: session) {
            return
        }

        // 12. Scalar FP and Advanced SIMD (NEON)
        if parseFpOrSimd(mnemonic: mnem, ops: ops, loc: loc, session: session) {
            return
        }
        if Self.scalarMnemonics.contains(mnem) || resolveTableMnemonic(mnem) != nil {
            return
        }
        diagnostics.report(.asmInvalidInstruction, at: loc, args: [rawMnemonic])
    }

    // MARK: - Helpers

    private static let maintKinds: [String: A64SysMaintKind] = ["tlbi": .tlbi, "ic": .ic, "dc": .dc, "at": .at]

    /// Mnemonics `parseBitfieldOrShiftOrMulOrCond` handles: an operand mismatch there is an invalid form of a
    /// known instruction (reported as such), not an unknown mnemonic.
    private static let scalarMnemonics: Set<String> = [
        "lsl", "lsr", "asr", "ror", "lslv", "lsrv", "asrv", "rorv", "udiv", "sdiv", "smulh", "umulh", "mul", "mneg",
        "madd", "msub", "ubfiz", "sbfiz", "bfi", "ubfx", "sbfx", "bfxil", "bfc", "ubfm", "sbfm", "bfm", "extr",
        "sxtb", "sxth", "sxtw", "uxtb", "uxth", "clz", "cls", "rbit", "rev", "rev16", "rev32", "cset", "csetm",
        "csel", "csinc", "csinv", "csneg", "cinc", "cinv", "cneg", "ccmp", "ccmn", "adc", "adcs", "sbc", "sbcs",
        "ngc", "ngcs", "smaddl", "smsubl", "umaddl", "umsubl", "smull", "smnegl", "umull", "umnegl",
        "crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch", "crc32cw", "crc32cx",
    ]

    private static func emitInst(_ inst: A64Instruction, into sec: AsmSectionBuilder, loc: AsmLoc) {
        if let bytes = A64Encoder.encodeBytes(inst) {
            sec.emitBytes(bytes, loc: loc)
        }
    }

    private static func evalExpr(_ raw: String, session: AsmSession) -> AsmExprValue? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        // Register names are not symbols (`add x0, x1, s3` is an error, not a reference to `s3`).
        if A64GPR.parse(s) != nil || A64VReg.parse(s) != nil { return nil }
        return AsmExprEvaluator.evaluate(s, constants: session.constants)
    }

    private static func parseImmediateValue(_ raw: String, session: AsmSession) -> Int64? {
        evalExpr(raw, session: session)?.constantValue
    }

    private static func emitBranchTarget(
        baseInst: A64Instruction,
        targetExpr: String,
        session: AsmSession,
        loc: AsmLoc
    ) {
        let sec = session.currentSection
        if let val = evalExpr(targetExpr, session: session) {
            switch val {
            case .constant(let c):
                var inst = baseInst
                inst.imm = c
                emitInst(inst, into: sec, loc: loc)
            case .symbolOffset(let sym, let addend, .none):
                if sym == "." {
                    var inst = baseInst
                    inst.imm = addend
                    emitInst(inst, into: sec, loc: loc)
                } else {
                    sec.emitRelaxable(.a64Branch(baseInst: baseInst, targetSymbol: sym, addend: addend), loc: loc)
                }
            default:
                break
            }
        }
    }

    /// Synthesizes `mov Rd, #imm` using `movz`, `movn`, or `orrImm` (LLVM MC priority).
    private static func encodeMovImmediate(rd: A64GPR, is64Bit: Bool, imm: Int64) -> A64Instruction? {
        let u64: UInt64 = is64Bit ? UInt64(bitPattern: imm) : UInt64(UInt32(truncatingIfNeeded: imm))

        // 1. Check `movz` at shift 0, 16, 32, 48
        if u64 <= 0xFFFF {
            return A64Instruction(opcode: .movz, is64Bit: is64Bit, rd: rd, amount: 0, imm: Int64(u64))
        }
        let maxShift = is64Bit ? 48 : 16
        for shift in stride(from: 16, through: maxShift, by: 16) {
            let chunk = (u64 >> shift) & 0xFFFF
            if chunk != 0 && (chunk << shift) == u64 {
                return A64Instruction(opcode: .movz, is64Bit: is64Bit, rd: rd, amount: UInt8(shift), imm: Int64(chunk))
            }
        }

        // 2. Check `movn` at shift 0, 16, 32, 48
        let inv: UInt64 = is64Bit ? ~u64 : UInt64(~UInt32(truncatingIfNeeded: u64))
        for shift in stride(from: 0, through: maxShift, by: 16) {
            let chunk = (inv >> shift) & 0xFFFF
            if (chunk << shift) == inv {
                return A64Instruction(opcode: .movn, is64Bit: is64Bit, rd: rd, amount: UInt8(shift), imm: Int64(chunk))
            }
        }

        // 3. Check logical bitmask immediate `orr Rd, xzr, #imm`
        if A64BitmaskImmediate.encode(value: u64, is64Bit: is64Bit) != nil {
            return A64Instruction(opcode: .orrImm, is64Bit: is64Bit, rd: rd, rn: .xzr, imm: Int64(bitPattern: u64))
        }

        return nil
    }

    /// A general-purpose register other than `sp`/`wsp` (register 31 is `xzr`/`wzr` here), as `(reg, is64)`.
    private static func gpr(_ op: String) -> (A64GPR, Bool)? {
        guard let (reg, is64, isSP) = A64GPR.parse(op.trimmingCharacters(in: .whitespaces)), !isSP else { return nil }
        return (reg, is64)
    }

    /// Registers other than `sp`/`wsp` that all have the same width, as `(regs, is64)`.
    private static func sameWidthGPRs(_ ops: ArraySlice<String>) -> ([A64GPR], Bool)? {
        var regs: [A64GPR] = []
        var width: Bool? = nil
        for op in ops {
            guard let (reg, is64) = gpr(op), width == nil || width == is64 else { return nil }
            regs.append(reg)
            width = is64
        }
        return width.map { (regs, $0) }
    }

    /// `<shift> #<amount>` (`lsl #12`, `asr #3`), with the amount required.
    private static func shiftOperand(_ op: String, session: AsmSession) -> (A64ShiftKind, Int64)? {
        let (kindStr, amtStr) = splitFirstWord(op)
        guard let kind = A64ShiftKind.parse(Substring(kindStr)), !amtStr.isEmpty,
              let amount = parseImmediateValue(amtStr, session: session), amount >= 0 else { return nil }
        return (kind, amount)
    }

    /// `<extend> {#<amount>}` or `lsl #<amount>`: `(extend, amount, amountWritten)` with `extend` nil for `lsl`.
    private static func extendOperand(_ op: String, session: AsmSession) -> (A64ExtendKind?, Int64, Bool)? {
        let (kindStr, amtStr) = splitFirstWord(op)
        let isLSL = kindStr.lowercased() == "lsl"
        guard isLSL || (A64ExtendKind.parse(Substring(kindStr)) != nil && kindStr.lowercased() != "uxtl") else { return nil }
        var amount: Int64 = 0
        if !amtStr.isEmpty {
            guard let a = parseImmediateValue(amtStr, session: session), a >= 0 else { return nil }
            amount = a
        } else if isLSL {
            return nil
        }
        return (isLSL ? nil : A64ExtendKind.parse(Substring(kindStr)), amount, !amtStr.isEmpty)
    }

    // MARK: - Add / Sub / Logical

    /// `add`/`adds`/`sub`/`subs` in their immediate, shifted-register and extended-register forms (and `cmp`/`cmn`,
    /// passed as `subs`/`adds` with a leading `xzr` for Rd, whose width then follows Rn).
    private static func parseAddSub(
        mnemonic: String,
        ops rawOps: [String],
        loc: AsmLoc,
        session: AsmSession,
        compareAlias: Bool
    ) -> Bool {
        guard rawOps.count >= 3, rawOps.count <= 4, let (rnReg, rnIs64, rnIsSP) = A64GPR.parse(rawOps[1]) else { return false }
        var ops = rawOps
        if compareAlias { ops[0] = rnIs64 ? "xzr" : "wzr" }
        guard let (rd, is64, rdIsSP) = A64GPR.parse(ops[0]), rnIs64 == is64 else { return false }
        let rn = rnReg
        let setsFlags = mnemonic.hasSuffix("s")
        // `adds`/`subs` write zr, never SP.
        if setsFlags && rdIsSP { return false }
        let sec = session.currentSection
        let isAdd = mnemonic.hasPrefix("add")

        // Register third operand: shifted register, or extended register when SP is involved or an extend is written.
        if let (rm, rmIs64, rmIsSP) = A64GPR.parse(ops[2]) {
            guard !rmIsSP else { return false }
            let spInvolved = rdIsSP || rnIsSP
            // In the extended form Rn (and Rd of `add`/`sub`) register 31 is SP, so zr is not encodable there.
            let extendedOK = !(rn.rawValue == 31 && !rnIsSP) && !(!setsFlags && rd.rawValue == 31 && !rdIsSP)
            if ops.count == 4, let (ext, amount, written) = extendOperand(ops[3], session: session), ext != nil || spInvolved {
                guard extendedOK else { return false }
                // `lsl` with SP is `uxtx` (`uxtw` for W); Rm is X only for the 64-bit `uxtx`/`sxtx`.
                let extend = ext ?? (is64 ? .uxtx : .uxtw)
                guard rmIs64 == (is64 && extend.uses64BitRegister), (0...4).contains(amount) else { return false }
                if ext == nil && !written { return false }
                let op: A64OpcodeId = isAdd ? (setsFlags ? .addsExtended : .addExtended) : (setsFlags ? .subsExtended : .subExtended)
                emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, extendKind: extend, amount: UInt8(amount)), into: sec, loc: loc)
                return true
            }
            if spInvolved {
                guard ops.count == 3, rmIs64 == is64, extendedOK else { return false }
                let op: A64OpcodeId = isAdd ? (setsFlags ? .addsExtended : .addExtended) : (setsFlags ? .subsExtended : .subExtended)
                emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, extendKind: is64 ? .uxtx : .uxtw), into: sec, loc: loc)
                return true
            }
            guard rmIs64 == is64 else { return false }
            var shift = A64ShiftKind.lsl
            var amount: Int64 = 0
            if ops.count == 4 {
                guard let (k, a) = shiftOperand(ops[3], session: session), k != .ror, k != .msl, a < (is64 ? 64 : 32) else { return false }
                (shift, amount) = (k, a)
            }
            let op: A64OpcodeId = isAdd ? (setsFlags ? .addsShifted : .addShifted) : (setsFlags ? .subsShifted : .subShifted)
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, shiftKind: shift, amount: UInt8(amount)), into: sec, loc: loc)
            return true
        }

        // Immediate or `:lo12:sym` third operand, with an optional `lsl #0`/`lsl #12`.
        let opImm: A64OpcodeId = isAdd ? (setsFlags ? .addsImm : .addImm) : (setsFlags ? .subsImm : .subImm)
        var shiftAmt: Int64 = 0
        if ops.count == 4 {
            guard let (k, a) = shiftOperand(ops[3], session: session), k == .lsl, a == 0 || a == 12 else { return false }
            shiftAmt = a
        }
        // A zr register (not SP) as Rd of `add`/`sub` or Rn of any form has no immediate encoding.
        if (!setsFlags && rd.rawValue == 31 && !rdIsSP) || (rn.rawValue == 31 && !rnIsSP) { return false }
        switch evalExpr(ops[2], session: session) {
        case .constant(let imm):
            if imm < 0 && imm >= -0xFFF {
                let flippedOp: A64OpcodeId
                switch opImm {
                case .addImm:  flippedOp = .subImm
                case .addsImm: flippedOp = .subsImm
                case .subImm:  flippedOp = .addImm
                default:       flippedOp = .addsImm
                }
                emitInst(A64Instruction(opcode: flippedOp, is64Bit: is64, rd: rd, rn: rn, amount: UInt8(shiftAmt), imm: -imm), into: sec, loc: loc)
            } else if imm > 0xFFF && (imm & 0xFFF) == 0 && (imm >> 12) <= 0xFFF && shiftAmt == 0 {
                emitInst(A64Instruction(opcode: opImm, is64Bit: is64, rd: rd, rn: rn, amount: 12, imm: imm >> 12), into: sec, loc: loc)
            } else {
                emitInst(A64Instruction(opcode: opImm, is64Bit: is64, rd: rd, rn: rn, amount: UInt8(shiftAmt), imm: imm), into: sec, loc: loc)
            }
            return true

        case .symbolOffset(let sym, let addend, let mod):
            let base = A64Instruction(opcode: opImm, is64Bit: is64, rd: rd, rn: rn, amount: UInt8(shiftAmt), imm: 0)
            guard let bytes = A64Encoder.encodeBytes(base) else { return false }
            let rKind: RelocKind
            switch mod {
            case .a64TprelHi12:   rKind = .aarch64_tlsle_add_tprel_hi12
            case .a64TprelLo12Nc: rKind = .aarch64_tlsle_add_tprel_lo12_nc
            default:              rKind = .aarch64_add_abs_lo12_nc
            }
            sec.emitBytes(bytes, fixups: [AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: sym, addend: addend)], loc: loc)
            return true

        default:
            return false
        }
    }

    /// `and`/`ands`/`orr`/`orn`/`eor`/`eon`/`bic`/`bics` in their shifted-register and immediate forms.
    private static func parseLogical(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        guard ops.count == 3 || ops.count == 4 else { return false }
        let sec = session.currentSection

        if let (regs, is64) = sameWidthGPRs(ops.prefix(3)) {
            var shift = A64ShiftKind.lsl
            var amount: Int64 = 0
            if ops.count == 4 {
                guard let (k, a) = shiftOperand(ops[3], session: session), k != .msl, a < (is64 ? 64 : 32) else { return false }
                (shift, amount) = (k, a)
            }
            let opcodes: [String: A64OpcodeId] = [
                "and": .andShifted, "ands": .andsShifted, "orr": .orrShifted, "orn": .ornShifted,
                "eor": .eorShifted, "eon": .eonShifted, "bic": .bicShifted, "bics": .bicsShifted,
            ]
            emitInst(A64Instruction(opcode: opcodes[mnemonic]!, is64Bit: is64, rd: regs[0], rn: regs[1], rm: regs[2], shiftKind: shift,
                                    amount: UInt8(amount)), into: sec, loc: loc)
            return true
        }

        // Immediate: `and`/`orr`/`eor` may write SP; `bic`/`bics` (and `orn`/`eon`) take the inverted mask.
        guard ops.count == 3, let (rd, is64, rdIsSP) = A64GPR.parse(ops[0]), let (rn, rnIs64) = gpr(ops[1]), rnIs64 == is64,
              let imm = parseImmediateValue(ops[2], session: session) else { return false }
        // A W operation takes a 32-bit value (zero- or sign-extended spelling).
        guard is64 || imm >> 32 == 0 || imm >> 31 == -1 else { return false }
        var mask = UInt64(bitPattern: imm)
        let op: A64OpcodeId
        switch mnemonic {
        case "and": op = .andImm
        case "ands": op = .andsImm
        case "orr": op = .orrImm
        case "eor": op = .eorImm
        case "bic": op = .andImm; mask = ~mask
        case "bics": op = .andsImm; mask = ~mask
        case "orn": op = .orrImm; mask = ~mask
        default: op = .eorImm; mask = ~mask
        }
        if !is64 { mask &= 0xFFFF_FFFF }
        // Rd is SP-or-register for `and`/`orr`/`eor` (31 is SP) and zr-or-register for `ands` (31 is zr).
        if op == .andsImm ? rdIsSP : (rd.rawValue == 31 && !rdIsSP) { return false }
        emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, imm: Int64(bitPattern: mask)), into: sec, loc: loc)
        return true
    }

    // MARK: - Bitfields, Shifts, Multiply/Divide, Conditional Select

    private static func parseBitfieldOrShiftOrMulOrCond(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        let sec = session.currentSection
        func emit(_ inst: A64Instruction) -> Bool {
            emitInst(inst, into: sec, loc: loc)
            return true
        }
        /// An immediate operand in `range`.
        func imm(_ op: String, _ range: ClosedRange<Int64>) -> Int64? {
            parseImmediateValue(op, session: session).flatMap { range.contains($0) ? $0 : nil }
        }

        switch mnemonic {
        case "lsl", "lsr", "asr", "ror":
            guard ops.count == 3, let (regs, is64) = sameWidthGPRs(ops.prefix(2)) else { return false }
            let (rd, rn) = (regs[0], regs[1])
            if let (rm, rmIs64) = gpr(ops[2]) {
                guard rmIs64 == is64 else { return false }
                let op: [String: A64OpcodeId] = ["lsl": .lslv, "lsr": .lsrv, "asr": .asrv, "ror": .rorv]
                return emit(A64Instruction(opcode: op[mnemonic]!, is64Bit: is64, rd: rd, rn: rn, rm: rm))
            }
            guard let shiftVal = imm(ops[2], 0...(is64 ? 63 : 31)) else { return false }
            let shift = UInt8(shiftVal)
            switch mnemonic {
            case "lsl": return emit(.lslImm(is64Bit: is64, rd: rd, rn: rn, shift: shift))
            case "lsr": return emit(.lsrImm(is64Bit: is64, rd: rd, rn: rn, shift: shift))
            case "asr": return emit(.asrImm(is64Bit: is64, rd: rd, rn: rn, shift: shift))
            default:    return emit(A64Instruction(opcode: .extr, is64Bit: is64, rd: rd, rn: rn, rm: rn, amount: shift))
            }

        case "lslv", "lsrv", "asrv", "rorv", "udiv", "sdiv", "smulh", "umulh", "mul", "mneg":
            guard ops.count == 3, let (regs, is64) = sameWidthGPRs(ops[...]) else { return false }
            let op: [String: A64OpcodeId] = [
                "lslv": .lslv, "lsrv": .lsrv, "asrv": .asrv, "rorv": .rorv, "udiv": .udiv, "sdiv": .sdiv,
                "smulh": .smulh, "umulh": .umulh, "mul": .madd, "mneg": .msub,
            ]
            if mnemonic.hasSuffix("mulh") && !is64 { return false }
            let ra: A64GPR = mnemonic == "mul" || mnemonic == "mneg" ? .xzr : .x0
            return emit(A64Instruction(opcode: op[mnemonic]!, is64Bit: is64, rd: regs[0], rn: regs[1], rm: regs[2], ra: ra))

        case "madd", "msub":
            guard ops.count == 4, let (regs, is64) = sameWidthGPRs(ops[...]) else { return false }
            return emit(A64Instruction(opcode: mnemonic == "madd" ? .madd : .msub, is64Bit: is64, rd: regs[0], rn: regs[1], rm: regs[2], ra: regs[3]))

        case "ubfiz", "sbfiz", "bfi", "ubfx", "sbfx", "bfxil", "bfc":
            // `<op> Rd, Rn, #lsb, #width` (`bfc Rd, #lsb, #width`): 0 <= lsb < W and 1 <= width <= W - lsb.
            let regCount = mnemonic == "bfc" ? 1 : 2
            guard ops.count == regCount + 2, let (regs, is64) = sameWidthGPRs(ops.prefix(regCount)) else { return false }
            let regWidth: Int64 = is64 ? 64 : 32
            guard let lsb = imm(ops[regCount], 0...(regWidth - 1)), let width = imm(ops[regCount + 1], 1...(regWidth - lsb)) else { return false }
            let rd = regs[0], rn = regCount == 2 ? regs[1] : .xzr
            let insertImmr = (regWidth - lsb) % regWidth
            switch mnemonic {
            case "ubfiz": return emit(A64Instruction(opcode: .ubfm, is64Bit: is64, rd: rd, rn: rn, imm: insertImmr, imm2: UInt8(width - 1)))
            case "sbfiz": return emit(A64Instruction(opcode: .sbfm, is64Bit: is64, rd: rd, rn: rn, imm: insertImmr, imm2: UInt8(width - 1)))
            case "bfi", "bfc": return emit(A64Instruction(opcode: .bfm, is64Bit: is64, rd: rd, rn: rn, imm: insertImmr, imm2: UInt8(width - 1)))
            case "ubfx": return emit(A64Instruction(opcode: .ubfm, is64Bit: is64, rd: rd, rn: rn, imm: lsb, imm2: UInt8(lsb + width - 1)))
            case "sbfx": return emit(A64Instruction(opcode: .sbfm, is64Bit: is64, rd: rd, rn: rn, imm: lsb, imm2: UInt8(lsb + width - 1)))
            default:     return emit(A64Instruction(opcode: .bfm, is64Bit: is64, rd: rd, rn: rn, imm: lsb, imm2: UInt8(lsb + width - 1)))
            }

        case "ubfm", "sbfm", "bfm":
            guard ops.count == 4, let (regs, is64) = sameWidthGPRs(ops.prefix(2)) else { return false }
            let maxField: Int64 = is64 ? 63 : 31
            guard let immr = imm(ops[2], 0...maxField), let imms = imm(ops[3], 0...maxField) else { return false }
            let op: A64OpcodeId = mnemonic == "ubfm" ? .ubfm : (mnemonic == "sbfm" ? .sbfm : .bfm)
            return emit(A64Instruction(opcode: op, is64Bit: is64, rd: regs[0], rn: regs[1], imm: immr, imm2: UInt8(imms)))

        case "extr":
            guard ops.count == 4, let (regs, is64) = sameWidthGPRs(ops.prefix(3)), let lsb = imm(ops[3], 0...(is64 ? 63 : 31)) else { return false }
            return emit(A64Instruction(opcode: .extr, is64Bit: is64, rd: regs[0], rn: regs[1], rm: regs[2], amount: UInt8(lsb)))

        case "sxtb", "sxth", "sxtw", "uxtb", "uxth":
            // The source is always a W register; `sxtw` writes X, `uxtb`/`uxth` write W.
            guard ops.count == 2, let (rd, is64) = gpr(ops[0]), case (let rn, false)? = gpr(ops[1]) else { return false }
            switch mnemonic {
            case "sxtb": return emit(.sxtb(is64Bit: is64, rd: rd, rn: rn))
            case "sxth": return emit(.sxth(is64Bit: is64, rd: rd, rn: rn))
            case "sxtw": return is64 && emit(.sxtw(rd: rd, rn: rn))
            case "uxtb": return !is64 && emit(.uxtb(rd: rd, rn: rn))
            default:     return !is64 && emit(.uxth(rd: rd, rn: rn))
            }

        case "clz", "cls", "rbit", "rev", "rev16", "rev32":
            guard ops.count == 2, let (regs, is64) = sameWidthGPRs(ops[...]) else { return false }
            let op: [String: A64OpcodeId] = ["clz": .clz, "cls": .cls, "rbit": .rbit, "rev": .rev, "rev16": .rev16, "rev32": .rev32]
            if mnemonic == "rev32" && !is64 { return false }
            return emit(A64Instruction(opcode: op[mnemonic]!, is64Bit: is64, rd: regs[0], rn: regs[1]))

        case "cset", "csetm":
            guard ops.count == 2, let (rd, is64) = gpr(ops[0]), let cond = A64Cond.parse(ops[1]), cond != .al, cond != .nv else { return false }
            return emit(mnemonic == "cset" ? .cset(is64Bit: is64, rd: rd, cond: cond) : .csetm(is64Bit: is64, rd: rd, cond: cond))

        case "csel", "csinc", "csinv", "csneg":
            guard ops.count == 4, let (regs, is64) = sameWidthGPRs(ops.prefix(3)), let cond = A64Cond.parse(ops[3]) else { return false }
            let op: [String: A64OpcodeId] = ["csel": .csel, "csinc": .csinc, "csinv": .csinv, "csneg": .csneg]
            return emit(A64Instruction(opcode: op[mnemonic]!, is64Bit: is64, rd: regs[0], rn: regs[1], rm: regs[2], cond: cond))

        case "cinc", "cinv", "cneg":
            guard ops.count == 3, let (regs, is64) = sameWidthGPRs(ops.prefix(2)), let cond = A64Cond.parse(ops[2]),
                  cond != .al, cond != .nv else { return false }
            let op: A64OpcodeId = (mnemonic == "cinc") ? .csinc : ((mnemonic == "cinv") ? .csinv : .csneg)
            return emit(A64Instruction(opcode: op, is64Bit: is64, rd: regs[0], rn: regs[1], rm: regs[1], cond: cond.inverted))

        case "ccmp", "ccmn":
            guard ops.count == 4, let (rn, is64) = gpr(ops[0]), let nzcv = imm(ops[2], 0...15), let cond = A64Cond.parse(ops[3]) else { return false }
            let isCmp = mnemonic == "ccmp"
            if let (rm, rmIs64) = gpr(ops[1]) {
                guard rmIs64 == is64 else { return false }
                return emit(A64Instruction(opcode: isCmp ? .ccmpReg : .ccmnReg, is64Bit: is64, rn: rn, rm: rm, cond: cond, imm2: UInt8(nzcv)))
            }
            guard let imm5 = imm(ops[1], 0...31) else { return false }
            return emit(A64Instruction(opcode: isCmp ? .ccmpImm : .ccmnImm, is64Bit: is64, rn: rn, cond: cond, imm: imm5, imm2: UInt8(nzcv)))

        case "adc", "adcs", "sbc", "sbcs", "ngc", "ngcs":
            // `ngc[s] Rd, Rm` is `sbc[s] Rd, zr, Rm`.
            let negate = mnemonic.hasPrefix("ngc")
            guard ops.count == (negate ? 2 : 3), let (regs, is64) = sameWidthGPRs(ops[...]) else { return false }
            let op: [String: A64OpcodeId] = ["adc": .adc, "adcs": .adcs, "sbc": .sbc, "sbcs": .sbcs, "ngc": .sbc, "ngcs": .sbcs]
            let rn = negate ? A64GPR.xzr : regs[1]
            return emit(A64Instruction(opcode: op[mnemonic]!, is64Bit: is64, rd: regs[0], rn: rn, rm: regs[regs.count - 1]))

        case "smaddl", "smsubl", "umaddl", "umsubl", "smull", "smnegl", "umull", "umnegl":
            // `Xd, Wn, Wm, Xa`; the multiply-only aliases take Ra = xzr. Vector `smull`/`umull` are parsed as SIMD.
            let accumulates = mnemonic.hasSuffix("addl") || mnemonic.hasSuffix("subl")
            guard ops.count == (accumulates ? 4 : 3), case (let rd, true)? = gpr(ops[0]), case (let rn, false)? = gpr(ops[1]),
                  case (let rm, false)? = gpr(ops[2]) else { return false }
            var ra = A64GPR.xzr
            if accumulates {
                guard case (let r, true)? = gpr(ops[3]) else { return false }
                ra = r
            }
            let op: [String: A64OpcodeId] = [
                "smaddl": .smaddl, "smsubl": .smsubl, "umaddl": .umaddl, "umsubl": .umsubl,
                "smull": .smaddl, "smnegl": .smsubl, "umull": .umaddl, "umnegl": .umsubl,
            ]
            return emit(A64Instruction(opcode: op[mnemonic]!, rd: rd, rn: rn, rm: rm, ra: ra))

        case "crc32b", "crc32h", "crc32w", "crc32x", "crc32cb", "crc32ch", "crc32cw", "crc32cx":
            guard ops.count == 3, case (let rd, false)? = gpr(ops[0]), case (let rn, false)? = gpr(ops[1]),
                  let (rm, rmIs64) = gpr(ops[2]), rmIs64 == mnemonic.hasSuffix("x") else { return false }
            let op: [String: A64OpcodeId] = [
                "crc32b": .crc32b, "crc32h": .crc32h, "crc32w": .crc32w, "crc32x": .crc32x,
                "crc32cb": .crc32cb, "crc32ch": .crc32ch, "crc32cw": .crc32cw, "crc32cx": .crc32cx,
            ]
            return emit(A64Instruction(opcode: op[mnemonic]!, rd: rd, rn: rn, rm: rm))

        default:
            return false
        }
    }

    // MARK: - Loads and Stores

    private static func isLoadStoreMnemonic(_ m: String) -> Bool {
        gprLoadStores[m] != nil || exclusiveOps[m] != nil || ["ldp", "stp", "ldnp", "stnp", "prfm", "prfum", "rprfm"].contains(m)
    }

    /// Register-width rules of the GPR load/store mnemonics.
    private enum A64TransferWidth {
        case wOrX   // ldr, str, ldur, ..., ldrsb, ldrsh
        case w      // ldrb, strb, ldrh, strh and their unscaled/unprivileged forms
        case x      // ldrsw, ldursw, ldtrsw
    }

    /// GPR load/store mnemonics: `(unsigned-offset, pre, post, register-offset, unscaled, unprivileged)` descriptors
    /// for the X (or only) and W register forms, and the register width rule. Unscaled (`ldur`) and unprivileged
    /// (`ldtr`) mnemonics have only their own form; `nil` marks an addressing mode the mnemonic does not have.
    private struct A64GPRTransfer {
        typealias Ops = (imm: A64OpcodeId?, pre: A64OpcodeId?, post: A64OpcodeId?, reg: A64OpcodeId?, unscaled: A64OpcodeId?, unpriv: A64OpcodeId?)
        let x: Ops
        let w: Ops
        let width: A64TransferWidth
        let scaleLog2: Int64?   // nil: 2 for W, 3 for X
    }

    private static let gprLoadStores: [String: A64GPRTransfer] = {
        typealias T = A64GPRTransfer
        func same(_ ops: T.Ops, _ width: A64TransferWidth, _ scale: Int64?) -> T { T(x: ops, w: ops, width: width, scaleLog2: scale) }
        return [
            "ldr":   same((.ldrImm, .ldrPre, .ldrPost, .ldrReg, .ldur, nil), .wOrX, nil),
            "str":   same((.strImm, .strPre, .strPost, .strReg, .stur, nil), .wOrX, nil),
            "ldrb":  same((.ldrbImm, .ldrbPre, .ldrbPost, .ldrbReg, .ldurb, nil), .w, 0),
            "strb":  same((.strbImm, .strbPre, .strbPost, .strbReg, .sturb, nil), .w, 0),
            "ldrh":  same((.ldrhImm, .ldrhPre, .ldrhPost, .ldrhReg, .ldurh, nil), .w, 1),
            "strh":  same((.strhImm, .strhPre, .strhPost, .strhReg, .sturh, nil), .w, 1),
            "ldrsb": T(x: (.ldrsbImm64, .ldrsbPre64, .ldrsbPost64, .ldrsbReg64, .ldursb64, nil),
                       w: (.ldrsbImm32, .ldrsbPre32, .ldrsbPost32, .ldrsbReg32, .ldursb32, nil), width: .wOrX, scaleLog2: 0),
            "ldrsh": T(x: (.ldrshImm64, .ldrshPre64, .ldrshPost64, .ldrshReg64, .ldursh64, nil),
                       w: (.ldrshImm32, .ldrshPre32, .ldrshPost32, .ldrshReg32, .ldursh32, nil), width: .wOrX, scaleLog2: 1),
            "ldrsw": same((.ldrswImm, .ldrswPre, .ldrswPost, .ldrswReg, .ldursw, nil), .x, 2),
            "ldur":   same((nil, nil, nil, nil, .ldur, nil), .wOrX, nil),
            "stur":   same((nil, nil, nil, nil, .stur, nil), .wOrX, nil),
            "ldurb":  same((nil, nil, nil, nil, .ldurb, nil), .w, 0),
            "sturb":  same((nil, nil, nil, nil, .sturb, nil), .w, 0),
            "ldurh":  same((nil, nil, nil, nil, .ldurh, nil), .w, 1),
            "sturh":  same((nil, nil, nil, nil, .sturh, nil), .w, 1),
            "ldursb": T(x: (nil, nil, nil, nil, .ldursb64, nil), w: (nil, nil, nil, nil, .ldursb32, nil), width: .wOrX, scaleLog2: 0),
            "ldursh": T(x: (nil, nil, nil, nil, .ldursh64, nil), w: (nil, nil, nil, nil, .ldursh32, nil), width: .wOrX, scaleLog2: 1),
            "ldursw": same((nil, nil, nil, nil, .ldursw, nil), .x, 2),
            "ldtr":   same((nil, nil, nil, nil, nil, .ldtr), .wOrX, nil),
            "sttr":   same((nil, nil, nil, nil, nil, .sttr), .wOrX, nil),
            "ldtrb":  same((nil, nil, nil, nil, nil, .ldtrb), .w, 0),
            "sttrb":  same((nil, nil, nil, nil, nil, .sttrb), .w, 0),
            "ldtrh":  same((nil, nil, nil, nil, nil, .ldtrh), .w, 1),
            "sttrh":  same((nil, nil, nil, nil, nil, .sttrh), .w, 1),
            "ldtrsb": T(x: (nil, nil, nil, nil, nil, .ldtrsb64), w: (nil, nil, nil, nil, nil, .ldtrsb32), width: .wOrX, scaleLog2: 0),
            "ldtrsh": T(x: (nil, nil, nil, nil, nil, .ldtrsh64), w: (nil, nil, nil, nil, nil, .ldtrsh32), width: .wOrX, scaleLog2: 1),
            "ldtrsw": same((nil, nil, nil, nil, nil, .ldtrsw), .x, 2),
        ]
    }()

    /// Exclusive and acquire/release mnemonics (one descriptor each).
    private static let exclusiveOps: [String: A64OpcodeId] = [
        "ldxr": .ldxr, "ldaxr": .ldaxr, "ldar": .ldar, "stlr": .stlr, "ldarb": .ldarb, "stlrb": .stlrb,
        "ldarh": .ldarh, "stlrh": .stlrh, "ldxrb": .ldxrb, "ldxrh": .ldxrh, "ldaxrb": .ldaxrb, "ldaxrh": .ldaxrh,
        "stxr": .stxr, "stlxr": .stlxr, "stxrb": .stxrb, "stxrh": .stxrh, "stlxrb": .stlxrb, "stlxrh": .stlxrh,
        "ldxp": .ldxp, "ldaxp": .ldaxp, "stxp": .stxp, "stlxp": .stlxp,
        "ldapr": .ldapr, "ldaprb": .ldaprb, "ldaprh": .ldaprh,
    ]

    /// Parses a load/store. An invalid form (a W or zr base, a register of the wrong width or class, an addressing
    /// mode the mnemonic does not have) emits nothing, which `parseInstruction` reports.
    private static func parseLoadStore(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let sec = session.currentSection
        func emit(_ inst: A64Instruction) { emitInst(inst, into: sec, loc: loc) }
        guard ops.count >= 2 else { return }

        // 1. SVE `ldr`/`str` `zN` or `pN`, `[Xn|SP{, #simm9, mul vl}]`
        if mnemonic == "ldr" || mnemonic == "str" {
            let isLoad = (mnemonic == "ldr")
            if let zd = A64ZReg.parse(Substring(ops[0])) {
                if let (baseReg, immVal) = parseSVEMemOperand(ops: Array(ops.dropFirst()), session: session) {
                    emit(A64Instruction(opcode: isLoad ? .sveLdrZ : .sveStrZ, rn: baseReg, zd: zd, imm: immVal))
                }
                return
            }
            if !ops[0].lowercased().hasSuffix(".b"), let pd = A64PReg.parse(Substring(ops[0])) {
                if let (baseReg, immVal) = parseSVEMemOperand(ops: Array(ops.dropFirst()), session: session) {
                    emit(A64Instruction(opcode: isLoad ? .sveLdrP : .sveStrP, rn: baseReg, pd: pd, imm: immVal))
                }
                return
            }
        }

        // 2. Pair loads/stores (`ldp`, `stp`, non-temporal `ldnp`, `stnp`) of W/X or S/D/Q registers
        if ["ldp", "stp", "ldnp", "stnp"].contains(mnemonic) {
            let isLoad = mnemonic.hasPrefix("ld")
            let nonTemporal = mnemonic.hasSuffix("np")
            guard ops.count >= 3, let mem = parseMemAddressing(ops: Array(ops.dropFirst(2)), session: session),
                  mem.indexReg == nil, mem.symbolReloc == nil else { return }
            // `ldnp`/`stnp` have only the signed-offset form.
            if nonTemporal && mem.indexing != .signed { return }
            if let (v1, sw1, _) = A64VReg.parse(ops[0]), let w = sw1, let (v2, sw2, _) = A64VReg.parse(ops[1]), sw2 == w {
                let op: A64OpcodeId
                switch mem.indexing {
                case .pre:    op = isLoad ? .ldpFpPre : .stpFpPre
                case .post:   op = isLoad ? .ldpFpPost : .stpFpPost
                case .signed: op = nonTemporal ? (isLoad ? .ldnpFp : .stnpFp) : (isLoad ? .ldpFpSigned : .stpFpSigned)
                }
                emit(A64Instruction(opcode: op, rn: mem.base, vd: v1, vn: v2, scalarWidth: w, imm: mem.offset))
            } else if let (regs, is64) = sameWidthGPRs(ops.prefix(2)) {
                let op: A64OpcodeId
                switch mem.indexing {
                case .pre:    op = isLoad ? .ldpPre : .stpPre
                case .post:   op = isLoad ? .ldpPost : .stpPost
                case .signed: op = nonTemporal ? (isLoad ? .ldnp : .stnp) : (isLoad ? .ldpSigned : .stpSigned)
                }
                emit(A64Instruction(opcode: op, is64Bit: is64, rd: regs[0], rn: mem.base, rm: regs[1], imm: mem.offset))
            }
            return
        }

        // Prefetch (`prfm <op>, [addr]` / `prfm <op>, label`, `prfum <op>, [Xn, #simm9]`, `rprfm <op>, Xm, [Xn]`)
        if mnemonic == "prfm" || mnemonic == "prfum" || mnemonic == "rprfm" {
            parsePrefetch(mnemonic: mnemonic, ops: ops, loc: loc, session: session)
            return
        }

        // 3. Atomics / exclusives: `[Ws,] Rt [, Rt2], [Xn|SP{, #0}]`
        if let op = exclusiveOps[mnemonic] {
            let desc = A64InstructionTable.descriptor(for: op)
            let hasStatus = desc.format == .atomicStoreExcl || desc.format == .atomicStoreExclPair
            let hasPair = desc.format == .atomicLoadPair || desc.format == .atomicStoreExclPair
            let regCount = 1 + (hasStatus ? 1 : 0) + (hasPair ? 1 : 0)
            guard ops.count == regCount + 1 else { return }
            var status = A64GPR.x0
            if hasStatus {
                guard case (let s, false)? = gpr(ops[0]) else { return }
                status = s
            }
            // The transfer registers share a width; byte/halfword forms (a fixed `size`) take W registers only.
            guard let (regs, is64) = sameWidthGPRs(ops[(hasStatus ? 1 : 0)..<regCount]) else { return }
            if is64 && desc.opcodeMask & (1 << 30) != 0 { return }
            guard let mem = parseMemAddressing(ops: [ops[regCount]], session: session), mem.indexing == .signed,
                  mem.indexReg == nil, mem.symbolReloc == nil, mem.offset == 0 else { return }
            emit(A64Instruction(opcode: op, is64Bit: is64, rd: regs[0], rn: mem.base, rm: status, ra: hasPair ? regs[1] : .x0))
            return
        }

        // 4. Literal pool load `ldr Rt, =expr` or PC-relative literal `ldr Rt, label` / `ldrsw Xt, label`
        let rhs = ops[1].trimmingCharacters(in: .whitespaces)
        if (mnemonic == "ldr" || mnemonic == "ldrsw") && ops.count == 2 && !rhs.hasPrefix("[") {
            let base: A64Instruction
            if let (rt, is64) = gpr(ops[0]) {
                if mnemonic == "ldrsw" && !is64 { return }
                base = A64Instruction(opcode: mnemonic == "ldrsw" ? .ldrswLit : .ldrLit, is64Bit: is64, rd: rt, imm: 0)
            } else if mnemonic == "ldr", let (vt, sw, _) = A64VReg.parse(ops[0]), let w = sw, !rhs.hasPrefix("=") {
                base = A64Instruction(opcode: .ldrFpLit, vd: vt, scalarWidth: w, imm: 0)
            } else {
                return
            }
            if rhs.hasPrefix("=") {
                let poolExpr = String(rhs.dropFirst()).trimmingCharacters(in: .whitespaces)
                session.literalPoolCounter += 1
                let poolLabel = ".Lpool_\(session.literalPoolCounter)"
                sec.literalPool.append((label: poolLabel, expr: poolExpr))
                if let bytes = A64Encoder.encodeBytes(base) {
                    let fixup = AsmInstFixup(offsetInInst: 0, kind: .aarch64_ld_prel_lo19, symbol: poolLabel, addend: 0, width: 4,
                                             resolveIfSameSection: true)
                    sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                }
                return
            }
            switch evalExpr(rhs, session: session) {
            case .constant(let disp):
                // `ldr Rt, #disp` -- PC-relative literal with an explicit byte displacement
                var inst = base
                inst.imm = disp
                emit(inst)
            case .symbolOffset(let sym, let addend, .none):
                if let bytes = A64Encoder.encodeBytes(base) {
                    let fixup = AsmInstFixup(offsetInInst: 0, kind: .aarch64_ld_prel_lo19, symbol: sym, addend: addend, width: 4,
                                             resolveIfSameSection: true)
                    sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                }
            default:
                break
            }
            return
        }

        guard let mem = parseMemAddressing(ops: Array(ops.dropFirst()), session: session) else { return }

        // 5. SIMD/FP register loads/stores (`bN`/`hN`/`sN`/`dN`/`qN`) in every addressing mode
        if ["ldr", "str", "ldur", "stur"].contains(mnemonic), let (vt, someWidth, _) = A64VReg.parse(ops[0]) {
            guard let w = someWidth else { return }
            let isLoad = mnemonic.hasPrefix("ld")
            if mnemonic == "ldur" || mnemonic == "stur" {
                guard mem.indexing == .signed, mem.indexReg == nil, mem.symbolReloc == nil else { return }
                emit(A64Instruction(opcode: isLoad ? .ldurFp : .sturFp, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset))
            } else if let indexReg = mem.indexReg {
                emit(A64Instruction(opcode: isLoad ? .ldrFpReg : .strFpReg, rn: mem.base, rm: indexReg, vd: vt, scalarWidth: w,
                                    extendKind: mem.extendKind, amount: mem.shiftAmount, imm2: mem.shiftPresent ? 1 : 0))
            } else if mem.indexing == .pre {
                emit(A64Instruction(opcode: isLoad ? .ldrFpPre : .strFpPre, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset))
            } else if mem.indexing == .post {
                emit(A64Instruction(opcode: isLoad ? .ldrFpPost : .strFpPost, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset))
            } else {
                let unsignedOps: [A64ScalarWidth: (load: A64OpcodeId, store: A64OpcodeId)] = [
                    .b: (.ldrFpImmB, .strFpImmB), .h: (.ldrFpImmH, .strFpImmH), .s: (.ldrFpImmS, .strFpImmS),
                    .d: (.ldrFpImmD, .strFpImmD), .q: (.ldrFpImmQ, .strFpImmQ),
                ]
                let pair = unsignedOps[w]!
                let scaled = A64Instruction(opcode: isLoad ? pair.load : pair.store, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset)
                if let symReloc = mem.symbolReloc {
                    guard symReloc.modifier == .none || symReloc.modifier == .a64Lo12,
                          let bytes = A64Encoder.encodeBytes(A64Instruction(opcode: scaled.opcode, rn: mem.base, vd: vt, scalarWidth: w)) else { return }
                    let kinds: [RelocKind] = [.aarch64_ldst8_abs_lo12_nc, .aarch64_ldst16_abs_lo12_nc, .aarch64_ldst32_abs_lo12_nc,
                                              .aarch64_ldst64_abs_lo12_nc, .aarch64_ldst128_abs_lo12_nc]
                    let fixup = AsmInstFixup(offsetInInst: 0, kind: kinds[Int(w.rawValue)], symbol: symReloc.symbol, addend: symReloc.addend)
                    sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                    return
                }
                // A negative or unaligned offset falls back to the unscaled `ldur`/`stur` form.
                emit(A64Encoder.encode(scaled) != nil
                     ? scaled
                     : A64Instruction(opcode: isLoad ? .ldurFp : .sturFp, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset))
            }
            return
        }

        // 6. GPR loads/stores
        guard let transfer = gprLoadStores[mnemonic], let (rt, is64) = gpr(ops[0]) else { return }
        switch transfer.width {
        case .w: if is64 { return }
        case .x: if !is64 { return }
        case .wOrX: break
        }
        let forms = is64 ? transfer.x : transfer.w
        let scaleLog2 = transfer.scaleLog2 ?? (is64 ? 3 : 2)

        if let unpriv = forms.unpriv {
            guard mem.indexing == .signed, mem.indexReg == nil, mem.symbolReloc == nil else { return }
            emit(A64Instruction(opcode: unpriv, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset))
            return
        }
        if forms.imm == nil, let unscaled = forms.unscaled {
            guard mem.indexing == .signed, mem.indexReg == nil, mem.symbolReloc == nil else { return }
            emit(A64Instruction(opcode: unscaled, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset))
            return
        }
        guard let opImm = forms.imm, let opPre = forms.pre, let opPost = forms.post, let opReg = forms.reg,
              let opUnscaled = forms.unscaled else { return }

        // Register-offset addressing `[Xn, Rm {, extend #shift}]`
        if let indexReg = mem.indexReg {
            emit(A64Instruction(opcode: opReg, is64Bit: is64, rd: rt, rn: mem.base, rm: indexReg, extendKind: mem.extendKind,
                                amount: mem.shiftAmount, imm2: mem.shiftPresent ? 1 : 0))
            return
        }
        // Pre-indexed / post-indexed
        if mem.indexing != .signed {
            emit(A64Instruction(opcode: mem.indexing == .pre ? opPre : opPost, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset))
            return
        }
        if let symReloc = mem.symbolReloc {
            if let bytes = A64Encoder.encodeBytes(A64Instruction(opcode: opImm, is64Bit: is64, rd: rt, rn: mem.base, imm: 0)) {
                let rKind: RelocKind
                switch (symReloc.modifier, scaleLog2) {
                case (.a64GotLo12, _): rKind = .aarch64_ld64_got_lo12_nc
                case (_, 0):           rKind = .aarch64_ldst8_abs_lo12_nc
                case (_, 1):           rKind = .aarch64_ldst16_abs_lo12_nc
                case (_, 2):           rKind = .aarch64_ldst32_abs_lo12_nc
                default:               rKind = .aarch64_ldst64_abs_lo12_nc
                }
                sec.emitBytes(bytes, fixups: [AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: symReloc.symbol, addend: symReloc.addend)], loc: loc)
            }
            return
        }
        // Unsigned scaled offset, or the unscaled `ldur`/`stur` form for a negative or unaligned one (as LLVM does).
        let candidate = A64Instruction(opcode: opImm, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset)
        emit(A64Encoder.encode(candidate) != nil ? candidate : A64Instruction(opcode: opUnscaled, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset))
    }

    /// `prfm`/`prfum`: the operation is a name (`pldl1keep`) or `#imm5`; `prfm` takes every addressing mode of a
    /// 64-bit `ldr` (an offset the scaled form cannot encode selects `prfum`, as in LLVM) and a literal label.
    private static func parsePrefetch(mnemonic: String, ops: [String], loc: AsmLoc, session: AsmSession) {
        let sec = session.currentSection
        guard ops.count >= 2 else { return }
        let opText = ops[0].trimmingCharacters(in: .whitespaces)
        if mnemonic == "rprfm" {
            // `rprfm <op>, Xm, [Xn]` is a register-offset `prfm` (A64PrefetchOp.rangeFields).
            let rangeOp: UInt8
            if let named = A64PrefetchOp.parseRange(Substring(opText)) {
                rangeOp = named
            } else if opText.hasPrefix("#"), let v = parseImmediateValue(opText, session: session), (0...63).contains(v) {
                rangeOp = UInt8(v)
            } else {
                return
            }
            guard ops.count == 3, case (let rm, true)? = gpr(ops[1]), let fields = A64PrefetchOp.rangeFields(rangeOp),
                  let mem = parseMemAddressing(ops: [ops[2]], session: session), mem.indexing == .signed, mem.indexReg == nil,
                  mem.symbolReloc == nil, mem.offset == 0 else { return }
            emitInst(A64Instruction(opcode: .prfmReg, rd: fields.rt, rn: mem.base, rm: rm, extendKind: fields.extend,
                                    amount: fields.shifted ? 3 : 0), into: sec, loc: loc)
            return
        }
        let prfop: UInt8
        if let named = A64PrefetchOp.parse(Substring(opText)) {
            prfop = named
        } else if opText.hasPrefix("#"), let v = parseImmediateValue(opText, session: session), (0...31).contains(v) {
            prfop = UInt8(v)
        } else {
            return
        }
        let rt = A64GPR(rawValue: prfop)
        let rhs = ops[1].trimmingCharacters(in: .whitespaces)
        if !rhs.hasPrefix("[") {
            guard mnemonic == "prfm", ops.count == 2 else { return }
            let base = A64Instruction(opcode: .prfmLit, rd: rt)
            switch evalExpr(rhs, session: session) {
            case .constant(let disp):
                var inst = base
                inst.imm = disp
                emitInst(inst, into: sec, loc: loc)
            case .symbolOffset(let sym, let addend, .none):
                guard let bytes = A64Encoder.encodeBytes(base) else { return }
                let fixup = AsmInstFixup(offsetInInst: 0, kind: .aarch64_ld_prel_lo19, symbol: sym, addend: addend, width: 4,
                                         resolveIfSameSection: true)
                sec.emitBytes(bytes, fixups: [fixup], loc: loc)
            default:
                break
            }
            return
        }
        guard let mem = parseMemAddressing(ops: Array(ops.dropFirst()), session: session), mem.indexing == .signed else { return }
        if mnemonic == "prfum" {
            guard mem.indexReg == nil, mem.symbolReloc == nil else { return }
            emitInst(A64Instruction(opcode: .prfum, rd: rt, rn: mem.base, imm: mem.offset), into: sec, loc: loc)
        } else if let indexReg = mem.indexReg {
            emitInst(A64Instruction(opcode: .prfmReg, rd: rt, rn: mem.base, rm: indexReg, extendKind: mem.extendKind,
                                    amount: mem.shiftAmount), into: sec, loc: loc)
        } else if let symReloc = mem.symbolReloc {
            guard symReloc.modifier == .none || symReloc.modifier == .a64Lo12,
                  let bytes = A64Encoder.encodeBytes(A64Instruction(opcode: .prfmImm, rd: rt, rn: mem.base)) else { return }
            let fixup = AsmInstFixup(offsetInInst: 0, kind: .aarch64_ldst64_abs_lo12_nc, symbol: symReloc.symbol, addend: symReloc.addend)
            sec.emitBytes(bytes, fixups: [fixup], loc: loc)
        } else {
            let scaled = A64Instruction(opcode: .prfmImm, rd: rt, rn: mem.base, imm: mem.offset)
            emitInst(A64Encoder.encode(scaled) != nil ? scaled : A64Instruction(opcode: .prfum, rd: rt, rn: mem.base, imm: mem.offset),
                     into: sec, loc: loc)
        }
    }

    private enum A64MemIndexing {
        case signed
        case pre
        case post
    }

    private struct A64ParsedMem {
        var base: A64GPR = .x0
        var offset: Int64 = 0
        var indexing: A64MemIndexing = .signed
        var indexReg: A64GPR? = nil
        var extendKind: A64ExtendKind = .uxtx
        var shiftAmount: UInt8 = 0
        /// An explicit shift amount was written (`lsl #0` sets `S` for byte accesses).
        var shiftPresent = false
        var symbolReloc: (symbol: String, addend: Int64, modifier: AsmRelocModifier)? = nil
    }

    /// Parses `[Xn|SP]`, `[Xn|SP, #imm]`, `[Xn|SP, #imm]!`, `[Xn|SP], #imm`, `[Xn|SP, :lo12:sym]` and
    /// `[Xn|SP, Rm{, extend {#amount}}]` (a W index with `uxtw`/`sxtw`, an X index alone or with `lsl`/`sxtx`).
    /// Nil for anything else: a W or zr base, a missing or mismatched index extend, a register post-index,
    /// trailing operands.
    private static func parseMemAddressing(ops: [String], session: AsmSession) -> A64ParsedMem? {
        var result = A64ParsedMem()
        guard let first = ops.first?.trimmingCharacters(in: .whitespaces), ops.count <= 2 else { return nil }
        func baseRegister(_ text: String) -> A64GPR? {
            guard let (reg, is64, isSP) = A64GPR.parse(text.trimmingCharacters(in: .whitespaces)), is64, isSP || reg.rawValue != 31 else { return nil }
            return reg
        }

        // Post-indexed `[Xn], #imm`
        if ops.count == 2 {
            guard first.hasPrefix("["), first.hasSuffix("]"), let base = baseRegister(String(first.dropFirst().dropLast())),
                  let offset = parseImmediateValue(ops[1], session: session) else { return nil }
            result.base = base
            result.indexing = .post
            result.offset = offset
            return result
        }

        // `[Xn ...]` or `[Xn ...]!`
        var raw = first
        if raw.hasSuffix("!") {
            result.indexing = .pre
            raw = String(raw.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard raw.hasPrefix("[") && raw.hasSuffix("]") else { return nil }
        raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let innerParts = splitCommaSeparated(raw)
        guard let basePart = innerParts.first, let base = baseRegister(basePart), innerParts.count <= 3 else { return nil }
        result.base = base
        guard innerParts.count >= 2 else { return result.indexing == .pre ? nil : result }

        // Index register `[Xn, Rm {, extend #shift}]`
        if let (rm, rmIs64, rmIsSP) = A64GPR.parse(innerParts[1]) {
            guard !rmIsSP, result.indexing == .signed else { return nil }
            result.indexReg = rm
            result.extendKind = rmIs64 ? .uxtx : .uxtw
            if innerParts.count == 3 {
                guard let (ext, amount, written) = extendOperand(innerParts[2], session: session), amount <= 4 else { return nil }
                let kind = ext ?? .uxtx
                // A W index is extended (`uxtw`/`sxtw`); an X index is shifted (`lsl`) or `sxtx`.
                guard rmIs64 ? (kind == .uxtx || kind == .sxtx) && !(ext == .uxtx) : (kind == .uxtw || kind == .sxtw) else { return nil }
                result.extendKind = kind
                result.shiftAmount = UInt8(amount)
                result.shiftPresent = written
            } else if !rmIs64 {
                return nil
            }
            return result
        }

        // Otherwise an immediate or `:lo12:sym`
        guard innerParts.count == 2 else { return nil }
        switch evalExpr(innerParts[1], session: session) {
        case .constant(let v):
            result.offset = v
        case .symbolOffset(let sym, let addend, let mod) where result.indexing == .signed:
            result.symbolReloc = (sym, addend, mod)
        default:
            return nil
        }
        return result
    }

    /// `[Xn|SP]` or `[Xn|SP, #simm9, mul vl]` of SVE `ldr`/`str`, as `(base, imm)`.
    private static func parseSVEMemOperand(ops: [String], session: AsmSession) -> (A64GPR, Int64)? {
        guard ops.count == 1 else { return nil }
        var raw = ops[0].trimmingCharacters(in: .whitespaces)
        guard raw.hasPrefix("[") && raw.hasSuffix("]") else { return nil }
        raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let parts = splitCommaSeparated(raw)
        guard let basePart = parts.first, let (base, is64, isSP) = A64GPR.parse(basePart), is64, isSP || base.rawValue != 31 else { return nil }
        if parts.count == 1 { return (base, 0) }
        guard parts.count == 3, parts[2].lowercased().split(separator: " ").joined(separator: " ") == "mul vl",
              let imm = parseImmediateValue(parts[1], session: session) else { return nil }
        return (base, imm)
    }

    // MARK: - Scalar FP, Advanced SIMD (NEON), and LSE Atomics (table-driven)
    //
    // These formats are parsed generically: the mnemonic selects candidate descriptors from
    // `A64InstructionTable` (plus the aliases the disassembler prints), the operands are classified once,
    // and each candidate binds them by its format. The first binding the encoder accepts is emitted.

    /// One classified operand of a SIMD/FP/LSE instruction.
    private enum A64Operand {
        case gpr(A64GPR, is64: Bool, isSP: Bool)
        case scalar(A64VReg, A64ScalarWidth)
        case vector(A64VReg, A64Arrangement)
        case element(A64VReg, A64ScalarWidth, UInt8)
        /// `v2.4b[1]`: a group of four bytes, the by-element operand of `sdot`/`udot`.
        case byteQuad(A64VReg, UInt8)
        /// `{v0.16b, v1.16b}` (`arrangement` set) or `{v0.s}[1]` (`laneWidth` and `lane` set).
        case list(first: A64VReg, count: Int, arrangement: A64Arrangement?, laneWidth: A64ScalarWidth?, lane: UInt8?)
        case mem(base: A64GPR, offset: String?, preIndex: Bool)
        case shift(A64ShiftKind, amount: String)
        /// Immediates, condition codes, and anything else, as written.
        case other(String)
    }

    /// The descriptors a mnemonic may denote, plus what its spelling adds (LSE ordering/size suffixes,
    /// the `st<op>` store aliases, and the `2` upper-half suffix).
    private struct A64MnemonicForm {
        var descs: [A64InstrDesc]
        /// The mnemonic as written, without a `2` suffix (`mov`, `sxtl`, ... select alias operand shapes).
        var spelling = ""
        var acquire = false
        var release = false
        var size: A64ScalarWidth? = nil
        var storeAlias = false
        var upperHalf = false
    }

    private static func isTableParsed(_ format: A64InstrFormat) -> Bool {
        switch format {
        case .lseAtomic, .lseCas, .lseCasp,
             .fpMovGprToFp, .fpMovFpToGpr, .fpDp1, .fpCvtPrecision, .fpIntToFp, .fpToInt, .fpFixedToFp, .fpToFixed,
             .fpBinary, .fpDp3, .fpCmpReg, .fpCmpZero, .fpCondCompare, .fpCondSelect, .fpImm,
             .simdThreeSameInt, .simdThreeSameBit, .simdThreeSameFp, .simdPermute, .simdTwoRegMisc, .simdCmpZero,
             .simdTwoRegMiscFp, .simdAcrossLanes, .simdNarrow, .simdShiftImm, .simdShiftLong, .simdShiftNarrow,
             .simdDupElem, .simdDupGpr, .simdDupScalar, .simdInsGpr, .simdInsElem, .simdUmovSmov, .simdModImm,
             .simdLdStMulti, .simdLdStMultiPost, .simdLd1R, .simdLd1RPost, .simdLdStLane, .simdLdStLanePost,
             .simdTbl, .simdExt, .simdThreeLong, .simdThreeWide, .simdThreeNarrow, .simdDot, .simdElem, .simdElemLong,
             .simdDotElem, .simdLongPairwise, .simdFpCmpZero, .simdFpNarrow, .simdFpLong, .simdScalarTwoRegMiscFp,
             .simdScalarPairwise, .simdAcrossLanesLong, .simdAcrossLanesFp, .cryptoAes, .cryptoSha3, .cryptoSha2,
             .simdScalarElem, .simdScalarFpCmpZero, .simdScalarThreeSameFp:
            return true
        default:
            return false
        }
    }

    private static let tableParsedByMnemonic: [String: [A64InstrDesc]] = {
        var map: [String: [A64InstrDesc]] = [:]
        for desc in A64InstructionTable.entries where isTableParsed(desc.format) {
            map[desc.mnemonic, default: []].append(desc)
        }
        // Aliases the disassembler prints (and the architectural names behind them).
        let d = A64InstructionTable.descriptor(for:)
        map["mov", default: []] += [d(.simdOrr), d(.simdUmov)]
        map["ins"] = [d(.simdInsGpr), d(.simdInsElem)]
        map["dup", default: []].append(d(.simdDupScalar))
        map["mvn"] = [d(.simdNot)]
        map["sxtl"] = [d(.simdSshll)]
        map["uxtl"] = [d(.simdUshll)]
        return map
    }()

    /// LSE base mnemonics, longest first so `casp` wins over `cas`; `st<op>` maps to `ld<op>` with Rt = zr.
    private static let lseBases: [(name: String, op: A64OpcodeId, store: Bool)] = [
        ("ldsmax", .ldsmax, false), ("ldsmin", .ldsmin, false), ("ldumax", .ldumax, false), ("ldumin", .ldumin, false),
        ("stsmax", .ldsmax, true), ("stsmin", .ldsmin, true), ("stumax", .ldumax, true), ("stumin", .ldumin, true),
        ("ldadd", .ldadd, false), ("ldclr", .ldclr, false), ("ldeor", .ldeor, false), ("ldset", .ldset, false),
        ("stadd", .ldadd, true), ("stclr", .ldclr, true), ("steor", .ldeor, true), ("stset", .ldset, true),
        ("casp", .casp, false), ("swp", .swp, false), ("cas", .cas, false),
    ]

    /// Formats with a `2` (upper-half) mnemonic suffix: the `Q` bit selects the upper half of the narrow operand.
    private static func hasUpperHalfForm(_ format: A64InstrFormat) -> Bool {
        switch format {
        case .simdNarrow, .simdShiftLong, .simdShiftNarrow, .simdThreeLong, .simdThreeWide, .simdThreeNarrow,
             .simdElemLong, .simdFpNarrow, .simdFpLong:
            return true
        default:
            return false
        }
    }

    private static func resolveTableMnemonic(_ mnem: String) -> A64MnemonicForm? {
        if let descs = tableParsedByMnemonic[mnem] {
            return A64MnemonicForm(descs: descs, spelling: mnem)
        }
        if mnem.hasSuffix("2"), let descs = tableParsedByMnemonic[String(mnem.dropLast())]?.filter({ hasUpperHalfForm($0.format) }),
           !descs.isEmpty {
            return A64MnemonicForm(descs: descs, spelling: String(mnem.dropLast()), upperHalf: true)
        }
        for base in lseBases where mnem.hasPrefix(base.name) {
            var rest = mnem.dropFirst(base.name.count)
            var size: A64ScalarWidth? = nil
            if base.op != .casp, let last = rest.last, last == "b" || last == "h" {
                size = last == "b" ? .b : .h
                rest = rest.dropLast()
            }
            let order: (acquire: Bool, release: Bool)
            switch rest {
            case "":   order = (false, false)
            case "a":  order = (true, false)
            case "l":  order = (false, true)
            case "al": order = (true, true)
            default:   continue
            }
            if base.store && order.acquire { continue }
            return A64MnemonicForm(descs: [A64InstructionTable.descriptor(for: base.op)], acquire: order.acquire,
                                   release: order.release, size: size, storeAlias: base.store)
        }
        return nil
    }

    /// `v1.s[2]` -> `(v1, .s, 2)`; `v1.s` -> `(v1, .s, nil)` (a lane list element).
    private static func parseVectorElement(_ text: String) -> (A64VReg, A64ScalarWidth, UInt8?)? {
        let lower = text.lowercased().filter { !$0.isWhitespace }
        guard lower.hasPrefix("v"), let dot = lower.firstIndex(of: ".") else { return nil }
        guard let num = UInt8(lower[lower.index(after: lower.startIndex)..<dot]), num <= 31 else { return nil }
        var rest = lower[lower.index(after: dot)...]
        var lane: UInt8? = nil
        if let lb = rest.firstIndex(of: "[") {
            guard rest.hasSuffix("]"), let l = UInt8(rest[rest.index(after: lb)..<rest.index(before: rest.endIndex)]) else { return nil }
            lane = l
            rest = rest[..<lb]
        }
        let width: A64ScalarWidth
        switch rest {
        case "b": width = .b
        case "h": width = .h
        case "s": width = .s
        case "d": width = .d
        default:  return nil
        }
        return (A64VReg(rawValue: num), width, lane)
    }

    private static func classifyOperand(_ raw: String) -> A64Operand {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("{") {
            guard let close = s.firstIndex(of: "}") else { return .other(s) }
            let inner = s[s.index(after: s.startIndex)..<close]
            let after = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            var lane: UInt8? = nil
            if !after.isEmpty {
                guard after.hasPrefix("["), after.hasSuffix("]"), let l = UInt8(after.dropFirst().dropLast()) else { return .other(s) }
                lane = l
            }
            let isRange = inner.contains("-")
            var regs: [(reg: A64VReg, arr: A64Arrangement?, width: A64ScalarWidth?)] = []
            for item in inner.split(separator: isRange ? "-" : ",") {
                let text = item.trimmingCharacters(in: .whitespaces)
                if let (v, _, arr) = A64VReg.parse(text), let arr {
                    regs.append((v, arr, nil))
                } else if let (v, w, l) = parseVectorElement(text), l == nil {
                    regs.append((v, nil, w))
                } else {
                    return .other(s)
                }
            }
            guard let first = regs.first, regs.allSatisfy({ $0.arr == first.arr && $0.width == first.width }) else { return .other(s) }
            let count: Int
            if isRange {
                guard regs.count == 2 else { return .other(s) }
                count = Int((regs[1].reg.rawValue &- first.reg.rawValue) & 31) + 1
            } else {
                for (i, r) in regs.enumerated() where r.reg.rawValue != (first.reg.rawValue &+ UInt8(i)) & 31 {
                    return .other(s)
                }
                count = regs.count
            }
            return .list(first: first.reg, count: count, arrangement: first.arr, laneWidth: first.width, lane: lane)
        }
        if s.hasPrefix("[") {
            var body = s
            var pre = false
            if body.hasSuffix("!") {
                pre = true
                body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard body.hasSuffix("]") else { return .other(s) }
            let parts = splitCommaSeparated(String(body.dropFirst().dropLast()))
            guard let base = parts.first.flatMap({ A64GPR.parse($0) }), base.is64Bit, parts.count <= 2 else { return .other(s) }
            return .mem(base: base.reg, offset: parts.count == 2 ? parts[1] : nil, preIndex: pre)
        }
        let (word, rest) = splitFirstWord(s)
        if !rest.isEmpty, let kind = A64ShiftKind.parse(Substring(word)) {
            return .shift(kind, amount: rest)
        }
        if let (reg, is64, isSP) = A64GPR.parse(s) {
            return .gpr(reg, is64: is64, isSP: isSP)
        }
        if let (v, width, arr) = A64VReg.parse(s) {
            if let width { return .scalar(v, width) }
            if let arr { return .vector(v, arr) }
        }
        if let (v, w, lane) = parseVectorElement(s), let lane {
            return .element(v, w, lane)
        }
        let lower = s.lowercased()
        if lower.hasPrefix("v"), let dot = lower.range(of: ".4b["), lower.hasSuffix("]"),
           let num = UInt8(lower[lower.index(after: lower.startIndex)..<dot.lowerBound]), num <= 31,
           let lane = UInt8(lower[dot.upperBound..<lower.index(before: lower.endIndex)]) {
            return .byteQuad(A64VReg(rawValue: num), lane)
        }
        return .other(s)
    }

    /// Parses an FP immediate such as `#1.0`, `#-0.5`, or `#1.00000000`.
    private static func parseFPImmediate(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        return Double(s.trimmingCharacters(in: .whitespaces))
    }

    /// True for the `#0.0` (or `#0`) of an FP compare with zero; `#-0.0` is rejected, as in LLVM.
    private static func isFPZero(_ text: String) -> Bool {
        guard let v = parseFPImmediate(text) else { return false }
        return v == 0 && v.sign == .plus
    }

    /// Parses an integer immediate, accepting full 64-bit hexadecimal patterns (`#0xff00ff0000000000`).
    private static func parseWideImmediate(_ text: String, session: AsmSession) -> Int64? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x"), let v = UInt64(s.dropFirst(2), radix: 16) {
            return Int64(bitPattern: v)
        }
        return parseImmediateValue(s, session: session)
    }

    private static func parseFpOrSimd(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        guard let form = resolveTableMnemonic(mnemonic) else { return false }
        let operands = ops.map(classifyOperand)
        for desc in form.descs {
            if let inst = bind(desc, form: form, operands, session: session), A64Encoder.encode(inst) != nil {
                emitInst(inst, into: session.currentSection, loc: loc)
                return true
            }
        }
        return false
    }

    /// Binds classified operands to `desc`'s format, or returns nil if they do not have its shape.
    private static func bind(_ desc: A64InstrDesc, form: A64MnemonicForm, _ ops: [A64Operand], session: AsmSession) -> A64Instruction? {
        func immediate(_ op: A64Operand) -> Int64? {
            if case .other(let s) = op { return parseImmediateValue(s, session: session) }
            return nil
        }
        func condition(_ op: A64Operand) -> A64Cond? {
            if case .other(let s) = op { return A64Cond.parse(s) }
            return nil
        }
        func scalars(_ count: Int) -> (regs: [A64VReg], width: A64ScalarWidth)? {
            guard ops.count >= count else { return nil }
            var regs: [A64VReg] = []
            var width: A64ScalarWidth? = nil
            for op in ops.prefix(count) {
                guard case .scalar(let v, let w) = op, width == nil || width == w else { return nil }
                regs.append(v)
                width = w
            }
            return width.map { (regs, $0) }
        }
        func vectors(_ count: Int) -> (regs: [A64VReg], arrangement: A64Arrangement)? {
            vectorsFrom(0, count: count)
        }
        /// `count` vector operands from `start` that share one arrangement.
        func vectorsFrom(_ start: Int, count: Int) -> (regs: [A64VReg], arrangement: A64Arrangement)? {
            guard ops.count >= start + count else { return nil }
            var regs: [A64VReg] = []
            var arr: A64Arrangement? = nil
            for op in ops[start..<(start + count)] {
                guard case .vector(let v, let a) = op, arr == nil || arr == a else { return nil }
                regs.append(v)
                arr = a
            }
            return arr.map { (regs, $0) }
        }
        /// A plain `[Xn]` (LSE also accepts `[Xn, #0]`).
        func baseOnly(_ op: A64Operand) -> A64GPR? {
            guard case .mem(let base, let offset, false) = op else { return nil }
            if let offset, parseImmediateValue(offset, session: session) != 0 { return nil }
            return base
        }
        /// The trailing `#imm` / `Xm` of a post-indexed structure access, as `(rm, imm)`.
        func postIndex(_ op: A64Operand) -> (A64GPR, Int64)? {
            if case .gpr(let rm, true, false) = op, rm.rawValue != 31 { return (rm, 0) }
            return immediate(op).map { (.xzr, $0) }
        }

        if form.upperHalf && !hasUpperHalfForm(desc.format) { return nil }
        var inst = A64Instruction(opcode: desc.id)
        switch desc.format {
        case .lseAtomic, .lseCas:
            var regOps = ops
            if form.storeAlias {
                guard ops.count == 2, case .gpr(_, let is64, false) = ops[0] else { return nil }
                regOps = [ops[0], .gpr(.xzr, is64: is64, isSP: false), ops[1]]
            }
            guard regOps.count == 3, case .gpr(let rs, let rsIs64, false) = regOps[0], case .gpr(let rt, let rtIs64, false) = regOps[1],
                  rsIs64 == rtIs64, let base = baseOnly(regOps[2]) else { return nil }
            if form.size != nil && rsIs64 { return nil }
            let size = form.size ?? (rsIs64 ? .d : .s)
            inst = A64Instruction(opcode: desc.id, is64Bit: size == .d, rd: rt, rn: base, rm: rs, scalarWidth: size,
                                  acquire: form.acquire, release: form.release)

        case .lseCasp:
            guard ops.count == 5, let base = baseOnly(ops[4]) else { return nil }
            var regs: [A64GPR] = []
            var is64: Bool? = nil
            for op in ops.prefix(4) {
                guard case .gpr(let r, let w, false) = op, is64 == nil || is64 == w else { return nil }
                regs.append(r)
                is64 = w
            }
            guard regs[1].rawValue == regs[0].rawValue + 1, regs[3].rawValue == regs[2].rawValue + 1 else { return nil }
            inst = A64Instruction(opcode: desc.id, is64Bit: is64 ?? true, rd: regs[2], rn: base, rm: regs[0],
                                  scalarWidth: is64 == true ? .d : .s, acquire: form.acquire, release: form.release)

        case .fpMovGprToFp, .fpIntToFp, .fpFixedToFp:
            let operandCount = desc.format == .fpFixedToFp ? 3 : 2
            guard ops.count == operandCount, case .scalar(let vd, let w) = ops[0], case .gpr(let rn, let is64, false) = ops[1] else { return nil }
            inst = A64Instruction(opcode: desc.id, is64Bit: is64, rn: rn, vd: vd, scalarWidth: w)
            if desc.format == .fpFixedToFp {
                guard let fbits = immediate(ops[2]) else { return nil }
                inst.imm = fbits
            }

        case .fpMovFpToGpr, .fpToInt, .fpToFixed:
            let operandCount = desc.format == .fpToFixed ? 3 : 2
            guard ops.count == operandCount, case .gpr(let rd, let is64, false) = ops[0], case .scalar(let vn, let w) = ops[1] else { return nil }
            inst = A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, vn: vn, scalarWidth: w)
            if desc.format == .fpToFixed {
                guard let fbits = immediate(ops[2]) else { return nil }
                inst.imm = fbits
            }

        case .fpDp1, .fpBinary, .fpDp3, .fpCmpReg:
            let counts: [A64InstrFormat: Int] = [.fpDp1: 2, .fpBinary: 3, .fpDp3: 4, .fpCmpReg: 2]
            let count = counts[desc.format]!
            guard ops.count == count, let (regs, w) = scalars(count) else { return nil }
            if desc.format == .fpCmpReg {
                inst = A64Instruction(opcode: desc.id, vn: regs[0], vm: regs[1], scalarWidth: w)
            } else {
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: count > 2 ? regs[2] : .v0,
                                      va: count > 3 ? regs[3] : .v0, scalarWidth: w)
            }

        case .fpCvtPrecision:
            guard ops.count == 2, case .scalar(let vd, let dst) = ops[0], case .scalar(let vn, let src) = ops[1] else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, scalarWidth: dst, scalarWidth2: src)

        case .fpCmpZero:
            guard ops.count == 2, case .scalar(let vn, let w) = ops[0], case .other(let z) = ops[1], isFPZero(z) else { return nil }
            inst = A64Instruction(opcode: desc.id, vn: vn, scalarWidth: w)

        case .fpCondCompare:
            guard ops.count == 4, let (regs, w) = scalars(2), let nzcv = immediate(ops[2]), (0...15).contains(nzcv),
                  let cond = condition(ops[3]) else { return nil }
            inst = A64Instruction(opcode: desc.id, vn: regs[0], vm: regs[1], scalarWidth: w, cond: cond, imm2: UInt8(nzcv))

        case .fpCondSelect:
            guard ops.count == 4, let (regs, w) = scalars(3), let cond = condition(ops[3]) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[2], scalarWidth: w, cond: cond)

        case .fpImm:
            guard ops.count == 2, case .scalar(let vd, let w) = ops[0], case .other(let text) = ops[1],
                  let value = parseFPImmediate(text), let imm8 = A64FPImmediate.encode(value) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, scalarWidth: w, imm: Int64(imm8))

        case .simdThreeSameInt, .simdThreeSameBit, .simdThreeSameFp, .simdPermute:
            // `mov Vd.<T>, Vn.<T>` is `orr Vd.<T>, Vn.<T>, Vn.<T>`.
            if desc.id == .simdOrr && ops.count == 2 && form.spelling == "mov", let (regs, arr) = vectors(2) {
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[1], arrangement: arr)
            } else {
                guard ops.count == 3, let (regs, arr) = vectors(3) else { return nil }
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[2], arrangement: arr)
            }

        case .simdTwoRegMisc, .simdTwoRegMiscFp, .simdCmpZero:
            guard ops.count == (desc.format == .simdCmpZero ? 3 : 2), let (regs, arr) = vectors(2) else { return nil }
            if desc.format == .simdCmpZero && immediate(ops[2]) != 0 { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], arrangement: arr)

        case .simdFpCmpZero:
            guard ops.count == 3, let (regs, arr) = vectors(2), case .other(let z) = ops[2], isFPZero(z) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], arrangement: arr)

        case .simdLongPairwise:
            guard ops.count == 2, case .vector(let vd, let dArr) = ops[0], case .vector(let vn, let nArr) = ops[1],
                  nArr.pairwiseWidened == dArr else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: nArr)

        case .simdAcrossLanes, .simdAcrossLanesFp, .simdAcrossLanesLong, .simdScalarPairwise:
            // `saddlv`/`uaddlv` write a scalar of twice the element width.
            let widening: UInt8 = desc.format == .simdAcrossLanesLong ? 1 : 0
            guard ops.count == 2, case .scalar(let vd, let w) = ops[0], case .vector(let vn, let arr) = ops[1],
                  w.rawValue == arr.elementWidth.rawValue + widening else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: arr)

        case .simdScalarTwoRegMiscFp:
            guard ops.count == 2, let (regs, w) = scalars(2) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], scalarWidth: w)

        case .simdScalarFpCmpZero:
            guard ops.count == 3, let (regs, w) = scalars(2), case .other(let z) = ops[2], isFPZero(z) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], scalarWidth: w)

        case .simdScalarThreeSameFp:
            guard ops.count == 3, let (regs, w) = scalars(3) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[2], scalarWidth: w)

        case .simdFpNarrow, .simdFpLong:
            guard ops.count == 2, case .vector(let vd, let dArr) = ops[0], case .vector(let vn, let nArr) = ops[1] else { return nil }
            let (narrow, wide) = desc.format == .simdFpNarrow ? (dArr, nArr) : (nArr, dArr)
            guard narrow.widened == wide, (narrow.qBit == 1) == form.upperHalf else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: narrow)

        case .simdThreeLong, .simdThreeWide, .simdThreeNarrow:
            guard ops.count == 3, case .vector(let vd, let dArr) = ops[0], case .vector(let vn, let nArr) = ops[1],
                  case .vector(let vm, let mArr) = ops[2] else { return nil }
            // (destination, first source, second source) as (narrow or wide) for each shape.
            let narrow: A64Arrangement, shapeOK: Bool
            switch desc.format {
            case .simdThreeLong: (narrow, shapeOK) = (nArr, mArr == nArr && nArr.widened == dArr)
            case .simdThreeWide: (narrow, shapeOK) = (mArr, nArr == dArr && mArr.widened == dArr)
            default:             (narrow, shapeOK) = (dArr, mArr == nArr && dArr.widened == nArr)
            }
            guard shapeOK, (narrow.qBit == 1) == form.upperHalf else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: narrow)

        case .simdDot:
            guard ops.count == 3, case .vector(let vd, let dArr) = ops[0], let (regs, nArr) = vectorsFrom(1, count: 2),
                  nArr == (dArr.qBit == 1 ? A64Arrangement.b16 : .b8) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: regs[0], vm: regs[1], arrangement: dArr)

        case .simdElem:
            guard ops.count == 3, let (regs, arr) = vectors(2), case .element(let vm, let w, let idx) = ops[2],
                  w == arr.elementWidth else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: vm, arrangement: arr, index: idx)

        case .simdScalarElem:
            guard ops.count == 3, let (regs, w) = scalars(2), case .element(let vm, let ew, let idx) = ops[2], ew == w else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: vm, scalarWidth: w, index: idx)

        case .simdElemLong:
            guard ops.count == 3, case .vector(let vd, let dArr) = ops[0], case .vector(let vn, let nArr) = ops[1],
                  case .element(let vm, let w, let idx) = ops[2], w == nArr.elementWidth, nArr.widened == dArr,
                  (nArr.qBit == 1) == form.upperHalf else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: nArr, index: idx)

        case .simdDotElem:
            guard ops.count == 3, case .vector(let vd, let dArr) = ops[0], case .vector(let vn, let nArr) = ops[1],
                  nArr == (dArr.qBit == 1 ? A64Arrangement.b16 : .b8), case .byteQuad(let vm, let idx) = ops[2] else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: dArr, index: idx)

        case .cryptoAes:
            guard ops.count == 2, let (regs, arr) = vectors(2), arr == .b16 else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1])

        case .cryptoSha3:
            guard ops.count == 3 else { return nil }
            switch desc.id {
            case .sha1c, .sha1p, .sha1m, .sha256h, .sha256h2:
                let nWidth: A64ScalarWidth = desc.id == .sha256h || desc.id == .sha256h2 ? .q : .s
                guard case .scalar(let vd, .q) = ops[0], case .scalar(let vn, let w) = ops[1], w == nWidth,
                      case .vector(let vm, .s4) = ops[2] else { return nil }
                inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm)
            default:
                guard let (regs, arr) = vectors(3), arr == .s4 else { return nil }
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[2])
            }

        case .cryptoSha2:
            guard ops.count == 2 else { return nil }
            if desc.id == .sha1h {
                guard let (regs, w) = scalars(2), w == .s else { return nil }
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1])
            } else {
                guard let (regs, arr) = vectors(2), arr == .s4 else { return nil }
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1])
            }

        case .simdNarrow, .simdShiftNarrow, .simdShiftLong:
            // Narrowing forms take the narrow destination arrangement, `sshll`/`ushll` the narrow source.
            let isLong = desc.format == .simdShiftLong
            let isAlias = form.spelling == "sxtl" || form.spelling == "uxtl"
            let operandCount = desc.format == .simdNarrow || isAlias ? 2 : 3
            guard ops.count == operandCount, case .vector(let vd, let dArr) = ops[0], case .vector(let vn, let nArr) = ops[1] else { return nil }
            let narrow = isLong ? nArr : dArr
            guard narrow.widened == (isLong ? dArr : nArr), (narrow.qBit == 1) == form.upperHalf else { return nil }
            var amount: Int64 = 0
            if operandCount == 3 {
                guard let a = immediate(ops[2]), (0...64).contains(a) else { return nil }
                amount = a
            }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: narrow, amount: UInt8(amount))

        case .simdShiftImm:
            guard ops.count == 3, let (regs, arr) = vectors(2), let a = immediate(ops[2]), (0...64).contains(a) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], arrangement: arr, amount: UInt8(a))

        case .simdDupElem:
            guard ops.count == 2, case .vector(let vd, let arr) = ops[0], case .element(let vn, let w, let idx) = ops[1],
                  w == arr.elementWidth else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: arr, index: idx)

        case .simdDupGpr:
            guard ops.count == 2, case .vector(let vd, let arr) = ops[0], case .gpr(let rn, let is64, false) = ops[1],
                  is64 == (arr.elementWidth == .d) else { return nil }
            inst = A64Instruction(opcode: desc.id, rn: rn, vd: vd, arrangement: arr)

        case .simdDupScalar:
            guard ops.count == 2, case .scalar(let vd, let w) = ops[0], case .element(let vn, let ew, let idx) = ops[1], w == ew else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, scalarWidth: w, index: idx)

        case .simdInsGpr:
            guard ops.count == 2, case .element(let vd, let w, let idx) = ops[0], case .gpr(let rn, let is64, false) = ops[1],
                  is64 == (w == .d) else { return nil }
            inst = A64Instruction(opcode: desc.id, rn: rn, vd: vd, scalarWidth: w, index: idx)

        case .simdInsElem:
            guard ops.count == 2, case .element(let vd, let w, let idx) = ops[0], case .element(let vn, let w2, let idx2) = ops[1],
                  w == w2 else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, scalarWidth: w, index: idx, imm2: idx2)

        case .simdUmovSmov:
            // `mov` is the `umov` alias for 32- and 64-bit lanes only.
            if form.spelling == "mov", ops.count == 2, case .element(_, let w, _) = ops[1], w != .s && w != .d { return nil }
            guard ops.count == 2, case .gpr(let rd, let is64, false) = ops[0], case .element(let vn, let w, let idx) = ops[1] else { return nil }
            inst = A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, vn: vn, scalarWidth: w, index: idx)

        case .simdModImm:
            guard ops.count == 2 || ops.count == 3 else { return nil }
            let arr: A64Arrangement
            switch ops[0] {
            case .vector(let v, let a) where a != .d1:
                inst.vd = v
                arr = a
            case .scalar(let v, .d) where desc.id == .simdMovi:
                inst.vd = v
                arr = .d1
            default:
                return nil
            }
            guard case .other(let text) = ops[1] else { return nil }
            inst.arrangement = arr
            if desc.id == .simdFmovImm {
                guard ops.count == 2, let value = parseFPImmediate(text), let imm8 = A64FPImmediate.encode(value) else { return nil }
                inst.imm = Int64(imm8)
            } else {
                guard let value = parseWideImmediate(text, session: session) else { return nil }
                inst.imm = value
                if ops.count == 3 {
                    guard case .shift(let kind, let amountText) = ops[2], let amount = parseImmediateValue(amountText, session: session),
                          (0...24).contains(amount) else { return nil }
                    inst.shiftKind = kind
                    inst.amount = UInt8(amount)
                }
            }

        case .simdLdStMulti, .simdLdStMultiPost, .simdLd1R, .simdLd1RPost:
            let isPost = desc.format == .simdLdStMultiPost || desc.format == .simdLd1RPost
            guard ops.count == (isPost ? 3 : 2), case .list(let first, let count, let someArr, nil, nil) = ops[0],
                  let arr = someArr, let base = baseOnly(ops[1]) else { return nil }
            if desc.format == .simdLd1R || desc.format == .simdLd1RPost {
                guard count == A64Encoder.structureCount(desc.id) else { return nil }
            }
            inst = A64Instruction(opcode: desc.id, rn: base, rm: .xzr, vd: first, arrangement: arr, imm2: UInt8(count))
            if isPost {
                guard let (rm, imm) = postIndex(ops[2]) else { return nil }
                inst.rm = rm
                inst.imm = imm
            }

        case .simdLdStLane, .simdLdStLanePost:
            let isPost = desc.format == .simdLdStLanePost
            guard ops.count == (isPost ? 3 : 2), case .list(let first, let count, nil, let someWidth, let someLane) = ops[0],
                  count == A64Encoder.structureCount(desc.id), let w = someWidth, let lane = someLane,
                  let base = baseOnly(ops[1]) else { return nil }
            inst = A64Instruction(opcode: desc.id, rn: base, rm: .xzr, vd: first, scalarWidth: w, index: lane)
            if isPost {
                guard let (rm, imm) = postIndex(ops[2]) else { return nil }
                inst.rm = rm
                inst.imm = imm
            }

        case .simdTbl:
            guard ops.count == 3, case .vector(let vd, let arr) = ops[0], case .list(let first, let count, .b16?, nil, nil) = ops[1],
                  case .vector(let vm, let mArr) = ops[2], mArr == arr else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: first, vm: vm, arrangement: arr, imm2: UInt8(count))

        case .simdExt:
            guard ops.count == 4, let (regs, arr) = vectors(3), let idx = immediate(ops[3]), (0...15).contains(idx) else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[2], arrangement: arr, amount: UInt8(idx))

        default:
            return nil
        }
        return inst
    }
}
