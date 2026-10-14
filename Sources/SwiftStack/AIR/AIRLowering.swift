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

    public init(
        tree: UnsafePointer<ParseTree>,
        tokens: UnsafePointer<TokenBuffer>,
        semResult: SemResult,
        typePool: TypePool,
        sourceBuffer: UnsafePointer<UInt8>,
        sourceLength: Int
    ) {
        self.tree = tree
        self.tokens = tokens
        self.semResult = semResult
        self.typePool = typePool
        self.sourceBuffer = sourceBuffer
        self.sourceLength = sourceLength
    }

    private func spelling(of tok: TokenId) -> String {
        guard tok.isValid else { return "" }
        let s = Int(tokens.pointee.start(of: tok).rawValue)
        let e = Int(tokens.pointee.end(of: tok).rawValue)
        guard s >= 0, e >= s, e <= sourceLength else { return "" }
        return String(decoding: UnsafeBufferPointer(start: sourceBuffer + s, count: e - s), as: UTF8.self)
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
                stackFrameSize: sig.stackFrameSize
            )

            let entryBlock = airFn.createBlock()
            var currentBlock = entryBlock

            // Lower parameters into stack slots
            for (idx, pName) in sig.paramNames.enumerated() {
                if !pName.isEmpty, let sym = lookupParam(pName, in: sig) {
                    let pVal = ValueId.instResult(airFn.appendInstruction(
                        opcode: .param,
                        type: sym.type,
                        aux: UInt32(idx),
                        inBlock: currentBlock
                    ))
                    if case .param(_, let offset) = sym.storage {
                        let absOff = UInt32(abs(offset))
                        let ptrVal = ValueId.instResult(airFn.appendInstruction(
                            opcode: .alloca,
                            type: typePool.pointerTo(sym.type),
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

            module.addFunction(consume airFn)
        }

        return consume module
    }

    private func lookupParam(_ name: String, in sig: FunctionSignature) -> CSymbol? {
        for (idx, pName) in sig.paramNames.enumerated() where pName == name {
            let ty = sig.paramTypes[idx]
            let offset: Int32 = -Int32(idx + 1) * 8
            return CSymbol(name: name, type: ty, storage: .param(index: idx, offset: offset))
        }
        return nil
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
            let children = tree.pointee.children(of: stmtNode)
            var initVal: ValueId? = nil
            if children.count > 1 {
                initVal = lowerExpression(children[1], airFn: &airFn, currentBlock: &currentBlock)
            }

            if let sym = semResult.symbolRefs[stmtNode], case .local(let offset) = sym.storage {
                let absOff = UInt32(abs(offset))
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
            let val = parseInteger(txt)
            let inst = airFn.appendInstruction(
                opcode: .iconst,
                type: exprType,
                aux: UInt32(bitPattern: val),
                inBlock: currentBlock
            )
            return ValueId.instResult(inst)

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
            var raw = spelling(of: tok)
            if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast())
            }
            let unescaped = unescapeString(raw)
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
                case .local(let offset), .param(_, let offset):
                    let absOff = UInt32(abs(offset))
                    let ptrInst = airFn.appendInstruction(
                        opcode: .alloca,
                        type: typePool.pointerTo(sym.type),
                        aux: absOff,
                        inBlock: currentBlock
                    )
                    let loadInst = airFn.appendInstruction(
                        opcode: .load,
                        type: sym.type,
                        op0: ValueId.instResult(ptrInst),
                        inBlock: currentBlock
                    )
                    return ValueId.instResult(loadInst)
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
            let rhsVal = lowerExpression(rhs, airFn: &airFn, currentBlock: &currentBlock)

            if tree.pointee.kind(of: lhs) == .identExpr, let sym = semResult.symbolRefs[lhs] {
                switch sym.storage {
                case .local(let offset), .param(_, let offset):
                    let absOff = UInt32(abs(offset))
                    let ptrInst = airFn.appendInstruction(
                        opcode: .alloca,
                        type: typePool.pointerTo(sym.type),
                        aux: absOff,
                        inBlock: currentBlock
                    )
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
            let v0 = lowerExpression(children[0], airFn: &airFn, currentBlock: &currentBlock)
            let v1 = lowerExpression(children[1], airFn: &airFn, currentBlock: &currentBlock)

            let opTok = tree.pointee.token(of: exprNode)
            let opKind = CTokenKind(rawValue: tokens.pointee.kind(of: opTok)) ?? .errorToken

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
                    case .local(let offset), .param(_, let offset):
                        let absOff = UInt32(abs(offset))
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

            // Aux encodes: high 16 bits = arg count, low 16 bits = callee name hash
            let calleeHash = fnv1a16(calleeName)
            let auxVal = (UInt32(argVals.count) << 16) | calleeHash

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

    private func unescapeString(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 1
                switch chars[i] {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "0": result.append("\0")
                default: result.append(chars[i])
                }
            } else {
                result.append(chars[i])
            }
            i += 1
        }
        return result
    }

    private func parseInteger(_ txt: String) -> Int32 {
        var clean = txt
        if clean.hasSuffix("u") || clean.hasSuffix("U") || clean.hasSuffix("l") || clean.hasSuffix("L") {
            clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "uUlL"))
        }
        if clean.hasPrefix("0x") || clean.hasPrefix("0X") {
            return Int32(clean.dropFirst(2), radix: 16) ?? 0
        } else if clean.hasPrefix("0b") || clean.hasPrefix("0B") {
            return Int32(clean.dropFirst(2), radix: 2) ?? 0
        } else if clean.hasPrefix("0") && clean.count > 1 {
            return Int32(clean.dropFirst(1), radix: 8) ?? 0
        }
        return Int32(clean) ?? 0
    }
}
