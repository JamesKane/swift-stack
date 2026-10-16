// Sources/SwiftStack/Codegen/X86/X86ISel.swift
//
// Instruction selection for x86-64 (04-backend.md §4.4): AIR to LIR, one block at a time, in AIR's block order.
//
// Values. An integer of at most 64 bits, or a pointer, is in a GPR, in its low bits; the bits above its width are
// unspecified, so operations whose result depends on them (division, right shifts, comparisons, conversions) extend
// their operands first. An integer of 65 to 128 bits is a pair of GPRs. `f16`, `f32`, `f64` and `f128` are in XMM
// registers. An `f80` lives in a 16-byte stack slot of its own and is computed on the x87 stack.
//
// Folding (the single-use rule of §4.4). A `ptradd` used once, in its own block, as the address of a memory access
// becomes part of that access's address. A comparison used once, in its own block, by a branch or a `select` is
// emitted right before it. `alloca`s, globals and constants are rematerialized at each use.

import Foundation

/// The module-wide context of code generation: the AIR module, symbol names, and what each symbol is.
final class X86ModuleContext {
    let module: AIRModule
    let symbols = LIRSymbols()
    let abi: X86ABI
    /// The LIR symbol of each AIR symbol.
    private(set) var symbolOf: [UInt32] = []
    /// Libcalls and other undefined functions codegen refers to.
    var referencedExternals: Set<String> = []

    init(module: AIRModule) {
        self.module = module
        self.abi = X86ABI(types: module.typePool)
        symbolOf = module.symbols.map { symbols.intern(Self.asmName($0)) }
    }

    /// The assembly name of a symbol: internal symbols named with a leading `.` (string literals, compound literals)
    /// become assembler-local `.L` labels.
    static func asmName(_ s: AIRSymbol) -> String {
        if s.linkage == .internal && s.name.hasPrefix(".") { return ".L" + s.name }
        return s.name
    }

    func symbol(_ index: Int) -> AIRSymbol { module.symbols[index] }
    func isDefined(_ index: Int) -> Bool { module.symbols[index].linkage != .undefined }
}

/// The LIR form of an AIR value.
enum X86Val {
    case none
    case reg(LIRReg)
    /// The low and high words of an integer wider than 64 bits.
    case pair(LIRReg, LIRReg)
    /// A stack slot holding the value (`f80`).
    case slot(UInt32)
}

/// A condition to branch on, set in the flags by a compare: one condition code, or two combined (the ordered
/// `oeq` is `e` and `np`; the unordered `une` is `ne` or `p`).
enum X86Condition {
    case single(X86Cond)
    case both(X86Cond, X86Cond)
    case either(X86Cond, X86Cond)
}

final class X86FunctionISel {
    let ctx: X86ModuleContext
    let box: AIRFunctionBox
    var lir: LIRFunction
    var issues: [String] = []

    /// The LIR block instructions are appended to, and the layout order of blocks.
    var cur = 0
    var order: [Int] = []
    /// The first LIR block of each AIR block.
    var blockOf: [Int] = []
    /// The LIR value of each AIR instruction and parameter.
    var vals: [X86Val] = []
    var paramVals: [X86Val] = []
    /// The address of each aggregate parameter's copy (rematerialized at each use).
    var paramAddress: [LIRAddress?] = []
    var useCount: [UInt32] = []
    var folded: [Bool] = []
    /// The LIR slot of each AIR slot.
    var slotMap: [UInt32] = []
    /// Per (AIR predecessor block, phi instruction): the value the predecessor supplies.
    var phiInputs: [UInt64: X86Val] = [:]
    /// Per AIR phi instruction of type `f80`: the slot its predecessors write (copied to the phi's own slot on entry,
    /// so that writing it does not change the phi's value on another path).
    var phiIncomingSlot: [UInt32: UInt32] = [:]
    /// Constant pool labels by contents.
    var constantLabels: [[UInt8]: UInt32] = [:]
    /// The C type information of the function.
    var layout: X86CallLayout!
    var sretPointer: LIRReg = .none
    /// Stack bytes of named arguments (for `va_start`'s overflow area), and register counts.
    var namedStackBytes = 0
    var namedGPRs = 0
    var namedSSEs = 0
    let functionIndex: Int

    init(ctx: X86ModuleContext, function: Int) {
        self.ctx = ctx
        self.box = ctx.module.functions[function]
        self.functionIndex = function
        self.lir = LIRFunction(name: X86ModuleContext.asmName(ctx.module.symbols[box.function.symbol]))
    }

    // MARK: - AIR access

    func op(_ i: InstId) -> AIROpcode { box.function.op(i) }
    func o0(_ i: InstId) -> ValueId { ValueId(box.function.op0[i]) }
    func o1(_ i: InstId) -> ValueId { ValueId(box.function.op1[i]) }
    func aux(_ i: InstId) -> UInt32 { box.function.aux[i] }
    func list(_ i: InstId) -> [UInt32] { box.function.extraList(box.function.aux[i]) }
    func ty(_ v: ValueId) -> AIRType { box.function.valueType(v) }
    func resultType(_ i: InstId) -> AIRType { box.function.resultType(i) }

    func report(_ message: String) {
        issues.append("\(lir.name): \(message)")
    }

    // MARK: - Emission

    func emit(_ op: LIROp, _ size: Int, cond: X86Cond = .o, lock: Bool = false, _ ops: LIROperand...) {
        lir.append(cur, op, size: size, cond: cond, lock: lock, ops)
    }

    func emit(_ op: LIROp, _ size: Int, cond: X86Cond = .o, lock: Bool = false, operands ops: [LIROperand]) {
        lir.append(cur, op, size: size, cond: cond, lock: lock, ops)
    }

    func newGPR() -> LIRReg { lir.newVReg(.gpr) }
    func newXMM() -> LIRReg { lir.newVReg(.xmm) }

    /// A new LIR block of the current AIR block, placed after `after` in the layout.
    func newBlock(after: Int? = nil) -> Int {
        lir.blocks.append(LIRBlock())
        let b = lir.blocks.count - 1
        lir.blocks[b].airBlock = lir.blocks[cur].airBlock
        let anchor = after ?? order.last!
        if let k = order.lastIndex(of: anchor) { order.insert(b, at: k + 1) } else { order.append(b) }
        return b
    }

    func jump(_ target: Int) {
        emit(.jmp, 8, .block(target))
        lir.blocks[cur].successors.append(target)
    }

    func branch(_ c: X86Cond, _ target: Int) {
        emit(.jcc, 8, cond: c, .block(target))
        if !lir.blocks[cur].successors.contains(target) { lir.blocks[cur].successors.append(target) }
    }

    /// Branches to `t` if `c` holds and to `f` otherwise, ending the current block.
    func branch(_ c: X86Condition, _ t: Int, _ f: Int) {
        switch c {
        case .single(let cc):
            branch(cc, t)
        case .both(let c1, let c2):
            branch(c1.inverted, f)
            branch(c2, t)
        case .either(let c1, let c2):
            branch(c1, t)
            branch(c2, t)
        }
        jump(f)
    }

    func copy(_ dst: LIRReg, _ src: LIRReg, _ size: Int = 8) {
        emit(.copy, size, .def(dst, size), .use(src, size))
    }

    /// A copy of a GPR value in a new register.
    func copied(_ src: LIRReg, _ size: Int = 8) -> LIRReg {
        let r = lir.regClass(of: src) == .xmm ? newXMM() : newGPR()
        copy(r, src, size)
        return r
    }

    // MARK: - Selection

    func run() -> LIRFunction {
        let blockCount = Int(box.function.blockCount)
        let instCount = Int(box.function.instructionCount)
        vals = [X86Val](repeating: .none, count: instCount)
        slotMap = box.function.slots.map { lir.newSlot(size: $0.size, alignment: $0.alignment) }
        countUses()

        // Block 0 receives the arguments; each AIR block starts a block of its own
        lir.blocks.append(LIRBlock())
        order.append(0)
        blockOf = [Int](repeating: 0, count: blockCount)
        for b in 1..<blockCount {
            lir.blocks.append(LIRBlock())
            lir.blocks[b].airBlock = UInt32(b)
            blockOf[b] = b
            order.append(b)
        }
        for b in box.function.addressTakenBlocks { lir.blocks[blockOf[Int(b.rawIndex)]].addressTaken = true }
        cur = 0
        lowerEntry()
        jump(blockOf[1])

        for b in 1..<blockCount {
            cur = blockOf[b]
            for raw in box.function.instructions(of: BlockId(UInt32(b))) {
                let i = InstId(raw)
                if folded[Int(raw)] { continue }
                select(i)
            }
        }
        buildPhis()
        // Lay the blocks out in selection order
        let renumber = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        lir.relabel(renumber)
        lir.airBlockMap = blockOf.map { renumber[$0] ?? 0 }
        lir.computePredecessors()
        return lir
    }

    /// Use counts, and which instructions fold into their single user.
    func countUses() {
        let n = Int(box.function.instructionCount)
        useCount = [UInt32](repeating: 0, count: n)
        folded = [Bool](repeating: false, count: n)
        var user = [UInt32](repeating: 0, count: n)
        func use(_ v: ValueId, by i: UInt32) {
            guard v.rawIndex != 0, v.valueTag == .inst, Int(v.index) < n else { return }
            useCount[Int(v.index)] += 1
            user[Int(v.index)] = i
        }
        for raw in 1..<UInt32(n) {
            let i = InstId(raw)
            let o = op(i)
            let fields = o.fields
            if fields.op0 == .value { use(o0(i), by: raw) }
            if fields.op1 == .value { use(o1(i), by: raw) }
            if fields.aux == .value { use(ValueId(aux(i)), by: raw) }
            let items = o.hasExtra ? list(i) : []
            switch o {
            case .copy, .fill, .cmpxchg: if let first = items.first { use(ValueId(first), by: raw) }
            case .call: for a in items.dropFirst(2) { use(ValueId(a), by: raw) }
            case .phi: for k in stride(from: 1, to: items.count, by: 2) { use(ValueId(items[k]), by: raw); use(ValueId(items[k]), by: 0) }
            case .inlineAsm, .asmGoto:
                for p in AIRAsm.valuePositions(items).values { use(ValueId(items[p]), by: raw) }
            default: break
            }
        }
        for raw in 1..<UInt32(n) where useCount[Int(raw)] == 1 && user[Int(raw)] != 0 {
            let i = InstId(raw), u = InstId(user[Int(raw)])
            guard box.function.block(of: i) == box.function.block(of: u) else { continue }
            let v = ValueId.instResult(i)
            switch op(i) {
            case .ptrAdd:
                // Into the address of a memory access
                switch op(u) {
                case .load, .atomicLoad, .atomicRMW, .cmpxchg: folded[Int(raw)] = o0(u) == v
                case .store, .atomicStore: folded[Int(raw)] = o1(u) == v && o0(u) != v
                default: break
                }
            case .icmp, .fcmp:
                // Into a branch or a select
                if (op(u) == .condBr || op(u) == .select) && o0(u) == v {
                    let t = ty(o0(i))
                    folded[Int(raw)] = !(t.isFloat && t.width == 16)
                }
            default:
                break
            }
        }
    }

    func select(_ i: InstId) {
        let o = op(i)
        switch o {
        case .nilOp, .dead, .alloca:
            break
        case .load: vals[idx(i)] = load(o0(i), type: resultType(i), flags: AIRMemFlags(rawValue: aux(i)))
        case .store: store(o0(i), to: o1(i), flags: AIRMemFlags(rawValue: aux(i)))
        case .copy:
            let items = list(i)
            copyMemory(to: o0(i), from: o1(i), size: ValueId(items[0]))
        case .fill:
            let items = list(i)
            fillMemory(o0(i), byte: o1(i), size: ValueId(items[0]))
        case .ptrAdd: vals[idx(i)] = .reg(lea(addressOf(.instResult(i))))
        case .dynAlloca: vals[idx(i)] = .reg(dynamicAlloca(o0(i), alignment: Int(aux(i))))
        case .stackSave:
            let r = newGPR()
            emit(.mov, 8, .def(r, 8), .use(.physical(.rsp), 8))
            vals[idx(i)] = .reg(r)
        case .stackRestore:
            emit(.mov, 8, .def(.physical(.rsp), 8), .use(gpr(o0(i)), 8))
        case .tlsAddr: vals[idx(i)] = .reg(tlsAddress(o0(i)))
        case .blockAddr:
            let target = blockOf[Int(aux(i))]
            lir.blocks[target].addressTaken = true
            let r = newGPR()
            emit(.lea, 8, .def(r, 8), LIROperand(kind: .mem, size: 8, value: Int64(target)).withBlockSymbol())
            vals[idx(i)] = .reg(r)
        case .add, .sub, .mul, .sdiv, .udiv, .srem, .urem, .and, .or, .xor, .shl, .lshr, .ashr:
            vals[idx(i)] = integerBinary(o, resultType(i), o0(i), o1(i))
        case .fadd, .fsub, .fmul, .fdiv:
            vals[idx(i)] = floatBinary(o, resultType(i), o0(i), o1(i))
        case .fneg, .fabs:
            vals[idx(i)] = floatUnary(o, resultType(i), o0(i))
        case .bswap, .clz, .ctz, .popcount:
            vals[idx(i)] = bitOperation(o, resultType(i), o0(i))
        case .icmp, .fcmp:
            vals[idx(i)] = .reg(materialize(condition(i)))
        case .select:
            vals[idx(i)] = selectValue(i)
        case .trunc, .zext, .sext, .fptrunc, .fpext, .fptosi, .fptoui, .sitofp, .uitofp, .ptrtoint, .inttoptr, .bitcast:
            vals[idx(i)] = convert(o, from: ty(o0(i)), to: resultType(i), o0(i))
        case .call: vals[idx(i)] = lowerCall(i)
        case .vaStart: vaStart(o0(i))
        case .vaEnd: break
        case .vaCopy: copyMemory(to: o0(i), from: o1(i), constantSize: 24, alignment: 8)
        case .vaArg: vals[idx(i)] = .reg(vaArg(o0(i), type: TypeId(aux(i))))
        case .atomicLoad, .atomicStore, .atomicRMW, .cmpxchg, .fence:
            vals[idx(i)] = atomic(i)
        case .inlineAsm, .asmGoto:
            inlineAsm(i)
        case .frameAddress, .returnAddress:
            vals[idx(i)] = .reg(frameOrReturnAddress(o == .returnAddress, level: Int(aux(i))))
        case .phi:
            vals[idx(i)] = phiValue(i)
        case .br:
            materializePhiInputs()
            jump(blockOf[Int(aux(i))])
        case .condBr:
            materializePhiInputs()
            let t = blockOf[Int(o1(i).rawIndex)], f = blockOf[Int(aux(i))]
            branch(branchCondition(o0(i)), t, f)
        case .switch:
            materializePhiInputs()
            lowerSwitch(i)
        case .indirectBr:
            materializePhiInputs()
            let target = gpr(o0(i))
            emit(.jmpIndirect, 8, .use(target, 8))
            for b in list(i) {
                let t = blockOf[Int(b)]
                lir.blocks[t].addressTaken = true
                if !lir.blocks[cur].successors.contains(t) { lir.blocks[cur].successors.append(t) }
            }
        case .ret: lowerReturn(o0(i))
        case .unreachable, .trap:
            emit(.ud2, 0)
        }
    }

    @inline(__always) func idx(_ i: InstId) -> Int { Int(i.rawIndex) }

    // MARK: - Values

    /// The value of `v` as AIR computed it: instruction results, parameters, constants and globals.
    func value(_ v: ValueId) -> X86Val {
        let t = ty(v)
        switch v.valueTag {
        case .inst:
            let i = v.inst
            switch op(i) {
            case .alloca:
                return .reg(lea(.slot(slotMap[Int(aux(i))])))
            default:
                if case .none = vals[Int(v.index)] {
                    // A folded value used elsewhere after all, or one used before its block was selected: computed here
                    if folded[Int(v.index)] || op(i) == .icmp || op(i) == .fcmp || op(i) == .ptrAdd {
                        let saved = folded[Int(v.index)]
                        folded[Int(v.index)] = false
                        select(i)
                        folded[Int(v.index)] = saved
                        let r = vals[Int(v.index)]
                        vals[Int(v.index)] = .none
                        return r
                    }
                    report("value %\(v.index) (\(op(i).name)) used before it is computed")
                    return .reg(newGPR())
                }
                return vals[Int(v.index)]
            }
        case .parameter:
            if let a = paramAddress[Int(v.index)] { return .reg(lea(a)) }
            return paramVals[Int(v.index)]
        case .global:
            return .reg(lea(globalAddress(Int(v.index))))
        case .constant:
            return constant(v, t)
        }
    }

    func gpr(_ v: ValueId) -> LIRReg {
        switch value(v) {
        case .reg(let r): return r
        case .pair(let lo, _): return lo
        case .slot(let s):
            let r = newGPR()
            emit(.mov, 8, .def(r, 8), LIRAddress.slot(s).operand(size: 8))
            return r
        case .none:
            report("no value for \(v.rawIndex)")
            return newGPR()
        }
    }

    func xmm(_ v: ValueId) -> LIRReg {
        if case .reg(let r) = value(v) { return r }
        report("no XMM value for \(v.rawIndex)")
        return newXMM()
    }

    func pair(_ v: ValueId) -> (LIRReg, LIRReg) {
        switch value(v) {
        case .pair(let lo, let hi): return (lo, hi)
        case .reg(let r):
            let hi = newGPR()
            emit(.zero, 4, .def(hi, 4))
            return (r, hi)
        default:
            report("no register pair for \(v.rawIndex)")
            return (newGPR(), newGPR())
        }
    }

    /// The slot of an `f80` value.
    func slot(_ v: ValueId) -> UInt32 {
        if case .slot(let s) = value(v) { return s }
        report("no slot for \(v.rawIndex)")
        return lir.newSlot(size: 16, alignment: 16)
    }

    func newValueSlot(_ t: AIRType) -> UInt32 {
        lir.newSlot(size: 16, alignment: 16)
    }

    /// The bits of an integer constant, sign-extended from its width.
    func constantInt(_ v: ValueId) -> Int64? {
        guard v.valueTag == .constant else { return nil }
        let t = box.function.constants.type(v.index)
        guard t.isInt || t.isPointer, t.width <= 64 else { return nil }
        return box.function.constants.int64(v.index, signed: true)
    }

    func constantWords(_ v: ValueId) -> [UInt64] { Array(box.function.constants.words(v.index)) }

    /// An immediate operand for `v` if it is a constant that fits a sign-extended 32-bit field at `size` bytes.
    func immediate(_ v: ValueId, size: Int) -> Int64? {
        guard let c = constantInt(v) else { return nil }
        let t = ty(v)
        // At a size wider than the type, the operand is the type's bits sign-extended (the high bits are unspecified)
        let value: Int64
        if size == 8 && t.width < 64 && t.width > 32 { return nil }
        value = c
        return value >= Int64(Int32.min) && value <= Int64(Int32.max) ? value : nil
    }

    func constant(_ v: ValueId, _ t: AIRType) -> X86Val {
        let words = constantWords(v)
        switch t.kind {
        case .int, .pointer:
            if t.width > 128 { return wideConstant(words, width: t.width) }
            if t.width > 64 {
                let lo = materializeInt(Int64(bitPattern: words.first ?? 0), size: 8)
                var hiWord = words.count > 1 ? words[1] : 0
                if t.width < 128, t.width > 64, (hiWord >> UInt64(t.width - 65)) & 1 == 1 { hiWord |= ~0 << UInt64(t.width - 64) }
                if t.width > 128 { report("integer constant of \(t.width) bits") }
                return .pair(lo, materializeInt(Int64(bitPattern: hiWord), size: 8))
            }
            return .reg(materializeInt(constantInt(v) ?? 0, size: t.width > 32 ? 8 : 4))
        case .float:
            if t.width == 80 {
                let s = newValueSlot(t)
                var bytes = [UInt8](repeating: 0, count: 16)
                for k in 0..<8 { bytes[k] = UInt8(truncatingIfNeeded: (words.first ?? 0) >> UInt64(8 * k)) }
                let hi = words.count > 1 ? words[1] : 0
                bytes[8] = UInt8(truncatingIfNeeded: hi)
                bytes[9] = UInt8(truncatingIfNeeded: hi >> 8)
                let label = constantLabel(bytes, alignment: 16)
                emit(.fldt, 10, LIRAddress.symbol(label).operand(size: 10))
                emit(.fstpt, 10, LIRAddress.slot(s).operand(size: 10))
                return .slot(s)
            }
            let r = newXMM()
            if words.allSatisfy({ $0 == 0 }) {
                emit(.zero, 16, .def(r, 16))
                return .reg(r)
            }
            let size = t.width / 8
            var bytes: [UInt8] = []
            for k in 0..<size { bytes.append(UInt8(truncatingIfNeeded: words[k / 8] >> UInt64(8 * (k % 8)))) }
            let label = constantLabel(bytes, alignment: size)
            switch t.width {
            case 32: emit(.movss, 4, .def(r, 16), LIRAddress.symbol(label).operand(size: 4))
            case 64: emit(.movsd, 8, .def(r, 16), LIRAddress.symbol(label).operand(size: 8))
            case 16:
                let g = newGPR()
                emit(.movzw, 4, .def(g, 4), LIRAddress.symbol(label).operand(size: 2))
                emit(.movd, 4, .def(r, 16), .use(g, 4))
            default: emit(.movaps, 16, .def(r, 16), LIRAddress.symbol(label).operand(size: 16))
            }
            return .reg(r)
        case .void:
            return .none
        }
    }

    func materializeInt(_ c: Int64, size: Int) -> LIRReg {
        let r = newGPR()
        if size == 4 || (c >= 0 && c <= Int64(UInt32.max)) {
            emit(.mov, 4, .def(r, 4), .imm(Int64(UInt32(truncatingIfNeeded: c))))
        } else if c >= Int64(Int32.min) && c <= Int64(Int32.max) {
            emit(.mov, 8, .def(r, 8), .imm(c))
        } else {
            emit(.movabs, 8, .def(r, 8), .imm(c))
        }
        return r
    }

    /// The label of a read-only constant with `bytes` (shared within the function).
    func constantLabel(_ bytes: [UInt8], alignment: Int) -> UInt32 {
        if let l = constantLabels[bytes] { return l }
        let label = ctx.symbols.intern(".LCPI\(functionIndex)_\(lir.constants.count)")
        lir.constants.append((label, bytes, max(alignment, bytes.count >= 16 ? 16 : alignment)))
        constantLabels[bytes] = label
        return label
    }

    // MARK: - Addresses

    func lea(_ a: LIRAddress) -> LIRReg {
        if a.slot == 0 && a.symbol == 0 && a.index.isNone && a.disp == 0 && !a.base.isNone && a.segment == 0 { return a.base }
        let r = newGPR()
        emit(.lea, 8, .def(r, 8), a.operand(size: 8))
        return r
    }

    /// The address of global `index`: RIP-relative if the module defines it, else through the GOT.
    func globalAddress(_ index: Int) -> LIRAddress {
        let s = ctx.symbolOf[index]
        if ctx.isDefined(index) { return .symbol(s) }
        let r = newGPR()
        emit(.mov, 8, .def(r, 8), LIRAddress(symbol: s, modifier: .gotpcrel).operand(size: 8))
        return LIRAddress(base: r)
    }

    /// The address `v` names, folding a single-use `ptradd` chain, an `alloca` or a global into it.
    func addressOf(_ v: ValueId) -> LIRAddress {
        switch v.valueTag {
        case .global:
            return globalAddress(Int(v.index))
        case .inst:
            let i = v.inst
            if op(i) == .alloca { return .slot(slotMap[Int(aux(i))]) }
            if op(i) == .ptrAdd && (folded[Int(v.index)] || vals[Int(v.index)].isNone) {
                var a = addressOf(o0(i))
                let off = o1(i)
                if let c = constantInt(off) {
                    let d = a.disp + c
                    if d >= Int64(Int32.min) && d <= Int64(Int32.max) {
                        a.disp = d
                        return a
                    }
                }
                // A base plus a register index (RIP-relative addresses take no index)
                if a.index.isNone && a.symbol == 0 {
                    a.index = gpr(off)
                    a.scale = 1
                    return a
                }
                let base = lea(a)
                return LIRAddress(base: base, index: gpr(off))
            }
            return LIRAddress(base: gpr(v))
        case .parameter:
            if let a = paramAddress[Int(v.index)] { return a }
            return LIRAddress(base: gpr(v))
        default:
            return LIRAddress(base: gpr(v))
        }
    }

    func tlsAddress(_ global: ValueId) -> LIRReg {
        let index = Int(global.index)
        let s = ctx.symbolOf[index]
        let r = newGPR()
        emit(.mov, 8, .def(r, 8), LIROperand(kind: .mem, size: 8, segment: 4, value: 0))
        if ctx.isDefined(index) {
            // Local exec
            let a = newGPR()
            emit(.lea, 8, .def(a, 8), LIRAddress(base: r, symbol: s, modifier: .tpoff).operand(size: 8))
            return a
        }
        // Initial exec
        emit(.add, 8, .useDef(r, 8), LIRAddress(symbol: s, modifier: .gottpoff).operand(size: 8))
        return r
    }

    func frameOrReturnAddress(_ isReturn: Bool, level: Int) -> LIRReg {
        var fp = newGPR()
        emit(.mov, 8, .def(fp, 8), .use(.physical(.rbp), 8))
        for _ in 0..<level {
            let next = newGPR()
            emit(.mov, 8, .def(next, 8), LIRAddress(base: fp).operand(size: 8))
            fp = next
        }
        guard isReturn else { return fp }
        let r = newGPR()
        emit(.mov, 8, .def(r, 8), LIRAddress(base: fp, disp: 8).operand(size: 8))
        return r
    }

    func dynamicAlloca(_ size: ValueId, alignment: Int) -> LIRReg {
        lir.hasDynamicAlloca = true
        let n = copied(gpr(size))
        emit(.add, 8, .useDef(n, 8), .imm(15))
        emit(.and, 8, .useDef(n, 8), .imm(-16))
        emit(.sub, 8, .useDef(.physical(.rsp), 8), .use(n, 8))
        if alignment > 16 { emit(.and, 8, .useDef(.physical(.rsp), 8), .imm(Int64(-alignment))) }
        let r = newGPR()
        emit(.mov, 8, .def(r, 8), .use(.physical(.rsp), 8))
        return r
    }

    // MARK: - Phis

    func phiValue(_ i: InstId) -> X86Val {
        let t = resultType(i)
        if isSlotType(t) {
            // Copied from the incoming slot on entry
            let incoming = incomingSlot(i.rawIndex, t)
            let s = t.isInt ? wideSlot(t.width) : newValueSlot(t)
            copySlotValue(from: incoming, to: s, t)
            return .slot(s)
        }
        if t.isInt && t.width > 64 { return .pair(newGPR(), newGPR()) }
        return .reg(t.isFloat ? newXMM() : newGPR())
    }

    /// The slot the predecessors of `f80` phi `raw` write its value to (made by whichever is selected first).
    func incomingSlot(_ raw: UInt32, _ t: AIRType) -> UInt32 {
        if let s = phiIncomingSlot[raw] { return s }
        let s = t.isInt ? wideSlot(t.width) : lir.newSlot(size: 16, alignment: 16)
        phiIncomingSlot[raw] = s
        return s
    }

    /// Before a terminator: the value each successor's phis take from this block, in registers (or, for `f80`,
    /// written to the phi's incoming slot).
    func materializePhiInputs() {
        let airBlock = BlockId(lir.blocks[cur].airBlock)
        for s in box.function.successors(of: airBlock) {
            for raw in box.function.instructions(of: s) {
                let i = InstId(raw)
                guard op(i) == .phi else { break }
                let items = list(i)
                for k in stride(from: 0, to: items.count - 1, by: 2) where items[k] == airBlock.rawIndex {
                    let v = ValueId(items[k + 1])
                    let key = UInt64(airBlock.rawIndex) << 32 | UInt64(raw)
                    let t = resultType(i)
                    if isSlotType(t) {
                        copySlotValue(from: slot(v), to: incomingSlot(raw, t), t)
                        phiInputs[key] = .none
                    } else {
                        phiInputs[key] = value(v)
                    }
                }
            }
        }
    }

    /// Builds the LIR phis of every AIR phi from the inputs its predecessors materialized.
    func buildPhis() {
        var lirPreds = [[Int]](repeating: [], count: lir.blocks.count)
        for b in lir.blocks.indices { for s in lir.blocks[b].successors where !lirPreds[s].contains(b) { lirPreds[s].append(b) } }
        for b in 1..<Int(box.function.blockCount) {
            let lb = blockOf[b]
            for raw in box.function.instructions(of: BlockId(UInt32(b))) {
                let i = InstId(raw)
                guard op(i) == .phi else { break }
                let t = resultType(i)
                if isSlotType(t) { continue }
                var lo: [(block: Int, reg: LIRReg)] = [], hi: [(block: Int, reg: LIRReg)] = []
                for p in lirPreds[lb] {
                    let key = UInt64(lir.blocks[p].airBlock) << 32 | UInt64(raw)
                    switch phiInputs[key] ?? .none {
                    case .reg(let r): lo.append((p, r))
                    case .pair(let l, let h): lo.append((p, l)); hi.append((p, h))
                    default: report("phi %\(raw) has no value from block \(p)")
                    }
                }
                switch vals[Int(raw)] {
                case .reg(let r): lir.blocks[lb].phis.append(LIRPhi(def: r, incoming: lo))
                case .pair(let l, let h):
                    lir.blocks[lb].phis.append(LIRPhi(def: l, incoming: lo))
                    lir.blocks[lb].phis.append(LIRPhi(def: h, incoming: hi))
                default: break
                }
            }
        }
    }
}

extension X86Val {
    var isNone: Bool { if case .none = self { return true } else { return false } }
}

extension LIROperand {
    /// A memory operand naming a block's label (`lea .LBB(%rip)`): `value` is the block, `symbol` stays 0.
    func withBlockSymbol() -> LIROperand {
        var o = self
        o.modifier = .none
        o.slot = UInt32.max
        return o
    }

    var isBlockAddress: Bool { kind == .mem && slot == UInt32.max }
}

extension LIRFunction {
    /// Renumbers blocks: `map[old] = new`.
    mutating func relabel(_ map: [Int: Int]) {
        var newBlocks = [LIRBlock](repeating: LIRBlock(), count: blocks.count)
        for (old, b) in blocks.enumerated() {
            var nb = b
            nb.successors = b.successors.map { map[$0]! }
            nb.phis = b.phis.map { LIRPhi(def: $0.def, incoming: $0.incoming.map { (map[$0.block]!, $0.reg) }) }
            newBlocks[map[old]!] = nb
        }
        blocks = newBlocks
        for k in operands.indices where operands[k].kind == .block || operands[k].isBlockAddress {
            operands[k].value = Int64(map[Int(operands[k].value)]!)
        }
        jumpTables = jumpTables.map { $0.map { map[$0]! } }
        for k in asmStatements.indices {
            asmStatements[k].labels = asmStatements[k].labels.map { map[$0]! }
            asmStatements[k].block = map[asmStatements[k].block]!
        }
    }
}
