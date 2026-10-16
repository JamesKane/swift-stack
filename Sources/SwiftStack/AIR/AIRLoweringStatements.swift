// Sources/SwiftStack/AIR/AIRLoweringStatements.swift
//
// Statements of a function body (C23 6.8): structured control flow becomes blocks and branches. A VLA's storage
// is released when its scope is left: at the end of the block, and by `break`, `continue` and `goto` out of it.

import Foundation

extension FunctionLowering {
    func kind(_ id: SemInstId) -> SemInstKind { c.block.kind(of: id) }
    func type(_ id: SemInstId) -> QualType { c.block.type(of: id) }
    func arg0(_ id: SemInstId) -> SemInstId { SemInstId(c.block.arg0[id]) }
    func arg1(_ id: SemInstId) -> SemInstId { SemInstId(c.block.arg1[id]) }
    func extra(_ id: SemInstId) -> [UInt32] { Array(c.block.extra(of: id)) }

    /// Whether a declaration statement allocates a VLA object.
    func isVLADeclaration(_ id: SemInstId) -> Bool {
        guard kind(id) == .declLocal else { return false }
        let decl = DeclId(c.block.arg0[id])
        return sem.declTable.kind(of: decl) == .variable && typePool.isVariableLengthArray(sem.declTable.type(of: decl).typeId)
    }

    /// Records, for each label, the VLA declarations lexically in scope there.
    mutating func collectLabelChains(_ id: SemInstId, chain: [SemInstId]) {
        guard id.isValid else { return }
        var chain = chain
        let e = extra(id)
        switch kind(id) {
        case .compound:
            for s in e {
                collectLabelChains(SemInstId(s), chain: chain)
                if isVLADeclaration(SemInstId(s)) { chain.append(SemInstId(s)) }
            }
        case .label:
            labelChains[c.block.arg1[id]] = chain
            collectLabelChains(arg0(id), chain: chain)
        case .caseLabel, .defaultLabel, .caseRange:
            collectLabelChains(arg0(id), chain: chain)
        case .ifStmt:
            for s in e where s != 0 { collectLabelChains(SemInstId(s), chain: chain) }
        case .whileStmt:
            collectLabelChains(arg1(id), chain: chain)
        case .doWhileStmt:
            collectLabelChains(arg0(id), chain: chain)
        case .forStmt where e.count == 4:
            // The `for` clause's declarations are in scope in the body
            if e[0] != 0 {
                collectLabelChains(SemInstId(e[0]), chain: chain)
                for s in extra(SemInstId(e[0])) where kind(SemInstId(e[0])) == .compound && isVLADeclaration(SemInstId(s)) {
                    chain.append(SemInstId(s))
                }
            }
            collectLabelChains(SemInstId(e[3]), chain: chain)
        case .switchStmt where !e.isEmpty:
            collectLabelChains(SemInstId(e[0]), chain: chain)
        default:
            break
        }
        // Statement expressions hold statements too
        if !kind(id).isStatement || kind(id) == .exprStmt || kind(id) == .declLocal || kind(id) == .returnStmt {
            collectStatementExpressions(id, chain: chain)
        }
    }

    mutating func collectStatementExpressions(_ id: SemInstId, chain: [SemInstId]) {
        guard id.isValid, id.rawIndex < c.block.count else { return }
        if kind(id) == .stmtExpr {
            collectLabelChains(arg0(id), chain: chain)
            return
        }
        for (op, _) in SemIRVerifier.operands(id, c) where op.rawIndex < id.rawIndex && !kind(op).isStatement {
            collectStatementExpressions(op, chain: chain)
        }
    }

    /// Releases the VLAs declared after the first `depth` of the current chain (their storage is freed by restoring
    /// the stack pointer saved before the first of them).
    mutating func releaseVLAs(downTo depth: Int) {
        guard depth < vlaChain.count, let save = vlaSaves[vlaChain[depth]] else { return }
        let sp = b.emit(.load, .ptr, save, aux: AIRMemFlags(alignment: 8).rawValue)
        b.emit(.stackRestore, .void, sp)
    }

    mutating func block(forLabel n: UInt32) -> BlockId {
        if let blk = labels[n] { return blk }
        let blk = b.newBlock()
        labels[n] = blk
        b.labelBlocks[n] = blk
        if Int(n) < function.labels.count { b.blockNames[blk] = function.labels[Int(n)] }
        if parent.staticLabelAddresses[module.symbols[symbol].name]?.contains(n) == true, !b.addressTaken.contains(blk) { b.addressTaken.append(blk) }
        return blk
    }

    /// Continues in `blk`, falling through from the current block.
    mutating func enter(_ blk: BlockId) {
        b.branch(to: blk)
        b.position(at: blk)
    }

    mutating func statement(_ id: SemInstId) {
        guard id.isValid else { return }
        b.node = c.block.nodes[id]
        let e = extra(id)
        switch kind(id) {
        case .compound:
            _ = compound(id, value: .nilId)
        case .declLocal:
            declaration(id)
        case .exprStmt:
            if arg0(id).isValid { effect(arg0(id)) }
        case .nullStmt:
            break
        case .ifStmt:
            let thenBlock = b.newBlock(), joinBlock = b.newBlock()
            let elseBlock = e.count > 1 && e[1] != 0 ? b.newBlock() : joinBlock
            branch(on: arg0(id), ifTrue: thenBlock, ifFalse: elseBlock)
            b.position(at: thenBlock)
            statement(SemInstId(e.first ?? 0))
            b.branch(to: joinBlock)
            if elseBlock != joinBlock {
                b.position(at: elseBlock)
                statement(SemInstId(e[1]))
                b.branch(to: joinBlock)
            }
            b.position(at: joinBlock)
        case .whileStmt:
            let header = b.newBlock(), body = b.newBlock(), exit = b.newBlock()
            enter(header)
            branch(on: arg0(id), ifTrue: body, ifFalse: exit)
            b.position(at: body)
            loopBody(arg1(id), breakTo: exit, continueTo: header)
            b.branch(to: header)
            b.position(at: exit)
        case .doWhileStmt:
            let body = b.newBlock(), condition = b.newBlock(), exit = b.newBlock()
            enter(body)
            loopBody(arg0(id), breakTo: exit, continueTo: condition)
            enter(condition)
            branch(on: arg1(id), ifTrue: body, ifFalse: exit)
            b.position(at: exit)
        case .forStmt:
            guard e.count == 4 else { report("malformed for statement"); return }
            let depth = vlaChain.count
            if e[0] != 0 {
                // The declarations of the clause are in scope until the loop ends
                let initStmt = SemInstId(e[0])
                if kind(initStmt) == .compound {
                    for s in extra(initStmt) { statement(SemInstId(s)) }
                } else {
                    statement(initStmt)
                }
            }
            let header = b.newBlock(), body = b.newBlock(), step = b.newBlock(), exit = b.newBlock()
            enter(header)
            if e[1] != 0 { branch(on: SemInstId(e[1]), ifTrue: body, ifFalse: exit) } else { b.branch(to: body) }
            b.position(at: body)
            loopBody(SemInstId(e[3]), breakTo: exit, continueTo: step)
            enter(step)
            if e[2] != 0 { effect(SemInstId(e[2])) }
            b.branch(to: header)
            b.position(at: exit)
            if vlaChain.count > depth {
                releaseVLAs(downTo: depth)
                vlaChain.removeLast(vlaChain.count - depth)
            }
        case .switchStmt:
            switchStatement(id)
        case .caseLabel, .caseRange, .defaultLabel:
            if let blk = caseBlocks[id] { enter(blk) } else { report("case label outside its switch") }
            statement(arg0(id))
        case .label:
            enter(block(forLabel: c.block.arg1[id]))
            statement(arg0(id))
        case .gotoStmt:
            let n = c.block.arg0[id]
            let target = labelChains[n] ?? []
            var common = 0
            while common < min(target.count, vlaChain.count) && target[common] == vlaChain[common] { common += 1 }
            releaseVLAs(downTo: common)
            b.emit(.br, aux: block(forLabel: n).rawIndex)
        case .indirectGoto:
            let address = value(arg0(id))
            indirectBranches.append(b.emit(.indirectBr, .void, address))
        case .breakStmt, .continueStmt:
            let isBreak = kind(id) == .breakStmt
            guard let t = jumpTargets.last(where: { isBreak || $0.continueBlock != nil }) else { report("\(kind(id).name) outside a loop"); return }
            releaseVLAs(downTo: t.vlaDepth)
            b.emit(.br, aux: (isBreak ? t.breakBlock : t.continueBlock!).rawIndex)
        case .returnStmt:
            let v = arg0(id)
            if v.isValid {
                let result = value(v)
                b.emit(.ret, .void, isVoid(returnCType) ? .nilId : result)
            } else {
                b.emit(.ret)
            }
        case .asmStmt:
            asmStatement(id)
        case .errorInst:
            report("an unmodeled statement")
            b.emit(.trap)
        default:
            // An expression in a statement position (a statement expression's last expression is not one)
            effect(id)
        }
    }

    /// A compound statement: its statements in order, then `value` (a statement expression's value, returned), then
    /// the release of the VLAs it declared.
    mutating func compound(_ id: SemInstId, value valueInst: SemInstId) -> ValueId {
        let depth = vlaChain.count
        for s in extra(id) { statement(SemInstId(s)) }
        let result = valueInst.isValid ? value(valueInst) : .nilId
        if vlaChain.count > depth {
            if !b.isTerminated { releaseVLAs(downTo: depth) }
            vlaChain.removeLast(vlaChain.count - depth)
        }
        return result
    }

    mutating func loopBody(_ body: SemInstId, breakTo exit: BlockId, continueTo next: BlockId) {
        jumpTargets.append(JumpTarget(breakBlock: exit, continueBlock: next, vlaDepth: vlaChain.count))
        statement(body)
        jumpTargets.removeLast()
    }

    /// Branches on a condition (a `bool`).
    mutating func branch(on condition: SemInstId, ifTrue: BlockId, ifFalse: BlockId) {
        let cond = self.condition(condition)
        b.emit(.condBr, .void, cond.rawIndex, ifTrue.rawIndex, aux: ifFalse.rawIndex)
    }

    // MARK: - Declarations

    mutating func declaration(_ id: SemInstId) {
        let decl = arg0(id).rawIndex
        let d = DeclId(decl)
        let e = extra(id)
        // The VLA lengths of the declarator, evaluated when the declaration is reached
        if e.count > 2 { evaluateVLALengths(e[2...]) }
        guard sem.declTable.kind(of: d) == .variable else { return }
        let t = sem.declTable.type(of: d)
        let initializer = SemInstId(e.first ?? 0)
        if typePool.isVariableLengthArray(t.typeId) {
            // Save the stack pointer, allocate, and keep the address in a slot
            let save = b.alloca(size: 8, alignment: 8, name: "vla.sp")
            b.emit(.store, .void, b.emit(.stackSave, .ptr), save, aux: AIRMemFlags(alignment: 8).rawValue)
            vlaSaves[id] = save
            vlaChain.append(id)
            let align = max(alignment(t), sem.objectAlignments[d] ?? 1, 16)
            let size = sizeValue(t)
            let address = b.emit(.dynAlloca, .ptr, size, aux: UInt32(align))
            let home: ValueId
            if let h = vlaObjects[d] { home = h } else {
                home = b.alloca(size: 8, alignment: 8, name: sem.declTable.name(of: d), decl: d)
                vlaObjects[d] = home
            }
            b.emit(.store, .void, address, home, aux: AIRMemFlags(alignment: 8).rawValue)
            if initializer.isValid {
                // `T a[n] = {}`: zero
                fill(address, size: size, alignment: align)
            }
            return
        }
        guard initializer.isValid else { return }
        let home = slot(for: d)
        initialize(home.address, alignment: home.alignment, type: t, with: initializer, zeroed: false)
    }

    /// Initializes the object at `address` of type `t` (C23 6.7.10): a braced list (everything it does not list
    /// is zero), a string literal for a character array, or a value. `zeroed`: the object is already all zero.
    mutating func initialize(_ address: ValueId, alignment align: Int, type t: QualType, with initializer: SemInstId, zeroed: Bool) {
        b.node = c.block.nodes[initializer]
        switch kind(initializer) {
        case .initList:
            let e = extra(initializer)
            if !isAggregate(t) {
                // `T x = {}` or `T x = { v }` of a scalar
                let v = e.count >= 3 ? value(SemInstId(e[2])) : zero(airType(t))
                storeScalar(v, to: address, type: t, alignment: align, isVolatile: t.isVolatile)
                return
            }
            if !zeroed { fill(address, size: sizeValue(t), alignment: align) }
            var i = 0
            while i + 2 < e.count {
                let index = Int(e[i]), count = Int(e[i + 1]), element = SemInstId(e[i + 2])
                i += 3
                switch canonicalKind(t) {
                case .struct(_, let fields, _):
                    guard index < fields.count else { continue }
                    let field = fields[index]
                    let fieldType = QualType(rawValue: field.type.rawValue | UInt32(t.qualifiers & 0b011))
                    if let width = field.bitWidth {
                        guard width > 0 else { continue }
                        let lv = bitField(address, alignment: align, unitOffset: Int(field.offset), bitOffset: field.bitOffset, width: width,
                                          isSigned: isSigned(fieldType), isVolatile: t.isVolatile)
                        store(value(element), to: lv, type: fieldType, needsResult: false)
                    } else {
                        initialize(offset(address, by: Int(field.offset)), alignment: alignment(align, offset: Int(field.offset)),
                                   type: fieldType, with: element, zeroed: true)
                    }
                case .array(let elementType, _):
                    let elementSize = size(elementType)
                    let elementAlign = alignment(align, offset: elementSize)
                    if count <= 1 {
                        initialize(offset(address, by: index * elementSize), alignment: alignment(align, offset: index * elementSize),
                                   type: elementType, with: element, zeroed: true)
                    } else if !isAggregate(elementType) {
                        // A GNU range `[lo ... hi] = v`: `v` is evaluated once (as GCC documents; Clang rejects side
                        // effects there), then stored to each element
                        let v = value(element)
                        if count > 8 {
                            storeRange(v, at: address, from: index, count: count, elementType: elementType, alignment: elementAlign)
                        } else {
                            for k in index..<(index + count) {
                                storeScalar(v, to: offset(address, by: k * elementSize), type: elementType,
                                            alignment: alignment(align, offset: k * elementSize), isVolatile: t.isVolatile)
                            }
                        }
                    } else {
                        for k in index..<(index + count) {
                            initialize(offset(address, by: k * elementSize), alignment: alignment(align, offset: k * elementSize),
                                       type: elementType, with: element, zeroed: true)
                        }
                    }
                default:
                    break
                }
            }
        case .stringLiteral:
            // A character array: the literal's code units, then zeros
            let s = c.block.stringConstant(of: initializer)
            let n = min(s.bytes.count, size(t))
            let source = AIRLowering.globalValue(parent.stringSymbol(s))
            if !zeroed && n < size(t) { fill(offset(address, by: n), size: i64(size(t) - n), alignment: alignment(align, offset: n)) }
            if n > 0 { copy(to: address, from: source, size: i64(n), alignment: min(align, s.elementSize)) }
        default:
            let v = value(initializer)
            if isAggregate(t) {
                copy(to: address, from: v, size: sizeValue(t), alignment: align, isVolatile: t.isVolatile)
            } else {
                storeScalar(v, to: address, type: t, alignment: align, isVolatile: t.isVolatile)
            }
        }
    }

    /// Stores `v` to elements `from ..< from + count` of an array, in a loop.
    mutating func storeRange(_ v: ValueId, at address: ValueId, from: Int, count: Int, elementType: QualType, alignment: Int) {
        let elementSize = size(elementType)
        let counter = b.alloca(size: 8, alignment: 8, name: "init.index")
        let flags = AIRMemFlags(alignment: 8).rawValue
        b.emit(.store, .void, i64(from), counter, aux: flags)
        let header = b.newBlock(), body = b.newBlock(), exit = b.newBlock()
        enter(header)
        let k = b.emit(.load, .i64, counter, aux: flags)
        let done = b.emit(.icmp, .i1, k, i64(from + count), aux: AIRICmp.uge.rawValue)
        b.emit(.condBr, .void, done.rawIndex, exit.rawIndex, aux: body.rawIndex)
        b.position(at: body)
        let at = b.emit(.ptrAdd, .ptr, address, b.emit(.mul, .i64, k, i64(elementSize)))
        storeScalar(v, to: at, type: elementType, alignment: alignment, isVolatile: false)
        b.emit(.store, .void, b.emit(.add, .i64, k, i64(1)), counter, aux: flags)
        b.branch(to: header)
        b.position(at: exit)
    }

    /// A bit-field of the object at `base`: accessed as the bytes it spans (from the byte holding its first bit), so
    /// that no byte outside it is read or written beyond those it shares.
    mutating func bitField(_ base: ValueId, alignment align: Int, unitOffset: Int, bitOffset: Int, width: Int, isSigned: Bool,
                           isVolatile: Bool) -> AIRLValue {
        let start = unitOffset + bitOffset / 8, bit = bitOffset % 8
        let bytes = (bit + width + 7) / 8
        return .bitField(unit: offset(base, by: start), unitBytes: bytes, bitOffset: bit, width: width, isSigned: isSigned,
                         alignment: alignment(align, offset: start), isVolatile: isVolatile)
    }

    // MARK: - switch

    mutating func switchStatement(_ id: SemInstId) {
        let e = extra(id)
        guard !e.isEmpty else { report("malformed switch"); return }
        let controlling = value(arg0(id))
        let ct = airType(type(arg0(id)))
        let exit = b.newBlock()
        var defaultBlock = exit
        if e.count > 1, e[1] != 0 {
            defaultBlock = b.newBlock()
            caseBlocks[SemInstId(e[1])] = defaultBlock
        }
        var cases: [(Int64, BlockId)] = []
        var ranges: [(low: Int64, high: Int64, block: BlockId)] = []
        for raw in e.dropFirst(2) {
            let label = SemInstId(raw)
            let blk = b.newBlock()
            caseBlocks[label] = blk
            if kind(label) == .caseLabel {
                cases.append((c.block.intConstant(at: c.block.arg1[label]), blk))
            } else if kind(label) == .caseRange {
                let bounds = extra(label)
                guard bounds.count == 2 else { continue }
                let low = c.block.intConstant(at: bounds[0]), high = c.block.intConstant(at: bounds[1])
                let signed = isSigned(type(arg0(id)))
                let empty = signed ? low > high : UInt64(bitPattern: low) > UInt64(bitPattern: high)
                if empty { continue }
                let span = UInt64(bitPattern: high &- low)
                if span < 64 {
                    for k in 0...span { cases.append((low &+ Int64(bitPattern: k), blk)) }
                } else {
                    ranges.append((low, high, blk))
                }
            }
        }
        // Wide case ranges are tested on the way to the default
        var dispatchDefault = defaultBlock
        if !ranges.isEmpty {
            let first = b.newBlock()
            dispatchDefault = first
            var testBlock = first
            for (k, r) in ranges.enumerated() {
                let next = k + 1 < ranges.count ? b.newBlock() : defaultBlock
                let saved = b.current
                b.position(at: testBlock)
                let offsetValue = b.emit(.sub, ct, controlling, const(ct, r.low))
                let inRange = b.emit(.icmp, .i1, offsetValue, const(ct, r.high &- r.low), aux: AIRICmp.ule.rawValue)
                b.emit(.condBr, .void, inRange.rawIndex, r.block.rawIndex, aux: next.rawIndex)
                b.position(at: saved)
                testBlock = next
            }
        }
        var items: [UInt32] = [dispatchDefault.rawIndex]
        for (v, blk) in cases { items += [const(ct, v).rawIndex, blk.rawIndex] }
        b.emit(.switch, .void, controlling.rawIndex, 0, aux: b.list(items))
        jumpTargets.append(JumpTarget(breakBlock: exit, continueBlock: nil, vlaDepth: vlaChain.count))
        // Code before the first label is unreachable
        b.position(at: b.newBlock())
        statement(SemInstId(e[0]))
        jumpTargets.removeLast()
        enter(exit)
    }

    // MARK: - asm

    mutating func asmStatement(_ id: SemInstId) {
        guard let asm = SemAsm(id, in: c.block) else { report("malformed asm statement"); return }
        /// The register a local `register` variable is bound to, if the operand names one: GCC places it there.
        func registerVariable(_ v: SemInstId) -> String? {
            var e = v
            if kind(e) == .lvalueToRvalue { e = arg0(e) }
            guard kind(e) == .declRef else { return nil }
            return sem.registerVariables[DeclId(arg0(e).rawIndex)]
        }
        /// The constraint, with a register variable's register (as LLVM writes it, `{reg}`) in place of its class.
        func constraint(_ o: SemAsm.Operand) -> String {
            guard let reg = registerVariable(o.value) else { return o.constraint }
            let prefix = o.constraint.prefix { "=+&".contains($0) }
            return prefix + "{" + reg.trimmingCharacters(in: CharacterSet(charactersIn: "%")) + "}"
        }
        func operand(_ o: SemAsm.Operand) -> [UInt32] {
            let name = o.name.isEmpty ? AIRAsm.noName : module.intern(string: o.name)
            return [module.intern(string: constraint(o)), name, 0, type(o.value).typeId.rawIndex]
        }
        var outputs: [UInt32] = [], inputs: [UInt32] = []
        for o in asm.outputs {
            var entry = operand(o)
            switch lvalue(o.value) {
            case .memory(let address, _, _): entry[2] = address.rawIndex
            case .bitField: report("a bit-field as an asm output")
            }
            outputs += entry
        }
        for o in asm.inputs {
            var entry = operand(o)
            // An input whose constraint allows only memory is its object's address; any other is its value
            if kind(o.value).isLvalue, case .memory(let address, _, _) = lvalue(o.value) {
                entry[2] = address.rawIndex
            } else {
                entry[2] = value(o.value).rawIndex
            }
            inputs += entry
        }
        let clobbers = asm.clobbers.map { module.intern(string: $0) }
        var items = [module.intern(string: asm.template), asm.flags, UInt32(asm.outputs.count), UInt32(asm.inputs.count),
                     UInt32(clobbers.count), 0] + outputs + inputs + clobbers
        if asm.isGoto {
            let fallthroughBlock = b.newBlock()
            let targets = [fallthroughBlock] + asm.labels.map { block(forLabel: $0) }
            items[5] = UInt32(targets.count)
            items += targets.map(\.rawIndex)
            b.emit(.asmGoto, aux: b.list(items))
            b.position(at: fallthroughBlock)
        } else {
            b.emit(.inlineAsm, aux: b.list(items))
        }
    }
}

extension AIRLowering {
    /// The address of symbol `s`.
    static func globalValue(_ s: Int) -> ValueId { .global(UInt32(s)) }
}
