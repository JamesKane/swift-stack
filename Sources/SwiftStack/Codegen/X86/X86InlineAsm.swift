// Sources/SwiftStack/Codegen/X86/X86InlineAsm.swift
//
// GNU inline `asm` statements (GCC's "Extended Asm"): each operand is bound to a register, memory or an immediate by
// its constraint, and after register allocation the template is written out with each operand reference replaced.
//
// Constraints: the first alternative of each is used. Registers: `r`, `q`, `Q`, `R`, `l` (any GPR), `a` `b` `c` `d`
// `S` `D` (one GPR), `A` (`rax`), `x` `v` (an XMM register), and `{reg}` (a `register` variable's register). Memory:
// `m` `o` `V` `<` `>`. Immediates: `i` `n` `I`-`O` `e` `Z` `s`. Either: `g` `X` (an immediate if constant, else a
// register). `0`-`9` and `[name]` tie an input to an output. `=@cc<cond>` outputs a condition. Modifiers in the
// template: `b` `h` `w` `k` `q` (register sizes), `x` (XMM name), `c` `P` (a bare constant), `n` (negated), `a`
// (an address), `l` (a label), `z` (the size suffix), `V` (a register's bare name); `%=` and `%%`.

import Foundation

struct X86InlineAsm {
    let isel: X86FunctionISel

    enum Binding {
        case register(LIRRegClass)
        case fixed(PhysReg)
        case memory
        case immediate
        /// A register (any, or the one given), or an immediate when the value is a constant (`g`, `X`, `Nd`...).
        case registerOrImmediate(PhysReg?)
        /// `=@cc<cond>`.
        case flag(X86Cond)
        case tied(Int)
        case unsupported(String)
    }

    struct Parsed {
        var binding: Binding
        var isOutput = false
        var readWrite = false
        var earlyClobber = false
    }

    static func register(named raw: String) -> PhysReg? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        guard let r = X86Reg.parse("%" + name) ?? X86Reg.parse(name) else { return nil }
        switch r.regClass {
        case .xmm, .ymm: return PhysReg.xmm(Int(r.hwEncoding))
        default: return r.isGPR ? PhysReg.gpr(r.hwEncoding) : nil
        }
    }

    func parse(_ text: String, outputs: [String?], isOutput: Bool) -> Parsed {
        var p = Parsed(binding: .unsupported(text))
        var c = Substring(text)
        while let ch = c.first, "=+&%*#!?".contains(ch) {
            if ch == "=" { p.isOutput = true }
            if ch == "+" { p.isOutput = true; p.readWrite = true }
            if ch == "&" { p.earlyClobber = true }
            c = c.dropFirst()
        }
        let alternative = c.split(separator: ",", omittingEmptySubsequences: false).first ?? ""
        if alternative.hasPrefix("@cc") {
            let cond = String(alternative.dropFirst(3))
            let all: [(String, X86Cond)] = [("o", .o), ("no", .no), ("b", .b), ("c", .b), ("nae", .b), ("ae", .ae), ("nb", .ae), ("nc", .ae),
                                            ("e", .e), ("z", .e), ("ne", .ne), ("nz", .ne), ("be", .be), ("na", .be), ("a", .a),
                                            ("nbe", .a), ("s", .s), ("ns", .ns), ("p", .p), ("np", .np), ("l", .l), ("nge", .l),
                                            ("ge", .ge), ("nl", .ge), ("le", .le), ("ng", .le), ("g", .g), ("nle", .g)]
            if let m = all.first(where: { $0.0 == cond }) { p.binding = .flag(m.1) }
            return p
        }
        if alternative.hasPrefix("{"), let close = alternative.firstIndex(of: "}") {
            let name = String(alternative[alternative.index(after: alternative.startIndex)..<close])
            if let r = Self.register(named: name) { p.binding = .fixed(r) }
            return p
        }
        if alternative.hasPrefix("["), let close = alternative.firstIndex(of: "]") {
            let name = String(alternative[alternative.index(after: alternative.startIndex)..<close])
            if let k = outputs.firstIndex(where: { $0 == name }) { p.binding = .tied(k) }
            return p
        }
        if let first = alternative.first, first.isNumber, let k = Int(alternative.prefix { $0.isNumber }) {
            p.binding = .tied(k)
            return p
        }
        var reg = false, mem = false, imm = false
        var fixed: PhysReg?
        var xmm = false
        for ch in alternative {
            switch ch {
            case "r", "q", "Q", "R", "l", "U": reg = true
            case "a", "A": fixed = .rax
            case "b": fixed = .rbx
            case "c": fixed = .rcx
            case "d": fixed = .rdx
            case "S": fixed = .rsi
            case "D": fixed = .rdi
            case "x", "v": xmm = true
            case "m", "o", "V", "<", ">", "p": mem = true
            case "i", "n", "I", "J", "K", "L", "M", "N", "O", "e", "Z", "s", "E", "F": imm = true
            case "g", "X": reg = true; imm = true; mem = true
            default: break
            }
        }
        if let fixed {
            p.binding = imm && !isOutput ? .registerOrImmediate(fixed) : .fixed(fixed)
            return p
        }
        if xmm { p.binding = .register(.xmm) } else if reg && imm && !isOutput { p.binding = .registerOrImmediate(nil) } else if reg {
            p.binding = .register(.gpr)
        } else if mem { p.binding = .memory } else if imm { p.binding = isOutput ? .unsupported(text) : .immediate }
        return p
    }

    func lower(_ i: InstId) {
        let items = isel.list(i)
        guard let asm = AIRAsm(items) else {
            isel.report("malformed asm statement")
            return
        }
        let strings = isel.ctx.module.strings
        let types = isel.ctx.module.typePool
        var statement = LIRAsmStatement(template: strings[Int(asm.template)])
        let operands = asm.outputs + asm.inputs
        let names: [String?] = operands.map { $0.name == AIRAsm.noName ? nil : strings[Int($0.name)] }
        let outputNames = Array(names.prefix(asm.outputs.count))
        var lir: [LIROperand] = []
        var after: [() -> Void] = []
        var bound: [PhysReg] = []
        /// The register each output was given (to tie inputs to).
        var outputReg: [LIRReg?] = Array(repeating: nil, count: asm.outputs.count)
        var outputLIRIndex: [Int] = Array(repeating: -1, count: asm.outputs.count)

        func size(of t: TypeId) -> Int { max(1, min(types.size(of: t), 16)) }
        func isFloat(_ t: TypeId) -> Bool { types.isFloating(type: t) }

        /// Loads the value at `address` (of C type `t`) into register `r` of the operand's class.
        func loadValue(_ address: ValueId, _ t: TypeId, into r: LIRReg) {
            let a = isel.addressOf(address)
            let n = size(of: t)
            if isel.lir.regClass(of: r) == .xmm {
                isel.emit(n == 4 ? .movss : n == 8 ? .movsd : .movups, n, .def(r, 16), a.operand(size: n))
            } else {
                let v = isel.loadBytes(a, min(n, 8))
                isel.emit(.copy, 8, .def(r, 8), .use(v, 8))
            }
        }

        func storeValue(_ r: LIRReg, _ address: ValueId, _ t: TypeId) {
            let a = isel.addressOf(address)
            let n = size(of: t)
            if isel.lir.regClass(of: r) == .xmm {
                isel.emit(n == 4 ? .movss : n == 8 ? .movsd : .movups, n, a.operand(size: n), .use(r, 16))
            } else {
                isel.storeBytes(r, a, min(n, 8))
            }
        }

        /// The value of an input in a new register of class `cls`.
        func inputRegister(_ v: ValueId, _ t: TypeId, _ cls: LIRRegClass) -> LIRReg {
            if cls == .xmm {
                if case .reg(let r) = isel.value(v), isel.lir.regClass(of: r) == .xmm { return r }
                let r = isel.newXMM()
                isel.emit(.movq, 8, .def(r, 16), .use(isel.gpr(v), 8))
                return r
            }
            let at = isel.ty(v)
            if at.isFloat {
                let r = isel.newGPR()
                isel.emit(at.width == 32 ? .movd : .movq, at.width == 32 ? 4 : 8, .def(r, at.width == 32 ? 4 : 8), .use(isel.xmm(v), 16))
                return r
            }
            return isel.gpr(v)
        }

        // Outputs
        for (k, o) in asm.outputs.enumerated() {
            let parsed = parse(strings[Int(o.constraint)], outputs: outputNames, isOutput: true)
            let n = size(of: o.type)
            statement.operandSize.append(n)
            switch parsed.binding {
            case .register(let cls):
                let r = cls == .xmm ? isel.newXMM() : isel.newGPR()
                if parsed.readWrite { loadValue(o.value, o.type, into: r) }
                var flags: LIROperand.Flags = parsed.readWrite ? [.use, .def] : .def
                if parsed.earlyClobber { flags.insert(.earlyClobber) }
                outputLIRIndex[k] = lir.count
                statement.operandIndex.append(lir.count + 1)
                lir.append(LIROperand(kind: .reg, flags: flags, size: cls == .xmm ? 16 : min(n, 8), reg: r))
                outputReg[k] = r
                after.append { storeValue(r, o.value, o.type) }
            case .fixed(let p):
                bound.append(p)
                let preg = LIRReg.physical(p)
                if parsed.readWrite {
                    let r = p.isXMM ? isel.newXMM() : isel.newGPR()
                    loadValue(o.value, o.type, into: r)
                    isel.emit(.copy, p.isXMM ? 16 : 8, .def(preg, p.isXMM ? 16 : 8), .use(r, p.isXMM ? 16 : 8))
                }
                outputLIRIndex[k] = lir.count
                statement.operandIndex.append(lir.count + 1)
                var flags: LIROperand.Flags = parsed.readWrite ? [.use, .def] : .def
                if parsed.earlyClobber { flags.insert(.earlyClobber) }
                lir.append(LIROperand(kind: .reg, flags: flags, size: p.isXMM ? 16 : min(n, 8), reg: preg))
                outputReg[k] = preg
                after.append {
                    let r = p.isXMM ? isel.newXMM() : isel.newGPR()
                    isel.copy(r, preg, p.isXMM ? 16 : 8)
                    storeValue(r, o.value, o.type)
                }
            case .memory:
                statement.operandIndex.append(lir.count + 1)
                lir.append(isel.addressOf(o.value).operand(size: n))
            case .flag(let cc):
                statement.operandIndex.append(-1)
                after.append {
                    let r = isel.newGPR(), z = isel.newGPR()
                    isel.emit(.setcc, 1, cond: cc, .def(r, 1))
                    isel.emit(.movzb, 4, .def(z, 4), .use(r, 1))
                    isel.storeBytes(z, isel.addressOf(o.value), min(n, 8))
                }
            default:
                isel.report("asm output constraint '\(strings[Int(o.constraint)])'")
                statement.operandIndex.append(-1)
            }
        }

        // Inputs
        for o in asm.inputs {
            let constraint = strings[Int(o.constraint)]
            let parsed = parse(constraint, outputs: outputNames, isOutput: false)
            let n = size(of: o.type)
            statement.operandSize.append(n)
            var binding = parsed.binding
            if case .registerOrImmediate(let fixed) = binding {
                if o.value.valueTag == .constant, isel.constantInt(o.value) != nil {
                    binding = .immediate
                } else if o.value.valueTag == .global, !SemAsm.isMemoryOnly(constraint) {
                    binding = .immediate
                } else {
                    binding = fixed.map { .fixed($0) } ?? .register(.gpr)
                }
            }
            switch binding {
            case .tied(let k):
                guard k < asm.outputs.count, let out = outputReg[k] else {
                    isel.report("asm input tied to operand \(k)")
                    statement.operandIndex.append(-1)
                    continue
                }
                let cls = isel.lir.regClass(of: out)
                let value = inputRegister(o.value, o.type, cls)
                isel.emit(.copy, cls == .xmm ? 16 : 8, .def(out, cls == .xmm ? 16 : 8), .use(value, cls == .xmm ? 16 : 8))
                // The output is read as well as written
                lir[outputLIRIndex[k]].flags.insert(.use)
                statement.operandIndex.append(outputLIRIndex[k] + 1)
            case .register(let cls):
                let r = inputRegister(o.value, o.type, cls)
                statement.operandIndex.append(lir.count + 1)
                lir.append(.use(r, cls == .xmm ? 16 : min(n, 8)))
            case .fixed(let p):
                bound.append(p)
                let r = inputRegister(o.value, o.type, p.isXMM ? .xmm : .gpr)
                isel.emit(.copy, p.isXMM ? 16 : 8, .def(.physical(p), p.isXMM ? 16 : 8), .use(r, p.isXMM ? 16 : 8))
                statement.operandIndex.append(lir.count + 1)
                lir.append(.use(.physical(p), p.isXMM ? 16 : min(n, 8)))
            case .memory:
                let a: LIRAddress = SemAsm.isMemoryOnly(constraint) ? isel.addressOf(o.value) : {
                    // A value for a memory operand: in a temporary
                    let s = isel.scratchSlot()
                    let at = isel.ty(o.value)
                    if at.isFloat { isel.emit(.movsd, 8, LIRAddress.slot(s).operand(size: 8), .use(isel.xmm(o.value), 16)) } else {
                        isel.emit(.mov, 8, LIRAddress.slot(s).operand(size: 8), .use(isel.gpr(o.value), 8))
                    }
                    return LIRAddress.slot(s)
                }()
                statement.operandIndex.append(lir.count + 1)
                lir.append(a.operand(size: n))
            case .immediate:
                statement.operandIndex.append(lir.count + 1)
                if o.value.valueTag == .global {
                    var imm = LIROperand.imm(0)
                    imm.symbol = isel.ctx.symbolOf[Int(o.value.index)]
                    lir.append(imm)
                } else if let c = isel.constantInt(o.value) {
                    lir.append(.imm(c))
                } else {
                    isel.report("asm input '\(constraint)' needs a constant")
                    lir.append(.imm(0))
                }
            default:
                isel.report("asm input constraint '\(constraint)'")
                statement.operandIndex.append(-1)
            }
        }
        statement.operandName = names

        // Clobbered registers (other than those bound to operands)
        for c in asm.clobbers {
            let name = strings[Int(c)]
            if name == "memory" || name == "cc" || name == "dirflag" || name == "fpsr" || name == "flags" { continue }
            guard let r = Self.register(named: name) else { continue }
            if r == .rsp || r == .rbp || bound.contains(r) { continue }
            lir.append(.implicitDef(r))
        }

        // `asm goto` labels
        if op(i) == .asmGoto {
            for b in asm.labels {
                statement.labels.append(isel.blockOf[Int(b.rawIndex)])
                statement.labelNames.append(isel.box.function.blockNames[b])
            }
        }
        statement.block = isel.cur
        let index = isel.lir.asmStatements.count
        isel.lir.asmStatements.append(statement)
        var imm = LIROperand.imm(Int64(index))
        imm.flags = .implicit
        isel.emit(.inlineAsm, 0, operands: [imm] + lir)
        for store in after { store() }

        if op(i) == .asmGoto {
            isel.materializePhiInputs()
            let targets = statement.labels
            // The first label is the fallthrough
            for t in targets.dropFirst() {
                isel.lir.blocks[t].addressTaken = true
                if !isel.lir.blocks[isel.cur].successors.contains(t) { isel.lir.blocks[isel.cur].successors.append(t) }
            }
            if let fall = targets.first { isel.jump(fall) }
        }
    }

    func op(_ i: InstId) -> AIROpcode { isel.op(i) }

    // MARK: - Printing

    /// The template of `asm` instruction `inst` with its operands (after allocation) substituted.
    static func text(_ f: LIRFunction, _ inst: LIRInst, function: Int, printer: X86AsmPrinter) -> String {
        let all = Array(f.operands[inst.operandRange])
        let index = Int(all[0].value)
        let s = f.asmStatements[index]
        let t = Array(s.template)
        var out = ""
        var k = 0
        let operandCount = s.operandIndex.count

        func operandNumber(_ from: inout Int) -> Int? {
            if from < t.count, t[from] == "[" {
                guard let close = t[from...].firstIndex(of: "]") else { return nil }
                let name = String(t[(from + 1)..<close])
                from = close + 1
                if let n = s.operandName.firstIndex(where: { $0 == name }) { return n }
                if let l = s.labelNames.firstIndex(where: { $0 == name }) { return operandCount + l }
                return nil
            }
            var digits = ""
            while from < t.count, t[from].isNumber {
                digits.append(t[from])
                from += 1
            }
            return Int(digits)
        }

        while k < t.count {
            let ch = t[k]
            if ch == "{" {
                // Dialect alternatives {att|intel}: the first
                var j = k + 1
                var depth = 0
                var text = ""
                while j < t.count && !(t[j] == "|" && depth == 0) && !(t[j] == "}" && depth == 0) {
                    text.append(t[j])
                    j += 1
                }
                while j < t.count && t[j] != "}" { j += 1 }
                depth = 0
                out += text
                k = j + 1
                continue
            }
            if ch == "|" || ch == "}" {
                k += 1
                continue
            }
            guard ch == "%", k + 1 < t.count else {
                out.append(ch)
                k += 1
                continue
            }
            k += 1
            if t[k] == "%" { out += "%"; k += 1; continue }
            if t[k] == "=" { out += "\(function * 10000 + index)"; k += 1; continue }
            var modifier: Character?
            if t[k].isLetter, k + 1 < t.count, t[k + 1].isNumber || t[k + 1] == "[" {
                modifier = t[k]
                k += 1
            }
            guard let n = operandNumber(&k) else {
                out += "%"
                if let modifier { out.append(modifier) }
                continue
            }
            if n >= operandCount {
                let l = n - operandCount
                if l < s.labels.count { out += X86AsmPrinter.blockLabel(function: function, block: s.labels[l]) }
                continue
            }
            let at = s.operandIndex[n]
            guard at >= 0, at < all.count else { continue }
            out += operandText(all[at], size: s.operandSize[n], modifier: modifier, function: function, printer: printer)
        }
        return out
    }

    static func operandText(_ o: LIROperand, size: Int, modifier: Character?, function: Int, printer: X86AsmPrinter) -> String {
        switch o.kind {
        case .reg:
            let r = o.reg.physical
            if r.isXMM { return modifier == "V" ? r.name(size: 16) : "%" + r.name(size: 16) }
            var sz = min(max(size, 1), 8)
            if sz == 3 { sz = 4 }
            if sz > 4 && sz < 8 { sz = 8 }
            switch modifier {
            case "b": sz = 1
            case "w": sz = 2
            case "k": sz = 4
            case "q": sz = 8
            case "h":
                let high = ["ah", "ch", "dh", "bh"]
                return r.hw < 4 ? "%" + high[Int(r.hw)] : "%" + r.name(size: 1)
            case "z": return sz == 1 ? "b" : sz == 2 ? "w" : sz == 4 ? "l" : "q"
            case "V": return r.name(size: sz)
            default: break
            }
            return "%" + r.name(size: sz)
        case .imm:
            let value = modifier == "n" ? -o.value : o.value
            let symbol = o.symbol != 0 ? printer.symbolName(o.symbol) : nil
            let text = symbol.map { value == 0 ? $0 : "\($0)+\(value)" } ?? "\(value)"
            if modifier == "z" { return size == 1 ? "b" : size == 2 ? "w" : size == 4 ? "l" : "q" }
            return modifier == "c" || modifier == "P" || modifier == "n" ? text : "$" + text
        case .mem:
            if modifier == "z" { return size == 1 ? "b" : size == 2 ? "w" : size == 4 ? "l" : "q" }
            guard case .mem(let m)? = printer.x86(o, function) else { return "" }
            return m.attString
        default:
            return ""
        }
    }
}
