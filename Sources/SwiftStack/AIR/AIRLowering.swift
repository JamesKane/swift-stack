// Sources/SwiftStack/AIR/AIRLowering.swift
import Foundation

/// Lowers type-checked ParseTree nodes into an AIRModule (03-intermediate-representation.md §4.1).
public struct AIRLowering {
    private let tree: UnsafePointer<ParseTree>
    private let tokens: UnsafePointer<TokenBuffer>
    private let semResult: SemResult
    private let typePool: TypePool
    private let sourceBuffer: UnsafePointer<UInt8>
    private let sourceLength: Int
    /// Resolves token spellings in any buffer (included headers, macro expansions, pasted tokens).
    private let sourceManager: SourceManager?
    public private(set) var hasLoweringError: Bool = false
    /// Frame offsets (below the frame pointer) of the current function's parameters and locals, by declaration:
    /// sema assigns no frame locations, so this throwaway lowering lays the frame out as it meets each object.
    private var frameSlots: [DeclId: UInt32] = [:]

    public init(
        tree: UnsafePointer<ParseTree>,
        tokens: UnsafePointer<TokenBuffer>,
        semResult: SemResult,
        typePool: TypePool,
        sourceBuffer: UnsafePointer<UInt8>,
        sourceLength: Int,
        sourceManager: SourceManager? = nil
    ) {
        self.sourceManager = sourceManager
        self.tree = tree
        self.tokens = tokens
        self.semResult = semResult
        self.typePool = typePool
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
    }

    private func spelling(of tok: TokenId) -> String {
        guard tok.isValid else { return "" }
        let startLoc = tokens.pointee.start(of: tok)
        let endLoc = tokens.pointee.end(of: tok)
        if let sm = sourceManager, let text = sm.text(from: startLoc, to: endLoc) {
            return text
        }
        let s = Int(startLoc.rawValue)
        let e = Int(endLoc.rawValue)
        guard s >= 0, e >= s, e <= sourceLength else { return "" }
        return String(decoding: UnsafeBufferPointer(start: sourceBuffer + s, count: e - s), as: UTF8.self)
    }

    /// Arithmetic opcode of a compound assignment (`+=` → `add`), or nil for plain `=`.
    private static func compoundAssignmentOpcode(_ k: CTokenKind) -> AIROpcode? {
        switch k {
        case .plusEqual:           return .add
        case .minusEqual:          return .sub
        case .starEqual:           return .mul
        case .slashEqual:          return .sdiv
        case .percentEqual:        return .srem
        case .ampEqual:            return .band
        case .pipeEqual:           return .bor
        case .caretEqual:          return .bxor
        case .lessLessEqual:       return .shl
        case .greaterGreaterEqual: return .shr
        default:                   return nil
        }
    }

    public mutating func lower() -> AIRModule {
        var module = AIRModule(stringLiterals: semResult.stringLiterals)

        // Lower each function definition in deterministic source declaration order
        for fnName in semResult.functionOrder {
            guard let sig = semResult.functions[fnName], sig.bodyNode.isValid else { continue }
            var airFn = AIRFunctionSoA(
                name: sig.name,
                returnType: sig.returnType,
                paramTypes: sig.paramTypes,
                stackFrameSize: 0
            )
            frameSlots = [:]

            let entryBlock = airFn.createBlock()
            var currentBlock = entryBlock

            // Lower parameters into stack slots
            for (idx, pName) in sig.paramNames.enumerated() {
                // Every parameter has a slot, so the frame layout matches the order of declaration
                let pType = QualType(typeId: sig.paramTypes[idx])
                let pDecl = idx < sig.paramDecls.count ? sig.paramDecls[idx] : .nilId
                let absOff = slot(for: pDecl, type: pType, in: &airFn)
                if !pName.isEmpty {
                    let pVal = ValueId.instResult(airFn.appendInstruction(
                        opcode: .param,
                        type: pType.typeId,
                        aux: UInt32(idx),
                        inBlock: currentBlock
                    ))
                    do {
                        let ptrVal = ValueId.instResult(airFn.appendInstruction(
                            opcode: .alloca,
                            type: typePool.pointerTo(pType),
                            aux: absOff,
                            inBlock: currentBlock
                        ))
                        _ = airFn.appendInstruction(
                            opcode: .store,
                            type: .void,
                            op0: pVal,
                            op1: ptrVal,
                            inBlock: currentBlock
                        )
                    }
                }
            }

            // Lower function body
            lowerStatement(sig.bodyNode, airFn: &airFn, currentBlock: &currentBlock)

            // Ensure block ends with a terminator if open
            if currentBlock.isValid {
                _ = airFn.appendInstruction(
                    opcode: .ret,
                    type: .void,
                    op0: .nilId,
                    inBlock: currentBlock
                )
            }
            // 16-byte align the stack frame
            airFn.stackFrameSize = (airFn.stackFrameSize + 15) & ~15

            module.addFunction(consume airFn)
        }

        return consume module
    }

    /// The frame offset of a parameter's or local's slot: assigned on first use, 8-byte aligned, at least 8 bytes.
    private mutating func slot(for decl: DeclId, type: QualType, in airFn: inout AIRFunctionSoA) -> UInt32 {
        if decl.isValid, let existing = frameSlots[decl] { return existing }
        let size = max(8, typePool.size(of: type.typeId))
        airFn.stackFrameSize += Int32((size + 7) & ~7)
        let offset = UInt32(airFn.stackFrameSize)
        if decl.isValid { frameSlots[decl] = offset }
        return offset
    }

    private mutating func lowerStatement(
        _ stmtNode: NodeId,
        airFn: inout AIRFunctionSoA,
        currentBlock: inout BlockId
    ) {
        guard currentBlock.isValid else { return }
        let kind = tree.pointee.kind(of: stmtNode)

        switch kind {
        case .compoundStmt:
            for child in tree.pointee.children(of: stmtNode) {
                lowerStatement(child, airFn: &airFn, currentBlock: &currentBlock)
            }

        case .varDecl:
            // Children: `declSpecs`, then each `declarator` followed by its initializer, if any
            let children = tree.pointee.children(of: stmtNode)
            for (idx, declarator) in children.enumerated() where tree.pointee.kind(of: declarator) == .declarator {
                var initVal: ValueId? = nil
                if idx + 1 < children.count, tree.pointee.kind(of: children[idx + 1]) != .declarator,
                   tree.pointee.kind(of: children[idx + 1]) != .attributeSpec {
                    initVal = lowerExpression(children[idx + 1], airFn: &airFn, currentBlock: &currentBlock)
                }
                guard let sym = semResult.symbolRefs[declarator] else { continue }
                switch sym.storage {
                case .local, .staticLocal: break
                default: continue
                }
                let absOff = slot(for: sym.declId, type: sym.type, in: &airFn)
                let ptrVal = ValueId.instResult(airFn.appendInstruction(
                    opcode: .alloca,
                    type: typePool.pointerTo(sym.type),
                    aux: absOff,
                    inBlock: currentBlock
                ))
                if let val = initVal {
                    _ = airFn.appendInstruction(
                        opcode: .store,
                        type: .void,
                        op0: val,
                        op1: ptrVal,
                        inBlock: currentBlock
                    )
                }
            }

        case .returnStmt:
            let children = tree.pointee.children(of: stmtNode)
            var retVal: ValueId = .nilId
            if let expr = children.first {
                retVal = lowerExpression(expr, airFn: &airFn, currentBlock: &currentBlock)
            }
            _ = airFn.appendInstruction(
                opcode: .ret,
                type: .void,
                op0: retVal,
                inBlock: currentBlock
            )
            currentBlock = .nilId // Block is terminated

        case .ifStmt:
            let children = tree.pointee.children(of: stmtNode)
            guard children.count >= 2 else { return }
            let condVal = lowerExpression(children[0], airFn: &airFn, currentBlock: &currentBlock)

            let thenBlock = airFn.createBlock()
            let mergeBlock = airFn.createBlock()
            let elseBlock = children.count >= 3 ? airFn.createBlock() : mergeBlock

            _ = airFn.appendInstruction(
                opcode: .cond_br,
                type: .void,
                op0: condVal,
                op1: ValueId(elseBlock.rawIndex),
                aux: thenBlock.rawIndex,
                inBlock: currentBlock
            )

            // Then branch
            var thenCurrent = thenBlock
            lowerStatement(children[1], airFn: &airFn, currentBlock: &thenCurrent)
            if thenCurrent.isValid {
                _ = airFn.appendInstruction(
                    opcode: .br,
                    type: .void,
                    aux: mergeBlock.rawIndex,
                    inBlock: thenCurrent
                )
            }

            // Else branch if present
            if children.count >= 3 {
                var elseCurrent = elseBlock
                lowerStatement(children[2], airFn: &airFn, currentBlock: &elseCurrent)
                if elseCurrent.isValid {
                    _ = airFn.appendInstruction(
                        opcode: .br,
                        type: .void,
                        aux: mergeBlock.rawIndex,
                        inBlock: elseCurrent
                    )
                }
            }

            currentBlock = mergeBlock

        case .whileStmt:
            let children = tree.pointee.children(of: stmtNode)
            guard children.count >= 2 else { return }

            let headerBlock = airFn.createBlock()
            let bodyBlock = airFn.createBlock()
            let exitBlock = airFn.createBlock()

            _ = airFn.appendInstruction(
                opcode: .br,
                type: .void,
                aux: headerBlock.rawIndex,
                inBlock: currentBlock
            )

            // Header (Condition test)
            var headerCurrent = headerBlock
            let condVal = lowerExpression(children[0], airFn: &airFn, currentBlock: &headerCurrent)
            _ = airFn.appendInstruction(
                opcode: .cond_br,
                type: .void,
                op0: condVal,
                op1: ValueId(exitBlock.rawIndex),
                aux: bodyBlock.rawIndex,
                inBlock: headerCurrent
            )

            // Loop body
            var bodyCurrent = bodyBlock
            lowerStatement(children[1], airFn: &airFn, currentBlock: &bodyCurrent)
            if bodyCurrent.isValid {
                _ = airFn.appendInstruction(
                    opcode: .br,
                    type: .void,
                    aux: headerBlock.rawIndex,
                    inBlock: bodyCurrent
                )
            }

            currentBlock = exitBlock

        case .exprStmt:
            let children = tree.pointee.children(of: stmtNode)
            if let expr = children.first {
                _ = lowerExpression(expr, airFn: &airFn, currentBlock: &currentBlock)
            }

        default:
            break
        }
    }

    private mutating func lowerExpression(
        _ exprNode: NodeId,
        airFn: inout AIRFunctionSoA,
        currentBlock: inout BlockId
    ) -> ValueId {
        let kind = tree.pointee.kind(of: exprNode)
        let exprType = semResult.nodeTypes[exprNode] ?? .int

        switch kind {
        case .intLiteral:
            let tok = tree.pointee.token(of: exprNode)
            let txt = spelling(of: tok)
            let val = CLiteral.integerValue(txt)?.value ?? 0
            if val > UInt64(UInt32.max) {
                let inst = airFn.appendInstruction(
                    opcode: .iconst64,
                    type: exprType,
                    op0: ValueId(UInt32(val >> 32)),
                    aux: UInt32(truncatingIfNeeded: val),
                    inBlock: currentBlock
                )
                return ValueId.instResult(inst)
            } else {
                let inst = airFn.appendInstruction(
                    opcode: .iconst,
                    type: exprType,
                    aux: UInt32(truncatingIfNeeded: val),
                    inBlock: currentBlock
                )
                return ValueId.instResult(inst)
            }

        case .charLiteral:
            let tok = tree.pointee.token(of: exprNode)
            let txt = spelling(of: tok)
            var b: UInt8 = 0
            if txt.count >= 3 && txt.hasPrefix("'") && txt.hasSuffix("'") {
                let inner = txt.dropFirst().dropLast()
                b = inner.utf8.first ?? 0
            }
            let inst = airFn.appendInstruction(
                opcode: .iconst,
                type: .char,
                aux: UInt32(b),
                inBlock: currentBlock
            )
            return ValueId.instResult(inst)

        case .stringLiteral:
            let tok = tree.pointee.token(of: exprNode)
            let unescaped = CLiteral.unescapedString(CLiteral.body(of: spelling(of: tok), quote: "\""))
            let idx = semResult.stringLiterals[unescaped] ?? 0
            let inst = airFn.appendInstruction(
                opcode: .stringConst,
                type: typePool.pointerTo(.char),
                aux: UInt32(idx),
                inBlock: currentBlock
            )
            return ValueId.instResult(inst)

        case .identExpr:
            if let sym = semResult.symbolRefs[exprNode] {
                switch sym.storage {
                case .local, .staticLocal, .param:
                    let absOff = slot(for: sym.declId, type: sym.type, in: &airFn)
                    let ptrInst = airFn.appendInstruction(
                        opcode: .alloca,
                        type: typePool.pointerTo(sym.type),
                        aux: absOff,
                        inBlock: currentBlock
                    )
                    let loadInst = airFn.appendInstruction(
                        opcode: .load,
                        type: sym.type.typeId,
                        op0: ValueId.instResult(ptrInst),
                        inBlock: currentBlock
                    )
                    return ValueId.instResult(loadInst)
                case .global:
                    hasLoweringError = true
                default:
                    break
                }
            }
            return .nilId

        case .assignExpr:
            let children = tree.pointee.children(of: exprNode)
            guard children.count == 2 else { return .nilId }
            let lhs = children[0]
            let rhs = children[1]
            var rhsVal = lowerExpression(rhs, airFn: &airFn, currentBlock: &currentBlock)
            let assignOp = CTokenKind(rawValue: tokens.pointee.kind(of: tree.pointee.token(of: exprNode))) ?? .equal
            let compoundOp = Self.compoundAssignmentOpcode(assignOp)

            /// For `lhs op= rhs`: loads the current value through `ptr` and combines it with `rhs`.
            func combine(withValueAt ptr: ValueId, lhsType: TypeId, airFn: inout AIRFunctionSoA, block: BlockId) -> ValueId {
                guard let op = compoundOp else { return rhsVal }
                let cur = ValueId.instResult(airFn.appendInstruction(opcode: .load, type: lhsType, op0: ptr, inBlock: block))
                var r = rhsVal
                if (op == .add || op == .sub) && typePool.isPointer(type: lhsType) {
                    let sz = typePool.size(of: typePool.pointeeType(of: lhsType).typeId)
                    if sz > 1 {
                        let szVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: UInt32(sz), inBlock: block))
                        r = ValueId.instResult(airFn.appendInstruction(opcode: .mul, type: .int, op0: r, op1: szVal, inBlock: block))
                    }
                }
                return ValueId.instResult(airFn.appendInstruction(opcode: op, type: lhsType, op0: cur, op1: r, inBlock: block))
            }

            if tree.pointee.kind(of: lhs) == .identExpr, let sym = semResult.symbolRefs[lhs] {
                switch sym.storage {
                case .local, .staticLocal, .param:
                    let absOff = slot(for: sym.declId, type: sym.type, in: &airFn)
                    let ptrInst = airFn.appendInstruction(
                        opcode: .alloca,
                        type: typePool.pointerTo(sym.type),
                        aux: absOff,
                        inBlock: currentBlock
                    )
                    rhsVal = combine(withValueAt: ValueId.instResult(ptrInst), lhsType: sym.type.typeId, airFn: &airFn, block: currentBlock)
                    _ = airFn.appendInstruction(
                        opcode: .store,
                        type: .void,
                        op0: rhsVal,
                        op1: ValueId.instResult(ptrInst),
                        inBlock: currentBlock
                    )
                    return rhsVal
                default:
                    break
                }
            } else if tree.pointee.kind(of: lhs) == .unaryExpr {
                // Check if dereference: *p = val
                let opTok = tree.pointee.token(of: lhs)
                let opKind = CTokenKind(rawValue: tokens.pointee.kind(of: opTok))
                if opKind == .star, let ptrExpr = tree.pointee.children(of: lhs).first {
                    let ptrVal = lowerExpression(ptrExpr, airFn: &airFn, currentBlock: &currentBlock)
                    if compoundOp != nil, let lhsType = semResult.nodeTypes[lhs] {
                        rhsVal = combine(withValueAt: ptrVal, lhsType: lhsType, airFn: &airFn, block: currentBlock)
                    }
                    _ = airFn.appendInstruction(
                        opcode: .store,
                        type: .void,
                        op0: rhsVal,
                        op1: ptrVal,
                        inBlock: currentBlock
                    )
                    return rhsVal
                }
            }
            return rhsVal

        case .binaryExpr:
            let children = tree.pointee.children(of: exprNode)
            guard children.count == 2 else { return .nilId }
            let opTok = tree.pointee.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.pointee.kind(of: opTok)) ?? .errorToken

            // Handle short-circuiting && and ||
            if opKind == .ampAmp {
                // a && b
                airFn.stackFrameSize += 8
                let slotOffset = UInt32(airFn.stackFrameSize)
                let resSlot = airFn.appendInstruction(opcode: .alloca, type: .int, aux: slotOffset, inBlock: currentBlock)
                let zeroVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: 0, inBlock: currentBlock))
                _ = airFn.appendInstruction(opcode: .store, type: .void, op0: zeroVal, op1: ValueId.instResult(resSlot), inBlock: currentBlock)

                let evalRhsBlock = airFn.createBlock()
                let mergeBlock = airFn.createBlock()

                let v0 = lowerExpression(children[0], airFn: &airFn, currentBlock: &currentBlock)
                let cond0 = airFn.appendInstruction(opcode: .icmp_ne, type: .int, op0: v0, op1: zeroVal, inBlock: currentBlock)
                _ = airFn.appendInstruction(
                    opcode: .cond_br,
                    type: .void,
                    op0: ValueId.instResult(cond0),
                    op1: ValueId(mergeBlock.rawIndex),
                    aux: evalRhsBlock.rawIndex,
                    inBlock: currentBlock
                )

                currentBlock = evalRhsBlock
                let v1 = lowerExpression(children[1], airFn: &airFn, currentBlock: &currentBlock)
                let cond1 = airFn.appendInstruction(opcode: .icmp_ne, type: .int, op0: v1, op1: zeroVal, inBlock: currentBlock)
                _ = airFn.appendInstruction(opcode: .store, type: .void, op0: ValueId.instResult(cond1), op1: ValueId.instResult(resSlot), inBlock: currentBlock)
                _ = airFn.appendInstruction(
                    opcode: .br,
                    type: .void,
                    aux: mergeBlock.rawIndex,
                    inBlock: currentBlock
                )

                currentBlock = mergeBlock
                let finalVal = airFn.appendInstruction(opcode: .load, type: .int, op0: ValueId.instResult(resSlot), inBlock: currentBlock)
                return ValueId.instResult(finalVal)
            }

            if opKind == .pipePipe {
                // a || b
                airFn.stackFrameSize += 8
                let slotOffset = UInt32(airFn.stackFrameSize)
                let resSlot = airFn.appendInstruction(opcode: .alloca, type: .int, aux: slotOffset, inBlock: currentBlock)
                let oneVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: 1, inBlock: currentBlock))
                let zeroVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: 0, inBlock: currentBlock))
                _ = airFn.appendInstruction(opcode: .store, type: .void, op0: oneVal, op1: ValueId.instResult(resSlot), inBlock: currentBlock)

                let evalRhsBlock = airFn.createBlock()
                let mergeBlock = airFn.createBlock()

                let v0 = lowerExpression(children[0], airFn: &airFn, currentBlock: &currentBlock)
                let cond0 = airFn.appendInstruction(opcode: .icmp_ne, type: .int, op0: v0, op1: zeroVal, inBlock: currentBlock)
                _ = airFn.appendInstruction(
                    opcode: .cond_br,
                    type: .void,
                    op0: ValueId.instResult(cond0),
                    op1: ValueId(evalRhsBlock.rawIndex),
                    aux: mergeBlock.rawIndex,
                    inBlock: currentBlock
                )

                currentBlock = evalRhsBlock
                let v1 = lowerExpression(children[1], airFn: &airFn, currentBlock: &currentBlock)
                let cond1 = airFn.appendInstruction(opcode: .icmp_ne, type: .int, op0: v1, op1: zeroVal, inBlock: currentBlock)
                _ = airFn.appendInstruction(opcode: .store, type: .void, op0: ValueId.instResult(cond1), op1: ValueId.instResult(resSlot), inBlock: currentBlock)
                _ = airFn.appendInstruction(
                    opcode: .br,
                    type: .void,
                    aux: mergeBlock.rawIndex,
                    inBlock: currentBlock
                )

                currentBlock = mergeBlock
                let finalVal = airFn.appendInstruction(opcode: .load, type: .int, op0: ValueId.instResult(resSlot), inBlock: currentBlock)
                return ValueId.instResult(finalVal)
            }

            let t0 = semResult.nodeTypes[children[0]] ?? .int
            let t1 = semResult.nodeTypes[children[1]] ?? .int
            var v0 = lowerExpression(children[0], airFn: &airFn, currentBlock: &currentBlock)
            var v1 = lowerExpression(children[1], airFn: &airFn, currentBlock: &currentBlock)

            // Pointer arithmetic element size scaling
            if opKind == .plus {
                if typePool.isPointer(type: t0) {
                    let elem = typePool.pointeeType(of: t0)
                    let sz = typePool.size(of: elem.typeId)
                    if sz > 1 {
                        let szVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: UInt32(sz), inBlock: currentBlock))
                        v1 = ValueId.instResult(airFn.appendInstruction(opcode: .mul, type: .int, op0: v1, op1: szVal, inBlock: currentBlock))
                    }
                } else if typePool.isPointer(type: t1) {
                    let elem = typePool.pointeeType(of: t1)
                    let sz = typePool.size(of: elem.typeId)
                    if sz > 1 {
                        let szVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: UInt32(sz), inBlock: currentBlock))
                        v0 = ValueId.instResult(airFn.appendInstruction(opcode: .mul, type: .int, op0: v0, op1: szVal, inBlock: currentBlock))
                    }
                }
            } else if opKind == .minus {
                if typePool.isPointer(type: t0) && typePool.isPointer(type: t1) {
                    let elem = typePool.pointeeType(of: t0)
                    let sz = typePool.size(of: elem.typeId)
                    let diff = airFn.appendInstruction(opcode: .sub, type: .int, op0: v0, op1: v1, inBlock: currentBlock)
                    if sz > 1 {
                        let szVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: UInt32(sz), inBlock: currentBlock))
                        let scaled = airFn.appendInstruction(opcode: .sdiv, type: .int, op0: ValueId.instResult(diff), op1: szVal, inBlock: currentBlock)
                        return ValueId.instResult(scaled)
                    }
                    return ValueId.instResult(diff)
                } else if typePool.isPointer(type: t0) {
                    let elem = typePool.pointeeType(of: t0)
                    let sz = typePool.size(of: elem.typeId)
                    if sz > 1 {
                        let szVal = ValueId.instResult(airFn.appendInstruction(opcode: .iconst, type: .int, aux: UInt32(sz), inBlock: currentBlock))
                        v1 = ValueId.instResult(airFn.appendInstruction(opcode: .mul, type: .int, op0: v1, op1: szVal, inBlock: currentBlock))
                    }
                }
            }

            let airOp: AIROpcode
            switch opKind {
            case .plus: airOp = .add
            case .minus: airOp = .sub
            case .star: airOp = .mul
            case .slash: airOp = .sdiv
            case .percent: airOp = .srem
            case .amp: airOp = .band
            case .pipe: airOp = .bor
            case .caret: airOp = .bxor
            case .lessLess: airOp = .shl
            case .greaterGreater: airOp = .shr
            case .equalEqual: airOp = .icmp_eq
            case .exclaimEqual: airOp = .icmp_ne
            case .less: airOp = .icmp_slt
            case .lessEqual: airOp = .icmp_sle
            case .greater: airOp = .icmp_sgt
            case .greaterEqual: airOp = .icmp_sge
            default: airOp = .add
            }

            let inst = airFn.appendInstruction(
                opcode: airOp,
                type: exprType,
                op0: v0,
                op1: v1,
                inBlock: currentBlock
            )
            return ValueId.instResult(inst)

        case .unaryExpr:
            let children = tree.pointee.children(of: exprNode)
            guard let child = children.first else { return .nilId }
            let opTok = tree.pointee.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.pointee.kind(of: opTok)) ?? .errorToken

            switch opKind {
            case .minus:
                let v = lowerExpression(child, airFn: &airFn, currentBlock: &currentBlock)
                let zeroInst = airFn.appendInstruction(
                    opcode: .iconst,
                    type: exprType,
                    aux: 0,
                    inBlock: currentBlock
                )
                let subInst = airFn.appendInstruction(
                    opcode: .sub,
                    type: exprType,
                    op0: ValueId.instResult(zeroInst),
                    op1: v,
                    inBlock: currentBlock
                )
                return ValueId.instResult(subInst)

            case .exclaim:
                let v = lowerExpression(child, airFn: &airFn, currentBlock: &currentBlock)
                let zeroInst = airFn.appendInstruction(
                    opcode: .iconst,
                    type: exprType,
                    aux: 0,
                    inBlock: currentBlock
                )
                let eqInst = airFn.appendInstruction(
                    opcode: .icmp_eq,
                    type: .int,
                    op0: v,
                    op1: ValueId.instResult(zeroInst),
                    inBlock: currentBlock
                )
                return ValueId.instResult(eqInst)

            case .tilde:
                let v = lowerExpression(child, airFn: &airFn, currentBlock: &currentBlock)
                let negOne = airFn.appendInstruction(
                    opcode: .iconst,
                    type: exprType,
                    aux: 0xFFFF_FFFF,
                    inBlock: currentBlock
                )
                let xorInst = airFn.appendInstruction(
                    opcode: .bxor,
                    type: exprType,
                    op0: v,
                    op1: ValueId.instResult(negOne),
                    inBlock: currentBlock
                )
                return ValueId.instResult(xorInst)

            case .amp: // address-of &x
                if tree.pointee.kind(of: child) == .identExpr, let sym = semResult.symbolRefs[child] {
                    switch sym.storage {
                    case .local, .staticLocal, .param:
                        let absOff = slot(for: sym.declId, type: sym.type, in: &airFn)
                        let ptrInst = airFn.appendInstruction(
                            opcode: .alloca,
                            type: typePool.pointerTo(sym.type),
                            aux: absOff,
                            inBlock: currentBlock
                        )
                        return ValueId.instResult(ptrInst)
                    default:
                        break
                    }
                }
                return .nilId

            case .star: // dereference *p
                let ptrVal = lowerExpression(child, airFn: &airFn, currentBlock: &currentBlock)
                let loadInst = airFn.appendInstruction(
                    opcode: .load,
                    type: exprType,
                    op0: ptrVal,
                    inBlock: currentBlock
                )
                return ValueId.instResult(loadInst)

            default:
                return lowerExpression(child, airFn: &airFn, currentBlock: &currentBlock)
            }

        case .callExpr:
            let children = tree.pointee.children(of: exprNode)
            guard children.count >= 1 else { return .nilId }
            let calleeNode = children[0]
            let calleeTok = tree.pointee.token(of: calleeNode)
            let calleeName = spelling(of: calleeTok)

            var argVals: [ValueId] = []
            if children.count > 1 {
                let argListNode = children[1]
                for arg in tree.pointee.children(of: argListNode) {
                    let v = lowerExpression(arg, airFn: &airFn, currentBlock: &currentBlock)
                    argVals.append(v)
                }
            }

            // Put args into extra operands
            let extraStart = airFn.extra.count
            for arg in argVals {
                _ = airFn.appendExtra(arg)
            }

            // Aux encodes: high 16 bits = arg count, low 16 bits = deterministic callee ID
            let calleeId = deterministicCalleeId(calleeName)
            let auxVal = (UInt32(argVals.count) << 16) | (calleeId & 0xFFFF)

            let callInst = airFn.appendInstruction(
                opcode: .call,
                type: exprType,
                op0: ValueId(extraStart),
                aux: auxVal,
                inBlock: currentBlock
            )
            return ValueId.instResult(callInst)

        default:
            return .nilId
        }
    }

    private func deterministicCalleeId(_ name: String) -> UInt32 {
        if name == "write" { return 1 }
        if name == "exit" { return 2 }
        for (idx, fn) in semResult.functionOrder.enumerated() {
            if fn == name {
                return UInt32(3 + idx)
            }
        }
        return 0
    }
}
