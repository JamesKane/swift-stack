// Sources/SwiftStack/Asm/RV64Assembler.swift
//
// RISC-V 64 (RVA23) assembler parser and instruction emitter (`05-assembler.md` §4.8).
// Handles RV64G + RVA23 instructions, pseudoinstructions (`li`, `la`, `lla`, `call`,
// `tail`, `ret`, `mv`, `not`, `neg`, `sext.w`, `zext.*`, `seqz`, `snez`, `beqz`, `bnez`,
// `csrr`/`csrw`/`csrs`/`csrc`, `rdtime`/`rdcycle`/`rdinstret`, `frcsr`/`fscsr`),
// `.option rvc`/`norvc` compression, and `.insn` directives.

import Foundation

public enum RVAsm {

    // MARK: - Mnemonic Lookup Table

    private static let mnemonicToOpcode: [String: RV64Opcode] = {
        var map: [String: RV64Opcode] = [:]
        for desc in RV64InstructionTable.descriptors {
            if map[desc.mnemonic] == nil {
                map[desc.mnemonic] = desc.opcode
            }
        }
        return map
    }()

    // MARK: - Entry Point

    static func parseInstruction(
        mnemonic rawMnemonic: String,
        args operandsStr: String,
        lineNumber: Int,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let m = rawMnemonic.lowercased()
        let ops = splitOperands(operandsStr)
        let rvc = session.rvOptions.rvcEnabled

        // 1. Handle Pseudoinstructions & Aliases
        if tryHandlePseudo(mnemonic: m, ops: ops, rvc: rvc, lineNumber: lineNumber, session: session, diagnostics: &diagnostics) {
            return
        }

        // 2. Check Atomic `.aq`, `.rl`, `.aqrl` suffixes (e.g., `amoswap.d.aqrl`, `lr.d.aq`, `sc.d.rl`)
        var baseMnemonic = m
        var aq = false
        var rl = false
        if baseMnemonic.hasSuffix(".aqrl") {
            aq = true
            rl = true
            baseMnemonic = String(baseMnemonic.dropLast(5))
        } else if baseMnemonic.hasSuffix(".aq") {
            aq = true
            baseMnemonic = String(baseMnemonic.dropLast(3))
        } else if baseMnemonic.hasSuffix(".rl") {
            rl = true
            baseMnemonic = String(baseMnemonic.dropLast(3))
        }

        // Also handle `vl8r.v` -> `vl8re8.v`, `vl4r.v` -> `vl4re8.v`, `vl2r.v` -> `vl2re8.v`, `vl1r.v` -> `vl1re8.v`
        switch baseMnemonic {
        case "vl1r.v": baseMnemonic = "vl1re8.v"
        case "vl2r.v": baseMnemonic = "vl2re8.v"
        case "vl4r.v": baseMnemonic = "vl4re8.v"
        case "vl8r.v": baseMnemonic = "vl8re8.v"
        default: break
        }

        guard let opcode = mnemonicToOpcode[baseMnemonic] else {
            diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [rawMnemonic])
            return
        }

        let desc = RV64InstructionTable.descriptor(for: opcode)
        encodeByFormat(desc: desc, ops: ops, aq: aq, rl: rl, rvc: rvc, lineNumber: lineNumber, session: session, diagnostics: &diagnostics)
    }

    // MARK: - `.insn` Directive Parser

    static func parseInsnDirective(
        args: String,
        lineNumber: Int,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Check if starts with format letter (`i`, `r`, `s`, `b`, `u`, `j`) followed by whitespace
        let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" })
        if let spIdx = firstSpace {
            let fmt = trimmed[..<spIdx].lowercased()
            let rest = String(trimmed[trimmed.index(after: spIdx)...])
            let ops = splitOperands(rest)

            switch fmt {
            case "i":
                // `.insn i opcode, funct3, rd, rs1, simm12`
                // e.g. `.insn i 0x0f, 0, x0, x0, 0x010`
                if ops.count == 5,
                   let opc = evalConst(ops[0], session: session),
                   let f3 = evalConst(ops[1], session: session),
                   let rd = parseGPR(ops[2]),
                   let rs1 = parseGPR(ops[3]),
                   let imm12 = evalConst(ops[4], session: session) {
                    let word = (UInt32(bitPattern: Int32(truncatingIfNeeded: imm12)) & 0xFFF) << 20
                        | (UInt32(rs1.rawValue) << 15)
                        | ((UInt32(bitPattern: Int32(truncatingIfNeeded: f3)) & 0x7) << 12)
                        | (UInt32(rd.rawValue) << 7)
                        | (UInt32(bitPattern: Int32(truncatingIfNeeded: opc)) & 0x7F)
                    emitWord32(word, session: session, lineNumber: lineNumber)
                    return
                }
            case "r":
                // `.insn r opcode, funct3, funct7, rd, rs1, rs2`
                if ops.count == 6,
                   let opc = evalConst(ops[0], session: session),
                   let f3 = evalConst(ops[1], session: session),
                   let f7 = evalConst(ops[2], session: session),
                   let rd = parseGPR(ops[3]),
                   let rs1 = parseGPR(ops[4]),
                   let rs2 = parseGPR(ops[5]) {
                    let word = ((UInt32(bitPattern: Int32(truncatingIfNeeded: f7)) & 0x7F) << 25)
                        | (UInt32(rs2.rawValue) << 20)
                        | (UInt32(rs1.rawValue) << 15)
                        | ((UInt32(bitPattern: Int32(truncatingIfNeeded: f3)) & 0x7) << 12)
                        | (UInt32(rd.rawValue) << 7)
                        | (UInt32(bitPattern: Int32(truncatingIfNeeded: opc)) & 0x7F)
                    emitWord32(word, session: session, lineNumber: lineNumber)
                    return
                }
            default:
                break
            }
        }

        // Fallback: raw numeric instruction encoding (16-bit or 32-bit)
        if let val = evalConst(trimmed, session: session) {
            if (val & 0x3) != 0x3 && val >= 0 && val <= 0xFFFF {
                let hw = UInt16(truncatingIfNeeded: val)
                session.currentSection.emitBytes([UInt8(hw & 0xFF), UInt8((hw >> 8) & 0xFF)], lineNumber: lineNumber)
            } else {
                emitWord32(UInt32(truncatingIfNeeded: UInt64(bitPattern: val)), session: session, lineNumber: lineNumber)
            }
        }
    }

    // MARK: - Pseudoinstruction Handler

    private static func tryHandlePseudo(
        mnemonic: String,
        ops: [String],
        rvc: Bool,
        lineNumber: Int,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) -> Bool {
        switch mnemonic {
        case "nop":
            emitInst(.gpr(.addi, rd: .zero, rs1: .zero, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
            return true

        case "unimp":
            if rvc {
                emitInst(RV64Instruction(opcode: .c_unimp), rvc: true, session: session, lineNumber: lineNumber)
            } else {
                emitWord32(0xC000_1073, session: session, lineNumber: lineNumber)
            }
            return true

        case "ret":
            emitInst(.gpr(.jalr, rd: .zero, rs1: .ra, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
            return true

        case "li":
            guard ops.count == 2, let rd = parseGPR(ops[0]),
                  let exprVal = AsmExprEvaluator.evaluate(ops[1].trimmingCharacters(in: .whitespaces), constants: session.constants) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [mnemonic])
                return true
            }
            switch exprVal {
            case .constant(let imm):
                let seq = RV64Encoder.expandLi(rd: rd, imm: imm, rvcEnabled: rvc)
                for inst in seq {
                    emitInst(inst, rvc: rvc, session: session, lineNumber: lineNumber)
                }
            case .symbolDiff(let plusSym, let minusSym, let addend):
                let bytes = RV64Encoder.encode(.gpr(.addi, rd: rd, rs1: .zero, imm: 0), rvcEnabled: false)
                let fixup = AsmInstFixup(
                    offsetInInst: 0,
                    kind: .riscv_lo12_i,
                    symbol: plusSym,
                    minusSymbol: minusSym,
                    addend: addend,
                    width: 4
                )
                session.currentSection.emitBytes(bytes, fixups: [fixup], lineNumber: lineNumber)
            default:
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [mnemonic])
            }
            return true

        case "lla", "la":
            guard ops.count == 2, let rd = parseGPR(ops[0]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [mnemonic])
                return true
            }
            let (sym, addend) = parseSymbolTarget(ops[1], session: session)
            let pcrelLabel = ".Lpcrel_hi\(session.pcrelHiCounter)"
            session.pcrelHiCounter += 1
            session.noteSymbol(pcrelLabel)
            session.currentSection.fragments.append(.label(name: pcrelLabel))

            let useGOT = (mnemonic == "la" && session.rvOptions.picEnabled)
            let auipcBytes = RV64Encoder.encode(.gpr(.auipc, rd: rd, imm: 0), rvcEnabled: false)
            let secondInst: RV64Instruction = useGOT
                ? .gpr(.ld, rd: rd, rs1: rd, imm: 0)
                : .gpr(.addi, rd: rd, rs1: rd, imm: 0)
            let secondBytes = RV64Encoder.encode(secondInst, rvcEnabled: false)

            let hiFixup = AsmInstFixup(
                offsetInInst: 0,
                kind: useGOT ? .riscv_got_hi20 : .riscv_pcrel_hi20,
                symbol: sym,
                addend: addend,
                width: 4,
                resolveIfSameSection: !useGOT
            )
            let loFixup = AsmInstFixup(
                offsetInInst: 4,
                kind: .riscv_pcrel_lo12_i,
                symbol: pcrelLabel,
                addend: 0,
                width: 4,
                resolveIfSameSection: !useGOT
            )
            session.currentSection.emitBytes(auipcBytes + secondBytes, fixups: [hiFixup, loFixup], lineNumber: lineNumber)
            return true

        case "mv":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.addi, rd: rd, rs1: rs, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
            return true

        case "not":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            // Standard RV64GC encodes `not` as 32-bit `xori rd, rs, -1`
            emitInst(.gpr(.xori, rd: rd, rs1: rs, imm: -1), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "neg":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.sub, rd: rd, rs1: .zero, rs2: rs), rvc: rvc, session: session, lineNumber: lineNumber)
            return true

        case "negw":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.subw, rd: rd, rs1: .zero, rs2: rs), rvc: rvc, session: session, lineNumber: lineNumber)
            return true

        case "sext.w":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.addiw, rd: rd, rs1: rs, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
            return true

        case "zext.b":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.andi, rd: rd, rs1: rs, imm: 255), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "zext.w":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.add_uw, rd: rd, rs1: rs, rs2: .zero), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "seqz":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.sltiu, rd: rd, rs1: rs, imm: 1), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "snez":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.sltu, rd: rd, rs1: .zero, rs2: rs), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "sltz":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.slt, rd: rd, rs1: rs, rs2: .zero), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "sgtz":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.slt, rd: rd, rs1: .zero, rs2: rs), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "beqz":
            guard ops.count == 2, let rs = parseGPR(ops[0]) else { return false }
            emitBranch(opcode: (rvc && rs.isCompressedReg) ? .c_beqz : .beq, rs1: rs, rs2: .zero, targetExpr: ops[1], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bnez":
            guard ops.count == 2, let rs = parseGPR(ops[0]) else { return false }
            emitBranch(opcode: (rvc && rs.isCompressedReg) ? .c_bnez : .bne, rs1: rs, rs2: .zero, targetExpr: ops[1], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "blez":
            guard ops.count == 2, let rs = parseGPR(ops[0]) else { return false }
            emitBranch(opcode: .bge, rs1: .zero, rs2: rs, targetExpr: ops[1], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bgez":
            guard ops.count == 2, let rs = parseGPR(ops[0]) else { return false }
            emitBranch(opcode: .bge, rs1: rs, rs2: .zero, targetExpr: ops[1], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bltz":
            guard ops.count == 2, let rs = parseGPR(ops[0]) else { return false }
            emitBranch(opcode: .blt, rs1: rs, rs2: .zero, targetExpr: ops[1], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bgtz":
            guard ops.count == 2, let rs = parseGPR(ops[0]) else { return false }
            emitBranch(opcode: .blt, rs1: .zero, rs2: rs, targetExpr: ops[1], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bgt":
            guard ops.count == 3, let rs = parseGPR(ops[0]), let rt = parseGPR(ops[1]) else { return false }
            emitBranch(opcode: .blt, rs1: rt, rs2: rs, targetExpr: ops[2], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "ble":
            guard ops.count == 3, let rs = parseGPR(ops[0]), let rt = parseGPR(ops[1]) else { return false }
            emitBranch(opcode: .bge, rs1: rt, rs2: rs, targetExpr: ops[2], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bgtu":
            guard ops.count == 3, let rs = parseGPR(ops[0]), let rt = parseGPR(ops[1]) else { return false }
            emitBranch(opcode: .bltu, rs1: rt, rs2: rs, targetExpr: ops[2], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "bleu":
            guard ops.count == 3, let rs = parseGPR(ops[0]), let rt = parseGPR(ops[1]) else { return false }
            emitBranch(opcode: .bgeu, rs1: rt, rs2: rs, targetExpr: ops[2], rvc: rvc, lineNumber: lineNumber, session: session)
            return true

        case "j":
            guard ops.count == 1 else { return false }
            let (sym, addend) = parseSymbolTarget(ops[0], session: session)
            let baseInst = RV64Instruction(opcode: rvc ? .c_j : .jal, rd: RVGPR.zero.rawValue)
            session.currentSection.fragments.append(
                .relaxable(
                    branch: .rvBranch(baseInst: baseInst, rvcAllowed: rvc, targetSymbol: sym, addend: addend),
                    isLong: !rvc,
                    lineNumber: lineNumber
                )
            )
            return true

        case "jr":
            if ops.count == 1, let rs = parseGPR(ops[0]) {
                emitInst(.gpr(.jalr, rd: .zero, rs1: rs, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
                return true
            }
            if ops.count == 1, let (imm, base) = parseMemOperand(ops[0], session: session) {
                emitInst(.gpr(.jalr, rd: .zero, rs1: base, imm: imm), rvc: rvc, session: session, lineNumber: lineNumber)
                return true
            }
            return false

        case "call":
            guard ops.count == 1 else { return false }
            let (sym, addend) = parseSymbolTarget(ops[0], session: session)
            let auipcBytes = RV64Encoder.encode(.gpr(.auipc, rd: .ra, imm: 0), rvcEnabled: false)
            let jalrBytes = RV64Encoder.encode(.gpr(.jalr, rd: .ra, rs1: .ra, imm: 0), rvcEnabled: false)
            let fixup = AsmInstFixup(
                offsetInInst: 0,
                kind: .riscv_call_plt,
                symbol: sym,
                addend: addend,
                width: 8,
                resolveIfSameSection: false
            )
            session.currentSection.emitBytes(auipcBytes + jalrBytes, fixups: [fixup], lineNumber: lineNumber)
            return true

        case "tail":
            guard ops.count == 1 else { return false }
            let (sym, addend) = parseSymbolTarget(ops[0], session: session)
            let auipcBytes = RV64Encoder.encode(.gpr(.auipc, rd: .t1, imm: 0), rvcEnabled: false)
            let jalrBytes = RV64Encoder.encode(.gpr(.jalr, rd: .zero, rs1: .t1, imm: 0), rvcEnabled: false)
            let fixup = AsmInstFixup(
                offsetInInst: 0,
                kind: .riscv_call_plt,
                symbol: sym,
                addend: addend,
                width: 8,
                resolveIfSameSection: false
            )
            session.currentSection.emitBytes(auipcBytes + jalrBytes, fixups: [fixup], lineNumber: lineNumber)
            return true

        case "csrr":
            guard ops.count == 2, let rd = parseGPR(ops[0]), let csr = parseCSR(ops[1], session: session) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "csrw":
            guard ops.count == 2, let csr = parseCSR(ops[0], session: session), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.csrrw, rd: .zero, rs1: rs, imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "csrs":
            guard ops.count == 2, let csr = parseCSR(ops[0], session: session), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.csrrs, rd: .zero, rs1: rs, imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "csrc":
            guard ops.count == 2, let csr = parseCSR(ops[0], session: session), let rs = parseGPR(ops[1]) else { return false }
            emitInst(.gpr(.csrrc, rd: .zero, rs1: rs, imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "csrwi":
            guard ops.count == 2, let csr = parseCSR(ops[0], session: session), let uimm = evalConst(ops[1], session: session) else { return false }
            emitInst(RV64Instruction(opcode: .csrrwi, rd: 0, rs1: UInt8(uimm & 0x1F), imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "csrsi":
            guard ops.count == 2, let csr = parseCSR(ops[0], session: session), let uimm = evalConst(ops[1], session: session) else { return false }
            emitInst(RV64Instruction(opcode: .csrrsi, rd: 0, rs1: UInt8(uimm & 0x1F), imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "csrci":
            guard ops.count == 2, let csr = parseCSR(ops[0], session: session), let uimm = evalConst(ops[1], session: session) else { return false }
            emitInst(RV64Instruction(opcode: .csrrci, rd: 0, rs1: UInt8(uimm & 0x1F), imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "rdcycle":
            guard ops.count == 1, let rd = parseGPR(ops[0]) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(RVCSR.cycle.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "rdtime":
            guard ops.count == 1, let rd = parseGPR(ops[0]) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(RVCSR.time.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "rdinstret":
            guard ops.count == 1, let rd = parseGPR(ops[0]) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(RVCSR.instret.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "frcsr", "frsr":
            guard ops.count == 1, let rd = parseGPR(ops[0]) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(RVCSR.fcsr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fscsr", "fssr":
            if ops.count == 1, let rs = parseGPR(ops[0]) {
                emitInst(.gpr(.csrrw, rd: .zero, rs1: rs, imm: Int64(RVCSR.fcsr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
                return true
            }
            if ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) {
                emitInst(.gpr(.csrrw, rd: rd, rs1: rs, imm: Int64(RVCSR.fcsr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
                return true
            }
            return false

        case "frrm":
            guard ops.count == 1, let rd = parseGPR(ops[0]) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(RVCSR.frm.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fsrm":
            if ops.count == 1, let rs = parseGPR(ops[0]) {
                emitInst(.gpr(.csrrw, rd: .zero, rs1: rs, imm: Int64(RVCSR.frm.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
                return true
            }
            if ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) {
                emitInst(.gpr(.csrrw, rd: rd, rs1: rs, imm: Int64(RVCSR.frm.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
                return true
            }
            return false

        case "frflags":
            guard ops.count == 1, let rd = parseGPR(ops[0]) else { return false }
            emitInst(.gpr(.csrrs, rd: rd, rs1: .zero, imm: Int64(RVCSR.fflags.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fsflags":
            if ops.count == 1, let rs = parseGPR(ops[0]) {
                emitInst(.gpr(.csrrw, rd: .zero, rs1: rs, imm: Int64(RVCSR.fflags.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
                return true
            }
            if ops.count == 2, let rd = parseGPR(ops[0]), let rs = parseGPR(ops[1]) {
                emitInst(.gpr(.csrrw, rd: rd, rs1: rs, imm: Int64(RVCSR.fflags.rawValue)), rvc: false, session: session, lineNumber: lineNumber)
                return true
            }
            return false

        case "fmv.s":
            guard ops.count == 2, let fd = parseFPR(ops[0]), let fs = parseFPR(ops[1]) else { return false }
            emitInst(.fp(.fsgnj_s, rd: fd.rawValue, rs1: fs.rawValue, rs2: fs.rawValue), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fabs.s":
            guard ops.count == 2, let fd = parseFPR(ops[0]), let fs = parseFPR(ops[1]) else { return false }
            emitInst(.fp(.fsgnjx_s, rd: fd.rawValue, rs1: fs.rawValue, rs2: fs.rawValue), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fneg.s":
            guard ops.count == 2, let fd = parseFPR(ops[0]), let fs = parseFPR(ops[1]) else { return false }
            emitInst(.fp(.fsgnjn_s, rd: fd.rawValue, rs1: fs.rawValue, rs2: fs.rawValue), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fmv.d":
            guard ops.count == 2, let fd = parseFPR(ops[0]), let fs = parseFPR(ops[1]) else { return false }
            emitInst(.fp(.fsgnj_d, rd: fd.rawValue, rs1: fs.rawValue, rs2: fs.rawValue), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fabs.d":
            guard ops.count == 2, let fd = parseFPR(ops[0]), let fs = parseFPR(ops[1]) else { return false }
            emitInst(.fp(.fsgnjx_d, rd: fd.rawValue, rs1: fs.rawValue, rs2: fs.rawValue), rvc: false, session: session, lineNumber: lineNumber)
            return true

        case "fneg.d":
            guard ops.count == 2, let fd = parseFPR(ops[0]), let fs = parseFPR(ops[1]) else { return false }
            emitInst(.fp(.fsgnjn_d, rd: fd.rawValue, rs1: fs.rawValue, rs2: fs.rawValue), rvc: false, session: session, lineNumber: lineNumber)
            return true

        default:
            return false
        }
    }

    // MARK: - Format-Based Instruction Encoder

    private static func encodeByFormat(
        desc: RV64InstrDesc,
        ops: [String],
        aq: Bool,
        rl: Bool,
        rvc: Bool,
        lineNumber: Int,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        let opcode = desc.opcode
        switch desc.format {
        case .systemFixed, .cFixed:
            emitInst(RV64Instruction(opcode: opcode), rvc: rvc, session: session, lineNumber: lineNumber)

        case .fence:
            if ops.isEmpty {
                let imm = Int64((Int(RVFenceMask.iorw.rawValue) << 4) | Int(RVFenceMask.iorw.rawValue))
                emitInst(RV64Instruction(opcode: .fence, imm: imm), rvc: false, session: session, lineNumber: lineNumber)
            } else if ops.count == 2,
                      let pred = RVFenceMask(name: ops[0]),
                      let succ = RVFenceMask(name: ops[1]) {
                let imm = Int64((Int(pred.rawValue) << 4) | Int(succ.rawValue))
                emitInst(RV64Instruction(opcode: .fence, imm: imm), rvc: false, session: session, lineNumber: lineNumber)
            } else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
            }

        case .sfenceVMA:
            if ops.isEmpty {
                emitInst(.gpr(.sfence_vma, rs1: .zero, rs2: .zero), rvc: false, session: session, lineNumber: lineNumber)
            } else if ops.count == 1, let rs1 = parseGPR(ops[0]) {
                emitInst(.gpr(.sfence_vma, rs1: rs1, rs2: .zero), rvc: false, session: session, lineNumber: lineNumber)
            } else if ops.count == 2, let rs1 = parseGPR(ops[0]), let rs2 = parseGPR(ops[1]) {
                emitInst(.gpr(.sfence_vma, rs1: rs1, rs2: rs2), rvc: false, session: session, lineNumber: lineNumber)
            } else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
            }

        case .r:
            // Also check `%tprel_add(sym)` as 4th operand on `add`
            if opcode == .add && ops.count == 4,
               let rd = parseGPR(ops[0]),
               let rs1 = parseGPR(ops[1]),
               let rs2 = parseGPR(ops[2]),
               let mod = parseRelocModifier(ops[3], session: session) {
                let bytes = RV64Encoder.encode(.gpr(.add, rd: rd, rs1: rs1, rs2: rs2), rvcEnabled: false)
                let fixup = AsmInstFixup(offsetInInst: 0, kind: mod.kind, symbol: mod.symbol, addend: mod.addend, width: 4)
                session.currentSection.emitBytes(bytes, fixups: [fixup], lineNumber: lineNumber)
                return
            }
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let rs1 = parseGPR(ops[1]),
                  let rs2 = parseGPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            // Note: in RV64GC (without Zcb), `mul` is 32-bit; keep `mul` uncompressed unless explicitly `c.mul`.
            let allowCompress = rvc && opcode != .mul && opcode != .add_uw
            emitInst(.gpr(opcode, rd: rd, rs1: rs1, rs2: rs2), rvc: allowCompress, session: session, lineNumber: lineNumber)

        case .rUnary:
            guard ops.count == 2,
                  let rd = parseGPR(ops[0]),
                  let rs1 = parseGPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.gpr(opcode, rd: rd, rs1: rs1), rvc: false, session: session, lineNumber: lineNumber)

        case .rShift64, .rShift32:
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let rs1 = parseGPR(ops[1]),
                  let shamt = evalConst(ops[2], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.gpr(opcode, rd: rd, rs1: rs1, imm: shamt), rvc: rvc, session: session, lineNumber: lineNumber)

        case .i:
            // Special case for `jalr`:
            // - `jalr rs1` -> `jalr ra, rs1, 0`
            // - `jalr rd, rs1` -> `jalr rd, rs1, 0`
            // - `jalr rd, imm(rs1)` -> `jalr rd, rs1, imm`
            // - `jalr rd, rs1, imm` -> `jalr rd, rs1, imm`
            if opcode == .jalr {
                if ops.count == 1, let rs1 = parseGPR(ops[0]) {
                    emitInst(.gpr(.jalr, rd: .ra, rs1: rs1, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
                    return
                }
                if ops.count == 2, let rd = parseGPR(ops[0]) {
                    if let rs1 = parseGPR(ops[1]) {
                        emitInst(.gpr(.jalr, rd: rd, rs1: rs1, imm: 0), rvc: rvc, session: session, lineNumber: lineNumber)
                        return
                    }
                    if let (imm, rs1) = parseMemOperand(ops[1], session: session) {
                        emitInst(.gpr(.jalr, rd: rd, rs1: rs1, imm: imm), rvc: rvc, session: session, lineNumber: lineNumber)
                        return
                    }
                }
            }
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let rs1 = parseGPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            if let mod = parseRelocModifier(ops[2], session: session) {
                let bytes = RV64Encoder.encode(.gpr(opcode, rd: rd, rs1: rs1, imm: 0), rvcEnabled: false)
                let fixup = AsmInstFixup(offsetInInst: 0, kind: mod.kind, symbol: mod.symbol, addend: mod.addend, width: 4)
                session.currentSection.emitBytes(bytes, fixups: [fixup], lineNumber: lineNumber)
                return
            }
            guard let imm = evalConst(ops[2], session: session) else {
                diagnostics.report(.asmInvalidExpression, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [ops[2]])
                return
            }
            // Note: in RV64GC without Zcb, `andi rd, rd, 255` and `xori rd, rd, -1` stay 32-bit
            let allowCompress = rvc && !(opcode == .andi && imm == 255) && opcode != .xori
            emitInst(.gpr(opcode, rd: rd, rs1: rs1, imm: imm), rvc: allowCompress, session: session, lineNumber: lineNumber)

        case .iLoad:
            guard ops.count == 2, let rd = parseGPR(ops[0]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            if let (mod, base) = parseRelocMemOperand(ops[1], session: session) {
                let bytes = RV64Encoder.encode(.gpr(opcode, rd: rd, rs1: base, imm: 0), rvcEnabled: false)
                let fixup = AsmInstFixup(offsetInInst: 0, kind: mod.kind, symbol: mod.symbol, addend: mod.addend, width: 4)
                session.currentSection.emitBytes(bytes, fixups: [fixup], lineNumber: lineNumber)
                return
            }
            guard let (imm, base) = parseMemOperand(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            // In RV64GC (standard C extension), only `lw` and `ld` have compressed forms (`c.lw`, `c.lwsp`, `c.ld`, `c.ldsp`).
            let allowCompress = rvc && (opcode == .lw || opcode == .ld)
            emitInst(.gpr(opcode, rd: rd, rs1: base, imm: imm), rvc: allowCompress, session: session, lineNumber: lineNumber)

        case .iFPLoad:
            guard ops.count == 2,
                  let fd = parseFPR(ops[0]),
                  let (imm, base) = parseMemOperand(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: base.rawValue, imm: imm), rvc: rvc, session: session, lineNumber: lineNumber)

        case .s:
            guard ops.count == 2, let rs2 = parseGPR(ops[0]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            if let (mod, base) = parseRelocMemOperand(ops[1], session: session) {
                let sKind: RelocKind = (mod.kind == .riscv_pcrel_lo12_i) ? .riscv_pcrel_lo12_s : mod.kind
                let bytes = RV64Encoder.encode(.gpr(opcode, rs1: base, rs2: rs2, imm: 0), rvcEnabled: false)
                let fixup = AsmInstFixup(offsetInInst: 0, kind: sKind, symbol: mod.symbol, addend: mod.addend, width: 4)
                session.currentSection.emitBytes(bytes, fixups: [fixup], lineNumber: lineNumber)
                return
            }
            guard let (imm, base) = parseMemOperand(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            // In RV64GC (standard C extension), only `sw` and `sd` have compressed forms (`c.sw`, `c.swsp`, `c.sd`, `c.sdsp`).
            let allowCompress = rvc && (opcode == .sw || opcode == .sd)
            emitInst(.gpr(opcode, rs1: base, rs2: rs2, imm: imm), rvc: allowCompress, session: session, lineNumber: lineNumber)

        case .sFP:
            guard ops.count == 2,
                  let fs2 = parseFPR(ops[0]),
                  let (imm, base) = parseMemOperand(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rs1: base.rawValue, rs2: fs2.rawValue, imm: imm), rvc: rvc, session: session, lineNumber: lineNumber)

        case .b:
            guard ops.count == 3,
                  let rs1 = parseGPR(ops[0]),
                  let rs2 = parseGPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            var branchOp = opcode
            if rvc && rs2 == .zero && rs1.isCompressedReg {
                if opcode == .beq { branchOp = .c_beqz }
                else if opcode == .bne { branchOp = .c_bnez }
            }
            emitBranch(opcode: branchOp, rs1: rs1, rs2: rs2, targetExpr: ops[2], rvc: rvc, lineNumber: lineNumber, session: session)

        case .u:
            guard ops.count == 2, let rd = parseGPR(ops[0]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            if let mod = parseRelocModifier(ops[1], session: session) {
                let bytes = RV64Encoder.encode(.gpr(opcode, rd: rd, imm: 0), rvcEnabled: false)
                let fixup = AsmInstFixup(offsetInInst: 0, kind: mod.kind, symbol: mod.symbol, addend: mod.addend, width: 4)
                session.currentSection.emitBytes(bytes, fixups: [fixup], lineNumber: lineNumber)
                return
            }
            guard let imm = evalConst(ops[1], session: session) else {
                diagnostics.report(.asmInvalidExpression, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [ops[1]])
                return
            }
            emitInst(.gpr(opcode, rd: rd, imm: imm), rvc: rvc, session: session, lineNumber: lineNumber)

        case .j:
            // `jal target` (1 operand, rd = ra) or `jal rd, target` (2 operands)
            let rd: RVGPR
            let targetStr: String
            if ops.count == 1 {
                rd = .ra
                targetStr = ops[0]
            } else if ops.count == 2, let parsedRd = parseGPR(ops[0]) {
                rd = parsedRd
                targetStr = ops[1]
            } else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let (sym, addend) = parseSymbolTarget(targetStr, session: session)
            let useCJ = rvc && rd == .zero
            let baseInst = RV64Instruction(opcode: useCJ ? .c_j : .jal, rd: rd.rawValue)
            session.currentSection.fragments.append(
                .relaxable(
                    branch: .rvBranch(baseInst: baseInst, rvcAllowed: useCJ, targetSymbol: sym, addend: addend),
                    isLong: !useCJ,
                    lineNumber: lineNumber
                )
            )

        case .csrReg:
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let csr = parseCSR(ops[1], session: session),
                  let rs1 = parseGPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.gpr(opcode, rd: rd, rs1: rs1, imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)

        case .csrImm:
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let csr = parseCSR(ops[1], session: session),
                  let uimm = evalConst(ops[2], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(RV64Instruction(opcode: opcode, rd: rd.rawValue, rs1: UInt8(uimm & 0x1F), imm: Int64(csr.rawValue)), rvc: false, session: session, lineNumber: lineNumber)

        case .rLR:
            guard ops.count == 2,
                  let rd = parseGPR(ops[0]),
                  let (imm, base) = parseMemOperand(ops[1], session: session), imm == 0 else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.gpr(opcode, rd: rd, rs1: base, aq: aq, rl: rl), rvc: false, session: session, lineNumber: lineNumber)

        case .rAMO:
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let rs2 = parseGPR(ops[1]),
                  let (imm, base) = parseMemOperand(ops[2], session: session), imm == 0 else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.gpr(opcode, rd: rd, rs1: base, rs2: rs2, aq: aq, rl: rl), rvc: false, session: session, lineNumber: lineNumber)

        case .rFP:
            guard ops.count >= 3,
                  let fd = parseFPR(ops[0]),
                  let fs1 = parseFPR(ops[1]),
                  let fs2 = parseFPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let rm = (ops.count >= 4 ? RVRoundingMode(name: ops[3]) : nil) ?? .dyn
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: fs1.rawValue, rs2: fs2.rawValue, rm: rm), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPFixed:
            guard ops.count == 3,
                  let fd = parseFPR(ops[0]),
                  let fs1 = parseFPR(ops[1]),
                  let fs2 = parseFPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: fs1.rawValue, rs2: fs2.rawValue), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPUnary:
            guard ops.count >= 2,
                  let fd = parseFPR(ops[0]),
                  let fs1 = parseFPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let rm = (ops.count >= 3 ? RVRoundingMode(name: ops[2]) : nil) ?? .dyn
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: fs1.rawValue, rm: rm), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPCmp:
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let fs1 = parseFPR(ops[1]),
                  let fs2 = parseFPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rd: rd.rawValue, rs1: fs1.rawValue, rs2: fs2.rawValue), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPCvtF2I:
            guard ops.count >= 2,
                  let rd = parseGPR(ops[0]),
                  let fs1 = parseFPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let rm = (ops.count >= 3 ? RVRoundingMode(name: ops[2]) : nil) ?? .rtz
            emitInst(.fp(opcode, rd: rd.rawValue, rs1: fs1.rawValue, rm: rm), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPCvtI2F:
            guard ops.count >= 2,
                  let fd = parseFPR(ops[0]),
                  let rs1 = parseGPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let rm = (ops.count >= 3 ? RVRoundingMode(name: ops[2]) : nil) ?? .dyn
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: rs1.rawValue, rm: rm), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPMvF2I:
            guard ops.count == 2,
                  let rd = parseGPR(ops[0]),
                  let fs1 = parseFPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rd: rd.rawValue, rs1: fs1.rawValue), rvc: false, session: session, lineNumber: lineNumber)

        case .rFPMvI2F:
            guard ops.count == 2,
                  let fd = parseFPR(ops[0]),
                  let rs1 = parseGPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: rs1.rawValue), rvc: false, session: session, lineNumber: lineNumber)

        case .rFLI:
            guard ops.count == 2,
                  let fd = parseFPR(ops[0]),
                  let idx = RVZfaFLITable.index(for: ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.fp(opcode, rd: fd.rawValue, rs1: idx), rvc: false, session: session, lineNumber: lineNumber)

        // --- RVV 1.0 ---
        case .vsetvl:
            guard ops.count == 3,
                  let rd = parseGPR(ops[0]),
                  let rs1 = parseGPR(ops[1]),
                  let rs2 = parseGPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.gpr(.vsetvl, rd: rd, rs1: rs1, rs2: rs2), rvc: false, session: session, lineNumber: lineNumber)

        case .vsetvli:
            guard ops.count >= 3,
                  let rd = parseGPR(ops[0]),
                  let rs1 = parseGPR(ops[1]),
                  let vtype = parseVType(Array(ops.dropFirst(2)), session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(RV64Instruction(opcode: .vsetvli, rd: rd.rawValue, rs1: rs1.rawValue, imm: Int64(vtype)), rvc: false, session: session, lineNumber: lineNumber)

        case .vsetivli:
            guard ops.count >= 3,
                  let rd = parseGPR(ops[0]),
                  let uimm = evalConst(ops[1], session: session),
                  let vtype = parseVType(Array(ops.dropFirst(2)), session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(RV64Instruction(opcode: .vsetivli, rd: rd.rawValue, rs1: UInt8(uimm & 0x1F), imm: Int64(vtype)), rvc: false, session: session, lineNumber: lineNumber)

        case .vLoadWhole, .vLoadUnit:
            guard ops.count >= 2,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let (_, base) = parseMemOperand(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let vm = !(ops.count >= 3 && ops[2].lowercased() == "v0.t")
            emitInst(RV64Instruction(opcode: opcode, rd: vd.rawValue, rs1: base.rawValue, vm: vm), rvc: false, session: session, lineNumber: lineNumber)

        case .vStoreWhole, .vStoreUnit:
            guard ops.count >= 2,
                  let vs3 = RVVReg(name: ops[0].lowercased()),
                  let (_, base) = parseMemOperand(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let vm = !(ops.count >= 3 && ops[2].lowercased() == "v0.t")
            emitInst(RV64Instruction(opcode: opcode, rd: vs3.rawValue, rs1: base.rawValue, rs2: vs3.rawValue, vm: vm), rvc: false, session: session, lineNumber: lineNumber)

        case .vOpiVV:
            guard ops.count >= 3,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let vs2 = RVVReg(name: ops[1].lowercased()),
                  let vs1 = RVVReg(name: ops[2].lowercased()) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let vm = !(ops.count >= 4 && ops[3].lowercased() == "v0.t")
            emitInst(.vec(opcode, vd: vd, vs1: vs1.rawValue, vs2: vs2, vm: vm), rvc: false, session: session, lineNumber: lineNumber)

        case .vOpiVX:
            guard ops.count >= 3,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let vs2 = RVVReg(name: ops[1].lowercased()),
                  let rs1 = parseGPR(ops[2]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let vm = !(ops.count >= 4 && ops[3].lowercased() == "v0.t")
            emitInst(.vec(opcode, vd: vd, vs1: rs1.rawValue, vs2: vs2, vm: vm), rvc: false, session: session, lineNumber: lineNumber)

        case .vOpiVI:
            guard ops.count >= 3,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let vs2 = RVVReg(name: ops[1].lowercased()),
                  let simm = evalConst(ops[2], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            let vm = !(ops.count >= 4 && ops[3].lowercased() == "v0.t")
            emitInst(.vec(opcode, vd: vd, vs2: vs2, imm: simm, vm: vm), rvc: false, session: session, lineNumber: lineNumber)

        case .vMvVV:
            guard ops.count == 2,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let vs1 = RVVReg(name: ops[1].lowercased()) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.vec(opcode, vd: vd, vs1: vs1.rawValue), rvc: false, session: session, lineNumber: lineNumber)

        case .vMvVX:
            guard ops.count == 2,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let rs1 = parseGPR(ops[1]) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.vec(opcode, vd: vd, vs1: rs1.rawValue), rvc: false, session: session, lineNumber: lineNumber)

        case .vMvVI:
            guard ops.count == 2,
                  let vd = RVVReg(name: ops[0].lowercased()),
                  let simm = evalConst(ops[1], session: session) else {
                diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
                return
            }
            emitInst(.vec(opcode, vd: vd, imm: simm), rvc: false, session: session, lineNumber: lineNumber)

        default:
            diagnostics.report(.asmInvalidInstruction, at: SourceLocation(rawValue: UInt32(max(1, lineNumber))), args: [desc.mnemonic])
        }
    }

    // MARK: - Emission & Parsing Helpers

    private static func emitInst(_ inst: RV64Instruction, rvc: Bool, session: AsmSession, lineNumber: Int) {
        let bytes = RV64Encoder.encode(inst, rvcEnabled: rvc)
        session.currentSection.emitBytes(bytes, lineNumber: lineNumber)
    }

    private static func emitWord32(_ word: UInt32, session: AsmSession, lineNumber: Int) {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: word),
            UInt8(truncatingIfNeeded: word >> 8),
            UInt8(truncatingIfNeeded: word >> 16),
            UInt8(truncatingIfNeeded: word >> 24),
        ]
        session.currentSection.emitBytes(bytes, lineNumber: lineNumber)
    }

    private static func emitBranch(
        opcode: RV64Opcode,
        rs1: RVGPR,
        rs2: RVGPR,
        targetExpr: String,
        rvc: Bool,
        lineNumber: Int,
        session: AsmSession
    ) {
        let (sym, addend) = parseSymbolTarget(targetExpr, session: session)
        let isCompressedOp = (opcode == .c_beqz || opcode == .c_bnez || opcode == .c_j)
        let baseInst = RV64Instruction(opcode: opcode, rs1: rs1.rawValue, rs2: rs2.rawValue)
        session.currentSection.fragments.append(
            .relaxable(
                branch: .rvBranch(baseInst: baseInst, rvcAllowed: isCompressedOp && rvc, targetSymbol: sym, addend: addend),
                isLong: !(isCompressedOp && rvc),
                lineNumber: lineNumber
            )
        )
    }

    private static func parseGPR(_ str: String) -> RVGPR? {
        RVGPR(name: str.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func parseFPR(_ str: String) -> RVFPR? {
        RVFPR(name: str.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func parseCSR(_ str: String, session: AsmSession) -> RVCSR? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        if let named = RVCSR(name: trimmed) {
            return named
        }
        if let val = evalConst(trimmed, session: session), val >= 0 && val <= 0xFFF {
            return RVCSR(rawValue: UInt16(val))
        }
        return nil
    }

    private static func evalConst(_ expr: String, session: AsmSession) -> Int64? {
        AsmExprEvaluator.evaluate(expr.trimmingCharacters(in: .whitespaces), constants: session.constants)?.constantValue
    }

    private static func parseMemOperand(_ str: String, session: AsmSession) -> (imm: Int64, base: RVGPR)? {
        let s = str.trimmingCharacters(in: .whitespaces)
        guard s.hasSuffix(")"), let openParen = s.lastIndex(of: "(") else {
            return nil
        }
        let dispStr = String(s[..<openParen]).trimmingCharacters(in: .whitespaces)
        let baseStr = String(s[s.index(after: openParen)..<s.index(before: s.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard let base = parseGPR(baseStr) else { return nil }
        if dispStr.isEmpty {
            return (0, base)
        }
        guard let imm = evalConst(dispStr, session: session) else { return nil }
        return (imm, base)
    }

    private struct RelocModInfo {
        let kind: RelocKind
        let symbol: String
        let addend: Int64
    }

    private static func parseRelocModifier(_ str: String, session: AsmSession) -> RelocModInfo? {
        let s = str.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("%"), s.hasSuffix(")"), let openIdx = s.firstIndex(of: "(") else {
            return nil
        }
        let modName = String(s[s.index(after: s.startIndex)..<openIdx]).lowercased()
        let inner = String(s[s.index(after: openIdx)..<s.index(before: s.endIndex)])
        let (sym, addend) = parseSymbolTarget(inner, session: session)

        let kind: RelocKind
        switch modName {
        case "hi":           kind = .riscv_hi20
        case "lo":           kind = .riscv_lo12_i
        case "pcrel_hi":     kind = .riscv_pcrel_hi20
        case "pcrel_lo":     kind = .riscv_pcrel_lo12_i
        case "got_pcrel_hi": kind = .riscv_got_hi20
        case "tprel_hi":     kind = .riscv_tprel_hi20
        case "tprel_lo":     kind = .riscv_tprel_lo12_i
        case "tprel_add":    kind = .riscv_tprel_add
        default: return nil
        }
        return RelocModInfo(kind: kind, symbol: sym, addend: addend)
    }

    private static func parseRelocMemOperand(_ str: String, session: AsmSession) -> (mod: RelocModInfo, base: RVGPR)? {
        let s = str.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("%"), s.hasSuffix(")"), let lastOpen = s.lastIndex(of: "(") else {
            return nil
        }
        let dispPart = String(s[..<lastOpen]).trimmingCharacters(in: .whitespaces)
        let baseStr = String(s[s.index(after: lastOpen)..<s.index(before: s.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard let base = parseGPR(baseStr),
              let mod = parseRelocModifier(dispPart, session: session) else {
            return nil
        }
        return (mod, base)
    }

    private static func parseSymbolTarget(_ expr: String, session: AsmSession) -> (symbol: String, addend: Int64) {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if let val = AsmExprEvaluator.evaluate(trimmed, constants: session.constants) {
            switch val {
            case .symbolOffset(let sym, let addend, _):
                return (sym, addend)
            case .constant(let c):
                return (String(c), 0)
            case .symbolDiff(let plusSym, _, let addend):
                return (plusSym, addend)
            }
        }
        return (trimmed, 0)
    }

    private static func parseVType(_ tokens: [String], session: AsmSession) -> UInt16? {
        if tokens.count == 1, let v = evalConst(tokens[0], session: session) {
            return UInt16(truncatingIfNeeded: v) & 0x7FF
        }
        var sewBits = 8
        var lmulBits: UInt8 = 0
        var ta = false
        var ma = false
        for tok in tokens {
            switch tok.trimmingCharacters(in: .whitespaces).lowercased() {
            case "e8":  sewBits = 8
            case "e16": sewBits = 16
            case "e32": sewBits = 32
            case "e64": sewBits = 64
            case "m1":  lmulBits = 0b000
            case "m2":  lmulBits = 0b001
            case "m4":  lmulBits = 0b010
            case "m8":  lmulBits = 0b011
            case "mf8": lmulBits = 0b101
            case "mf4": lmulBits = 0b110
            case "mf2": lmulBits = 0b111
            case "ta":  ta = true
            case "tu":  ta = false
            case "ma":  ma = true
            case "mu":  ma = false
            default: return nil
            }
        }
        return RVVType(sewBits: sewBits, lmulBits: lmulBits, tailAgnostic: ta, maskAgnostic: ma)?.rawValue
    }

    private static func splitOperands(_ s: String) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        for ch in trimmed {
            if ch == "(" { parenDepth += 1 }
            else if ch == ")" { parenDepth = max(0, parenDepth - 1) }
            if ch == "," && parenDepth == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty {
            result.append(last)
        }
        return result
    }
}
