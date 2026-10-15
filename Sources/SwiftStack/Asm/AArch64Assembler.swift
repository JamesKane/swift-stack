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
        let mnem = rawMnemonic.lowercased()
        let ops = splitCommaSeparated(args)
        let sec = session.currentSection

        // 1. Zero-operand fixed system instructions & barriers
        switch mnem {
        case "nop":
            emitInst(A64Instruction(opcode: .nop), into: sec, loc: loc)
            return
        case "ret":
            if ops.isEmpty {
                emitInst(A64Instruction(opcode: .ret, rn: .lr), into: sec, loc: loc)
            } else if let (rn, _, _) = A64GPR.parse(ops[0]) {
                emitInst(A64Instruction(opcode: .ret, rn: rn), into: sec, loc: loc)
            }
            return
        case "eret":
            emitInst(A64Instruction(opcode: .eret), into: sec, loc: loc)
            return
        case "yield":
            emitInst(A64Instruction(opcode: .yield), into: sec, loc: loc)
            return
        case "wfe":
            emitInst(A64Instruction(opcode: .wfe), into: sec, loc: loc)
            return
        case "wfi":
            emitInst(A64Instruction(opcode: .wfi), into: sec, loc: loc)
            return
        case "sev":
            emitInst(A64Instruction(opcode: .sev), into: sec, loc: loc)
            return
        case "sevl":
            emitInst(A64Instruction(opcode: .sevl), into: sec, loc: loc)
            return
        case "clrex":
            emitInst(A64Instruction(opcode: .clrex), into: sec, loc: loc)
            return
        case "isb":
            let opt = ops.first.flatMap { A64BarrierOption.parse(Substring($0)) } ?? .sy
            emitInst(A64Instruction(opcode: .isb, barrierOption: opt), into: sec, loc: loc)
            return
        case "dsb", "dmb":
            let op: A64OpcodeId = (mnem == "dsb") ? .dsb : .dmb
            let opt = ops.first.flatMap { A64BarrierOption.parse(Substring($0)) } ?? .sy
            emitInst(A64Instruction(opcode: op, barrierOption: opt), into: sec, loc: loc)
            return
        case "pacia1716":
            emitInst(A64Instruction(opcode: .hint, imm: 8), into: sec, loc: loc)
            return
        case "paciasp":
            emitInst(A64Instruction(opcode: .hint, imm: 25), into: sec, loc: loc)
            return
        case "autiasp":
            emitInst(A64Instruction(opcode: .hint, imm: 29), into: sec, loc: loc)
            return
        case "xpaclri":
            emitInst(A64Instruction(opcode: .hint, imm: 7), into: sec, loc: loc)
            return
        case "bti":
            let target = ops.first?.lowercased() ?? ""
            let imm7: Int64
            switch target {
            case "c":  imm7 = 34
            case "j":  imm7 = 36
            case "jc": imm7 = 38
            default:   imm7 = 32
            }
            emitInst(A64Instruction(opcode: .hint, imm: imm7), into: sec, loc: loc)
            return
        case "hint":
            let immVal = parseImmediateValue(ops.first ?? "0", session: session) ?? 0
            emitInst(A64Instruction(opcode: .hint, imm: immVal), into: sec, loc: loc)
            return
        case "svc", "hvc", "smc", "brk", "hlt", "udf":
            let immVal = parseImmediateValue(ops.first ?? "0", session: session) ?? 0
            let op: A64OpcodeId
            switch mnem {
            case "svc": op = .svc
            case "hvc": op = .hvc
            case "smc": op = .smc
            case "brk": op = .brk
            case "hlt": op = .hlt
            default:    op = .udf
            }
            emitInst(A64Instruction(opcode: op, imm: immVal), into: sec, loc: loc)
            return
        default:
            break
        }

        // 2. System maintenance (`tlbi`, `ic`, `dc`)
        if mnem == "tlbi" || mnem == "ic" || mnem == "dc" {
            guard let opName = ops.first,
                  let maintOp = A64SysMaintOp.allCases.first(where: { $0.operandName == opName.lowercased() }) else {
                diagnostics.report(.asmInvalidInstruction, at: loc, args: [rawMnemonic])
                return
            }
            let rt: A64GPR = (ops.count >= 2) ? (A64GPR.parse(ops[1])?.reg ?? .xzr) : .xzr
            emitInst(A64Instruction(opcode: .sysMaint, rd: rt, sysMaintOp: maintOp), into: sec, loc: loc)
            return
        }

        // 3. System register moves (`mrs`, `msr`)
        if mnem == "mrs" && ops.count == 2 {
            if let (rd, _, _) = A64GPR.parse(ops[0]),
               let sysReg = A64SysReg.parse(ops[1]) {
                emitInst(A64Instruction(opcode: .mrs, rd: rd, sysReg: sysReg), into: sec, loc: loc)
                return
            }
        }
        if mnem == "msr" && ops.count == 2 {
            if let pfield = A64PStateField.parse(Substring(ops[0])) {
                let immVal = parseImmediateValue(ops[1], session: session) ?? 0
                emitInst(A64Instruction(opcode: .msrPState, imm: immVal, pstateField: pfield), into: sec, loc: loc)
                return
            }
            if let sysReg = A64SysReg.parse(ops[0]),
               let (rt, _, _) = A64GPR.parse(ops[1]) {
                emitInst(A64Instruction(opcode: .msrReg, rd: rt, sysReg: sysReg), into: sec, loc: loc)
                return
            }
        }

        // 4. Branches (`b`, `bl`, `b.cond`, `b<cond>`, `br`, `blr`, `cbz`, `cbnz`, `tbz`, `tbnz`)
        if mnem == "b" || mnem == "bl" {
            guard let targetStr = ops.first else { return }
            emitBranchTarget(baseInst: A64Instruction(opcode: mnem == "bl" ? .bl : .b), targetExpr: targetStr, session: session, loc: loc)
            return
        }
        if mnem.hasPrefix("b.") {
            let condStr = String(mnem.dropFirst(2))
            if let cond = A64Cond.parse(condStr), let targetStr = ops.first {
                emitBranchTarget(baseInst: A64Instruction(opcode: .bCond, cond: cond), targetExpr: targetStr, session: session, loc: loc)
                return
            }
        }
        if mnem.count == 3 && mnem.hasPrefix("b") && mnem != "bic" && mnem != "bfi" && mnem != "bfm" && mnem != "brk" && mnem != "bti" && mnem != "blr" {
            let condStr = String(mnem.dropFirst(1))
            if let cond = A64Cond.parse(condStr), let targetStr = ops.first {
                emitBranchTarget(baseInst: A64Instruction(opcode: .bCond, cond: cond), targetExpr: targetStr, session: session, loc: loc)
                return
            }
        }
        if (mnem == "br" || mnem == "blr"), let firstOp = ops.first, let (rn, _, _) = A64GPR.parse(firstOp) {
            emitInst(A64Instruction(opcode: mnem == "br" ? .br : .blr, rn: rn), into: sec, loc: loc)
            return
        }
        if (mnem == "cbz" || mnem == "cbnz") && ops.count == 2 {
            if let (rt, is64, _) = A64GPR.parse(ops[0]) {
                let base = A64Instruction(opcode: mnem == "cbz" ? .cbz : .cbnz, is64Bit: is64, rd: rt)
                emitBranchTarget(baseInst: base, targetExpr: ops[1], session: session, loc: loc)
                return
            }
        }
        if (mnem == "tbz" || mnem == "tbnz") && ops.count == 3 {
            if let (rt, is64, _) = A64GPR.parse(ops[0]) {
                let bit = UInt8(truncatingIfNeeded: parseImmediateValue(ops[1], session: session) ?? 0)
                let base = A64Instruction(opcode: mnem == "tbz" ? .tbz : .tbnz, is64Bit: is64 || bit >= 32, rd: rt, amount: bit)
                emitBranchTarget(baseInst: base, targetExpr: ops[2], session: session, loc: loc)
                return
            }
        }

        // 5. PC-relative address formation (`adr`, `adrp`)
        if (mnem == "adr" || mnem == "adrp") && ops.count == 2 {
            if let (rd, _, _) = A64GPR.parse(ops[0]) {
                let isPage = (mnem == "adrp")
                let base = A64Instruction(opcode: isPage ? .adrp : .adr, is64Bit: true, rd: rd, imm: 0)
                guard let bytes = A64Encoder.encodeBytes(base) else { return }
                let exprVal = evalExpr(ops[1], session: session)
                switch exprVal {
                case .constant(let v):
                    var instWithImm = base
                    instWithImm.imm = v
                    if let immBytes = A64Encoder.encodeBytes(instWithImm) {
                        sec.emitBytes(immBytes, loc: loc)
                    }
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
                    sec.emitBytes(bytes, loc: loc)
                }
                return
            }
        }

        // 6. SVE instructions (`addvl`, `addpl`, `rdvl`, `rdsvl`, `rdffr`, `wrffr`, `ldr`/`str` zN/pN)
        if (mnem == "addvl" || mnem == "addpl") && ops.count == 3 {
            if let (rd, _, _) = A64GPR.parse(ops[0]),
               let (rn, _, _) = A64GPR.parse(ops[1]) {
                let imm = parseImmediateValue(ops[2], session: session) ?? 0
                emitInst(A64Instruction(opcode: mnem == "addvl" ? .sveAddvl : .sveAddpl, rd: rd, rn: rn, imm: imm), into: sec, loc: loc)
                return
            }
        }
        if (mnem == "rdvl" || mnem == "rdsvl") && ops.count == 2 {
            if let (rd, _, _) = A64GPR.parse(ops[0]) {
                let imm6 = UInt32(bitPattern: Int32(truncatingIfNeeded: parseImmediateValue(ops[1], session: session) ?? 0)) & 0x3F
                let baseWord: UInt32 = (mnem == "rdvl") ? 0x04BF5000 : 0x04BF5800
                let word = baseWord | (imm6 << 5) | UInt32(rd.rawValue)
                sec.emitBytes([
                    UInt8(truncatingIfNeeded: word),
                    UInt8(truncatingIfNeeded: word >> 8),
                    UInt8(truncatingIfNeeded: word >> 16),
                    UInt8(truncatingIfNeeded: word >> 24),
                ], loc: loc)
                return
            }
        }
        if (mnem == "rdffr" || mnem == "wrffr") && ops.count == 1 {
            if let pd = A64PReg.parse(Substring(ops[0])) {
                emitInst(A64Instruction(opcode: mnem == "rdffr" ? .sveRdffr : .sveWrffr, pd: pd), into: sec, loc: loc)
                return
            }
        }

        // 7. Loads and Stores (`ldr`, `str`, `ldrb`, `strb`, `ldrh`, `strh`, `ldrsb`, `ldrsh`, `ldrsw`,
        //    `ldur`, `stur`, `ldtr`, `sttr`, `ldp`, `stp`, `ldxr`, `stxr`, `ldaxr`, `stlxr`, `ldar`, `stlr`)
        if isLoadStoreMnemonic(mnem) {
            parseLoadStore(mnemonic: mnem, ops: ops, loc: loc, session: session, diagnostics: &diagnostics)
            return
        }

        // 8. Move wide & `mov` alias (`movz`, `movk`, `movn`, `mov`, `mvn`)
        if (mnem == "movz" || mnem == "movk" || mnem == "movn") && ops.count >= 2 {
            if let (rd, is64, _) = A64GPR.parse(ops[0]) {
                let op: A64OpcodeId = (mnem == "movz") ? .movz : ((mnem == "movk") ? .movk : .movn)
                var shiftAmt: UInt8 = 0
                if ops.count >= 3 {
                    let sParts = ops[2].split(whereSeparator: { $0.isWhitespace })
                    if sParts.count >= 2, let v = parseImmediateValue(String(sParts[1]), session: session) {
                        shiftAmt = UInt8(truncatingIfNeeded: v)
                    }
                }
                let exprVal = evalExpr(ops[1], session: session)
                switch exprVal {
                case .constant(let imm):
                    emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, amount: shiftAmt, imm: imm & 0xFFFF), into: sec, loc: loc)
                case .symbolOffset(let sym, let addend, let mod):
                    let base = A64Instruction(opcode: op, is64Bit: is64, rd: rd, amount: shiftAmt, imm: 0)
                    if let bytes = A64Encoder.encodeBytes(base) {
                        let rKind: RelocKind = (mod == .a64TprelHi12) ? .aarch64_tlsle_add_tprel_hi12 : .aarch64_tlsle_add_tprel_lo12_nc
                        sec.emitBytes(bytes, fixups: [AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: sym, addend: addend)], loc: loc)
                    }
                default:
                    break
                }
                return
            }
        }
        if mnem == "mov" && ops.count == 2 {
            if let (rd, is64, rdIsSP) = A64GPR.parse(ops[0]) {
                if let (rn, _, rnIsSP) = A64GPR.parse(ops[1]) {
                    emitInst(.movReg(is64Bit: is64, rd: rd, rn: rn, involvesSP: rdIsSP || rnIsSP), into: sec, loc: loc)
                    return
                }
                if let exprVal = evalExpr(ops[1], session: session) {
                    switch exprVal {
                    case .constant(let imm):
                        if let movInst = encodeMovImmediate(rd: rd, is64Bit: is64, imm: imm) {
                            emitInst(movInst, into: sec, loc: loc)
                            return
                        }
                    case .symbolDiff(let plusSym, let minusSym, let addend):
                        let base = A64Instruction(opcode: .movz, is64Bit: is64, rd: rd, amount: 0, imm: 0)
                        if let bytes = A64Encoder.encodeBytes(base) {
                            let fixup = AsmInstFixup(
                                offsetInInst: 0,
                                kind: .aarch64_abs16,
                                symbol: plusSym,
                                minusSymbol: minusSym,
                                addend: addend,
                                width: 4
                            )
                            sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                            return
                        }
                    default:
                        break
                    }
                }
            }
        }
        if mnem == "mvn" && ops.count >= 2 {
            if let (rd, is64, _) = A64GPR.parse(ops[0]),
               let (rm, _, _) = A64GPR.parse(ops[1]) {
                let (shift, amt) = parseOptionalShift(ops, startIndex: 2, session: session)
                emitInst(.mvn(is64Bit: is64, rd: rd, rm: rm, shift: shift, amount: amt), into: sec, loc: loc)
                return
            }
        }

        // 9. Compare & Test aliases (`cmp`, `cmn`, `tst`, `neg`, `negs`)
        if (mnem == "cmp" || mnem == "cmn") && ops.count >= 2 {
            if let (rn, is64, rnIsSP) = A64GPR.parse(ops[0]) {
                let isCmp = (mnem == "cmp")
                if let (rm, _, _) = A64GPR.parse(ops[1]) {
                    if rnIsSP || (ops.count >= 3 && hasExtendSpecifier(ops[2])) {
                        let (ext, amt) = parseOptionalExtend(ops, startIndex: 2, is64Bit: is64, session: session)
                        emitInst(
                            A64Instruction(
                                opcode: isCmp ? .subsExtended : .addsExtended,
                                is64Bit: is64,
                                rd: .xzr,
                                rn: rn,
                                rm: rm,
                                extendKind: ext,
                                amount: amt
                            ),
                            into: sec,
                            loc: loc
                        )
                    } else {
                        let (shift, amt) = parseOptionalShift(ops, startIndex: 2, session: session)
                        emitInst(
                            isCmp
                                ? .cmpShifted(is64Bit: is64, rn: rn, rm: rm, shift: shift, amount: amt)
                                : .cmnShifted(is64Bit: is64, rn: rn, rm: rm, shift: shift, amount: amt),
                            into: sec,
                            loc: loc
                        )
                    }
                    return
                }
                if let imm = parseImmediateValue(ops[1], session: session) {
                    let (_, shiftAmt) = parseOptionalShift(ops, startIndex: 2, session: session)
                    let lsl12 = (shiftAmt == 12)
                    emitInst(
                        isCmp
                            ? .cmpImm(is64Bit: is64, rn: rn, imm12: UInt16(truncatingIfNeeded: imm), lsl12: lsl12)
                            : .cmnImm(is64Bit: is64, rn: rn, imm12: UInt16(truncatingIfNeeded: imm), lsl12: lsl12),
                        into: sec,
                        loc: loc
                    )
                    return
                }
            }
        }
        if mnem == "tst" && ops.count >= 2 {
            if let (rn, is64, _) = A64GPR.parse(ops[0]) {
                if let (rm, _, _) = A64GPR.parse(ops[1]) {
                    let (shift, amt) = parseOptionalShift(ops, startIndex: 2, session: session)
                    emitInst(.tstShifted(is64Bit: is64, rn: rn, rm: rm, shift: shift, amount: amt), into: sec, loc: loc)
                    return
                }
                if let imm = parseImmediateValue(ops[1], session: session) {
                    emitInst(.tstImm(is64Bit: is64, rn: rn, bitmask: UInt64(bitPattern: imm)), into: sec, loc: loc)
                    return
                }
            }
        }
        if (mnem == "neg" || mnem == "negs") && ops.count >= 2 {
            if let (rd, is64, _) = A64GPR.parse(ops[0]),
               let (rm, _, _) = A64GPR.parse(ops[1]) {
                let (shift, amt) = parseOptionalShift(ops, startIndex: 2, session: session)
                emitInst(
                    mnem == "neg"
                        ? .neg(is64Bit: is64, rd: rd, rm: rm, shift: shift, amount: amt)
                        : .negs(is64Bit: is64, rd: rd, rm: rm, shift: shift, amount: amt),
                    into: sec,
                    loc: loc
                )
                return
            }
        }

        // 10. Arithmetic & Logical (`add`, `adds`, `sub`, `subs`, `and`, `ands`, `orr`, `orn`, `eor`, `eon`, `bic`, `bics`)
        if mnem == "add" || mnem == "adds" || mnem == "sub" || mnem == "subs" {
            if parseAddSub(mnemonic: mnem, ops: ops, loc: loc, session: session) {
                return
            }
        }
        if mnem == "and" || mnem == "ands" || mnem == "orr" || mnem == "orn" || mnem == "eor" || mnem == "eon" || mnem == "bic" || mnem == "bics" {
            if parseLogical(mnemonic: mnem, ops: ops, loc: loc, session: session) {
                return
            }
        }

        // 11. Shifts, Bitfields, Multiply/Divide, Conditional Select
        if parseBitfieldOrShiftOrMulOrCond(mnemonic: mnem, ops: ops, loc: loc, session: session) {
            return
        }

        // 12. Scalar FP and Advanced SIMD (NEON)
        if parseFpOrSimd(mnemonic: mnem, ops: ops, loc: loc, session: session) {
            return
        }

        diagnostics.report(.asmInvalidInstruction, at: loc, args: [rawMnemonic])
    }

    // MARK: - Helpers

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
            case .symbolOffset(let sym, let addend, _):
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

    /// Synthesizes `mov Rd, #imm` using `movz`, `movn`, or `orrImm` (matching GNU `as` / LLVM MC priority).
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

    private static func hasExtendSpecifier(_ op: String) -> Bool {
        let first = splitFirstWord(op).0
        return A64ExtendKind.parse(Substring(first)) != nil
    }

    private static func parseOptionalShift(_ ops: [String], startIndex: Int, session: AsmSession) -> (A64ShiftKind, UInt8) {
        guard startIndex < ops.count else { return (.lsl, 0) }
        let (kindStr, amtStr) = splitFirstWord(ops[startIndex])
        let kind = A64ShiftKind.parse(Substring(kindStr)) ?? .lsl
        let amt = UInt8(truncatingIfNeeded: parseImmediateValue(amtStr, session: session) ?? 0)
        return (kind, amt)
    }

    private static func parseOptionalExtend(_ ops: [String], startIndex: Int, is64Bit: Bool, session: AsmSession) -> (A64ExtendKind, UInt8) {
        let defaultExt: A64ExtendKind = is64Bit ? .uxtx : .uxtw
        guard startIndex < ops.count else { return (defaultExt, 0) }
        let (kindStr, amtStr) = splitFirstWord(ops[startIndex])
        if let ext = A64ExtendKind.parse(Substring(kindStr)) {
            let amt = amtStr.isEmpty ? 0 : UInt8(truncatingIfNeeded: parseImmediateValue(amtStr, session: session) ?? 0)
            return (ext, amt)
        }
        if kindStr.lowercased() == "lsl" {
            let amt = amtStr.isEmpty ? 0 : UInt8(truncatingIfNeeded: parseImmediateValue(amtStr, session: session) ?? 0)
            return (defaultExt, amt)
        }
        return (defaultExt, 0)
    }

    // MARK: - Add / Sub / Logical

    private static func parseAddSub(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        guard ops.count >= 3,
              let (rd, is64, rdIsSP) = A64GPR.parse(ops[0]),
              let (rn, _, rnIsSP) = A64GPR.parse(ops[1]) else {
            return false
        }
        let sec = session.currentSection

        // Register 3rd operand?
        if let (rm, rmIs64, _) = A64GPR.parse(ops[2]) {
            let useExtended = rdIsSP || rnIsSP || (ops.count >= 4 && hasExtendSpecifier(ops[3])) || (is64 && !rmIs64)
            if useExtended {
                var (ext, amt) = parseOptionalExtend(ops, startIndex: 3, is64Bit: is64, session: session)
                if is64 && !rmIs64 && ops.count < 4 {
                    ext = .uxtw
                }
                let op: A64OpcodeId
                switch mnemonic {
                case "add":  op = .addExtended
                case "adds": op = .addsExtended
                case "sub":  op = .subExtended
                default:     op = .subsExtended
                }
                emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, extendKind: ext, amount: amt), into: sec, loc: loc)
            } else {
                let (shift, amt) = parseOptionalShift(ops, startIndex: 3, session: session)
                let op: A64OpcodeId
                switch mnemonic {
                case "add":  op = .addShifted
                case "adds": op = .addsShifted
                case "sub":  op = .subShifted
                default:     op = .subsShifted
                }
                emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, shiftKind: shift, amount: amt), into: sec, loc: loc)
            }
            return true
        }

        // Immediate or `:lo12:sym` 3rd operand
        let opImm: A64OpcodeId
        switch mnemonic {
        case "add":  opImm = .addImm
        case "adds": opImm = .addsImm
        case "sub":  opImm = .subImm
        default:     opImm = .subsImm
        }

        let (_, shiftAmt) = parseOptionalShift(ops, startIndex: 3, session: session)
        let exprVal = evalExpr(ops[2], session: session)
        switch exprVal {
        case .constant(let imm):
            if imm < 0 && imm >= -0xFFF {
                let flippedOp: A64OpcodeId
                switch opImm {
                case .addImm:  flippedOp = .subImm
                case .addsImm: flippedOp = .subsImm
                case .subImm:  flippedOp = .addImm
                default:       flippedOp = .addsImm
                }
                emitInst(A64Instruction(opcode: flippedOp, is64Bit: is64, rd: rd, rn: rn, amount: shiftAmt, imm: -imm), into: sec, loc: loc)
            } else if imm > 0xFFF && (imm & 0xFFF) == 0 && (imm >> 12) <= 0xFFF && shiftAmt == 0 {
                emitInst(A64Instruction(opcode: opImm, is64Bit: is64, rd: rd, rn: rn, amount: 12, imm: imm >> 12), into: sec, loc: loc)
            } else {
                emitInst(A64Instruction(opcode: opImm, is64Bit: is64, rd: rd, rn: rn, amount: shiftAmt, imm: imm), into: sec, loc: loc)
            }
            return true

        case .symbolOffset(let sym, let addend, let mod):
            let base = A64Instruction(opcode: opImm, is64Bit: is64, rd: rd, rn: rn, amount: shiftAmt, imm: 0)
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

    private static func parseLogical(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        guard ops.count >= 3,
              let (rd, is64, _) = A64GPR.parse(ops[0]),
              let (rn, _, _) = A64GPR.parse(ops[1]) else {
            return false
        }
        let sec = session.currentSection

        if let (rm, _, _) = A64GPR.parse(ops[2]) {
            let (shift, amt) = parseOptionalShift(ops, startIndex: 3, session: session)
            let op: A64OpcodeId
            switch mnemonic {
            case "and":  op = .andShifted
            case "ands": op = .andsShifted
            case "orr":  op = .orrShifted
            case "orn":  op = .ornShifted
            case "eor":  op = .eorShifted
            case "eon":  op = .eonShifted
            case "bic":  op = .bicShifted
            default:     op = .bicsShifted
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, shiftKind: shift, amount: amt), into: sec, loc: loc)
            return true
        }

        if let imm = parseImmediateValue(ops[2], session: session) {
            // Note: `bic Rd, Rn, #imm` is an alias for `and Rd, Rn, #~imm`!
            var mask = UInt64(bitPattern: imm)
            let op: A64OpcodeId
            switch mnemonic {
            case "and":  op = .andImm
            case "ands": op = .andsImm
            case "orr":  op = .orrImm
            case "eor":  op = .eorImm
            case "bic":
                op = .andImm
                mask = is64 ? ~mask : (~mask & 0xFFFF_FFFF)
            case "bics":
                op = .andsImm
                mask = is64 ? ~mask : (~mask & 0xFFFF_FFFF)
            default:
                return false
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, imm: Int64(bitPattern: mask)), into: sec, loc: loc)
            return true
        }
        return false
    }

    // MARK: - Bitfields, Shifts, Multiply/Divide, Conditional Select

    private static func parseBitfieldOrShiftOrMulOrCond(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        let sec = session.currentSection

        switch mnemonic {
        case "lsl", "lsr", "asr", "ror":
            guard ops.count == 3,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]) else { return false }
            if let (rm, _, _) = A64GPR.parse(ops[2]) {
                let op: A64OpcodeId
                switch mnemonic {
                case "lsl": op = .lslv
                case "lsr": op = .lsrv
                case "asr": op = .asrv
                default:    op = .rorv
                }
                emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm), into: sec, loc: loc)
                return true
            }
            if let shiftVal = parseImmediateValue(ops[2], session: session) {
                let shift = UInt8(truncatingIfNeeded: shiftVal)
                let inst: A64Instruction
                switch mnemonic {
                case "lsl": inst = .lslImm(is64Bit: is64, rd: rd, rn: rn, shift: shift)
                case "lsr": inst = .lsrImm(is64Bit: is64, rd: rd, rn: rn, shift: shift)
                case "asr": inst = .asrImm(is64Bit: is64, rd: rd, rn: rn, shift: shift)
                default:    inst = A64Instruction(opcode: .extr, is64Bit: is64, rd: rd, rn: rn, rm: rn, amount: shift)
                }
                emitInst(inst, into: sec, loc: loc)
                return true
            }
            return false

        case "lslv", "lsrv", "asrv", "rorv", "udiv", "sdiv", "smulh", "umulh":
            guard ops.count == 3,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let (rm, _, _) = A64GPR.parse(ops[2]) else { return false }
            let op: A64OpcodeId
            switch mnemonic {
            case "lslv":  op = .lslv
            case "lsrv":  op = .lsrv
            case "asrv":  op = .asrv
            case "rorv":  op = .rorv
            case "udiv":  op = .udiv
            case "sdiv":  op = .sdiv
            case "smulh": op = .smulh
            default:      op = .umulh
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm), into: sec, loc: loc)
            return true

        case "mul":
            guard ops.count == 3,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let (rm, _, _) = A64GPR.parse(ops[2]) else { return false }
            emitInst(.mul(is64Bit: is64, rd: rd, rn: rn, rm: rm), into: sec, loc: loc)
            return true

        case "madd", "msub":
            guard ops.count == 4,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let (rm, _, _) = A64GPR.parse(ops[2]),
                  let (ra, _, _) = A64GPR.parse(ops[3]) else { return false }
            emitInst(A64Instruction(opcode: mnemonic == "madd" ? .madd : .msub, is64Bit: is64, rd: rd, rn: rn, rm: rm, ra: ra), into: sec, loc: loc)
            return true

        case "ubfx", "sbfx", "bfi", "bfxil", "ubfm", "sbfm", "bfm":
            guard ops.count == 4,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let v1 = parseImmediateValue(ops[2], session: session),
                  let v2 = parseImmediateValue(ops[3], session: session) else { return false }
            let a = UInt8(truncatingIfNeeded: v1)
            let b = UInt8(truncatingIfNeeded: v2)
            let inst: A64Instruction
            switch mnemonic {
            case "ubfx":  inst = .ubfx(is64Bit: is64, rd: rd, rn: rn, lsb: a, width: b)
            case "sbfx":  inst = .sbfx(is64Bit: is64, rd: rd, rn: rn, lsb: a, width: b)
            case "bfi":   inst = .bfi(is64Bit: is64, rd: rd, rn: rn, lsb: a, width: b)
            case "bfxil": inst = A64Instruction(opcode: .bfm, is64Bit: is64, rd: rd, rn: rn, imm: Int64(a), imm2: a + b - 1)
            case "ubfm":  inst = A64Instruction(opcode: .ubfm, is64Bit: is64, rd: rd, rn: rn, imm: Int64(a), imm2: b)
            case "sbfm":  inst = A64Instruction(opcode: .sbfm, is64Bit: is64, rd: rd, rn: rn, imm: Int64(a), imm2: b)
            default:      inst = A64Instruction(opcode: .bfm, is64Bit: is64, rd: rd, rn: rn, imm: Int64(a), imm2: b)
            }
            emitInst(inst, into: sec, loc: loc)
            return true

        case "extr":
            guard ops.count == 4,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let (rm, _, _) = A64GPR.parse(ops[2]),
                  let lsb = parseImmediateValue(ops[3], session: session) else { return false }
            emitInst(A64Instruction(opcode: .extr, is64Bit: is64, rd: rd, rn: rn, rm: rm, amount: UInt8(truncatingIfNeeded: lsb)), into: sec, loc: loc)
            return true

        case "sxtb", "sxth", "sxtw", "uxtb", "uxth":
            guard ops.count == 2,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]) else { return false }
            let inst: A64Instruction
            switch mnemonic {
            case "sxtb": inst = .sxtb(is64Bit: is64, rd: rd, rn: rn)
            case "sxth": inst = .sxth(is64Bit: is64, rd: rd, rn: rn)
            case "sxtw": inst = .sxtw(rd: rd, rn: rn)
            case "uxtb": inst = .uxtb(rd: rd, rn: rn)
            default:     inst = .uxth(rd: rd, rn: rn)
            }
            emitInst(inst, into: sec, loc: loc)
            return true

        case "clz", "rbit", "rev", "rev16", "rev32":
            guard ops.count == 2,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]) else { return false }
            let op: A64OpcodeId
            switch mnemonic {
            case "clz":   op = .clz
            case "rbit":  op = .rbit
            case "rev":   op = .rev
            case "rev16": op = .rev16
            default:      op = .rev32
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn), into: sec, loc: loc)
            return true

        case "cset", "csetm":
            guard ops.count == 2,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let cond = A64Cond.parse(ops[1]) else { return false }
            emitInst(mnemonic == "cset" ? .cset(is64Bit: is64, rd: rd, cond: cond) : .csetm(is64Bit: is64, rd: rd, cond: cond), into: sec, loc: loc)
            return true

        case "csel", "csinc", "csinv", "csneg":
            guard ops.count == 4,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let (rm, _, _) = A64GPR.parse(ops[2]),
                  let cond = A64Cond.parse(ops[3]) else { return false }
            let op: A64OpcodeId
            switch mnemonic {
            case "csel":  op = .csel
            case "csinc": op = .csinc
            case "csinv": op = .csinv
            default:      op = .csneg
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rm, cond: cond), into: sec, loc: loc)
            return true

        case "cinc", "cinv", "cneg":
            guard ops.count == 3,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let cond = A64Cond.parse(ops[2]) else { return false }
            let op: A64OpcodeId = (mnemonic == "cinc") ? .csinc : ((mnemonic == "cinv") ? .csinv : .csneg)
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rd, rn: rn, rm: rn, cond: cond.inverted), into: sec, loc: loc)
            return true

        case "ccmp":
            guard ops.count == 4,
                  let (rn, is64, _) = A64GPR.parse(ops[0]),
                  let nzcv = parseImmediateValue(ops[2], session: session),
                  let cond = A64Cond.parse(ops[3]) else { return false }
            if let (rm, _, _) = A64GPR.parse(ops[1]) {
                emitInst(A64Instruction(opcode: .ccmpReg, is64Bit: is64, rn: rn, rm: rm, cond: cond, imm2: UInt8(truncatingIfNeeded: nzcv)), into: sec, loc: loc)
                return true
            }
            if let imm5 = parseImmediateValue(ops[1], session: session) {
                emitInst(A64Instruction(opcode: .ccmpImm, is64Bit: is64, rn: rn, cond: cond, imm: imm5, imm2: UInt8(truncatingIfNeeded: nzcv)), into: sec, loc: loc)
                return true
            }
            return false

        default:
            return false
        }
    }

    // MARK: - Loads and Stores

    private static func isLoadStoreMnemonic(_ m: String) -> Bool {
        switch m {
        case "ldr", "str", "ldrb", "strb", "ldrh", "strh", "ldrsb", "ldrsh", "ldrsw",
             "ldur", "stur", "ldurb", "sturb", "ldurh", "sturh", "ldursb", "ldursh", "ldursw",
             "ldtr", "sttr", "ldtrb", "sttrb", "ldtrh", "sttrh", "ldtrsb", "ldtrsh", "ldtrsw",
             "ldp", "stp", "ldxr", "stxr", "ldaxr", "stlxr", "ldar", "stlr", "ldarb", "stlrb", "ldarh", "stlrh":
            return true
        default:
            return false
        }
    }

    private static func parseLoadStore(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let sec = session.currentSection

        // 1. SVE `ldr`/`str` `zN` or `pN`, `[xBase, #simm9, mul vl]`
        if (mnemonic == "ldr" || mnemonic == "str") && ops.count >= 2 {
            let isLoad = (mnemonic == "ldr")
            if let zd = A64ZReg.parse(Substring(ops[0])) {
                let (baseReg, immVal) = parseSVEMemOperand(ops: Array(ops.dropFirst()), session: session)
                emitInst(A64Instruction(opcode: isLoad ? .sveLdrZ : .sveStrZ, rn: baseReg, zd: zd, imm: immVal), into: sec, loc: loc)
                return
            }
            if let pd = A64PReg.parse(Substring(ops[0])) {
                let (baseReg, immVal) = parseSVEMemOperand(ops: Array(ops.dropFirst()), session: session)
                emitInst(A64Instruction(opcode: isLoad ? .sveLdrP : .sveStrP, rn: baseReg, pd: pd, imm: immVal), into: sec, loc: loc)
                return
            }
        }

        // 2. Pair loads/stores (`ldp`, `stp`)
        if (mnemonic == "ldp" || mnemonic == "stp") && ops.count >= 3 {
            let isLoad = (mnemonic == "ldp")
            let memMode = parseMemAddressing(ops: Array(ops.dropFirst(2)), session: session)
            if let (v1, sw1, _) = A64VReg.parse(ops[0]), sw1 == .q,
               let (v2, sw2, _) = A64VReg.parse(ops[1]), sw2 == .q {
                let op: A64OpcodeId
                switch memMode.indexing {
                case .pre:    op = isLoad ? .ldpPreQ : .stpPreQ
                case .post:   op = isLoad ? .ldpPostQ : .stpPostQ
                case .signed: op = isLoad ? .ldpSignedQ : .stpSignedQ
                }
                emitInst(A64Instruction(opcode: op, rn: memMode.base, vd: v1, vn: v2, scalarWidth: .q, imm: memMode.offset), into: sec, loc: loc)
                return
            }
            if let (r1, is64, _) = A64GPR.parse(ops[0]),
               let (r2, _, _) = A64GPR.parse(ops[1]) {
                let op: A64OpcodeId
                switch memMode.indexing {
                case .pre:    op = isLoad ? .ldpPre : .stpPre
                case .post:   op = isLoad ? .ldpPost : .stpPost
                case .signed: op = isLoad ? .ldpSigned : .stpSigned
                }
                emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: r1, rn: memMode.base, rm: r2, imm: memMode.offset), into: sec, loc: loc)
                return
            }
        }

        // 3. Atomics / exclusives (`ldxr`, `stxr`, `ldaxr`, `stlxr`, `ldar`, `stlr`, ...)
        switch mnemonic {
        case "stxr", "stlxr":
            guard ops.count == 3,
                  let (ws, _, _) = A64GPR.parse(ops[0]),
                  let (rt, is64, _) = A64GPR.parse(ops[1]) else { return }
            let mem = parseMemAddressing(ops: [ops[2]], session: session)
            emitInst(A64Instruction(opcode: mnemonic == "stxr" ? .stxr : .stlxr, is64Bit: is64, rd: rt, rn: mem.base, rm: ws), into: sec, loc: loc)
            return

        case "ldxr", "ldaxr", "ldar", "stlr", "ldarb", "stlrb", "ldarh", "stlrh":
            guard ops.count == 2,
                  let (rt, is64, _) = A64GPR.parse(ops[0]) else { return }
            let mem = parseMemAddressing(ops: [ops[1]], session: session)
            let op: A64OpcodeId
            switch mnemonic {
            case "ldxr":  op = .ldxr
            case "ldaxr": op = .ldaxr
            case "ldar":  op = .ldar
            case "stlr":  op = .stlr
            case "ldarb": op = .ldarb
            case "stlrb": op = .stlrb
            case "ldarh": op = .ldarh
            default:      op = .stlrh
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rt, rn: mem.base), into: sec, loc: loc)
            return

        default:
            break
        }

        // 4. Literal pool load `ldr xN, =expr` or PC-relative literal `ldr xN, label`
        if mnemonic == "ldr" && ops.count == 2, !ops[1].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            if let (rt, is64, _) = A64GPR.parse(ops[0]) {
                let rhs = ops[1].trimmingCharacters(in: .whitespaces)
                if rhs.hasPrefix("=") {
                    let poolExpr = String(rhs.dropFirst()).trimmingCharacters(in: .whitespaces)
                    session.literalPoolCounter += 1
                    let poolLabel = ".Lpool_\(session.literalPoolCounter)"
                    sec.literalPool.append((label: poolLabel, expr: poolExpr))
                    let base = A64Instruction(opcode: .ldrLit, is64Bit: is64, rd: rt, imm: 0)
                    if let bytes = A64Encoder.encodeBytes(base) {
                        let fixup = AsmInstFixup(
                            offsetInInst: 0,
                            kind: .aarch64_ld_prel_lo19,
                            symbol: poolLabel,
                            addend: 0,
                            width: 4,
                            resolveIfSameSection: true
                        )
                        sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                    }
                    return
                } else if let exprVal = evalExpr(rhs, session: session),
                          case .constant(let disp) = exprVal {
                    // `ldr xN, #disp` -- PC-relative literal with an explicit byte displacement
                    emitInst(A64Instruction(opcode: .ldrLit, is64Bit: is64, rd: rt, imm: disp), into: sec, loc: loc)
                    return
                } else if let exprVal = evalExpr(rhs, session: session),
                          case .symbolOffset(let sym, let addend, _) = exprVal {
                    let base = A64Instruction(opcode: .ldrLit, is64Bit: is64, rd: rt, imm: 0)
                    if let bytes = A64Encoder.encodeBytes(base) {
                        let fixup = AsmInstFixup(
                            offsetInInst: 0,
                            kind: .aarch64_ld_prel_lo19,
                            symbol: sym,
                            addend: addend,
                            width: 4,
                            resolveIfSameSection: true
                        )
                        sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                    }
                    return
                }
            }
        }

        // 5. Scalar FP / SIMD register load/store (`ldr`/`str` `bN`/`hN`/`sN`/`dN`/`qN`, `[xBase, #off]`)
        if (mnemonic == "ldr" || mnemonic == "str") && ops.count >= 2,
           let (vd, SomeWidth, _) = A64VReg.parse(ops[0]),
           let sw = SomeWidth {
            let isLoad = (mnemonic == "ldr")
            let mem = parseMemAddressing(ops: Array(ops.dropFirst()), session: session)
            let op: A64OpcodeId
            switch (isLoad, sw) {
            case (true, .b):  op = .ldrFpImmB
            case (false, .b): op = .strFpImmB
            case (true, .h):  op = .ldrFpImmH
            case (false, .h): op = .strFpImmH
            case (true, .s):  op = .ldrFpImmS
            case (false, .s): op = .strFpImmS
            case (true, .d):  op = .ldrFpImmD
            case (false, .d): op = .strFpImmD
            case (true, .q):  op = .ldrFpImmQ
            case (false, .q): op = .strFpImmQ
            }
            emitInst(A64Instruction(opcode: op, rn: mem.base, vd: vd, scalarWidth: sw, imm: mem.offset), into: sec, loc: loc)
            return
        }

        // 6. Standard GPR loads/stores
        guard ops.count >= 2, let (rt, is64, _) = A64GPR.parse(ops[0]) else {
            diagnostics.report(.asmInvalidInstruction, at: loc, args: [mnemonic])
            return
        }
        let mem = parseMemAddressing(ops: Array(ops.dropFirst()), session: session)

        // Register-offset addressing `[Xn, Rm {, extend #shift}]`
        if let indexReg = mem.indexReg {
            let op: A64OpcodeId
            switch mnemonic {
            case "ldr":   op = .ldrReg
            case "str":   op = .strReg
            case "ldrb":  op = .ldrbReg
            case "strb":  op = .strbReg
            case "ldrh":  op = .ldrhReg
            case "strh":  op = .strhReg
            case "ldrsb": op = .ldrsbReg64
            case "ldrsh": op = .ldrshReg64
            default:      op = .ldrswReg
            }
            emitInst(
                A64Instruction(
                    opcode: op,
                    is64Bit: is64,
                    rd: rt,
                    rn: mem.base,
                    rm: indexReg,
                    extendKind: mem.extendKind,
                    amount: mem.shiftAmount
                ),
                into: sec,
                loc: loc
            )
            return
        }

        // Pre-indexed / Post-indexed
        if mem.indexing == .pre || mem.indexing == .post {
            let isPre = (mem.indexing == .pre)
            let op: A64OpcodeId
            switch (mnemonic, isPre) {
            case ("ldr", true):    op = .ldrPre
            case ("ldr", false):   op = .ldrPost
            case ("str", true):    op = .strPre
            case ("str", false):   op = .strPost
            case ("ldrb", true):   op = .ldrbPre
            case ("ldrb", false):  op = .ldrbPost
            case ("strb", true):   op = .strbPre
            case ("strb", false):  op = .strbPost
            case ("ldrh", true):   op = .ldrhPre
            case ("ldrh", false):  op = .ldrhPost
            case ("strh", true):   op = .strhPre
            case ("strh", false):  op = .strhPost
            case ("ldrsb", true):  op = .ldrsbPre64
            case ("ldrsb", false): op = .ldrsbPost64
            case ("ldrsh", true):  op = .ldrshPre64
            case ("ldrsh", false): op = .ldrshPost64
            case ("ldrsw", true):  op = .ldrswPre
            default:               op = .ldrswPost
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset), into: sec, loc: loc)
            return
        }

        // Unscaled (`ldur`/`stur`) or Unprivileged (`ldtr`/`sttr`)
        if mnemonic.hasPrefix("ldur") || mnemonic.hasPrefix("stur") || mnemonic.hasPrefix("ldtr") || mnemonic.hasPrefix("sttr") {
            let op: A64OpcodeId
            switch mnemonic {
            case "ldur":   op = .ldur
            case "stur":   op = .stur
            case "ldurb":  op = .ldurb
            case "sturb":  op = .sturb
            case "ldurh":  op = .ldurh
            case "sturh":  op = .sturh
            case "ldursb": op = is64 ? .ldursb64 : .ldursb32
            case "ldursh": op = is64 ? .ldursh64 : .ldursh32
            case "ldursw": op = .ldursw
            case "ldtr":   op = .ldtr
            case "sttr":   op = .sttr
            case "ldtrb":  op = .ldtrb
            case "sttrb":  op = .sttrb
            case "ldtrh":  op = .ldtrh
            case "sttrh":  op = .sttrh
            case "ldtrsb": op = is64 ? .ldtrsb64 : .ldtrsb32
            case "ldtrsh": op = is64 ? .ldtrsh64 : .ldtrsh32
            default:       op = .ldtrsw
            }
            emitInst(A64Instruction(opcode: op, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset), into: sec, loc: loc)
            return
        }

        // Unsigned immediate (or auto-fallback to `ldur`/`stur` if negative/unaligned offset!)
        let opImm: A64OpcodeId
        let scaleLog2: Int
        switch mnemonic {
        case "ldr":   opImm = .ldrImm;  scaleLog2 = is64 ? 3 : 2
        case "str":   opImm = .strImm;  scaleLog2 = is64 ? 3 : 2
        case "ldrb":  opImm = .ldrbImm; scaleLog2 = 0
        case "strb":  opImm = .strbImm; scaleLog2 = 0
        case "ldrh":  opImm = .ldrhImm; scaleLog2 = 1
        case "strh":  opImm = .strhImm; scaleLog2 = 1
        case "ldrsb": opImm = is64 ? .ldrsbImm64 : .ldrsbImm32; scaleLog2 = 0
        case "ldrsh": opImm = is64 ? .ldrshImm64 : .ldrshImm32; scaleLog2 = 1
        default:      opImm = .ldrswImm; scaleLog2 = 2
        }

        if let symReloc = mem.symbolReloc {
            let base = A64Instruction(opcode: opImm, is64Bit: is64, rd: rt, rn: mem.base, imm: 0)
            if let bytes = A64Encoder.encodeBytes(base) {
                let rKind: RelocKind
                if symReloc.modifier == .a64GotLo12 {
                    rKind = .aarch64_ld64_got_lo12_nc
                } else {
                    switch scaleLog2 {
                    case 0:  rKind = .aarch64_ldst8_abs_lo12_nc
                    case 1:  rKind = .aarch64_ldst16_abs_lo12_nc
                    case 2:  rKind = .aarch64_ldst32_abs_lo12_nc
                    default: rKind = .aarch64_ldst64_abs_lo12_nc
                    }
                }
                sec.emitBytes(bytes, fixups: [AsmInstFixup(offsetInInst: 0, kind: rKind, symbol: symReloc.symbol, addend: symReloc.addend)], loc: loc)
            }
            return
        }

        let candidate = A64Instruction(opcode: opImm, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset)
        if let bytes = A64Encoder.encodeBytes(candidate) {
            sec.emitBytes(bytes, loc: loc)
            return
        }

        // Fallback to unscaled `ldur`/`stur` if `mem.offset` is negative or unaligned in -256...255
        let unscaledOp: A64OpcodeId
        switch mnemonic {
        case "ldr":   unscaledOp = .ldur
        case "str":   unscaledOp = .stur
        case "ldrb":  unscaledOp = .ldurb
        case "strb":  unscaledOp = .sturb
        case "ldrh":  unscaledOp = .ldurh
        case "strh":  unscaledOp = .sturh
        case "ldrsb": unscaledOp = is64 ? .ldursb64 : .ldursb32
        case "ldrsh": unscaledOp = is64 ? .ldursh64 : .ldursh32
        default:      unscaledOp = .ldursw
        }
        emitInst(A64Instruction(opcode: unscaledOp, is64Bit: is64, rd: rt, rn: mem.base, imm: mem.offset), into: sec, loc: loc)
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
        var symbolReloc: (symbol: String, addend: Int64, modifier: AsmRelocModifier)? = nil
    }

    private static func parseMemAddressing(ops: [String], session: AsmSession) -> A64ParsedMem {
        var result = A64ParsedMem()
        guard let first = ops.first?.trimmingCharacters(in: .whitespaces) else { return result }

        // Post-indexed `[Xn], #imm`
        if first.hasPrefix("[") && first.hasSuffix("]") && ops.count >= 2 {
            let baseName = String(first.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if let (bReg, _, _) = A64GPR.parse(baseName) {
                result.base = bReg
                result.indexing = .post
                result.offset = parseImmediateValue(ops[1], session: session) ?? 0
                return result
            }
        }

        // `[Xn ...]` or `[Xn ...] !`
        var raw = first
        if raw.hasSuffix("!") {
            result.indexing = .pre
            raw = String(raw.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let innerParts = splitCommaSeparated(raw)
        if let basePart = innerParts.first, let (bReg, _, _) = A64GPR.parse(basePart) {
            result.base = bReg
        }
        guard innerParts.count >= 2 else { return result }

        // Check if 2nd part is an index register `[Xn, Rm {, extend #shift}]`
        if let (rm, rmIs64, _) = A64GPR.parse(innerParts[1]) {
            result.indexReg = rm
            result.extendKind = rmIs64 ? .uxtx : .uxtw
            if innerParts.count >= 3 {
                let (ext, amt) = parseOptionalExtend(innerParts, startIndex: 2, is64Bit: rmIs64, session: session)
                result.extendKind = ext
                result.shiftAmount = amt
            }
            return result
        }

        // Otherwise evaluate immediate or `:lo12:sym`
        if let exprVal = evalExpr(innerParts[1], session: session) {
            switch exprVal {
            case .constant(let v):
                result.offset = v
            case .symbolOffset(let sym, let addend, let mod):
                result.symbolReloc = (sym, addend, mod)
            default:
                break
            }
        }
        return result
    }

    private static func parseSVEMemOperand(ops: [String], session: AsmSession) -> (A64GPR, Int64) {
        guard var raw = ops.first?.trimmingCharacters(in: .whitespaces) else { return (.x0, 0) }
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let parts = splitCommaSeparated(raw)
        let baseReg = parts.first.flatMap { A64GPR.parse($0)?.reg } ?? .x0
        let immVal = (parts.count >= 2) ? (parseImmediateValue(parts[1], session: session) ?? 0) : 0
        return (baseReg, immVal)
    }

    // MARK: - Scalar FP & Advanced SIMD (NEON)

    private static func parseFpOrSimd(
        mnemonic: String,
        ops: [String],
        loc: AsmLoc,
        session: AsmSession
    ) -> Bool {
        let sec = session.currentSection

        switch mnemonic {
        case "fmov":
            guard ops.count == 2 else { return false }
            if let (vd, SomeSw, _) = A64VReg.parse(ops[0]), let sw = SomeSw {
                if let (rn, _, _) = A64GPR.parse(ops[1]) {
                    emitInst(A64Instruction(opcode: .fmovGprToFp, is64Bit: sw == .d, rn: rn, vd: vd, scalarWidth: sw), into: sec, loc: loc)
                    return true
                }
                if let (vn, _, _) = A64VReg.parse(ops[1]) {
                    emitInst(A64Instruction(opcode: .fmovReg, is64Bit: sw == .d, vd: vd, vn: vn, scalarWidth: sw), into: sec, loc: loc)
                    return true
                }
            }
            if let (rd, _, _) = A64GPR.parse(ops[0]),
               let (vn, SomeSw, _) = A64VReg.parse(ops[1]), let sw = SomeSw {
                emitInst(A64Instruction(opcode: .fmovFpToGpr, is64Bit: sw == .d, rd: rd, vn: vn, scalarWidth: sw), into: sec, loc: loc)
                return true
            }
            return false

        case "fcvt":
            guard ops.count == 2,
                  let (vd, SomeSwD, _) = A64VReg.parse(ops[0]), let swD = SomeSwD,
                  let (vn, _, _) = A64VReg.parse(ops[1]) else { return false }
            emitInst(A64Instruction(opcode: swD == .d ? .fcvtStoD : .fcvtDtoS, is64Bit: swD == .d, vd: vd, vn: vn, scalarWidth: swD), into: sec, loc: loc)
            return true

        case "scvtf":
            guard ops.count == 2,
                  let (vd, SomeSw, _) = A64VReg.parse(ops[0]), let sw = SomeSw,
                  let (rn, is64, _) = A64GPR.parse(ops[1]) else { return false }
            emitInst(A64Instruction(opcode: .scvtf, is64Bit: is64, rn: rn, vd: vd, scalarWidth: sw), into: sec, loc: loc)
            return true

        case "fcvtzs":
            guard ops.count == 2,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (vn, SomeSw, _) = A64VReg.parse(ops[1]), let sw = SomeSw else { return false }
            emitInst(A64Instruction(opcode: .fcvtzs, is64Bit: is64, rd: rd, vn: vn, scalarWidth: sw), into: sec, loc: loc)
            return true

        case "fcmp":
            guard ops.count == 2,
                  let (vn, SomeSw, _) = A64VReg.parse(ops[0]), let sw = SomeSw else { return false }
            if let (vm, _, _) = A64VReg.parse(ops[1]) {
                emitInst(A64Instruction(opcode: .fcmpReg, is64Bit: sw == .d, vn: vn, vm: vm, scalarWidth: sw), into: sec, loc: loc)
                return true
            }
            emitInst(A64Instruction(opcode: .fcmpZero, is64Bit: sw == .d, vn: vn, scalarWidth: sw), into: sec, loc: loc)
            return true

        case "fadd", "fsub", "fmul", "fdiv":
            guard ops.count == 3 else { return false }
            if let (vd, SomeSw, _) = A64VReg.parse(ops[0]), let sw = SomeSw,
               let (vn, _, _) = A64VReg.parse(ops[1]),
               let (vm, _, _) = A64VReg.parse(ops[2]) {
                let op: A64OpcodeId
                switch mnemonic {
                case "fadd": op = .faddScalar
                case "fsub": op = .fsubScalar
                case "fmul": op = .fmulScalar
                default:     op = .fdivScalar
                }
                emitInst(A64Instruction(opcode: op, is64Bit: sw == .d, vd: vd, vn: vn, vm: vm, scalarWidth: sw), into: sec, loc: loc)
                return true
            }
            if let (vd, _, SomeArr) = A64VReg.parse(ops[0]), let arr = SomeArr,
               let (vn, _, _) = A64VReg.parse(ops[1]),
               let (vm, _, _) = A64VReg.parse(ops[2]) {
                let op: A64OpcodeId
                switch mnemonic {
                case "fadd": op = .simdFadd
                case "fsub": op = .simdFsub
                case "fmul": op = .simdFmul
                default:     op = .simdFdiv
                }
                emitInst(A64Instruction(opcode: op, vd: vd, vn: vn, vm: vm, arrangement: arr), into: sec, loc: loc)
                return true
            }
            return false

        case "add", "sub", "mul", "cmeq", "cmgt", "cmge", "and", "bic", "orr", "orn", "eor", "uzp1", "uzp2", "zip1", "zip2":
            guard ops.count == 3,
                  let (vd, _, SomeArr) = A64VReg.parse(ops[0]), let arr = SomeArr,
                  let (vn, _, _) = A64VReg.parse(ops[1]),
                  let (vm, _, _) = A64VReg.parse(ops[2]) else { return false }
            let op: A64OpcodeId
            switch mnemonic {
            case "add":  op = .simdAdd
            case "sub":  op = .simdSub
            case "mul":  op = .simdMul
            case "cmeq": op = .simdCmeq
            case "cmgt": op = .simdCmgt
            case "cmge": op = .simdCmge
            case "and":  op = .simdAnd
            case "bic":  op = .simdBic
            case "orr":  op = .simdOrr
            case "orn":  op = .simdOrn
            case "eor":  op = .simdEor
            case "uzp1": op = .simdUzp1
            case "uzp2": op = .simdUzp2
            case "zip1": op = .simdZip1
            default:     op = .simdZip2
            }
            emitInst(A64Instruction(opcode: op, vd: vd, vn: vn, vm: vm, arrangement: arr), into: sec, loc: loc)
            return true

        default:
            return false
        }
    }
}
