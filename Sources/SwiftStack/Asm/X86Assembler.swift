// Sources/SwiftStack/Asm/X86Assembler.swift
//
// AT&T-Syntax x86-64 Assembler (05-assembler.md §4.6).
// Parses AT&T instructions and operands (`%reg`, `$expr`, `*operand`, `seg:disp(base, index, scale)`),
// encodes via `X86TableEncoder`, and emits relaxable branches and ELF64 relocations.
//
// Layering rule: Asm/ uses Source/, Lex/, Encode/, and Object/. It MUST NOT reference Codegen/.

import Foundation

/// Caseless enum holding static AT&T x86-64 instruction parsing and encoding entry points (`05-assembler.md` §4.3, §4.6).
public enum X86Asm {

    private static let encoder = X86TableEncoder()

    private struct PendingSymDiff {
        let plusSymbol: String
        let minusSymbol: String
        let addend: Int64
    }

    /// Condition code nibble (`0x0..0xF`) for `jcc` mnemonics.
    private static let jccCondMap: [String: UInt8] = [
        "jo":   0x0,
        "jno":  0x1,
        "jb":   0x2, "jnae": 0x2, "jc":   0x2,
        "jae":  0x3, "jnb":  0x3, "jnc":  0x3,
        "je":   0x4, "jz":   0x4,
        "jne":  0x5, "jnz":  0x5,
        "jbe":  0x6, "jna":  0x6,
        "ja":   0x7, "jnbe": 0x7,
        "js":   0x8,
        "jns":  0x9,
        "jp":   0xA, "jpe":  0xA,
        "jnp":  0xB, "jpo":  0xB,
        "jl":   0xC, "jnge": 0xC,
        "jge":  0xD, "jnl":  0xD,
        "jle":  0xE, "jng":  0xE,
        "jg":   0xF, "jnle": 0xF,
    ]

    internal static func parseInstruction(
        mnemonic rawMnemonic: String,
        args rawArgs: String,
        loc: AsmLoc,
        session: AsmSession,
        diagnostics: inout DiagnosticBag
    ) {
        var mnem = rawMnemonic.lowercased()
        var args = rawArgs.trimmingCharacters(in: .whitespaces)
        var lockPrefix = false
        var repPrefix: X86RepPrefix = .none

        // Handle inline prefixes (`lock`, `rep`, `repe`, `repz`, `repne`, `repnz`)
        while true {
            if mnem == "lock" {
                lockPrefix = true
                let (nextMnem, nextArgs) = splitFirstWord(args)
                mnem = nextMnem.lowercased()
                args = nextArgs
            } else if mnem == "rep" || mnem == "repe" || mnem == "repz" {
                repPrefix = .rep
                let (nextMnem, nextArgs) = splitFirstWord(args)
                mnem = nextMnem.lowercased()
                args = nextArgs
            } else if mnem == "repne" || mnem == "repnz" {
                repPrefix = .repne
                let (nextMnem, nextArgs) = splitFirstWord(args)
                mnem = nextMnem.lowercased()
                args = nextArgs
            } else {
                break
            }
        }

        guard !mnem.isEmpty else { return }

        // 1. Check for relaxable direct branch (`jmp label` or `jcc label`)
        let rawOperands = splitCommaSeparated(args)
        if (mnem == "jmp" || mnem == "jmpq"),
           rawOperands.count == 1,
           !rawOperands[0].hasPrefix("*"),
           !rawOperands[0].hasPrefix("%") {
            if let exprVal = AsmExprEvaluator.evaluate(rawOperands[0], constants: session.constants) {
                switch exprVal {
                case .symbolOffset(let sym, let addend, _):
                    session.currentSection.emitRelaxable(
                        .x86Branch(isConditional: false, condCode: 0, targetSymbol: sym, addend: addend),
                        loc: loc
                    )
                    return
                case .constant(let relVal):
                    let inst = X86Instruction(mnemonic: "jmp", operands: [.relTarget(relVal)], codeMode: session.x86CodeMode)
                    if let enc = try? encoder.encode(inst) {
                        session.currentSection.emitBytes(enc.bytes, loc: loc)
                        return
                    }
                case .symbolDiff:
                    break
                }
            }
        }

        if let cc = jccCondMap[mnem],
           rawOperands.count == 1,
           !rawOperands[0].hasPrefix("*"),
           !rawOperands[0].hasPrefix("%") {
            if let exprVal = AsmExprEvaluator.evaluate(rawOperands[0], constants: session.constants) {
                switch exprVal {
                case .symbolOffset(let sym, let addend, _):
                    session.currentSection.emitRelaxable(
                        .x86Branch(isConditional: true, condCode: cc, targetSymbol: sym, addend: addend),
                        loc: loc
                    )
                    return
                case .constant(let relVal):
                    let inst = X86Instruction(mnemonic: mnem, operands: [.relTarget(relVal)], codeMode: session.x86CodeMode)
                    if let enc = try? encoder.encode(inst) {
                        session.currentSection.emitBytes(enc.bytes, loc: loc)
                        return
                    }
                case .symbolDiff:
                    break
                }
            }
        }

        // 2. Direct `call sym` / `callq sym`
        if (mnem == "call" || mnem == "callq"),
           rawOperands.count == 1,
           !rawOperands[0].hasPrefix("*"),
           !rawOperands[0].hasPrefix("%") {
            if let exprVal = AsmExprEvaluator.evaluate(rawOperands[0], constants: session.constants) {
                switch exprVal {
                case .symbolOffset(let sym, let addend, let modifier):
                    var fixup = AsmInstFixup(
                        offsetInInst: 1,
                        kind: .x86_64_plt32,
                        symbol: sym,
                        addend: addend - 4,
                        resolveIfSameSection: true
                    )
                    fixup.keepsSymbol = modifier == .x86PLT
                    session.currentSection.emitBytes([0xE8, 0, 0, 0, 0], fixups: [fixup], loc: loc)
                    return
                case .constant(let relVal):
                    let inst = X86Instruction(mnemonic: "call", operands: [.relTarget(relVal)], codeMode: session.x86CodeMode)
                    if let enc = try? encoder.encode(inst) {
                        session.currentSection.emitBytes(enc.bytes, loc: loc)
                        return
                    }
                case .symbolDiff:
                    break
                }
            }
        }

        // 3. Parse general AT&T operands
        var symDiffByDummyName: [String: PendingSymDiff] = [:]
        var symModifiers: [String: AsmRelocModifier] = [:]
        var parsedOperands: [X86Operand] = []
        parsedOperands.reserveCapacity(rawOperands.count)

        for (opIdx, rawOp) in rawOperands.enumerated() {
            guard let op = parseOperand(
                rawOp,
                opIdx: opIdx,
                constants: session.constants,
                symDiffByDummyName: &symDiffByDummyName,
                symModifiers: &symModifiers
            ) else {
                diagnostics.report(
                    .asmInvalidInstruction,
                    at: loc,
                    args: ["\(rawMnemonic) \(rawArgs)".trimmingCharacters(in: .whitespaces)]
                )
                return
            }
            parsedOperands.append(op)
        }

        // Normalize `movzx` / `movsx` when written without size suffixes (e.g. `movzx %ax, %ebx` in `smp.S`)
        if mnem == "movzx" && parsedOperands.count == 2,
           case .reg(let srcR) = parsedOperands[0],
           case .reg(let dstR) = parsedOperands[1] {
            let sChar = srcR.operandSize.attSuffix
            let dChar = dstR.operandSize.attSuffix
            if !sChar.isEmpty && !dChar.isEmpty {
                mnem = "movz\(sChar)\(dChar)"
            }
        } else if mnem == "movsx" && parsedOperands.count == 2,
                  case .reg(let srcR) = parsedOperands[0],
                  case .reg(let dstR) = parsedOperands[1] {
            let sChar = srcR.operandSize.attSuffix
            let dChar = dstR.operandSize.attSuffix
            if !sChar.isEmpty && !dChar.isEmpty {
                mnem = "movs\(sChar)\(dChar)"
            }
        }

        let inst = X86Instruction(
            mnemonic: mnem,
            operands: parsedOperands,
            lockPrefix: lockPrefix,
            repPrefix: repPrefix,
            codeMode: session.x86CodeMode
        )

        do {
            let encoded = try encoder.encode(inst)
            var fixups: [AsmInstFixup] = []
            for rel in encoded.relocations {
                if let diff = symDiffByDummyName[rel.symbol] {
                    let width: Int = (rel.kind == .abs16) ? 2 : (rel.kind == .abs64 ? 8 : 4)
                    fixups.append(
                        AsmInstFixup(
                            offsetInInst: rel.offset,
                            kind: .x86_64_32,
                            symbol: diff.plusSymbol,
                            minusSymbol: diff.minusSymbol,
                            addend: diff.addend,
                            width: width,
                            resolveIfSameSection: false
                        )
                    )
                } else {
                    let mod = symModifiers[rel.symbol] ?? .none
                    var mappedKind = mapRelocKind(rel.kind, modifier: mod)
                    if mappedKind == .x86_64_gotpcrel, let relaxable = relaxableGOTLoadKind(mnemonic: mnem, operands: parsedOperands, bytes: encoded.bytes) {
                        mappedKind = relaxable
                    }
                    let resolveSameSec = (mappedKind == .x86_64_pc32)
                    var fixup = AsmInstFixup(
                        offsetInInst: rel.offset,
                        kind: mappedKind,
                        symbol: rel.symbol,
                        addend: rel.addend,
                        resolveIfSameSection: resolveSameSec
                    )
                    fixup.keepsSymbol = mod == .x86PLT
                    fixups.append(fixup)
                }
            }
            session.currentSection.emitBytes(encoded.bytes, fixups: fixups, loc: loc)
        } catch {
            diagnostics.report(
                .asmInvalidInstruction,
                at: loc,
                args: ["\(rawMnemonic) \(rawArgs)".trimmingCharacters(in: .whitespaces)]
            )
        }
    }

    /// LLVM MC's linker-relaxable GOT references (`X86MCCodeEmitter::emitMemModRMByte`, `-mrelax-relocations`, on by
    /// default): `sym@GOTPCREL(%rip)` as the memory source of a 32/64-bit `mov` load, `lea`, `test` or ALU operation
    /// (`adc add and cmp or sbb sub xor`), or as the target of an indirect `call`/`jmp`, is `R_X86_64_REX_GOTPCRELX`
    /// when the instruction has a REX prefix and `R_X86_64_GOTPCRELX` otherwise. nil: plain `R_X86_64_GOTPCREL`.
    private static func relaxableGOTLoadKind(mnemonic: String, operands: [X86Operand], bytes: [UInt8]) -> RelocKind? {
        func isGPR32or64(_ op: X86Operand) -> Bool {
            guard case .reg(let r) = op else { return false }
            return r.operandSize == .dword || r.operandSize == .qword
        }
        func isMem(_ op: X86Operand) -> Bool {
            if case .mem = op { return true }
            return false
        }
        let base = ["l", "q"].contains(mnemonic.suffix(1)) && mnemonic.count > 2 ? String(mnemonic.dropLast()) : mnemonic
        let relaxable: Bool
        switch base {
        case "mov", "lea", "adc", "add", "and", "cmp", "or", "sbb", "sub", "xor":
            relaxable = operands.count == 2 && isMem(operands[0]) && isGPR32or64(operands[1])
        case "test":
            relaxable = operands.count == 2 && isGPR32or64(operands[0]) && isMem(operands[1])
        case "call", "jmp":
            if operands.count == 1, case .indirectMem = operands[0] { relaxable = true } else { relaxable = false }
        default:
            relaxable = false
        }
        guard relaxable else { return nil }
        let legacyPrefixes: Set<UInt8> = [0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65]
        let rex = bytes.first { !legacyPrefixes.contains($0) }.map { $0 & 0xF0 == 0x40 } ?? false
        return rex ? .x86_64_rexGotpcrelx : .x86_64_gotpcrelx
    }

    private static func mapRelocKind(_ kind: X86RelocKind, modifier: AsmRelocModifier) -> RelocKind {
        switch modifier {
        case .x86PLT:      return .x86_64_plt32
        case .x86GOTPCREL: return .x86_64_gotpcrel
        case .x86TPOFF:    return .x86_64_tpoff32
        case .x86GOTTPOFF: return .x86_64_gottpoff
        default:
            switch kind {
            case .pc32:     return .x86_64_pc32
            case .plt32:    return .x86_64_plt32
            case .gotpcrel: return .x86_64_gotpcrel
            case .abs64:    return .x86_64_64
            case .abs32s:   return .x86_64_32s
            case .abs32:    return .x86_64_32
            case .abs16:    return .x86_64_16
            case .tpoff32:  return .x86_64_tpoff32
            }
        }
    }

    private static func parseOperand(
        _ raw: String,
        opIdx: Int,
        constants: [String: Int64],
        symDiffByDummyName: inout [String: PendingSymDiff],
        symModifiers: inout [String: AsmRelocModifier]
    ) -> X86Operand? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // 1. Indirect operand (`*%rax`, `*0x94(%rbx)`, `*T_OFF(t_far32)`)
        if s.hasPrefix("*") {
            let inner = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("%"), !inner.contains(":"), let reg = X86Reg.parse(inner) {
                return .indirectReg(reg)
            }
            guard let mem = parseMemory(
                inner,
                opIdx: opIdx,
                constants: constants,
                symDiffByDummyName: &symDiffByDummyName,
                symModifiers: &symModifiers
            ) else {
                return nil
            }
            return .indirectMem(mem)
        }

        // 2. Register operand (`%rax`, `%cr3`, `%xmm0`, etc.) — but NOT `%fs:0` segment-prefixed memory!
        if s.hasPrefix("%") && !s.contains(":") {
            guard let reg = X86Reg.parse(s) else { return nil }
            return .reg(reg)
        }

        // 3. Immediate operand (`$42`, `$(1 << 5)`, `$sym`, `$(sym2 - sym1)`)
        if s.hasPrefix("$") {
            let exprStr = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let val = AsmExprEvaluator.evaluate(exprStr, constants: constants) else {
                return nil
            }
            switch val {
            case .constant(let c):
                return .imm(c)
            case .symbolOffset(let sym, let addend, let mod):
                if mod != .none { symModifiers[sym] = mod }
                return .imm(addend, symbol: sym)
            case .symbolDiff(let plusSym, let minusSym, let addend):
                let dummy = "__symdiff_imm_\(opIdx)"
                symDiffByDummyName[dummy] = PendingSymDiff(plusSymbol: plusSym, minusSymbol: minusSym, addend: addend)
                return .imm(0, symbol: dummy)
            }
        }

        // 4. Memory operand (`disp(base, index, scale)`, `%fs:0`, `sym(%rip)`, `T_OFF(t_gdt_pointer)`)
        guard let mem = parseMemory(
            s,
            opIdx: opIdx,
            constants: constants,
            symDiffByDummyName: &symDiffByDummyName,
            symModifiers: &symModifiers
        ) else {
            return nil
        }
        return .mem(mem)
    }

    private static func parseMemory(
        _ raw: String,
        opIdx: Int,
        constants: [String: Int64],
        symDiffByDummyName: inout [String: PendingSymDiff],
        symModifiers: inout [String: AsmRelocModifier]
    ) -> X86Mem? {
        var str = raw.trimmingCharacters(in: .whitespaces)
        var segmentByte: UInt8? = nil

        // Check for leading segment override `%fs:`, `%gs:`, `%cs:`, `%ds:`, `%es:`, `%ss:`
        if str.hasPrefix("%"), let colonIdx = str.firstIndex(of: ":") {
            let segName = String(str[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            if let segReg = X86Reg.parse(segName), let pByte = segReg.segmentPrefixByte {
                segmentByte = pByte
                str = String(str[str.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        var dispExprStr = str
        var baseReg: X86Reg? = nil
        var indexReg: X86Reg? = nil
        var scaleVal: UInt8 = 1

        // Check if `str` ends with `(base, index, scale)` where the final `(...)` contains `%` or `,`
        if str.hasSuffix(")") {
            let chars = Array(str)
            var depth = 0
            var openParenIdx: Int? = nil
            for i in stride(from: chars.count - 1, through: 0, by: -1) {
                if chars[i] == ")" {
                    depth += 1
                } else if chars[i] == "(" {
                    depth -= 1
                    if depth == 0 {
                        openParenIdx = i
                        break
                    }
                }
            }
            if let openIdx = openParenIdx {
                let inside = String(chars[(openIdx + 1)..<(chars.count - 1)]).trimmingCharacters(in: .whitespaces)
                if inside.contains("%") || inside.contains(",") {
                    dispExprStr = String(chars[0..<openIdx]).trimmingCharacters(in: .whitespaces)
                    let parts = inside.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 1 && !parts[0].isEmpty {
                        guard let b = X86Reg.parse(parts[0]) else { return nil }
                        baseReg = b
                    }
                    if parts.count >= 2 && !parts[1].isEmpty {
                        guard let idx = X86Reg.parse(parts[1]) else { return nil }
                        indexReg = idx
                    }
                    if parts.count >= 3 && !parts[2].isEmpty {
                        guard let sc = UInt8(parts[2]), (sc == 1 || sc == 2 || sc == 4 || sc == 8) else { return nil }
                        scaleVal = sc
                    }
                }
            }
        }

        var dispVal: Int64 = 0
        var symName: String? = nil
        var forceDisp32 = false

        if !dispExprStr.isEmpty {
            guard let evaluated = AsmExprEvaluator.evaluate(dispExprStr, constants: constants) else {
                return nil
            }
            switch evaluated {
            case .constant(let c):
                dispVal = c
            case .symbolOffset(let sym, let addend, let mod):
                symName = sym
                dispVal = addend
                if mod != .none {
                    symModifiers[sym] = mod
                }
            case .symbolDiff(let plusSym, let minusSym, let addend):
                let dummy = "__symdiff_disp_\(opIdx)"
                symDiffByDummyName[dummy] = PendingSymDiff(plusSymbol: plusSym, minusSymbol: minusSym, addend: addend)
                symName = dummy
                dispVal = 0
                forceDisp32 = (baseReg != nil || indexReg != nil)
            }
        }

        return X86Mem(
            segment: segmentByte,
            base: baseReg,
            index: indexReg,
            scale: scaleVal,
            disp: dispVal,
            symbol: symName,
            forceDisp32: forceDisp32
        )
    }
}
