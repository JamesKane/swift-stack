// Sources/SwiftStack/AIR/AIRLoweringExpressions.swift
//
// Expressions (C23 6.5): lvalues become addresses (or bit-field units), rvalues become SSA values. An aggregate
// rvalue is the address of memory holding it: the object it was read from, or a temporary.

import Foundation

extension FunctionLowering {
    // MARK: - Lvalues

    /// The object an lvalue designates.
    mutating func lvalue(_ id: SemInstId) -> AIRLValue {
        b.node = c.block.nodes[id]
        let t = type(id)
        let isVolatile = t.isVolatile
        switch kind(id) {
        case .declRef:
            let decl = arg0(id)
            let d = DeclId(decl.rawIndex)
            if let home = vlaObjects[d] {
                let address = b.emit(.load, .ptr, home, aux: AIRMemFlags(alignment: 8).rawValue)
                return .memory(address: address, alignment: max(alignment(t), 16), isVolatile: isVolatile)
            }
            let attrs = sem.attributes(of: d)
            switch sem.declTable.kind(of: d) {
            case .function:
                return .memory(address: AIRLowering.globalValue(parent.symbol(for: d)), alignment: 1, isVolatile: false)
            case .variable, .parameter:
                if attrs.hasStaticStorage {
                    let s = parent.symbol(for: d)
                    var address = AIRLowering.globalValue(s)
                    if module.symbols[s].isThreadLocal { address = b.emit(.tlsAddr, .ptr, address) }
                    return .memory(address: address, alignment: max(module.symbols[s].alignment, alignment(t)), isVolatile: isVolatile)
                }
                let home = slot(for: d)
                return .memory(address: home.address, alignment: home.alignment, isVolatile: isVolatile)
            default:
                report("a reference to a \(sem.declTable.kind(of: d))")
                return .memory(address: nullPointer(), alignment: 1, isVolatile: false)
            }
        case .member:
            guard case .memory(let base, let align, let baseVolatile) = lvalue(arg0(id)) else { return .memory(address: nullPointer(), alignment: 1, isVolatile: false) }
            let off = Int(c.block.arg1[id])
            return .memory(address: offset(base, by: off), alignment: alignment(align, offset: off), isVolatile: isVolatile || baseVolatile)
        case .bitField:
            let e = extra(id)
            guard e.count == 5, case .memory(let base, let align, let baseVolatile) = lvalue(arg0(id)) else {
                report("malformed bit-field")
                return .memory(address: nullPointer(), alignment: 1, isVolatile: false)
            }
            return bitField(base, alignment: align, unitOffset: Int(e[0]), bitOffset: Int(e[1]), width: Int(e[2]), isSigned: e[3] != 0,
                            isVolatile: isVolatile || baseVolatile)
        case .deref:
            let pointer = value(arg0(id))
            let align: Int
            switch canonicalKind(t) {
            case .void, .function: align = 1
            default: align = alignment(t)
            }
            return .memory(address: pointer, alignment: align, isVolatile: isVolatile)
        case .compoundLiteral:
            let d = DeclId(c.block.arg0[id])
            if sem.attributes(of: d).hasStaticStorage {
                let s = parent.symbol(for: d)
                return .memory(address: AIRLowering.globalValue(s), alignment: module.symbols[s].alignment, isVolatile: isVolatile)
            }
            let home = slot(for: d)
            let initializer = arg1(id)
            if initializer.isValid {
                initialize(home.address, alignment: home.alignment, type: sem.declTable.type(of: d), with: initializer, zeroed: false)
            }
            return .memory(address: home.address, alignment: home.alignment, isVolatile: isVolatile)
        case .materialize:
            let v = value(arg0(id))
            if isAggregate(t) { return .memory(address: v, alignment: alignment(t), isVolatile: false) }
            let temp = temporary(t)
            storeScalar(v, to: temp, type: t, alignment: alignment(t), isVolatile: false)
            return .memory(address: temp, alignment: alignment(t), isVolatile: false)
        case .stringLiteral:
            let s = parent.stringSymbol(c.block.stringConstant(of: id))
            return .memory(address: AIRLowering.globalValue(s), alignment: module.symbols[s].alignment, isVolatile: false)
        default:
            report("\(kind(id).name) is not an lvalue")
            return .memory(address: nullPointer(), alignment: 1, isVolatile: false)
        }
    }

    /// The address of an lvalue (not a bit-field).
    mutating func address(_ id: SemInstId) -> ValueId {
        switch lvalue(id) {
        case .memory(let address, _, _): return address
        case .bitField:
            report("the address of a bit-field")
            return nullPointer()
        }
    }

    // MARK: - Rvalues

    /// Evaluates an expression for its side effects. A volatile object is still read (C23 6.7.4.2p8: an access).
    mutating func effect(_ id: SemInstId) {
        let k = kind(id)
        if k.isLvalue {
            let lv = lvalue(id)
            let t = type(id)
            if t.isVolatile, !isAggregate(t) { _ = load(lv, type: t.unqualified()) }
            return
        }
        switch k {
        case .comma:
            effect(arg0(id))
            effect(arg1(id))
            return
        case .assign:
            let lv = lvalue(arg0(id))
            let v = value(arg1(id))
            b.node = c.block.nodes[id]
            store(v, to: lv, type: type(arg0(id)).unqualified(), needsResult: false)
            return
        case .compoundAssign:
            _ = compoundAssignment(id, needsResult: false)
            return
        case .preInc, .preDec, .postInc, .postDec:
            _ = incrementDecrement(id, needsResult: false)
            return
        case .explicitCast where isVoid(type(id)):
            // `(void)e`
            effect(arg0(id))
            return
        default:
            break
        }
        _ = value(id)
    }

    /// The value of an rvalue expression: a scalar, the address of an aggregate, or nil for `void`.
    mutating func value(_ id: SemInstId) -> ValueId {
        let node = c.block.nodes[id]
        b.node = node
        let t = type(id)
        let at = airType(t)
        switch kind(id) {
        case .intLiteral:
            return const(at, c.block.intConstant(of: id))
        case .floatLiteral:
            return floatConst(at, c.block.floatConstant(of: id))
        case .nullptrLiteral:
            return nullPointer()
        case .neg:
            let v = value(arg0(id))
            b.node = node
            return at.isFloat ? b.emit(.fneg, at, v) : b.emit(.sub, at, zero(at), v)
        case .bitNot:
            let v = value(arg0(id))
            b.node = node
            return b.emit(.xor, at, v, const(at, -1))
        case .logicalNot, .eq, .ne, .lt, .le, .gt, .ge, .logicalAnd, .logicalOr:
            let bit = condition(id)
            return resize(bit, from: .i1, to: at, signed: false)
        case .addrOf:
            return address(arg0(id))
        case .preInc, .preDec, .postInc, .postDec:
            return incrementDecrement(id)
        case .add, .sub, .mul, .div, .mod, .shl, .shr, .bitAnd, .bitOr, .bitXor:
            let l = value(arg0(id)), r = value(arg1(id))
            b.node = node
            return arithmetic(kind(id), l, r, type: t, rhsType: type(arg1(id)))
        case .assign:
            let lv = lvalue(arg0(id))
            let v = value(arg1(id))
            b.node = node
            return store(v, to: lv, type: type(arg0(id)).unqualified())
        case .compoundAssign:
            return compoundAssignment(id)
        case .ptrAdd, .ptrSub:
            let p = value(arg0(id)), n = value(arg1(id))
            b.node = node
            return pointerArithmetic(p, n, pointerType: t, subtract: kind(id) == .ptrSub)
        case .ptrDiff:
            let l = value(arg0(id)), r = value(arg1(id))
            b.node = node
            let diff = b.emit(.sub, .i64, b.emit(.ptrtoint, .i64, l), b.emit(.ptrtoint, .i64, r))
            let elementSize = pointeeSize(type(arg0(id)))
            let elements: ValueId
            if case .constant = elementSize.valueTag, b.constants.int64(elementSize.index) == 1 {
                elements = diff
            } else {
                elements = b.emit(.sdiv, .i64, diff, elementSize)
            }
            return resize(elements, from: .i64, to: at, signed: true)
        case .comma:
            effect(arg0(id))
            return value(arg1(id))
        case .explicitCast, .intPromotion, .arithmeticConvert, .assignConvert, .argPromotion, .boolConvert:
            let operand = arg0(id)
            if kind(id) == .boolConvert || isBool(t) { return resize(condition(id), from: .i1, to: at, signed: false) }
            let v = value(operand)
            b.node = node
            return convert(v, from: type(operand), to: t, kind: CastKind(rawValue: c.block.arg1[id]))
        case .nullPointerConvert:
            effect(arg0(id))
            return nullPointer()
        case .lvalueToRvalue:
            let lv = lvalue(arg0(id))
            b.node = node
            return load(lv, type: t)
        case .arrayToPointer, .functionToPointer:
            return address(arg0(id))
        case .call:
            return call(id)
        case .vaArg:
            let list = vaList(arg0(id))
            b.node = node
            let argAddress = b.emit(.vaArg, .ptr, list, aux: typePool.canonical(of: t.typeId).rawIndex)
            if isAggregate(t) { return argAddress }
            return loadScalar(from: argAddress, type: t, alignment: alignment(t), isVolatile: false)
        case .conditional:
            let e = extra(id)
            guard e.count == 3 else { report("malformed conditional"); return zero(at) }
            return conditional(condition: SemInstId(e[0]), SemInstId(e[1]), SemInstId(e[2]), type: t)
        case .elvis:
            // `a ?: b`: `a` is evaluated once
            let a = value(arg0(id))
            let aType = type(arg0(id))
            let test = truth(a, type: aType)
            let thenBlock = b.newBlock(), elseBlock = b.newBlock(), join = b.newBlock()
            b.emit(.condBr, .void, test.rawIndex, thenBlock.rawIndex, aux: elseBlock.rawIndex)
            b.position(at: thenBlock)
            let thenValue = isVoid(t) ? ValueId.nilId : convert(a, from: aType, to: t, kind: nil)
            let thenEnd = b.current
            b.branch(to: join)
            b.position(at: elseBlock)
            let elseValue = value(arg1(id))
            let elseEnd = b.current
            b.branch(to: join)
            b.position(at: join)
            if isVoid(t) { return .nilId }
            return phi(isAggregate(t) ? .ptr : at, [(thenEnd, thenValue), (elseEnd, elseValue)])
        case .initList:
            // A scalar's braced initializer used as a value
            let e = extra(id)
            if !isAggregate(t) { return e.count >= 3 ? value(SemInstId(e[2])) : zero(at) }
            let temp = temporary(t)
            initialize(temp, alignment: alignment(t), type: t, with: id, zeroed: false)
            return temp
        case .stmtExpr:
            return compound(arg0(id), value: arg1(id))
        case .labelAddress:
            let blk = block(forLabel: c.block.arg0[id])
            if !b.addressTaken.contains(blk) { b.addressTaken.append(blk) }
            return b.emit(.blockAddr, .ptr, aux: blk.rawIndex)
        case .vlaSizeof:
            evaluateVLALengths(extra(id)[...])
            let size = sizeValue(QualType(typeId: TypeId(c.block.arg0[id])))
            return resize(size, from: .i64, to: at, signed: false)
        case .materialize, .declRef, .member, .bitField, .deref, .compoundLiteral, .stringLiteral:
            // An lvalue where a value is wanted: an aggregate's address
            let lv = lvalue(id)
            return load(lv, type: t.unqualified())
        case .errorInst:
            report("an unmodeled expression")
            b.emit(.trap)
            return isAggregate(t) ? temporary(t) : zero(at)
        default:
            report("\(kind(id).name) in an expression")
            return zero(at)
        }
    }

    /// A `phi` of incoming values; a constant-free single source needs none.
    mutating func phi(_ type: AIRType, _ incoming: [(BlockId, ValueId)]) -> ValueId {
        // Arms that ended in a jump (`?:` with a statement expression that returns) do not reach the join
        let live = incoming.filter { $0.1.isValid }
        var items: [UInt32] = []
        for (blk, v) in live { items += [blk.rawIndex, v.rawIndex] }
        return b.emit(.phi, type, aux: b.list(items))
    }

    // MARK: - Conditions

    /// A `bool` (or a comparison or logical operator, whose `int` result is tested) as an `i1`.
    mutating func condition(_ id: SemInstId) -> ValueId {
        let node = c.block.nodes[id]
        b.node = node
        switch kind(id) {
        case .boolConvert:
            let operand = arg0(id)
            switch kind(operand) {
            case .eq, .ne, .lt, .le, .gt, .ge, .logicalAnd, .logicalOr, .logicalNot:
                return condition(operand)
            default:
                let v = value(operand)
                b.node = node
                return truth(v, type: type(operand))
            }
        case .eq, .ne, .lt, .le, .gt, .ge:
            let l = value(arg0(id)), r = value(arg1(id))
            b.node = node
            return compare(kind(id), l, r, type: type(arg0(id)))
        case .logicalNot:
            let v = condition(arg0(id))
            b.node = node
            return b.emit(.xor, .i1, v, const(.i1, 1))
        case .logicalAnd, .logicalOr:
            let isAnd = kind(id) == .logicalAnd
            let lhs = condition(arg0(id))
            let lhsEnd = b.current
            let rhsBlock = b.newBlock(), join = b.newBlock()
            b.emit(.condBr, .void, lhs.rawIndex, (isAnd ? rhsBlock : join).rawIndex, aux: (isAnd ? join : rhsBlock).rawIndex)
            b.position(at: rhsBlock)
            let rhs = condition(arg1(id))
            let rhsEnd = b.current
            b.branch(to: join)
            b.position(at: join)
            return phi(.i1, [(lhsEnd, const(.i1, isAnd ? 0 : 1)), (rhsEnd, rhs)])
        case .explicitCast, .assignConvert, .arithmeticConvert, .argPromotion, .intPromotion:
            // A conversion to `bool`
            let operand = arg0(id)
            switch kind(operand) {
            case .eq, .ne, .lt, .le, .gt, .ge, .logicalAnd, .logicalOr, .logicalNot: return condition(operand)
            default: break
            }
            if isBool(type(operand)) { return condition(operand) }
            let v = value(operand)
            b.node = node
            return truth(v, type: type(operand))
        default:
            let v = value(id)
            let t = type(id)
            if isBool(t) { return v }
            return truth(v, type: t)
        }
    }

    /// Whether a scalar compares unequal to 0, as an `i1`.
    mutating func truth(_ v: ValueId, type t: QualType) -> ValueId {
        let at = airType(t)
        if at == .i1 { return v }
        if case .nullptr = canonicalKind(t) { return const(.i1, 0) }
        if at.isFloat { return b.emit(.fcmp, .i1, v, zero(at), aux: AIRFCmp.une.rawValue) }
        return b.emit(.icmp, .i1, v, zero(at), aux: AIRICmp.ne.rawValue)
    }

    mutating func compare(_ k: SemInstKind, _ l: ValueId, _ r: ValueId, type t: QualType) -> ValueId {
        let at = airType(t)
        if case .nullptr = canonicalKind(t) { return const(.i1, k == .eq || k == .le || k == .ge ? 1 : 0) }
        if at.isFloat {
            let p: AIRFCmp
            switch k {
            case .eq: p = .oeq
            case .ne: p = .une
            case .lt: p = .olt
            case .le: p = .ole
            case .gt: p = .ogt
            default: p = .oge
            }
            return b.emit(.fcmp, .i1, l, r, aux: p.rawValue)
        }
        let signed = at.isInt && isSigned(t)
        let p: AIRICmp
        switch k {
        case .eq: p = .eq
        case .ne: p = .ne
        case .lt: p = signed ? .slt : .ult
        case .le: p = signed ? .sle : .ule
        case .gt: p = signed ? .sgt : .ugt
        default: p = signed ? .sge : .uge
        }
        return b.emit(.icmp, .i1, l, r, aux: p.rawValue)
    }

    /// `c ? a : b`.
    mutating func conditional(condition cond: SemInstId, _ thenInst: SemInstId, _ elseInst: SemInstId, type t: QualType) -> ValueId {
        let thenBlock = b.newBlock(), elseBlock = b.newBlock(), join = b.newBlock()
        branch(on: cond, ifTrue: thenBlock, ifFalse: elseBlock)
        b.position(at: thenBlock)
        let thenValue = isVoid(t) ? ValueId.nilId : value(thenInst)
        if isVoid(t) { effect(thenInst) }
        let thenEnd = b.current, thenLive = !b.isTerminated
        b.branch(to: join)
        b.position(at: elseBlock)
        let elseValue = isVoid(t) ? ValueId.nilId : value(elseInst)
        if isVoid(t) { effect(elseInst) }
        let elseEnd = b.current, elseLive = !b.isTerminated
        b.branch(to: join)
        b.position(at: join)
        if isVoid(t) { return .nilId }
        var incoming: [(BlockId, ValueId)] = []
        if thenLive { incoming.append((thenEnd, thenValue)) }
        if elseLive { incoming.append((elseEnd, elseValue)) }
        return phi(isAggregate(t) ? .ptr : airType(t), incoming)
    }

    // MARK: - Arithmetic

    /// A binary arithmetic operator on operands converted to `t` (a shift's count has its own promoted type).
    mutating func arithmetic(_ k: SemInstKind, _ l: ValueId, _ r: ValueId, type t: QualType, rhsType: QualType) -> ValueId {
        let at = airType(t)
        if at.isFloat {
            let op: AIROpcode
            switch k {
            case .add: op = .fadd
            case .sub: op = .fsub
            case .mul: op = .fmul
            default: op = .fdiv
            }
            return b.emit(op, at, l, r)
        }
        let signed = isSigned(t)
        let op: AIROpcode
        switch k {
        case .add: op = .add
        case .sub: op = .sub
        case .mul: op = .mul
        case .div: op = signed ? .sdiv : .udiv
        case .mod: op = signed ? .srem : .urem
        case .shl: op = .shl
        case .shr: op = signed ? .ashr : .lshr
        case .bitAnd: op = .and
        case .bitOr: op = .or
        default: op = .xor
        }
        if k == .shl || k == .shr {
            let count = resize(r, from: airType(rhsType), to: at, signed: false)
            return b.emit(op, at, l, count)
        }
        return b.emit(op, at, l, r)
    }

    /// `p + n` or `p - n` for a pointer of type `pointerType` and an `i64` index.
    mutating func pointerArithmetic(_ p: ValueId, _ n: ValueId, pointerType: QualType, subtract: Bool) -> ValueId {
        let elementSize = pointeeSize(pointerType)
        var bytes = n
        if !(elementSize.valueTag == .constant && b.constants.int64(elementSize.index) == 1) {
            bytes = b.emit(.mul, .i64, n, elementSize)
        }
        if subtract { bytes = b.emit(.sub, .i64, i64(0), bytes) }
        return b.emit(.ptrAdd, .ptr, p, bytes)
    }

    mutating func incrementDecrement(_ id: SemInstId, needsResult: Bool = true) -> ValueId {
        let k = kind(id)
        let isIncrement = k == .preInc || k == .postInc
        let t = type(arg0(id)).unqualified()
        let lv = lvalue(arg0(id))
        b.node = c.block.nodes[id]
        let old = load(lv, type: t)
        let at = airType(t)
        let new: ValueId
        if isBool(t) {
            // `b++` sets it; `b--` gives `b - 1`, which is nonzero exactly when `b` was 0
            new = isIncrement ? const(.i1, 1) : b.emit(.xor, .i1, old, const(.i1, 1))
        } else if isPointer(t) {
            new = pointerArithmetic(old, i64(1), pointerType: t, subtract: !isIncrement)
        } else if at.isFloat {
            new = b.emit(isIncrement ? .fadd : .fsub, at, old, floatOne(at))
        } else {
            new = b.emit(isIncrement ? .add : .sub, at, old, const(at, 1))
        }
        let isPre = k == .preInc || k == .preDec
        let stored = store(new, to: lv, type: t, needsResult: needsResult && isPre)
        return isPre ? stored : old
    }

    /// `lv op= rhs` (C23 6.5.16.2): the lvalue's value converted to the computation type, the operation, and the result
    /// converted back.
    mutating func compoundAssignment(_ id: SemInstId, needsResult: Bool = true) -> ValueId {
        let e = extra(id)
        guard e.count == 4, let op = SemInstKind(rawValue: UInt16(e[0])) else { report("malformed compound assignment"); return .nilId }
        let t = type(arg0(id)).unqualified()
        let lv = lvalue(arg0(id))
        let rhsInst = SemInstId(e[1])
        let rhs = value(rhsInst)
        b.node = c.block.nodes[id]
        let old = load(lv, type: t)
        let computation = QualType(rawValue: e[2]), resultType = QualType(rawValue: e[3])
        let new: ValueId
        switch op {
        case .ptrAdd, .ptrSub:
            new = pointerArithmetic(old, rhs, pointerType: t, subtract: op == .ptrSub)
        default:
            let l = convert(old, from: t, to: computation, kind: nil)
            let result = arithmetic(op, l, rhs, type: computation, rhsType: type(rhsInst))
            new = convert(result, from: resultType.isError ? computation : resultType, to: t, kind: nil)
        }
        return store(new, to: lv, type: t, needsResult: needsResult)
    }

    // MARK: - Conversions

    /// `v` of type `from` converted to `to` (C23 6.3). The representation change follows from the two types.
    mutating func convert(_ v: ValueId, from: QualType, to: QualType, kind castKind: CastKind?) -> ValueId {
        if isVoid(to) { return .nilId }
        if castKind == .toUnion {
            // GNU cast to a union: a temporary union holding the value in its first bytes
            let temp = temporary(to)
            fill(temp, size: i64(size(to)), alignment: alignment(to))
            if isAggregate(from) {
                copy(to: temp, from: v, size: sizeValue(from), alignment: alignment(to))
            } else {
                storeScalar(v, to: temp, type: from, alignment: alignment(to), isVolatile: false)
            }
            return temp
        }
        if isAggregate(to) || isAggregate(from) { return v }
        let ft = airType(from), tt = airType(to)
        if isBool(to) { return truth(v, type: from) }
        if case .nullptr = canonicalKind(from) { return tt.isPointer ? nullPointer() : zero(tt) }
        if ft == tt { return v }
        switch (ft.kind, tt.kind) {
        case (.int, .int):
            return resize(v, from: ft, to: tt, signed: isSigned(from))
        case (.int, .float):
            return b.emit(isSigned(from) && ft.width > 1 ? .sitofp : .uitofp, tt, v)
        case (.float, .int):
            return b.emit(isSigned(to) ? .fptosi : .fptoui, tt, v)
        case (.float, .float):
            return b.emit(ft.width > tt.width ? .fptrunc : .fpext, tt, v)
        case (.pointer, .int):
            return resize(b.emit(.ptrtoint, .i64, v), from: .i64, to: tt, signed: false)
        case (.int, .pointer):
            return b.emit(.inttoptr, .ptr, resize(v, from: ft, to: .i64, signed: isSigned(from)))
        default:
            report("conversion from \(ft) to \(tt)")
            return zero(tt)
        }
    }

    // MARK: - Calls

    /// The address of a `va_list` object: the object itself (an array on x86-64), or the pointer a `va_list`
    /// parameter was adjusted to.
    mutating func vaList(_ id: SemInstId) -> ValueId {
        guard kind(id).isLvalue else { return value(id) }
        if case .pointer = canonicalKind(type(id)) { return load(lvalue(id), type: type(id).unqualified()) }
        return address(id)
    }

    mutating func call(_ id: SemInstId) -> ValueId {
        let e = extra(id)
        guard e.count >= 3 else { report("malformed call"); return .nilId }
        let t = type(id)
        let args = e.dropFirst(3).map { SemInstId($0) }
        let direct = DeclId(e[0])
        if direct.isValid {
            let name = sem.declTable.name(of: direct)
            if ["__builtin_", "__atomic_", "__sync_", "__c11_atomic_"].contains(where: { name.hasPrefix($0) }),
               sem.declTable.kind(of: direct) == .function, sem.declTable.bodies[direct] == 0 {
                if let result = builtin(name, args: args, type: t, node: c.block.nodes[id]) { return result }
            }
        }
        let calleeType = type(arg0(id))
        let callee = value(arg0(id))
        var values: [ValueId] = []
        for a in args { values.append(value(a)) }
        b.node = c.block.nodes[id]
        var fnType = typePool.canonical(of: pointee(calleeType).typeId)
        // A variadic call is typed with its arguments' (promoted) types after the named ones, so that the ABI
        // lowering knows how each one travels
        if case .function(let ret, let params, true) = typePool.typeInfo(of: fnType).kind, args.count > params.count {
            fnType = typePool.functionType(returnType: ret, paramTypes: params + args.dropFirst(params.count).map { type($0) },
                                           isVariadic: true)
        }
        return emitCall(callee, functionType: fnType, args: values, result: t)
    }

    /// A call of `callee` (C type `functionType`); an aggregate result goes to a temporary, whose address is the value.
    mutating func emitCall(_ callee: ValueId, functionType: TypeId, args: [ValueId], result t: QualType) -> ValueId {
        let destination = isAggregate(t) ? temporary(t) : .nilId
        let list = b.list([functionType.rawIndex, UInt32(args.count)] + args.map(\.rawIndex))
        let r = b.emit(.call, isAggregate(t) ? .void : airType(t), callee.rawIndex, destination.rawIndex, aux: list)
        return isAggregate(t) ? destination : (isVoid(t) ? .nilId : r)
    }
}
