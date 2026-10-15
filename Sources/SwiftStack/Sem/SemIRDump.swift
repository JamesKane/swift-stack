// Sources/SwiftStack/Sem/SemIRDump.swift
//
// `--dump=sem-ir` (15-driver-and-diagnostics.md): a deterministic text form of a C module's SemIR, used by the golden
// tests. Each function body is listed instruction by instruction in block order (`%n = kind operands : type`);
// globals are listed with their data images.

import Foundation

extension SemModule {
    /// The SemIR of the module as text.
    public func dumpText() -> String {
        var out = ""
        for f in functions {
            let c = block(f.blockId)
            let params = f.params.map { "\(declTable.name(of: $0).isEmpty ? "_" : declTable.name(of: $0))#\($0.rawIndex): \(typePool.name(of: declTable.type(of: $0)))" }
            out += "function \(f.name)(\(params.joined(separator: ", "))) -> \(functionReturnTypeName(f.declId))\(f.isExternal ? "" : " internal")\n"
            for i in 1..<Int(c.block.count) {
                out += "  " + format(SemInstId(UInt32(i)), c) + "\n"
            }
        }
        if fileScopeBlock.block.count > 1 {
            out += "file scope\n"
            for i in 1..<Int(fileScopeBlock.block.count) {
                out += "  " + format(SemInstId(UInt32(i)), fileScopeBlock) + "\n"
            }
        }
        for g in globals {
            var line = "global \(g.symbol): \(typePool.name(of: g.type)) align \(g.alignment)"
            if !g.isExternal { line += " internal" }
            if g.isThreadLocal { line += " thread_local" }
            if g.isTentative { line += " tentative" }
            if g.initInst.isValid { line += " init %\(g.initInst.rawIndex)" + (g.initBlock.isValid ? " in block \(g.initBlock.rawIndex)" : "") }
            out += line + "\n"
            if let image = g.image {
                out += "  bytes [" + image.bytes.map { String(format: "%02x", $0) }.joined(separator: " ") + "]\n"
                for r in image.relocations {
                    let target: String
                    switch r.target {
                    case .decl(let d): target = symbolName(of: d)
                    case .string(let s): target = "string#\(s) \"\(escaped(staticStrings[s].bytes))\""
                    case .label(let f, let n): target = "\(symbolName(of: f)) label \(n)"
                    }
                    out += "  reloc +\(r.offset) \(r.size) bytes -> \(target)\(r.addend >= 0 ? "+" : "")\(r.addend)\n"
                }
            } else {
                out += "  no image: \(g.unsupportedReason)\n"
            }
        }
        return out
    }

    public func dump() {
        print(dumpText(), terminator: "")
    }

    private func functionReturnTypeName(_ decl: DeclId) -> String {
        if case .function(let ret, _, _) = typePool.typeInfo(of: typePool.canonical(of: declTable.type(of: decl).typeId)).kind {
            return typePool.name(of: ret)
        }
        return "?"
    }

    private func escaped(_ bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            switch b {
            case 0x22: s += "\\\""
            case 0x5C: s += "\\\\"
            case 0x0A: s += "\\n"
            case 0x20..<0x7F: s += String(UnicodeScalar(b))
            default: s += String(format: "\\x%02x", b)
            }
        }
        return s
    }

    private func declName(_ raw: UInt32) -> String {
        let d = DeclId(raw)
        let name = declTable.name(of: d)
        return "@\(name.isEmpty ? "_" : name)#\(raw)"
    }

    /// One instruction: `%id = kind operands : type`.
    func format(_ id: SemInstId, _ c: SemInstBlockContainer) -> String {
        let kind = c.block.kind(of: id)
        let type = c.block.type(of: id)
        let a0 = c.block.arg0[id], a1 = c.block.arg1[id]
        let extra = Array(c.block.extra(of: id))
        func r(_ x: UInt32) -> String { x == 0 ? "-" : "%\(x)" }
        var ops: String
        switch kind {
        case .intLiteral:
            ops = "\(c.block.intConstant(of: id))"
        case .floatLiteral:
            let f = c.block.floatConstant(of: id)
            ops = f.hi == 0 ? String(format: "0x%llx", f.lo) : String(format: "0x%llx_%016llx", f.hi, f.lo)
        case .stringLiteral:
            let s = c.block.stringConstant(of: id)
            ops = "\(s.encoding.prefix)\"\(escaped(s.bytes))\""
        case .nullptrLiteral, .breakStmt, .continueStmt, .asmStmt, .nullStmt, .nilInst:
            ops = ""
        case .declRef:
            ops = declName(a0)
        case .member:
            ops = "\(r(a0)) +\(a1)"
        case .bitField:
            ops = extra.count == 5 ? "\(r(a0)) +\(extra[0]) bit \(extra[1]) width \(extra[2]) \(extra[3] == 1 ? "signed" : "unsigned") unit \(extra[4])" : r(a0)
        case .compoundLiteral:
            ops = "\(declName(a0)) = \(r(a1))"
        case .explicitCast, .intPromotion, .arithmeticConvert, .assignConvert, .argPromotion, .boolConvert, .nullPointerConvert:
            ops = "\(r(a0)) \(CastKind(rawValue: a1)?.name ?? "?")"
        case .compoundAssign:
            let op = extra.first.flatMap { SemInstKind(rawValue: UInt16($0)) }?.name ?? "?"
            ops = extra.count == 4 ? "\(r(a0)) \(op)= \(r(extra[1])) in \(typePool.name(of: QualType(rawValue: extra[2])))" : r(a0)
        case .call:
            let args = extra.dropFirst(3).map { r($0) }.joined(separator: ", ")
            ops = "\(r(a0))(\(args))"
            if let d = extra.first, d != 0 { ops += " direct \(declName(d))" }
            if extra.count > 1 { ops += " params \(extra[1])" }
        case .conditional:
            ops = extra.count == 3 ? "\(r(extra[0])) ? \(r(extra[1])) : \(r(extra[2]))" : ""
        case .initList:
            var parts: [String] = []
            var i = 0
            while i + 2 < extra.count {
                parts.append(extra[i + 1] > 1 ? "[\(extra[i])...+\(extra[i + 1])] \(r(extra[i + 2]))" : "[\(extra[i])] \(r(extra[i + 2]))")
                i += 3
            }
            ops = "{" + parts.joined(separator: ", ") + "}"
        case .labelAddress, .gotoStmt:
            ops = "label \(a0)"
        case .vlaSizeof:
            ops = "type \(a0)" + (extra.isEmpty ? "" : " lengths \(extra)")
        case .compound:
            ops = "[" + extra.map { r($0) }.joined(separator: ", ") + "]"
        case .declLocal:
            ops = declName(a0) + ": \(typePool.name(of: declTable.type(of: DeclId(a0))))"
            if let initInst = extra.first, initInst != 0 { ops += " = \(r(initInst))" }
            if extra.count > 2 {
                ops += " vla " + stride(from: 2, to: extra.count - 1, by: 2).map { "type \(extra[$0]) length \(r(extra[$0 + 1]))" }.joined(separator: ", ")
            }
        case .ifStmt:
            ops = "\(r(a0)) then \(r(extra.first ?? 0)) else \(r(extra.count > 1 ? extra[1] : 0))"
        case .whileStmt:
            ops = "\(r(a0)) do \(r(a1))"
        case .doWhileStmt:
            ops = "\(r(a0)) while \(r(a1))"
        case .forStmt:
            ops = extra.count == 4 ? "init \(r(extra[0])) cond \(r(extra[1])) step \(r(extra[2])) body \(r(extra[3]))" : ""
        case .switchStmt:
            ops = extra.count >= 2 ? "\(r(a0)) body \(r(extra[0])) default \(r(extra[1])) cases [\(extra.dropFirst(2).map { r($0) }.joined(separator: ", "))]" : r(a0)
        case .caseLabel:
            ops = "\(c.block.intConstant(at: a1)): \(r(a0))"
        case .caseRange:
            ops = extra.count == 2 ? "\(c.block.intConstant(at: extra[0])) ... \(c.block.intConstant(at: extra[1])): \(r(a0))" : r(a0)
        case .defaultLabel:
            ops = r(a0)
        case .label:
            ops = "\(a1): \(r(a0))"
        case .returnStmt, .exprStmt, .indirectGoto:
            ops = r(a0)
        case .stmtExpr:
            ops = "\(r(a0)) value \(r(a1))"
        default:
            ops = [a0, a1].map { r($0) }.joined(separator: ", ")
            if kind.isLvalue || kind == .lvalueToRvalue || kind == .arrayToPointer || kind == .functionToPointer || kind == .addrOf
                || kind == .deref || kind == .materialize || kind == .neg || kind == .bitNot || kind == .logicalNot
                || kind == .preInc || kind == .preDec || kind == .postInc || kind == .postDec || kind == .vaArg {
                ops = r(a0)
            }
        }
        let typePart = kind.isStatement ? "" : " : \(typePool.name(of: type))"
        return "%\(id.rawIndex) = \(kind.name)\(ops.isEmpty ? "" : " " + ops)\(typePart)"
    }
}
