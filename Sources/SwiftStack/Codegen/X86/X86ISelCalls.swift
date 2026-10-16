// Sources/SwiftStack/Codegen/X86/X86ISelCalls.swift
//
// Calls, function entry and return, and variable arguments, by the System V x86-64 convention (04 §4.7.1).

import Foundation

/// An argument of a call, as instruction selection has it.
enum X86OutArg {
    /// An integer (or pointer) of `size` bytes in a GPR.
    case gpr(LIRReg, Int)
    /// A float in an XMM register (`wide`: a 16-byte `_Float128`).
    case xmm(LIRReg, wide: Bool)
    /// An integer of two words, and its alignment (16 for `__int128`, 8 for `_BitInt(65...128)`).
    case pair(LIRReg, LIRReg, alignment: Int = 16)
    /// An `f80` value in a slot.
    case x87(UInt32)
    /// An aggregate in memory at an address, passed as its ABI classification says.
    case aggregate(LIRAddress, X86ABIArgInfo)

    var info: X86ABIArgInfo {
        switch self {
        case .gpr: return X86ABIArgInfo(kind: .direct, parts: [.init(isSSE: false, offset: 0, size: 8)], size: 8, alignment: 8)
        case .xmm(_, let wide):
            return X86ABIArgInfo(kind: .direct, parts: [.init(isSSE: true, offset: 0, size: wide ? 16 : 8)], size: wide ? 16 : 8,
                                 alignment: wide ? 16 : 8)
        case .pair(_, _, let alignment):
            return X86ABIArgInfo(kind: .direct, parts: [.init(isSSE: false, offset: 0, size: 8), .init(isSSE: false, offset: 8, size: 8)],
                                 size: 16, alignment: alignment)
        case .x87: return X86ABIArgInfo(kind: .memory, size: 16, alignment: 16)
        case .aggregate(_, let info): return info
        }
    }
}

/// An argument of a runtime call.
enum X86LibArg {
    case gpr(LIRReg, Int)
    case xmm(LIRReg)
    case pair(LIRReg, LIRReg)
    case x87(UInt32)
}

enum X86LibResult {
    case none, gpr(Int), xmm, pair, x87
}

/// What happens to a call's result.
enum X86CallResult {
    /// Nothing (an `x87` result is popped).
    case discard
    /// Copied out of the result registers into new registers, one per part.
    case registers
    /// Written by the callee through the hidden pointer, which is this address.
    case memory(LIRAddress)
    /// Popped from the x87 stack to this address.
    case x87(LIRAddress)
}

extension X86FunctionISel {
    var types: TypePool { ctx.module.typePool }

    func isAggregate(_ t: TypeId) -> Bool {
        switch types.typeInfo(of: types.canonical(of: t)).kind {
        case .struct, .array: return true
        default: return false
        }
    }

    func functionParts(_ fnType: TypeId) -> (ret: QualType, params: [QualType], variadic: Bool) {
        if case .function(let r, let p, let v) = types.typeInfo(of: types.canonical(of: fnType)).kind { return (r, p, v) }
        return (QualType(typeId: .void), [], false)
    }

    func info(_ t: QualType, isResult: Bool) -> X86ABIArgInfo { ctx.abi.info(t.typeId, isResult: isResult) }

    // MARK: - The call sequence

    /// Emits a call of `target` (a symbol, or a register) with `args`, and returns the result registers (for
    /// `.registers`: one per part of `result`).
    @discardableResult
    func emitCall(symbol: String?, register: LIRReg?, args: [X86OutArg], result: X86ABIArgInfo, handling: X86CallResult,
                  variadic: Bool) -> [LIRReg] {
        lir.hasCalls = true
        let layout = X86CallLayout(args: args.map(\.info), result: result)
        // Values to move into argument registers once everything else is done (so that nothing in between needs a
        // fixed register): (register, value, size)
        var moves: [(PhysReg, LIRReg, Int)] = []
        if layout.stackBytes > 0 {
            emit(.callFrameSetup, 8, .imm(Int64(layout.stackBytes)))
            lir.maxOutgoingArgs = max(lir.maxOutgoingArgs, layout.stackBytes)
        }
        for (k, arg) in args.enumerated() {
            switch layout.args[k] {
            case .ignored:
                break
            case .stack(let offset):
                let at = LIRAddress(base: .physical(.rsp), disp: Int64(offset))
                switch arg {
                case .gpr(let r, let size): emit(.mov, 8, at.operand(size: 8), .use(r, max(size, 8)))
                case .xmm(let r, let wide):
                    emit(wide ? .movups : .movsd, wide ? 16 : 8, at.operand(size: wide ? 16 : 8), .use(r, 16))
                case .pair(let lo, let hi, _):
                    emit(.mov, 8, at.operand(size: 8), .use(lo, 8))
                    emit(.mov, 8, at.adding(8).operand(size: 8), .use(hi, 8))
                case .x87(let s):
                    emit(.fldt, 10, LIRAddress.slot(s).operand(size: 10))
                    emit(.fstpt, 10, at.operand(size: 10))
                case .aggregate(let a, let info):
                    copyBytes(to: at, from: a, info.size)
                }
            case .registers(let regs):
                switch arg {
                case .gpr(let r, let size): moves.append((regs[0], r, max(size, 4) == 4 ? 4 : 8))
                case .xmm(let r, _): moves.append((regs[0], r, 16))
                case .pair(let lo, let hi, _):
                    moves.append((regs[0], lo, 8))
                    moves.append((regs[1], hi, 8))
                case .x87:
                    break
                case .aggregate(let a, let info):
                    for (p, part) in info.parts.enumerated() {
                        let at = a.adding(Int64(part.offset))
                        if part.isSSE {
                            let r = newXMM()
                            switch part.size {
                            case 4: emit(.movss, 4, .def(r, 16), at.operand(size: 4))
                            case 16: emit(.movups, 16, .def(r, 16), at.operand(size: 16))
                            default: emit(.movsd, 8, .def(r, 16), at.operand(size: 8))
                            }
                            moves.append((regs[p], r, 16))
                        } else {
                            moves.append((regs[p], loadBytes(at, part.size), 8))
                        }
                    }
                }
            }
        }
        var hidden: LIRReg?
        if case .memory(let a) = handling { hidden = lea(a) }
        let target: LIRReg? = register
        var operands: [LIROperand] = []
        if let symbol {
            let s = ctx.symbols.intern(symbol)
            let defined = ctx.module.symbol(named: symbol).map { ctx.isDefined($0) } ?? false
            if !defined { ctx.referencedExternals.insert(symbol) }
            operands.append(.symbol(s, defined ? .none : .plt))
        } else if let target {
            operands.append(.use(target, 8))
        }
        if let hidden { emit(.copy, 8, .def(.physical(.rdi), 8), .use(hidden, 8)) }
        for (reg, value, size) in moves { emit(.copy, size, .def(.physical(reg), size), .use(value, size)) }
        var used: [PhysReg] = moves.map(\.0)
        if hidden != nil { used.append(.rdi) }
        if variadic {
            emit(.mov, 4, .def(.physical(.rax), 4), .imm(Int64(layout.sseRegistersUsed)))
            used.append(.rax)
        }
        for r in used { operands.append(.implicitUse(r)) }
        for r in PhysReg.allCases where r.isCallerSaved && r != .rsp { operands.append(.implicitDef(r)) }
        emit(symbol != nil ? .call : .callIndirect, 8, operands: operands)
        if layout.stackBytes > 0 { emit(.callFrameDestroy, 8, .imm(Int64(layout.stackBytes))) }

        switch handling {
        case .discard:
            if result.kind == .x87 { emit(.fstp, 10, .imm(0)) }
            return []
        case .memory:
            return []
        case .x87(let a):
            emit(.fstpt, 10, a.operand(size: 10))
            return []
        case .registers:
            var out: [LIRReg] = []
            var gprs: [PhysReg] = [.rax, .rdx], sses: [PhysReg] = [.xmm0, .xmm1]
            for part in result.parts {
                if part.isSSE {
                    let r = newXMM()
                    copy(r, .physical(sses.removeFirst()), 16)
                    out.append(r)
                } else {
                    let r = newGPR()
                    copy(r, .physical(gprs.removeFirst()), 8)
                    out.append(r)
                }
            }
            return out
        }
    }

    // MARK: - Runtime calls

    func libcall(_ name: String, _ args: [X86LibArg], result: X86LibResult) -> X86Val {
        let outs: [X86OutArg] = args.map {
            switch $0 {
            case .gpr(let r, let s): return .gpr(r, s)
            case .xmm(let r): return .xmm(r, wide: true)
            case .pair(let lo, let hi): return .pair(lo, hi)
            case .x87(let s): return .x87(s)
            }
        }
        // Libcalls take `_Float128` values whole and floats of 32/64 bits in the low part; both are one XMM register
        var info: X86ABIArgInfo
        switch result {
        case .none: info = X86ABIArgInfo(kind: .ignore, size: 0, alignment: 1)
        case .gpr: info = X86ABIArgInfo(kind: .direct, parts: [.init(isSSE: false, offset: 0, size: 8)], size: 8, alignment: 8)
        case .xmm: info = X86ABIArgInfo(kind: .direct, parts: [.init(isSSE: true, offset: 0, size: 16)], size: 16, alignment: 16)
        case .pair: info = X86OutArg.pair(.none, .none).info
        case .x87: info = X86ABIArgInfo(kind: .x87, size: 16, alignment: 16)
        }
        if case .x87 = result {
            let s = newValueSlot(.float(80))
            emitCall(symbol: name, register: nil, args: outs, result: info, handling: .x87(.slot(s)), variadic: false)
            return .slot(s)
        }
        let regs = emitCall(symbol: name, register: nil, args: outs, result: info, handling: .registers, variadic: false)
        switch result {
        case .none, .x87: return .none
        case .gpr, .xmm: return .reg(regs[0])
        case .pair: return .pair(regs[0], regs[1])
        }
    }

    func libcallXMM(_ name: String, _ args: [X86LibArg]) -> LIRReg {
        if case .reg(let r) = libcall(name, args, result: .xmm) { return r }
        return newXMM()
    }

    func libcallGPR(_ name: String, _ args: [X86LibArg], size: Int) -> LIRReg {
        if case .reg(let r) = libcall(name, args, result: .gpr(size)) { return r }
        return newGPR()
    }

    // MARK: - AIR calls

    /// An argument of C type `t` with AIR value `v`.
    func outArg(_ v: ValueId, type t: QualType) -> X86OutArg? {
        if isAggregate(t.typeId) {
            let i = info(t, isResult: false)
            if i.kind == .ignore { return nil }
            return .aggregate(addressOf(v), i)
        }
        let at = ty(v)
        switch at.kind {
        case .float:
            if at.width == 80 { return .x87(slot(v)) }
            return .xmm(xmm(v), wide: at.width == 128)
        case .int where at.width > 128:
            let n = Self.words(at.width)
            return .aggregate(.slot(wide(v)), X86ABIArgInfo(kind: .memory, size: 8 * n, alignment: 8))
        case .int where at.width > 64:
            let (lo, hi) = pair(v)
            return .pair(lo, hi, alignment: max(8, types.alignment(of: t.typeId)))
        case .int where at.width < 32:
            // The caller extends `bool`, `char` and `short` to 32 bits, as GCC and Clang do
            let signed = types.isSignedInteger(type: t.typeId) && at.width > 1
            return .gpr(extend(gpr(v), from: at.width, signed: signed), 4)
        case .int:
            return .gpr(gpr(v), at.width > 32 ? 8 : 4)
        default:
            return .gpr(gpr(v), 8)
        }
    }

    func lowerCall(_ i: InstId) -> X86Val {
        let items = list(i)
        let fnType = TypeId(items[0])
        let (ret, params, variadic) = functionParts(fnType)
        var args: [X86OutArg] = []
        for (k, raw) in items.dropFirst(2).enumerated() {
            let t = k < params.count ? params[k] : QualType(typeId: .void)
            if let a = outArg(ValueId(raw), type: t) { args.append(a) }
        }
        let callee = o0(i)
        var symbol: String?
        var register: LIRReg?
        if callee.valueTag == .global, ctx.symbol(Int(callee.index)).kind == .function {
            symbol = X86ModuleContext.asmName(ctx.symbol(Int(callee.index)))
        } else {
            register = gpr(callee)
        }
        let resultInfo = info(ret, isResult: true)
        let rt = resultType(i)
        if isAggregate(ret.typeId) {
            let dest = addressOf(o1(i))
            switch resultInfo.kind {
            case .memory:
                emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .memory(dest), variadic: variadic)
            case .x87:
                emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .x87(dest), variadic: variadic)
            case .ignore:
                emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .discard, variadic: variadic)
            case .direct:
                let regs = emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .registers,
                                    variadic: variadic)
                storeParts(regs, resultInfo, to: dest)
            }
            return .none
        }
        if rt.isVoid {
            emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .discard, variadic: variadic)
            return .none
        }
        if rt.isInt && rt.width > 128 {
            let s = wideSlot(rt.width)
            emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .memory(.slot(s)), variadic: variadic)
            return .slot(s)
        }
        if rt.isFloat && rt.width == 80 {
            let s = newValueSlot(rt)
            emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .x87(.slot(s)), variadic: variadic)
            return .slot(s)
        }
        let regs = emitCall(symbol: symbol, register: register, args: args, result: resultInfo, handling: .registers, variadic: variadic)
        if regs.count == 2 && !rt.isFloat { return .pair(regs[0], regs[1]) }
        return regs.isEmpty ? .none : .reg(regs[0])
    }

    /// Stores registers holding the parts of an aggregate at `dest`.
    func storeParts(_ regs: [LIRReg], _ info: X86ABIArgInfo, to dest: LIRAddress) {
        for (p, part) in info.parts.enumerated() {
            let at = dest.adding(Int64(part.offset))
            if part.isSSE {
                switch part.size {
                case 4: emit(.movss, 4, at.operand(size: 4), .use(regs[p], 16))
                case 16: emit(.movups, 16, at.operand(size: 16), .use(regs[p], 16))
                default: emit(.movsd, 8, at.operand(size: 8), .use(regs[p], 16))
                }
            } else {
                storeBytes(regs[p], at, part.size)
            }
        }
    }

    // MARK: - Entry and return

    func lowerEntry() {
        let (ret, _, variadic) = functionParts(box.function.cType)
        let paramTypes = cParamTypes()
        let resultInfo = info(ret, isResult: true)
        var infos: [X86ABIArgInfo] = []
        for (k, t) in paramTypes.enumerated() {
            let at = k < box.function.paramTypes.count ? box.function.paramTypes[k] : .ptr
            if isAggregate(t.typeId) { infos.append(info(t, isResult: false)); continue }
            switch at.kind {
            case .int where at.width > 128:
                infos.append(X86ABIArgInfo(kind: .memory, size: 8 * Self.words(at.width), alignment: 8))
            case .float where at.width == 80: infos.append(X86OutArg.x87(0).info)
            case .float: infos.append(X86OutArg.xmm(.none, wide: at.width == 128).info)
            case .int where at.width > 64:
                infos.append(X86OutArg.pair(.none, .none, alignment: max(8, types.alignment(of: t.typeId))).info)
            default: infos.append(X86OutArg.gpr(.none, 8).info)
            }
        }
        let layout = X86CallLayout(args: infos, result: resultInfo)
        self.layout = layout
        namedGPRs = layout.gprRegistersUsed
        namedSSEs = layout.sseRegistersUsed
        namedStackBytes = layout.stackBytes

        // The registers that carry arguments are defined on entry
        var entryDefs: [PhysReg] = variadic ? X86ABI.gprArgs + X86ABI.sseArgs : []
        if !variadic {
            if layout.resultInMemory { entryDefs.append(.rdi) }
            for case .registers(let regs) in layout.args { entryDefs += regs }
        }
        emit(.entry, 8, operands: entryDefs.map { .implicitDef($0) })
        if variadic {
            let area = lir.newSlot(size: 176, alignment: 16)
            lir.registerSaveArea = area
            for (k, r) in X86ABI.gprArgs.enumerated() {
                emit(.mov, 8, LIRAddress.slot(area, Int64(8 * k)).operand(size: 8), .use(.physical(r), 8))
            }
            for (k, r) in X86ABI.sseArgs.enumerated() {
                emit(.movaps, 16, LIRAddress.slot(area, Int64(48 + 16 * k)).operand(size: 16), .use(.physical(r), 16))
            }
        }
        if layout.resultInMemory {
            sretPointer = newGPR()
            copy(sretPointer, .physical(.rdi))
        }
        paramVals = [X86Val](repeating: .none, count: box.function.paramTypes.count)
        paramAddress = [LIRAddress?](repeating: nil, count: box.function.paramTypes.count)
        for k in 0..<box.function.paramTypes.count {
            let at = box.function.paramTypes[k]
            let aggregate = k < box.function.paramIsAggregate.count && box.function.paramIsAggregate[k]
            let info = k < infos.count ? infos[k] : X86OutArg.gpr(.none, 8).info
            switch k < layout.args.count ? layout.args[k] : .ignored {
            case .ignored:
                if aggregate { paramAddress[k] = .slot(lir.newSlot(size: 1, alignment: 1)) }
            case .stack(let offset):
                let fixed = fixedSlot(offset: 16 + offset, size: info.size)
                if aggregate {
                    paramAddress[k] = .slot(fixed)
                } else if (at.isFloat && at.width == 80) || (at.isInt && at.width > 128) {
                    paramVals[k] = .slot(fixed)
                } else if at.isFloat {
                    let r = newXMM()
                    emit(at.width == 128 ? .movups : at.width == 32 ? .movss : .movsd, at.width == 128 ? 16 : at.width / 8,
                         .def(r, 16), LIRAddress.slot(fixed).operand(size: at.width == 128 ? 16 : at.width / 8))
                    paramVals[k] = .reg(r)
                } else if at.isInt && at.width > 64 {
                    paramVals[k] = .pair(loadBytes(.slot(fixed), 8), loadBytes(.slot(fixed, 8), 8))
                } else {
                    paramVals[k] = .reg(loadBytes(.slot(fixed), 8))
                }
            case .registers(let regs):
                if aggregate {
                    // The callee's copy: the eightbytes stored to a slot of whole eightbytes
                    let s = lir.newSlot(size: (info.size + 7) / 8 * 8, alignment: max(8, info.alignment))
                    for (p, part) in info.parts.enumerated() {
                        let at = LIRAddress.slot(s, Int64(part.offset))
                        if part.isSSE {
                            emit(part.size == 16 ? .movups : .movsd, part.size == 16 ? 16 : 8, at.operand(size: part.size == 16 ? 16 : 8),
                                 .use(.physical(regs[p]), 16))
                        } else {
                            emit(.mov, 8, at.operand(size: 8), .use(.physical(regs[p]), 8))
                        }
                    }
                    paramAddress[k] = .slot(s)
                } else if regs.count == 2 {
                    let lo = newGPR(), hi = newGPR()
                    copy(lo, .physical(regs[0]))
                    copy(hi, .physical(regs[1]))
                    paramVals[k] = .pair(lo, hi)
                } else if at.isFloat && at.width != 80 {
                    let r = newXMM()
                    copy(r, .physical(regs[0]), 16)
                    paramVals[k] = .reg(r)
                } else {
                    let r = newGPR()
                    copy(r, .physical(regs[0]))
                    paramVals[k] = .reg(r)
                }
            }
        }
    }

    /// The C types of the function's parameters.
    func cParamTypes() -> [QualType] { functionParts(box.function.cType).params }

    /// A slot for an incoming stack argument at `offset` from the frame pointer.
    func fixedSlot(offset: Int, size: Int) -> UInt32 {
        let s = lir.newSlot(size: size, alignment: 8)
        lir.slots[Int(s)].isFixed = true
        lir.slots[Int(s)].offset = offset
        return s
    }

    func lowerReturn(_ v: ValueId) {
        let (ret, _, _) = functionParts(box.function.cType)
        var uses: [PhysReg] = []
        if !v.isNil {
            if isAggregate(ret.typeId) {
                let resultInfo = info(ret, isResult: true)
                let a = addressOf(v)
                switch resultInfo.kind {
                case .memory:
                    copyBytes(to: LIRAddress(base: sretPointer), from: a, resultInfo.size)
                    emit(.copy, 8, .def(.physical(.rax), 8), .use(sretPointer, 8))
                    uses.append(.rax)
                case .x87:
                    emit(.fldt, 10, a.operand(size: 10))
                case .ignore:
                    break
                case .direct:
                    var gprs: [PhysReg] = [.rax, .rdx], sses: [PhysReg] = [.xmm0, .xmm1]
                    var moves: [(PhysReg, LIRReg, Int)] = []
                    for part in resultInfo.parts {
                        let at = a.adding(Int64(part.offset))
                        if part.isSSE {
                            let r = newXMM()
                            switch part.size {
                            case 4: emit(.movss, 4, .def(r, 16), at.operand(size: 4))
                            case 16: emit(.movups, 16, .def(r, 16), at.operand(size: 16))
                            default: emit(.movsd, 8, .def(r, 16), at.operand(size: 8))
                            }
                            moves.append((sses.removeFirst(), r, 16))
                        } else {
                            moves.append((gprs.removeFirst(), loadBytes(at, part.size), 8))
                        }
                    }
                    for (reg, value, size) in moves {
                        emit(.copy, size, .def(.physical(reg), size), .use(value, size))
                        uses.append(reg)
                    }
                }
            } else {
                let t = ty(v)
                switch t.kind {
                case .int where t.width > 128:
                    copyBytes(to: LIRAddress(base: sretPointer), from: .slot(wide(v)), 8 * Self.words(t.width))
                    emit(.copy, 8, .def(.physical(.rax), 8), .use(sretPointer, 8))
                    uses.append(.rax)
                case .float where t.width == 80:
                    emit(.fldt, 10, LIRAddress.slot(slot(v)).operand(size: 10))
                case .float:
                    emit(.copy, 16, .def(.physical(.xmm0), 16), .use(xmm(v), 16))
                    uses.append(.xmm0)
                case .int where t.width > 64:
                    let (lo, hi) = pair(v)
                    emit(.copy, 8, .def(.physical(.rax), 8), .use(lo, 8))
                    emit(.copy, 8, .def(.physical(.rdx), 8), .use(hi, 8))
                    uses += [.rax, .rdx]
                case .int where t.width < 32:
                    let signed = types.isSignedInteger(type: ret.typeId) && t.width > 1
                    let r = extend(gpr(v), from: t.width, signed: signed)
                    emit(.copy, 4, .def(.physical(.rax), 4), .use(r, 4))
                    uses.append(.rax)
                default:
                    emit(.copy, 8, .def(.physical(.rax), 8), .use(gpr(v), 8))
                    uses.append(.rax)
                }
            }
        }
        emit(.ret, 8, operands: uses.map { .implicitUse($0) })
    }

    // MARK: - Variable arguments

    /// `va_start`: the `va_list` (psABI 3.5.7) at `ap` starts after the named arguments.
    func vaStart(_ ap: ValueId) {
        let a = addressOf(ap)
        emit(.mov, 4, a.operand(size: 4), .imm(Int64(8 * namedGPRs)))
        emit(.mov, 4, a.adding(4).operand(size: 4), .imm(Int64(48 + 16 * namedSSEs)))
        let overflow = lea(.slot(fixedSlot(offset: 16 + namedStackBytes, size: 8)))
        emit(.mov, 8, a.adding(8).operand(size: 8), .use(overflow, 8))
        if lir.registerSaveArea == 0 { lir.registerSaveArea = lir.newSlot(size: 176, alignment: 16) }
        let area = lea(.slot(lir.registerSaveArea))
        emit(.mov, 8, a.adding(16).operand(size: 8), .use(area, 8))
    }

    /// `va_arg`: the address of the next argument, of C type `t`, in the register save area or the overflow area.
    func vaArg(_ ap: ValueId, type t: TypeId) -> LIRReg {
        let info = ctx.abi.info(t, isResult: false)
        let list = lea(addressOf(ap))
        let base = LIRAddress(base: list)

        func overflow() -> LIRReg {
            let p = newGPR()
            emit(.mov, 8, .def(p, 8), base.adding(8).operand(size: 8))
            if info.alignment > 8 {
                emit(.add, 8, .useDef(p, 8), .imm(15))
                emit(.and, 8, .useDef(p, 8), .imm(-16))
            }
            let next = newGPR()
            emit(.lea, 8, .def(next, 8), LIRAddress(base: p, disp: Int64((info.size + 7) / 8 * 8)).operand(size: 8))
            emit(.mov, 8, base.adding(8).operand(size: 8), .use(next, 8))
            return p
        }

        guard info.kind == .direct else { return overflow() }
        let gp = info.gprCount, fp = info.sseCount
        let inMemory = newBlock(after: cur)
        let inRegisters = newBlock(after: cur)
        let join = newBlock(after: inMemory)
        var gpOffset = LIRReg.none, fpOffset = LIRReg.none
        if gp > 0 {
            gpOffset = newGPR()
            emit(.mov, 4, .def(gpOffset, 4), base.operand(size: 4))
            emit(.cmp, 4, .use(gpOffset, 4), .imm(Int64(48 - 8 * gp)))
            branch(.a, inMemory)
        }
        if fp > 0 {
            fpOffset = newGPR()
            emit(.mov, 4, .def(fpOffset, 4), base.adding(4).operand(size: 4))
            emit(.cmp, 4, .use(fpOffset, 4), .imm(Int64(176 - 16 * fp)))
            branch(.a, inMemory)
        }
        jump(inRegisters)

        cur = inRegisters
        let area = newGPR()
        emit(.mov, 8, .def(area, 8), base.adding(16).operand(size: 8))
        var address: LIRReg
        if fp == 0 {
            address = newGPR()
            emit(.lea, 8, .def(address, 8), LIRAddress(base: area, index: gpOffset).operand(size: 8))
        } else if gp == 0 && fp == 1 {
            address = newGPR()
            emit(.lea, 8, .def(address, 8), LIRAddress(base: area, index: fpOffset).operand(size: 8))
        } else {
            // Parts in both areas (or two SSE parts, 16 bytes apart): gathered in a temporary
            let tmp = lir.newSlot(size: 16, alignment: 16)
            var g = 0, f = 0
            for part in info.parts {
                if part.isSSE {
                    let r = newXMM()
                    emit(.movsd, 8, .def(r, 16), LIRAddress(base: area, index: fpOffset, disp: Int64(16 * f)).operand(size: 8))
                    emit(.movsd, 8, LIRAddress.slot(tmp, Int64(part.offset)).operand(size: 8), .use(r, 16))
                    f += 1
                } else {
                    let r = newGPR()
                    emit(.mov, 8, .def(r, 8), LIRAddress(base: area, index: gpOffset, disp: Int64(8 * g)).operand(size: 8))
                    emit(.mov, 8, LIRAddress.slot(tmp, Int64(part.offset)).operand(size: 8), .use(r, 8))
                    g += 1
                }
            }
            address = lea(.slot(tmp))
            if address == .none { address = newGPR() }
        }
        if gp > 0 {
            let n = copied(gpOffset, 4)
            emit(.add, 4, .useDef(n, 4), .imm(Int64(8 * gp)))
            emit(.mov, 4, base.operand(size: 4), .use(n, 4))
        }
        if fp > 0 {
            let n = copied(fpOffset, 4)
            emit(.add, 4, .useDef(n, 4), .imm(Int64(16 * fp)))
            emit(.mov, 4, base.adding(4).operand(size: 4), .use(n, 4))
        }
        let fromRegisters = cur
        jump(join)

        cur = inMemory
        let memoryAddress = overflow()
        let fromMemory = cur
        jump(join)

        cur = join
        let r = newGPR()
        lir.blocks[join].phis.append(LIRPhi(def: r, incoming: [(fromRegisters, address), (fromMemory, memoryAddress)]))
        return r
    }
}
