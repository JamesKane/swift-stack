// Sources/SwiftStack/AIR/AIRVerifier.swift
//
// The AIR verifier (`--verify-each`; 03-intermediate-representation.md §4.1). Per function it checks:
// - blocks: each is nonempty and ends in its only terminator; `phi`s open a block; `alloca`s are in the entry block,
//   which has no predecessors; the CSR edges match the terminators;
// - operands: every value names an instruction with a result, a parameter, a constant or a symbol; each opcode's
//   operand and result types agree (integer operations on one integer type, comparisons give `i1`, conversions
//   change width the right way, calls match their C function type, `ret` the function's result);
// - SSA: every use is dominated by its definition (a `phi`'s incoming value by the end of its predecessor), and
//   each `phi` has exactly one incoming value per predecessor.
// Per module it checks symbols: unique names, function symbols with bodies, data images of the object's size.

import Foundation

public struct AIRVerifier {
    public struct Issue: CustomStringConvertible, Sendable {
        public let function: String
        public let inst: UInt32
        public let message: String
        public var description: String { "\(function) %\(inst): \(message)" }
    }

    let module: AIRModule
    public private(set) var issues: [Issue] = []

    public init(module: AIRModule) {
        self.module = module
    }

    public static func verify(_ module: AIRModule) -> [Issue] {
        var v = AIRVerifier(module: module)
        v.run()
        return v.issues
    }

    public mutating func run() {
        var names = Set<String>()
        for (i, s) in module.symbols.enumerated() {
            if !names.insert(s.name).inserted { report("", 0, "duplicate symbol \(s.name)") }
            if s.kind == .function, s.linkage != .undefined, s.function == nil { report(s.name, 0, "defined function without a body") }
            if let image = s.image {
                if s.kind != .object { report(s.name, 0, "a function with a data image") }
                if image.bytes.count != s.size, s.size > 0 { report(s.name, 0, "data image of \(image.bytes.count) bytes for an object of \(s.size)") }
                for r in image.relocations {
                    if r.offset < 0 || r.offset + r.size > image.bytes.count { report(s.name, 0, "relocation at +\(r.offset) outside the image") }
                    switch r.target {
                    case .symbol(let t) where t < 0 || t >= module.symbols.count: report(s.name, 0, "relocation to symbol \(t)")
                    case .block(let f, let blk):
                        if f < 0 || f >= module.functions.count || blk.rawIndex == 0 || blk.rawIndex >= module.functions[f].function.blockCount {
                            report(s.name, 0, "relocation to a missing block")
                        } else if !module.functions[f].function.addressTakenBlocks.contains(blk) {
                            report(s.name, 0, "relocation to a block whose address is not taken")
                        }
                    default: break
                    }
                }
            }
            if let f = s.function, f >= module.functions.count || module.functions[f].function.symbol != i {
                report(s.name, 0, "function body index \(f) does not point back")
            }
        }
        for box in module.functions {
            verify(box.function)
        }
    }

    private mutating func report(_ function: String, _ inst: UInt32, _ message: String) {
        if issues.count < 1000 { issues.append(Issue(function: function, inst: inst, message: message)) }
    }

    // MARK: - Functions

    private mutating func verify(_ f: borrowing AIRFunction) {
        let name = f.name
        guard f.blockCount >= 2 else { report(name, 0, "no blocks"); return }
        // Blocks and terminators
        for blk in 1..<f.blockCount {
            let b = BlockId(blk)
            let range = f.instructions(of: b)
            if range.isEmpty { report(name, 0, "bb\(blk) is empty"); continue }
            var sawNonPhi = false
            for raw in range {
                let i = InstId(raw)
                let op = f.op(i)
                let isLast = raw == range.upperBound - 1
                if op.isTerminator != isLast {
                    report(name, raw, isLast ? "bb\(blk) does not end in a terminator" : "\(op.name) in the middle of bb\(blk)")
                }
                if op == .phi {
                    if sawNonPhi { report(name, raw, "phi after other instructions") }
                } else {
                    sawNonPhi = true
                }
                if op == .alloca && blk != 1 { report(name, raw, "alloca outside the entry block") }
            }
            // The CSR edges
            let targets = f.terminatorTargets(InstId(range.upperBound - 1))
            var unique: [BlockId] = []
            for t in targets where !unique.contains(t) { unique.append(t) }
            if unique != f.successors(of: b) { report(name, range.upperBound - 1, "successor list of bb\(blk) does not match its terminator") }
            for t in unique {
                if t.rawIndex == 0 || t.rawIndex >= f.blockCount { report(name, range.upperBound - 1, "branch to a missing block bb\(t.rawIndex)"); continue }
                if !f.predecessors(of: t).contains(b) { report(name, range.upperBound - 1, "bb\(t.rawIndex) does not list bb\(blk) as a predecessor") }
            }
        }
        if !f.predecessors(of: BlockId(1)).isEmpty { report(name, 0, "the entry block has predecessors") }
        for blk in f.addressTakenBlocks where blk.rawIndex == 0 || blk.rawIndex >= f.blockCount {
            report(name, 0, "address-taken block bb\(blk.rawIndex) is missing")
        }

        // Instructions
        for raw in 1..<f.instructionCount {
            verifyInstruction(f, InstId(raw))
        }
        verifyDominance(f)
    }

    private func isValid(_ f: borrowing AIRFunction, _ v: ValueId) -> Bool {
        switch v.valueTag {
        case .inst:
            guard v.index > 0, v.index < f.instructionCount else { return false }
            return !f.resultType(v.inst).isVoid
        case .parameter: return Int(v.index) < f.paramTypes.count
        case .constant: return v.index > 0 && Int(v.index) < f.constants.count
        case .global: return Int(v.index) < module.symbols.count
        }
    }

    private mutating func verifyInstruction(_ f: borrowing AIRFunction, _ i: InstId) {
        let name = f.name
        let raw = i.rawIndex
        let op = f.op(i)
        let t = f.resultType(i)
        let fields = op.fields
        let o0 = ValueId(f.op0[i]), o1 = ValueId(f.op1[i]), aux = f.aux[i]
        func fail(_ m: String) { report(name, raw, "\(op.name): \(m)") }
        func ty(_ v: ValueId) -> AIRType { f.valueType(v) }
        func check(_ v: ValueId, _ what: String) -> Bool {
            if isValid(f, v) { return true }
            fail("\(what) is not a value (\(v.rawIndex))")
            return false
        }
        if op == .nilOp || op == .dead { fail("invalid opcode \(f.opcode[i])"); return }
        if fields.op0 == .value, !(op == .ret && o0.isNil), !check(o0, "operand 0") { return }
        if fields.op1 == .value, !(op == .call && o1.isNil), !check(o1, "operand 1") { return }
        if fields.aux == .value, !check(ValueId(aux), "operand 2") { return }
        let blockCount = f.blockCount
        func checkBlock(_ b: UInt32) { if b == 0 || b >= blockCount { fail("block bb\(b) does not exist") } }
        if fields.op1 == .block { checkBlock(f.op1[i]) }
        if fields.aux == .block { checkBlock(aux) }
        let items = op.hasExtra ? f.extraList(aux) : []
        if op.hasExtra, aux == 0 { fail("no operand list"); return }

        switch op {
        case .alloca:
            if Int(aux) >= f.slots.count { fail("slot \(aux) does not exist") }
            if t != .ptr { fail("result \(t)") }
        case .dynAlloca:
            if ty(o0) != .i64 { fail("size \(ty(o0))") }
            if aux == 0 || aux & (aux - 1) != 0 { fail("alignment \(aux)") }
        case .load:
            if ty(o0) != .ptr { fail("address \(ty(o0))") }
            if t.isVoid { fail("void load") }
        case .store:
            if ty(o1) != .ptr { fail("address \(ty(o1))") }
        case .copy, .fill:
            if ty(o0) != .ptr || (op == .copy && ty(o1) != .ptr) || (op == .fill && ty(o1) != .i8) { fail("operands \(ty(o0)), \(ty(o1))") }
            if items.count != 2 { fail("list of \(items.count) items"); break }
            if !isValid(f, ValueId(items[0])) || ty(ValueId(items[0])) != .i64 { fail("size is not an i64 value") }
        case .ptrAdd:
            if ty(o0) != .ptr || ty(o1) != .i64 || t != .ptr { fail("operands \(ty(o0)), \(ty(o1))") }
        case .tlsAddr:
            if o0.valueTag != .global || !module.symbols[Int(o0.index)].isThreadLocal { fail("operand is not a thread-local object") }
        case .blockAddr:
            if t != .ptr { fail("result \(t)") }
            if !f.addressTakenBlocks.contains(BlockId(aux)) { fail("bb\(aux) is not address-taken") }
        case .stackSave:
            if t != .ptr { fail("result \(t)") }
        case .stackRestore:
            if ty(o0) != .ptr { fail("operand \(ty(o0))") }
        case .add, .sub, .mul, .sdiv, .udiv, .srem, .urem, .and, .or, .xor, .shl, .lshr, .ashr:
            if !t.isInt || ty(o0) != t || ty(o1) != t { fail("\(ty(o0)), \(ty(o1)) -> \(t)") }
        case .fadd, .fsub, .fmul, .fdiv:
            if !t.isFloat || ty(o0) != t || ty(o1) != t { fail("\(ty(o0)), \(ty(o1)) -> \(t)") }
        case .fneg, .fabs:
            if !t.isFloat || ty(o0) != t { fail("\(ty(o0)) -> \(t)") }
        case .bswap, .clz, .ctz, .popcount:
            if !t.isInt || ty(o0) != t { fail("\(ty(o0)) -> \(t)") }
            if op == .bswap && t.width % 16 != 0 { fail("bswap of \(t)") }
        case .icmp:
            if ty(o0) != ty(o1) || ty(o0).isFloat || ty(o0).isVoid || t != .i1 { fail("\(ty(o0)), \(ty(o1)) -> \(t)") }
            if AIRICmp(rawValue: aux) == nil { fail("predicate \(aux)") }
        case .fcmp:
            if ty(o0) != ty(o1) || !ty(o0).isFloat || t != .i1 { fail("\(ty(o0)), \(ty(o1)) -> \(t)") }
            if AIRFCmp(rawValue: aux) == nil { fail("predicate \(aux)") }
        case .select:
            if ty(o0) != .i1 || ty(o1) != t || ty(ValueId(aux)) != t { fail("\(ty(o0)) ? \(ty(o1)) : \(ty(ValueId(aux))) -> \(t)") }
        case .trunc:
            if !(ty(o0).isInt && t.isInt && t.width < ty(o0).width) { fail("\(ty(o0)) to \(t)") }
        case .zext, .sext:
            if !(ty(o0).isInt && t.isInt && t.width > ty(o0).width) { fail("\(ty(o0)) to \(t)") }
        case .fptrunc, .fpext:
            if !(ty(o0).isFloat && t.isFloat && (op == .fptrunc ? t.width < ty(o0).width : t.width > ty(o0).width)) { fail("\(ty(o0)) to \(t)") }
        case .fptosi, .fptoui:
            if !(ty(o0).isFloat && t.isInt) { fail("\(ty(o0)) to \(t)") }
        case .sitofp, .uitofp:
            if !(ty(o0).isInt && t.isFloat) { fail("\(ty(o0)) to \(t)") }
        case .ptrtoint:
            if !(ty(o0) == .ptr && t == .i64) { fail("\(ty(o0)) to \(t)") }
        case .inttoptr:
            if !(ty(o0) == .i64 && t == .ptr) { fail("\(ty(o0)) to \(t)") }
        case .bitcast:
            if !((ty(o0).isInt && t.isFloat) || (ty(o0).isFloat && t.isInt)) || ty(o0).width != t.width { fail("\(ty(o0)) to \(t)") }
        case .call:
            for m in callIssues(f, i, items) { fail(m) }
        case .vaStart, .vaEnd:
            if ty(o0) != .ptr { fail("operand \(ty(o0))") }
        case .vaCopy:
            if ty(o0) != .ptr || ty(o1) != .ptr { fail("operands \(ty(o0)), \(ty(o1))") }
        case .vaArg:
            if ty(o0) != .ptr || t != .ptr { fail("\(ty(o0)) -> \(t)") }
            if Int(aux) >= module.typePool.count || aux == 0 { fail("C type \(aux)") }
        case .atomicLoad:
            if ty(o0) != .ptr || !t.isInt { fail("\(ty(o0)) -> \(t)") }
            if AIRAtomicOrdering(rawValue: aux & 0xFF) == nil { fail("ordering \(aux & 0xFF)") }
        case .atomicStore:
            if ty(o1) != .ptr || !ty(o0).isInt { fail("\(ty(o0)) to \(ty(o1))") }
            if AIRAtomicOrdering(rawValue: aux & 0xFF) == nil { fail("ordering \(aux & 0xFF)") }
        case .atomicRMW:
            if ty(o0) != .ptr || ty(o1) != t || !t.isInt { fail("\(ty(o0)), \(ty(o1)) -> \(t)") }
            if AIRAtomicOrdering(rawValue: aux & 0xFF) == nil || AIRAtomicOp(rawValue: aux >> 8) == nil { fail("operation \(aux)") }
        case .cmpxchg:
            if ty(o0) != .ptr || ty(o1) != t || !t.isInt { fail("\(ty(o0)), \(ty(o1)) -> \(t)") }
            if items.count != 4 { fail("list of \(items.count) items"); break }
            if !isValid(f, ValueId(items[0])) || ty(ValueId(items[0])) != t { fail("desired value") }
            if AIRAtomicOrdering(rawValue: items[1]) == nil || AIRAtomicOrdering(rawValue: items[2]) == nil { fail("orderings") }
        case .fence:
            if AIRAtomicOrdering(rawValue: aux & 0xFF) == nil { fail("ordering \(aux & 0xFF)") }
        case .inlineAsm, .asmGoto:
            guard let asm = AIRAsm(items) else { fail("malformed operand list"); break }
            for o in asm.outputs + asm.inputs {
                if Int(o.constraint) >= module.strings.count || (o.name != AIRAsm.noName && Int(o.name) >= module.strings.count) { fail("string index") }
                if !isValid(f, o.value) { fail("operand \(o.value.rawIndex) is not a value") }
            }
            for o in asm.outputs where ty(o.value) != .ptr { fail("output operand is not an address") }
            if Int(asm.template) >= module.strings.count { fail("template index") }
            if op == .asmGoto { for l in asm.labels { checkBlock(l.rawIndex) } } else if !asm.labels.isEmpty { fail("labels without goto") }
        case .frameAddress, .returnAddress:
            if t != .ptr { fail("result \(t)") }
        case .phi:
            if items.count % 2 != 0 { fail("odd operand list"); break }
            let b = f.block(of: i)
            let preds = f.predecessors(of: b)
            var seen: [BlockId] = []
            for k in stride(from: 0, to: items.count, by: 2) {
                let from = BlockId(items[k]), v = ValueId(items[k + 1])
                if !preds.contains(from) { fail("bb\(from.rawIndex) is not a predecessor of bb\(b.rawIndex)") }
                if seen.contains(from) { fail("two values from bb\(from.rawIndex)") }
                seen.append(from)
                if !isValid(f, v) { fail("incoming \(v.rawIndex) is not a value") } else if ty(v) != t { fail("incoming \(ty(v)) for \(t)") }
            }
            for p in preds where !seen.contains(p) { fail("no value from predecessor bb\(p.rawIndex)") }
        case .br:
            break
        case .condBr:
            if ty(o0) != .i1 { fail("condition \(ty(o0))") }
        case .switch:
            if !ty(o0).isInt { fail("value \(ty(o0))") }
            if items.isEmpty || items.count % 2 != 1 { fail("malformed case list"); break }
            checkBlock(items[0])
            var values = Set<[UInt64]>()
            for k in stride(from: 1, to: items.count, by: 2) {
                let c = ValueId(items[k])
                if c.valueTag != .constant || !isValid(f, c) || ty(c) != ty(o0) { fail("case \(k / 2) is not a constant of \(ty(o0))"); continue }
                if !values.insert(Array(f.constants.words(c.index))).inserted { fail("duplicate case value") }
                checkBlock(items[k + 1])
            }
        case .indirectBr:
            if ty(o0) != .ptr { fail("address \(ty(o0))") }
            for blk in items where !f.addressTakenBlocks.contains(BlockId(blk)) { fail("target bb\(blk) is not address-taken") }
        case .ret:
            if f.returnsAggregate {
                if ty(o0) != .ptr { fail("aggregate result \(o0.isNil ? "missing" : "\(ty(o0))")") }
            } else if f.returnType.isVoid {
                if o0.isValid { fail("value returned from a void function") }
            } else if o0.isNil || ty(o0) != f.returnType {
                fail("returns \(o0.isNil ? "nothing" : "\(ty(o0))") from a function returning \(f.returnType)")
            }
        case .unreachable, .trap, .nilOp, .dead:
            break
        }
    }

    private func callIssues(_ f: borrowing AIRFunction, _ i: InstId, _ items: [UInt32]) -> [String] {
        var issues: [String] = []
        func fail(_ m: String) { issues.append(m) }
        guard items.count >= 2, Int(items[1]) == items.count - 2 else { fail("malformed argument list"); return issues }
        let pool = module.typePool
        let fnType = TypeId(items[0])
        guard case .function(let ret, let params, let variadic) = pool.typeInfo(of: pool.canonical(of: fnType)).kind else {
            fail("C type \(items[0]) is not a function type")
            return issues
        }
        let callee = ValueId(f.op0[i])
        if f.valueType(callee) != .ptr { fail("callee is \(f.valueType(callee))") }
        let args = items.dropFirst(2).map { ValueId($0) }
        if args.count < params.count || (args.count > params.count && !variadic) {
            fail("\(args.count) arguments for \(params.count) parameters\(variadic ? " and ..." : "")")
        }
        for (k, a) in args.enumerated() {
            guard isValid(f, a) else { fail("argument \(k + 1) is not a value"); continue }
            if k < params.count {
                let expected = airType(params[k])
                if f.valueType(a) != expected { fail("argument \(k + 1) is \(f.valueType(a)), the parameter \(expected)") }
            }
        }
        let aggregateResult = isAggregate(ret)
        let destination = ValueId(f.op1[i])
        if aggregateResult {
            if destination.isNil || f.valueType(destination) != .ptr { fail("aggregate result without a destination") }
            if !f.resultType(i).isVoid { fail("aggregate result typed \(f.resultType(i))") }
        } else {
            if destination.isValid { fail("destination for a scalar result") }
            if f.resultType(i) != airType(ret) { fail("result \(f.resultType(i)), the callee returns \(airType(ret))") }
        }
        return issues
    }

    private func isAggregate(_ t: QualType) -> Bool {
        let pool = module.typePool
        switch pool.typeInfo(of: pool.canonical(of: t.typeId)).kind {
        case .struct, .array, .function: return true
        default: return false
        }
    }

    private func airType(_ t: QualType) -> AIRType {
        let pool = module.typePool
        switch pool.typeInfo(of: pool.canonical(of: t.typeId)).kind {
        case .void, .error: return .void
        case .bool: return .i1
        case .int(let w, _): return .int(w)
        case .enum(_, let u, _): return airType(QualType(typeId: u))
        case .float(let w): return .float(w)
        case .pointer, .nullptr, .struct, .array, .function: return .ptr
        case .typedef(_, let u): return airType(u)
        }
    }

    // MARK: - Dominance

    /// Immediate dominators by the Cooper–Harvey–Kennedy algorithm over a reverse postorder (03 §4.6). Blocks not
    /// reachable from the entry (address-taken blocks with no `indirectBr`) have none.
    static func dominators(_ f: borrowing AIRFunction) -> (idom: [Int], rpoIndex: [Int]) {
        let n = Int(f.blockCount)
        var order: [Int] = []
        var visited = [Bool](repeating: false, count: n)
        // Iterative DFS for the postorder
        var stack: [(Int, [BlockId], Int)] = [(1, f.successors(of: BlockId(1)), 0)]
        visited[1] = true
        while !stack.isEmpty {
            let (b, succs, k) = stack[stack.count - 1]
            if k < succs.count {
                stack[stack.count - 1].2 += 1
                let s = Int(succs[k].rawIndex)
                if s < n, !visited[s] {
                    visited[s] = true
                    stack.append((s, f.successors(of: BlockId(UInt32(s))), 0))
                }
            } else {
                order.append(b)
                stack.removeLast()
            }
        }
        order.reverse()
        var rpoIndex = [Int](repeating: -1, count: n)
        for (k, b) in order.enumerated() { rpoIndex[b] = k }
        var idom = [Int](repeating: -1, count: n)
        idom[1] = 1
        var changed = true
        while changed {
            changed = false
            for b in order.dropFirst() {
                var newIdom = -1
                for p in f.predecessors(of: BlockId(UInt32(b))).map({ Int($0.rawIndex) }) where idom[p] != -1 {
                    if newIdom == -1 { newIdom = p; continue }
                    var x = p, y = newIdom
                    while x != y {
                        while rpoIndex[x] > rpoIndex[y] { x = idom[x] }
                        while rpoIndex[y] > rpoIndex[x] { y = idom[y] }
                    }
                    newIdom = x
                }
                if newIdom != -1, idom[b] != newIdom {
                    idom[b] = newIdom
                    changed = true
                }
            }
        }
        return (idom, rpoIndex)
    }

    private mutating func verifyDominance(_ f: borrowing AIRFunction) {
        let (idom, _) = Self.dominators(f)
        func dominates(_ a: Int, _ b: Int) -> Bool {
            guard idom[b] != -1 else { return true }  // unreachable uses are not checked
            var x = b
            while true {
                if x == a { return true }
                if x == 1 || idom[x] == -1 { return false }
                x = idom[x]
            }
        }
        var blockOf = [Int](repeating: 0, count: Int(f.instructionCount))
        for blk in 1..<f.blockCount {
            for raw in f.instructions(of: BlockId(blk)) { blockOf[Int(raw)] = Int(blk) }
        }
        for raw in 1..<f.instructionCount {
            let i = InstId(raw)
            let op = f.op(i)
            let useBlock = blockOf[Int(raw)]
            if op == .phi {
                let items = f.extraList(f.aux[i])
                for k in stride(from: 0, to: items.count - 1, by: 2) {
                    let v = ValueId(items[k + 1])
                    guard v.valueTag == .inst, v.index < f.instructionCount else { continue }
                    let from = Int(items[k])
                    if from < idom.count, !dominates(blockOf[Int(v.index)], from) {
                        report(f.name, raw, "phi: incoming %\(v.index) does not dominate the end of bb\(from)")
                    }
                }
                continue
            }
            for v in operandValues(f, i) where v.valueTag == .inst && v.index < f.instructionCount {
                let defBlock = blockOf[Int(v.index)]
                if defBlock == useBlock ? v.index >= raw : !dominates(defBlock, useBlock) {
                    report(f.name, raw, "\(op.name): %\(v.index) does not dominate its use")
                }
            }
        }
    }

    /// The values an instruction uses (other than a `phi`'s).
    func operandValues(_ f: borrowing AIRFunction, _ i: InstId) -> [ValueId] {
        let op = f.op(i)
        let fields = op.fields
        var out: [ValueId] = []
        if fields.op0 == .value, f.op0[i] != 0 { out.append(ValueId(f.op0[i])) }
        if fields.op1 == .value, f.op1[i] != 0 { out.append(ValueId(f.op1[i])) }
        if fields.aux == .value { out.append(ValueId(f.aux[i])) }
        let items = op.hasExtra ? f.extraList(f.aux[i]) : []
        switch op {
        case .copy, .fill, .cmpxchg: if let first = items.first { out.append(ValueId(first)) }
        case .call: out += items.dropFirst(2).map { ValueId($0) }
        case .inlineAsm, .asmGoto: out += AIRAsm.valuePositions(items).values.map { ValueId(items[$0]) }
        default: break
        }
        return out
    }
}
