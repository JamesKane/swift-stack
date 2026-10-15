// Sources/SwiftStack/AIR/AIRDump.swift
//
// `--dump=air` (15-driver-and-diagnostics.md): a deterministic text form of an AIR module, used by the golden
// tests. Each function lists its stack slots and its blocks (`bbN`, with predecessors and C label names); values
// print as `%N` (instructions), `%aN` (parameters), `@name` (symbols) and literals (constants). Objects follow with
// their data images, then the symbols the module refers to.

import Foundation

extension AIRModule {
    public func dumpText() -> String {
        var out = ""
        for box in functions {
            out += dumpFunction(box.function)
        }
        for s in symbols where s.kind == .object && s.linkage != .undefined {
            var line = "object @\(s.name): \(typePool.name(of: s.cType)) size \(s.size) align \(s.alignment)"
            if s.linkage == .internal { line += " internal" }
            if s.isThreadLocal { line += " thread_local" }
            if s.isConstant { line += " constant" }
            if s.isTentative { line += " tentative" }
            out += line + "\n"
            if let image = s.image {
                if !image.isZero || image.bytes.count <= 16 {
                    out += "  bytes [" + image.bytes.map { String(format: "%02x", $0) }.joined(separator: " ") + "]\n"
                } else {
                    out += "  zero\n"
                }
                for r in image.relocations {
                    let target: String
                    switch r.target {
                    case .symbol(let t): target = "@" + symbols[t].name
                    case .block(let f, let b): target = "@\(functions[f].function.name) bb\(b.rawIndex)"
                    }
                    out += "  reloc +\(r.offset) \(r.size) bytes -> \(target)\(r.addend >= 0 ? "+" : "")\(r.addend)\n"
                }
            }
        }
        for s in symbols where s.linkage == .undefined {
            out += "declare @\(s.name): \(typePool.name(of: s.cType))\(s.isThreadLocal ? " thread_local" : "")\n"
        }
        for (i, text) in moduleAsm.enumerated() {
            out += "module asm \(i): \"\(escape(text))\"\n"
        }
        return out
    }

    func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 || u.value > 0x7E { out += String(format: "\\x%02x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    func dumpFunction(_ f: borrowing AIRFunction) -> String {
        let s = symbols[f.symbol]
        let params = f.paramTypes.enumerated().map { "\(f.paramIsAggregate[$0.offset] ? "byval " : "")\($0.element) %a\($0.offset)" }
        var out = "function @\(f.name)(\(params.joined(separator: ", "))) -> \(f.returnsAggregate ? "sret" : "\(f.returnType)")"
        out += s.linkage == .internal ? " internal" : ""
        out += " : \(typePool.name(of: QualType(typeId: f.cType)))\n"
        for (k, slot) in f.slots.enumerated() {
            out += "  slot s\(k): \(slot.size) bytes align \(slot.alignment)\(slot.name.isEmpty ? "" : " (\(slot.name))")\n"
        }
        for blk in 1..<f.blockCount {
            let b = BlockId(blk)
            var header = "bb\(blk)"
            if let name = f.blockNames[b] { header += " (\(name))" }
            header += ":"
            let preds = f.predecessors(of: b)
            if !preds.isEmpty { header += " preds " + preds.map { "bb\($0.rawIndex)" }.joined(separator: ", ") }
            if f.addressTakenBlocks.contains(b) { header += " address-taken" }
            out += header + "\n"
            for raw in f.instructions(of: b) {
                out += "  " + format(f, InstId(raw)) + "\n"
            }
        }
        return out
    }

    /// A value operand.
    func value(_ f: borrowing AIRFunction, _ v: ValueId) -> String {
        if v.isNil { return "-" }
        switch v.valueTag {
        case .inst: return "%\(v.index)"
        case .parameter: return "%a\(v.index)"
        case .global: return Int(v.index) < symbols.count ? "@\(symbols[Int(v.index)].name)" : "@?\(v.index)"
        case .constant:
            let t = f.constants.type(v.index)
            let words = Array(f.constants.words(v.index))
            switch t.kind {
            case .pointer:
                return words.first == 0 ? "null" : String(format: "0x%llx", words.first ?? 0)
            case .float:
                if words.count > 1, words[1] != 0 { return String(format: "0x%llx_%016llx", words[1], words[0]) }
                return String(format: "0x%llx", words.first ?? 0)
            default:
                if t.width <= 64 {
                    if t.width == 1 { return words.first == 1 ? "true" : "false" }
                    return "\(f.constants.int64(v.index, signed: true))"
                }
                if words.dropFirst().allSatisfy({ $0 == 0 }) && (words.first ?? 0) < 1 << 63 { return "\(words.first ?? 0)" }
                if words.dropFirst().allSatisfy({ $0 == ~0 }) && (words.first ?? 0) >= 1 << 63 { return "\(Int64(bitPattern: words.first ?? 0))" }
                return "0x" + words.reversed().map { String(format: "%016llx", $0) }.joined()
            }
        }
    }

    func typed(_ f: borrowing AIRFunction, _ v: ValueId) -> String {
        "\(f.valueType(v)) \(value(f, v))"
    }

    func memFlags(_ raw: UInt32) -> String {
        let flags = AIRMemFlags(rawValue: raw)
        return "align \(flags.alignment)\(flags.isVolatile ? " volatile" : "")"
    }

    func string(_ i: UInt32) -> String { Int(i) < strings.count ? "\"\(escape(strings[Int(i)]))\"" : "?" }

    /// One instruction.
    func format(_ f: borrowing AIRFunction, _ i: InstId) -> String {
        let op = f.op(i)
        let t = f.resultType(i)
        let o0 = ValueId(f.op0[i]), o1 = ValueId(f.op1[i]), aux = f.aux[i]
        let items = op.hasExtra ? f.extraList(aux) : []
        let lhs = t.isVoid ? "" : "%\(i.rawIndex) = "
        var text: String
        switch op {
        case .alloca:
            let slot = Int(aux) < f.slots.count ? f.slots[Int(aux)] : AIRSlot(size: 0, alignment: 0, name: "?", decl: .nilId)
            text = "alloca s\(aux)\(slot.name.isEmpty ? "" : " (\(slot.name))")"
        case .dynAlloca:
            text = "dyn_alloca \(typed(f, o0)), align \(aux)"
        case .load:
            text = "load \(t), \(value(f, o0)), \(memFlags(aux))"
        case .store:
            text = "store \(typed(f, o0)), \(value(f, o1)), \(memFlags(aux))"
        case .copy, .fill:
            let size = items.first.map { value(f, ValueId($0)) } ?? "?"
            text = "\(op.name) \(value(f, o0)), \(op == .fill ? typed(f, o1) : value(f, o1)), size \(size), \(memFlags(items.count > 1 ? items[1] : 0))"
        case .ptrAdd:
            text = "ptradd \(value(f, o0)), \(value(f, o1))"
        case .tlsAddr, .stackRestore, .vaStart, .vaEnd:
            text = "\(op.name) \(value(f, o0))"
        case .blockAddr:
            text = "block_addr bb\(aux)"
        case .stackSave, .unreachable, .trap:
            text = op.name
        case .add, .sub, .mul, .sdiv, .udiv, .srem, .urem, .and, .or, .xor, .shl, .lshr, .ashr, .fadd, .fsub, .fmul, .fdiv:
            text = "\(op.name) \(t) \(value(f, o0)), \(value(f, o1))"
        case .fneg, .fabs, .bswap, .clz, .ctz, .popcount:
            text = "\(op.name) \(t) \(value(f, o0))"
        case .icmp:
            text = "icmp \(AIRICmp(rawValue: aux)?.name ?? "?") \(typed(f, o0)), \(value(f, o1))"
        case .fcmp:
            text = "fcmp \(AIRFCmp(rawValue: aux)?.name ?? "?") \(typed(f, o0)), \(value(f, o1))"
        case .select:
            text = "select \(value(f, o0)), \(t) \(value(f, o1)), \(value(f, ValueId(aux)))"
        case .trunc, .zext, .sext, .fptrunc, .fpext, .fptosi, .fptoui, .sitofp, .uitofp, .ptrtoint, .inttoptr, .bitcast:
            text = "\(op.name) \(typed(f, o0)) to \(t)"
        case .call:
            let args = items.dropFirst(2).map { typed(f, ValueId($0)) }.joined(separator: ", ")
            let fnType = items.first.map { typePool.name(of: QualType(typeId: TypeId($0))) } ?? "?"
            text = "call \(t) \(value(f, o0))(\(args))"
            if o1.isValid { text += " into \(value(f, o1))" }
            text += " : \(fnType)"
        case .vaCopy:
            text = "va_copy \(value(f, o0)), \(value(f, o1))"
        case .vaArg:
            text = "va_arg \(value(f, o0)), \(typePool.name(of: QualType(typeId: TypeId(aux))))"
        case .atomicLoad:
            text = "atomic_load \(t), \(value(f, o0)), \(AIRAtomicOrdering(rawValue: aux & 0xFF)?.name ?? "?"), \(memFlags(aux >> 8))"
        case .atomicStore:
            text = "atomic_store \(typed(f, o0)), \(value(f, o1)), \(AIRAtomicOrdering(rawValue: aux & 0xFF)?.name ?? "?"), \(memFlags(aux >> 8))"
        case .atomicRMW:
            text = "atomic_rmw \(AIRAtomicOp(rawValue: aux >> 8)?.name ?? "?") \(value(f, o0)), \(typed(f, o1)), \(AIRAtomicOrdering(rawValue: aux & 0xFF)?.name ?? "?")"
        case .cmpxchg:
            let desired = items.first.map { value(f, ValueId($0)) } ?? "?"
            let orders = items.count == 4 ? "\(AIRAtomicOrdering(rawValue: items[1])?.name ?? "?") \(AIRAtomicOrdering(rawValue: items[2])?.name ?? "?")\(items[3] != 0 ? " weak" : "")" : "?"
            text = "cmpxchg \(value(f, o0)), \(typed(f, o1)), \(desired), \(orders)"
        case .fence:
            text = "fence \(AIRAtomicOrdering(rawValue: aux & 0xFF)?.name ?? "?")\(aux & 0x100 != 0 ? " signal" : "")"
        case .inlineAsm, .asmGoto:
            guard let asm = AIRAsm(items) else { text = "\(op.name) ?"; break }
            func operand(_ o: AIRAsm.Operand) -> String {
                (o.name == AIRAsm.noName ? "" : "[\(strings[Int(o.name)])] ") + "\(string(o.constraint)) \(typed(f, o.value))"
            }
            text = "\(op.name)\(asm.flags & SemAsm.volatileFlag != 0 ? " volatile" : "") \(string(asm.template))"
            text += " outputs [\(asm.outputs.map(operand).joined(separator: ", "))]"
            text += " inputs [\(asm.inputs.map(operand).joined(separator: ", "))]"
            text += " clobbers [\(asm.clobbers.map(string).joined(separator: ", "))]"
            if op == .asmGoto { text += " labels [\(asm.labels.map { "bb\($0.rawIndex)" }.joined(separator: ", "))]" }
        case .frameAddress, .returnAddress:
            text = "\(op.name) \(aux)"
        case .phi:
            var parts: [String] = []
            for k in stride(from: 0, to: items.count - 1, by: 2) { parts.append("[bb\(items[k]): \(value(f, ValueId(items[k + 1])))]") }
            text = "phi \(t) " + parts.joined(separator: ", ")
        case .br:
            text = "br bb\(aux)"
        case .condBr:
            text = "cond_br \(value(f, o0)), bb\(f.op1[i]), bb\(aux)"
        case .switch:
            var parts: [String] = []
            for k in stride(from: 1, to: items.count - 1, by: 2) { parts.append("\(value(f, ValueId(items[k]))): bb\(items[k + 1])") }
            text = "switch \(typed(f, o0)), default bb\(items.first ?? 0) [\(parts.joined(separator: ", "))]"
        case .indirectBr:
            text = "indirect_br \(value(f, o0)) [\(items.map { "bb\($0)" }.joined(separator: ", "))]"
        case .ret:
            text = o0.isNil ? "ret" : "ret \(typed(f, o0))"
        case .nilOp, .dead:
            text = op.name
        }
        return lhs + text
    }
}
