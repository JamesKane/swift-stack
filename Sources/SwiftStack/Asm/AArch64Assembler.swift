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
        case "clrex", "isb", "dsb", "dmb":
            // A named option (`ish`, `sy`, ...) or a raw `#imm4` `CRm`; `clrex`/`isb` default to 15.
            let op: A64OpcodeId = mnem == "clrex" ? .clrex : (mnem == "isb" ? .isb : (mnem == "dsb" ? .dsb : .dmb))
            var opt = A64BarrierOption.sy
            if let first = ops.first {
                if let named = A64BarrierOption.parse(Substring(first)) {
                    opt = named
                } else if let crm = parseImmediateValue(first, session: session), (0...15).contains(crm) {
                    opt = A64BarrierOption(rawValue: UInt8(crm))
                } else {
                    return
                }
            }
            emitInst(A64Instruction(opcode: op, barrierOption: opt), into: sec, loc: loc)
            return
        case "ssbb", "pssbb":
            emitInst(A64Instruction(opcode: .dsb, barrierOption: A64BarrierOption(rawValue: mnem == "ssbb" ? 0 : 4)), into: sec, loc: loc)
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
        // PAC/BTI/CSDB hint aliases (`paciasp`, `bti c`, ...).
        let hintName = ops.count == 1 && mnem == "bti" ? "bti \(ops[0].lowercased())" : mnem
        if ops.count <= (mnem == "bti" ? 1 : 0), let imm7 = A64HintAlias.byName[hintName] {
            emitInst(A64Instruction(opcode: .hint, imm: imm7), into: sec, loc: loc)
            return
        }

        // 2. System maintenance (`tlbi`, `ic`, `dc`, `at`)
        if let kind = Self.maintKinds[mnem] {
            guard let opName = ops.first,
                  let maintOp = A64SysMaintOp.parse(kind: kind, name: Substring(opName)) else {
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
            // `spsel` names both a PSTATE field (`msr spsel, #imm`) and a system register (`msr spsel, xN`).
            if let pfield = A64PStateField.parse(Substring(ops[0])), A64GPR.parse(ops[1]) == nil {
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

    private static let maintKinds: [String: A64SysMaintKind] = ["tlbi": .tlbi, "ic": .ic, "dc": .dc, "at": .at]

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

        case "mneg":
            guard ops.count == 3,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let (rm, _, _) = A64GPR.parse(ops[2]) else { return false }
            emitInst(A64Instruction(opcode: .msub, is64Bit: is64, rd: rd, rn: rn, rm: rm, ra: .xzr), into: sec, loc: loc)
            return true

        case "ubfiz", "sbfiz":
            guard ops.count == 4,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let (rn, _, _) = A64GPR.parse(ops[1]),
                  let lsb = parseImmediateValue(ops[2], session: session),
                  let width = parseImmediateValue(ops[3], session: session) else { return false }
            let regWidth: Int64 = is64 ? 64 : 32
            guard lsb >= 0 && lsb < regWidth && width >= 1 && width <= regWidth - lsb else { return false }
            let immr = (regWidth - lsb) % regWidth
            emitInst(A64Instruction(opcode: mnemonic == "ubfiz" ? .ubfm : .sbfm, is64Bit: is64, rd: rd, rn: rn, imm: immr, imm2: UInt8(width - 1)),
                     into: sec, loc: loc)
            return true

        case "bfc":
            guard ops.count == 3,
                  let (rd, is64, _) = A64GPR.parse(ops[0]),
                  let lsb = parseImmediateValue(ops[1], session: session),
                  let width = parseImmediateValue(ops[2], session: session) else { return false }
            let regWidth: Int64 = is64 ? 64 : 32
            guard lsb >= 0 && lsb < regWidth && width >= 1 && width <= regWidth - lsb else { return false }
            emitInst(A64Instruction(opcode: .bfm, is64Bit: is64, rd: rd, rn: .xzr, imm: (regWidth - lsb) % regWidth, imm2: UInt8(width - 1)),
                     into: sec, loc: loc)
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
             "ldp", "stp":
            return true
        default:
            return exclusiveOps[m] != nil
        }
    }

    /// Exclusive and acquire/release mnemonics (one descriptor each).
    private static let exclusiveOps: [String: A64OpcodeId] = [
        "ldxr": .ldxr, "ldaxr": .ldaxr, "ldar": .ldar, "stlr": .stlr, "ldarb": .ldarb, "stlrb": .stlrb,
        "ldarh": .ldarh, "stlrh": .stlrh, "ldxrb": .ldxrb, "ldxrh": .ldxrh, "ldaxrb": .ldaxrb, "ldaxrh": .ldaxrh,
        "stxr": .stxr, "stlxr": .stlxr, "stxrb": .stxrb, "stxrh": .stxrh, "stlxrb": .stlxrb, "stlxrh": .stlxrh,
        "ldxp": .ldxp, "ldaxp": .ldaxp, "stxp": .stxp, "stlxp": .stlxp,
    ]

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

        // 2. Pair loads/stores (`ldp`, `stp`) of W/X or S/D/Q registers
        if (mnemonic == "ldp" || mnemonic == "stp") && ops.count >= 3 {
            let isLoad = (mnemonic == "ldp")
            let memMode = parseMemAddressing(ops: Array(ops.dropFirst(2)), session: session)
            if let (v1, sw1, _) = A64VReg.parse(ops[0]), let w = sw1,
               let (v2, sw2, _) = A64VReg.parse(ops[1]), sw2 == w {
                let op: A64OpcodeId
                switch memMode.indexing {
                case .pre:    op = isLoad ? .ldpFpPre : .stpFpPre
                case .post:   op = isLoad ? .ldpFpPost : .stpFpPost
                case .signed: op = isLoad ? .ldpFpSigned : .stpFpSigned
                }
                emitInst(A64Instruction(opcode: op, rn: memMode.base, vd: v1, vn: v2, scalarWidth: w, imm: memMode.offset), into: sec, loc: loc)
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

        // 3. Atomics / exclusives: `[Ws,] Rt [, Rt2], [Xn]`
        if let op = exclusiveOps[mnemonic] {
            let format = A64InstructionTable.descriptor(for: op).format
            let hasStatus = format == .atomicStoreExcl || format == .atomicStoreExclPair
            let hasPair = format == .atomicLoadPair || format == .atomicStoreExclPair
            let regCount = 1 + (hasStatus ? 1 : 0) + (hasPair ? 1 : 0)
            guard ops.count == regCount + 1 else { return }
            let regs = ops.prefix(regCount).compactMap { A64GPR.parse($0) }
            guard regs.count == regCount else { return }
            let status = hasStatus ? regs[0].reg : .x0
            let rt = regs[hasStatus ? 1 : 0]
            let rt2 = hasPair ? regs[regCount - 1].reg : .x0
            let mem = parseMemAddressing(ops: [ops[regCount]], session: session)
            emitInst(A64Instruction(opcode: op, is64Bit: rt.is64Bit, rd: rt.reg, rn: mem.base, rm: status, ra: rt2), into: sec, loc: loc)
            return
        }

        // 4. Literal pool load `ldr xN, =expr` or PC-relative literal `ldr Rt, label` / `ldrsw Xt, label`
        if (mnemonic == "ldr" || mnemonic == "ldrsw") && ops.count == 2, !ops[1].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let rhs = ops[1].trimmingCharacters(in: .whitespaces)
            let base: A64Instruction
            if let (rt, is64, _) = A64GPR.parse(ops[0]) {
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
            }
            switch evalExpr(rhs, session: session) {
            case .constant(let disp):
                // `ldr Rt, #disp` -- PC-relative literal with an explicit byte displacement
                var inst = base
                inst.imm = disp
                emitInst(inst, into: sec, loc: loc)
            case .symbolOffset(let sym, let addend, _):
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
            default:
                break
            }
            return
        }

        // 5. SIMD/FP register loads/stores (`bN`/`hN`/`sN`/`dN`/`qN`) in every addressing mode
        if ops.count >= 2, ["ldr", "str", "ldur", "stur"].contains(mnemonic),
           let (vt, someWidth, _) = A64VReg.parse(ops[0]), let w = someWidth {
            let isLoad = mnemonic.hasPrefix("ld")
            let mem = parseMemAddressing(ops: Array(ops.dropFirst()), session: session)
            let inst: A64Instruction
            if mnemonic == "ldur" || mnemonic == "stur" {
                inst = A64Instruction(opcode: isLoad ? .ldurFp : .sturFp, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset)
            } else if let indexReg = mem.indexReg {
                inst = A64Instruction(opcode: isLoad ? .ldrFpReg : .strFpReg, rn: mem.base, rm: indexReg, vd: vt, scalarWidth: w,
                                      extendKind: mem.extendKind, amount: mem.shiftAmount, imm2: mem.shiftPresent ? 1 : 0)
            } else if mem.indexing == .pre {
                inst = A64Instruction(opcode: isLoad ? .ldrFpPre : .strFpPre, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset)
            } else if mem.indexing == .post {
                inst = A64Instruction(opcode: isLoad ? .ldrFpPost : .strFpPost, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset)
            } else {
                let unsignedOps: [A64ScalarWidth: (load: A64OpcodeId, store: A64OpcodeId)] = [
                    .b: (.ldrFpImmB, .strFpImmB), .h: (.ldrFpImmH, .strFpImmH), .s: (.ldrFpImmS, .strFpImmS),
                    .d: (.ldrFpImmD, .strFpImmD), .q: (.ldrFpImmQ, .strFpImmQ),
                ]
                let pair = unsignedOps[w]!
                let scaled = A64Instruction(opcode: isLoad ? pair.load : pair.store, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset)
                if let symReloc = mem.symbolReloc {
                    guard let bytes = A64Encoder.encodeBytes(A64Instruction(opcode: scaled.opcode, rn: mem.base, vd: vt, scalarWidth: w)) else { return }
                    let kinds: [RelocKind] = [.aarch64_ldst8_abs_lo12_nc, .aarch64_ldst16_abs_lo12_nc, .aarch64_ldst32_abs_lo12_nc,
                                              .aarch64_ldst64_abs_lo12_nc, .aarch64_ldst128_abs_lo12_nc]
                    let fixup = AsmInstFixup(offsetInInst: 0, kind: kinds[Int(w.rawValue)], symbol: symReloc.symbol, addend: symReloc.addend)
                    sec.emitBytes(bytes, fixups: [fixup], loc: loc)
                    return
                }
                // A negative or unaligned offset falls back to the unscaled `ldur`/`stur` form.
                inst = A64Encoder.encode(scaled) != nil
                    ? scaled
                    : A64Instruction(opcode: isLoad ? .ldurFp : .sturFp, rn: mem.base, vd: vt, scalarWidth: w, imm: mem.offset)
            }
            emitInst(inst, into: sec, loc: loc)
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
            case "ldrsb": op = is64 ? .ldrsbReg64 : .ldrsbReg32
            case "ldrsh": op = is64 ? .ldrshReg64 : .ldrshReg32
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
                    amount: mem.shiftAmount,
                    imm2: mem.shiftPresent ? 1 : 0
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
            case ("ldrsb", true):  op = is64 ? .ldrsbPre64 : .ldrsbPre32
            case ("ldrsb", false): op = is64 ? .ldrsbPost64 : .ldrsbPost32
            case ("ldrsh", true):  op = is64 ? .ldrshPre64 : .ldrshPre32
            case ("ldrsh", false): op = is64 ? .ldrshPost64 : .ldrshPost32
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
        /// An explicit shift amount was written (`lsl #0` sets `S` for byte accesses).
        var shiftPresent = false
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
                result.shiftPresent = !splitFirstWord(innerParts[2]).1.isEmpty
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
             .simdTbl, .simdExt:
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

    private static func resolveTableMnemonic(_ mnem: String) -> A64MnemonicForm? {
        if let descs = tableParsedByMnemonic[mnem] {
            return A64MnemonicForm(descs: descs)
        }
        if mnem.hasSuffix("2"), let descs = tableParsedByMnemonic[String(mnem.dropLast())],
           descs.contains(where: { $0.format == .simdNarrow || $0.format == .simdShiftLong || $0.format == .simdShiftNarrow }) {
            return A64MnemonicForm(descs: descs, upperHalf: true)
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
        return .other(s)
    }

    /// Parses an FP immediate such as `#1.0`, `#-0.5`, or `#1.00000000`.
    private static func parseFPImmediate(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        return Double(s.trimmingCharacters(in: .whitespaces))
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
            guard ops.count >= count else { return nil }
            var regs: [A64VReg] = []
            var arr: A64Arrangement? = nil
            for op in ops.prefix(count) {
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
            guard ops.count == 2, case .scalar(let vn, let w) = ops[0], case .other(let z) = ops[1], parseFPImmediate(z) == 0 else { return nil }
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
            if desc.id == .simdOrr && ops.count == 2, let (regs, arr) = vectors(2) {
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[1], arrangement: arr)
            } else {
                guard ops.count == 3, let (regs, arr) = vectors(3) else { return nil }
                inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], vm: regs[2], arrangement: arr)
            }

        case .simdTwoRegMisc, .simdTwoRegMiscFp, .simdCmpZero:
            guard ops.count == (desc.format == .simdCmpZero ? 3 : 2), let (regs, arr) = vectors(2) else { return nil }
            if desc.format == .simdCmpZero && immediate(ops[2]) != 0 { return nil }
            inst = A64Instruction(opcode: desc.id, vd: regs[0], vn: regs[1], arrangement: arr)

        case .simdAcrossLanes:
            guard ops.count == 2, case .scalar(let vd, let w) = ops[0], case .vector(let vn, let arr) = ops[1],
                  w == arr.elementWidth else { return nil }
            inst = A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: arr)

        case .simdNarrow, .simdShiftNarrow, .simdShiftLong:
            // Narrowing forms take the narrow destination arrangement, `sshll`/`ushll` the narrow source.
            let isLong = desc.format == .simdShiftLong
            let isAlias = form.descs.count == 1 && (desc.id == .simdSshll || desc.id == .simdUshll) && ops.count == 2
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
            guard ops.count == 2, case .gpr(let rd, let is64, false) = ops[0], case .element(let vn, let w, let idx) = ops[1] else { return nil }
            inst = A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, vn: vn, scalarWidth: w, index: idx)

        case .simdModImm:
            guard ops.count == 2 || ops.count == 3 else { return nil }
            let arr: A64Arrangement
            switch ops[0] {
            case .vector(let v, let a):
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
                guard count == 1 else { return nil }
            }
            inst = A64Instruction(opcode: desc.id, rn: base, rm: .xzr, vd: first, arrangement: arr, imm2: UInt8(count))
            if isPost {
                guard let (rm, imm) = postIndex(ops[2]) else { return nil }
                inst.rm = rm
                inst.imm = imm
            }

        case .simdLdStLane, .simdLdStLanePost:
            let isPost = desc.format == .simdLdStLanePost
            guard ops.count == (isPost ? 3 : 2), case .list(let first, 1, nil, let someWidth, let someLane) = ops[0],
                  let w = someWidth, let lane = someLane, let base = baseOnly(ops[1]) else { return nil }
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
