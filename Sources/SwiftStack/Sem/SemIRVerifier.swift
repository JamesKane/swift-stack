// Sources/SwiftStack/Sem/SemIRVerifier.swift
//
// The SemIR verifier (10-semantic-ir-and-name-resolution.md §4.11): checks that a C module's SemIR is something AIR
// lowering can take without the parse tree. Run by tests on every corpus, and by the driver under `--verify-each`.
//
// It checks, per instruction: a type on every instruction (`void` on statements), operands that precede their user
// and have one user each, lvalue operands where an object is required and rvalues elsewhere, and the implicit
// conversions C requires (operands of an arithmetic operator have the result type, arguments their parameter's type,
// conditions are `bool`, and so on). It checks structured control flow from each function's root: statements in
// statement positions, `break`/`continue` inside loops (and `switch`), `case`/`default` labels inside the `switch`
// that lists them, and `goto` targets defined once. An instruction with an operand that sema left unmodeled (an
// `errorInst`, or a value of the error type) is poisoned: its operand checks are skipped.

import Foundation

public struct SemIRVerifier {
    public struct Issue: CustomStringConvertible, Sendable {
        public let block: Int
        public let inst: UInt32
        public let message: String
        public var description: String { "block \(block) %\(inst): \(message)" }
    }

    /// Per-module counts, for corpus reports.
    public struct Summary: Sendable {
        public var instructions = 0
        /// Instructions sema did not model (`errorInst`), and instructions whose checks were skipped because of one.
        public var unmodeled = 0
        public var poisoned = 0
        public var functions = 0
        public var globals = 0
    }

    private let module: SemModule
    private var typePool: TypePool { module.typePool }
    public private(set) var issues: [Issue] = []
    public private(set) var summary = Summary()

    public init(module: SemModule) {
        self.module = module
    }

    /// Verifies a module; returns the issues found (none if well formed).
    public static func verify(_ module: SemModule) -> [Issue] {
        var v = SemIRVerifier(module: module)
        v.run()
        return v.issues
    }

    public mutating func run() {
        for f in module.functions {
            summary.functions += 1
            let c = module.block(f.blockId)
            verifyInstructions(c, blockIndex: Int(f.blockId.rawIndex))
            verifyFunction(f, c)
        }
        verifyInstructions(module.fileScopeBlock, blockIndex: 0)
        for g in module.globals {
            summary.globals += 1
            guard g.initInst.isValid else { continue }
            let c = module.block(g.initBlock)
            if g.initInst.rawIndex >= c.block.count {
                report(Int(g.initBlock.rawIndex), g.initInst, "initializer of '\(g.symbol)' is not an instruction")
            } else if c.block.kind(of: g.initInst).isStatement {
                report(Int(g.initBlock.rawIndex), g.initInst, "initializer of '\(g.symbol)' is a statement")
            }
        }
    }

    private mutating func report(_ block: Int, _ inst: SemInstId, _ message: String) {
        if issues.count < 1000 { issues.append(Issue(block: block, inst: inst.rawIndex, message: message)) }
    }

    // MARK: - Types

    private func canonical(_ t: QualType) -> TypeId { typePool.canonical(of: t.typeId) }
    private func same(_ a: QualType, _ b: QualType) -> Bool { canonical(a) == canonical(b) }
    private func isVoid(_ t: QualType) -> Bool { canonical(t) == .void || canonical(t) == .cVoid }
    private func isBool(_ t: QualType) -> Bool { canonical(t) == .bool }
    private func isPointer(_ t: QualType) -> Bool {
        if case .pointer = typePool.typeInfo(of: canonical(t)).kind { return true }
        return false
    }
    private func isNullptr(_ t: QualType) -> Bool {
        if case .nullptr = typePool.typeInfo(of: canonical(t)).kind { return true }
        return false
    }
    private func isAggregate(_ t: QualType) -> Bool {
        switch typePool.typeInfo(of: canonical(t)).kind {
        case .array, .struct: return true
        default: return false
        }
    }
    private func isPromoted(_ t: QualType) -> Bool {
        !typePool.isInteger(type: t.typeId) || typePool.promote(type: t.typeId) == canonical(t)
    }

    // MARK: - Instructions

    /// The operands of an instruction (instruction references only), and which must be lvalues.
    private func operands(_ id: SemInstId, _ c: SemInstBlockContainer) -> [(inst: SemInstId, lvalue: Bool?)] {
        let a0 = SemInstId(c.block.arg0[id]), a1 = SemInstId(c.block.arg1[id])
        let extra = Array(c.block.extra(of: id))
        func opt(_ i: SemInstId, _ lv: Bool?) -> [(SemInstId, Bool?)] { i.isValid ? [(i, lv)] : [] }
        switch c.block.kind(of: id) {
        case .nilInst, .intLiteral, .floatLiteral, .stringLiteral, .nullptrLiteral, .declRef, .labelAddress, .gotoStmt,
             .breakStmt, .continueStmt, .asmStmt, .nullStmt:
            return []
        case .member, .bitField, .lvalueToRvalue, .arrayToPointer, .functionToPointer, .addrOf, .preInc, .preDec, .postInc,
             .postDec, .vaArg:
            return [(a0, true)]
        case .deref, .materialize, .neg, .bitNot, .logicalNot, .explicitCast, .intPromotion, .arithmeticConvert,
             .assignConvert, .argPromotion, .boolConvert, .nullPointerConvert, .indirectGoto:
            return [(a0, false)]
        case .compoundLiteral:
            return opt(a1, nil)
        case .add, .sub, .mul, .div, .mod, .shl, .shr, .bitAnd, .bitOr, .bitXor, .eq, .ne, .lt, .le, .gt, .ge,
             .logicalAnd, .logicalOr, .ptrAdd, .ptrSub, .ptrDiff:
            return [(a0, false), (a1, false)]
        case .assign:
            return [(a0, true), (a1, false)]
        case .compoundAssign:
            return [(a0, true)] + (extra.count > 1 ? [(SemInstId(extra[1]), false)] : [])
        case .comma:
            return [(a0, nil), (a1, false)]
        case .call:
            return [(a0, false)] + extra.dropFirst(3).map { (SemInstId($0), false) }
        case .conditional:
            return extra.map { (SemInstId($0), false) }
        case .elvis:
            return [(a0, false), (a1, false)]
        case .initList:
            var out: [(SemInstId, Bool?)] = []
            var i = 0
            while i + 2 < extra.count { out.append((SemInstId(extra[i + 2]), nil)); i += 3 }
            return out
        case .stmtExpr:
            return [(a0, nil)] + opt(a1, false)
        case .vlaSizeof:
            return stride(from: 1, to: extra.count, by: 2).map { (SemInstId(extra[$0]), false) }
        case .compound:
            return extra.map { (SemInstId($0), nil) }
        case .declLocal:
            var out: [(SemInstId, Bool?)] = extra.first.map { opt(SemInstId($0), nil) } ?? []
            if extra.count > 2 { out += stride(from: 3, to: extra.count, by: 2).map { (SemInstId(extra[$0]), false) } }
            return out
        case .exprStmt:
            return opt(a0, nil)
        case .ifStmt:
            return [(a0, false)] + extra.compactMap { $0 == 0 ? nil : (SemInstId($0), nil) }
        case .whileStmt:
            return [(a0, false), (a1, nil)]
        case .doWhileStmt:
            return [(a0, nil), (a1, false)]
        case .forStmt:
            return extra.enumerated().compactMap { $0.element == 0 ? nil : (SemInstId($0.element), $0.offset == 1 || $0.offset == 2 ? false : nil) }
        case .switchStmt:
            // The listed labels are references, not uses: they are used by their parent statements
            return [(a0, false)] + (extra.first.map { [(SemInstId($0), nil)] } ?? [])
        case .caseLabel, .caseRange, .defaultLabel, .label:
            return opt(a0, nil)
        case .returnStmt:
            return opt(a0, false)
        case .errorInst:
            return opt(a0, nil)
        }
    }

    private func isPoisoned(_ id: SemInstId, _ c: SemInstBlockContainer) -> Bool {
        c.block.kind(of: id) == .errorInst || c.block.type(of: id).isError
    }

    private mutating func verifyInstructions(_ c: SemInstBlockContainer, blockIndex: Int) {
        var uses = [UInt8](repeating: 0, count: Int(c.block.count))
        for raw in 1..<max(1, Int(c.block.count)) {
            let id = SemInstId(UInt32(raw))
            let kind = c.block.kind(of: id)
            let type = c.block.type(of: id)
            summary.instructions += 1
            if kind == .nilInst { report(blockIndex, id, "invalid instruction kind \(c.block.kinds[id])"); continue }
            if kind == .errorInst { summary.unmodeled += 1 }
            if kind.isStatement && !isVoid(type) { report(blockIndex, id, "\(kind.name) has type \(typePool.name(of: type))") }
            let ops = operands(id, c)
            var poisoned = false
            for (op, wantsLvalue) in ops {
                guard op.rawIndex > 0, op.rawIndex < id.rawIndex else {
                    report(blockIndex, id, "\(kind.name): operand %\(op.rawIndex) does not precede it")
                    poisoned = true
                    continue
                }
                if uses[Int(op.rawIndex)] == 1 { report(blockIndex, id, "\(kind.name): %\(op.rawIndex) has more than one user") }
                uses[Int(op.rawIndex)] = 1
                if isPoisoned(op, c) { poisoned = true; continue }
                let opKind = c.block.kind(of: op)
                if wantsLvalue != nil, opKind.isStatement {
                    report(blockIndex, id, "\(kind.name): operand %\(op.rawIndex) is a statement")
                } else if wantsLvalue == true && !opKind.isLvalue {
                    report(blockIndex, id, "\(kind.name): operand %\(op.rawIndex) (\(opKind.name)) is not an lvalue")
                } else if wantsLvalue == false && opKind.isLvalue {
                    report(blockIndex, id, "\(kind.name): operand %\(op.rawIndex) (\(opKind.name)) is an lvalue without lvalue conversion")
                }
            }
            if poisoned { summary.poisoned += 1; continue }
            if type.isError && kind != .errorInst && !isPoisonSource(kind) {
                report(blockIndex, id, "\(kind.name) has the error type without an unmodeled operand")
                continue
            }
            if !type.isError { verifyTypes(id, kind: kind, type: type, c, blockIndex: blockIndex) }
        }
    }

    /// Instructions that take the error type from a declaration or type sema does not model (`_Complex`, ...).
    private func isPoisonSource(_ kind: SemInstKind) -> Bool {
        switch kind {
        case .declRef, .compoundLiteral, .explicitCast, .vaArg, .call, .member, .bitField, .deref, .materialize, .stmtExpr,
             .lvalueToRvalue, .initList, .conditional, .elvis, .comma, .ptrAdd, .assign, .compoundAssign, .preInc, .preDec,
             .postInc, .postDec:
            return true
        default:
            return false
        }
    }

    /// The conversions C requires: operand types against the instruction's.
    private mutating func verifyTypes(_ id: SemInstId, kind: SemInstKind, type: QualType, _ c: SemInstBlockContainer, blockIndex: Int) {
        let a0 = SemInstId(c.block.arg0[id]), a1 = SemInstId(c.block.arg1[id])
        let t0 = c.block.type(of: a0), t1 = c.block.type(of: a1)
        func fail(_ m: String) { report(blockIndex, id, "\(kind.name): \(m)") }
        func name(_ t: QualType) -> String { typePool.name(of: t) }
        switch kind {
        case .add, .sub, .mul, .div, .mod, .bitAnd, .bitOr, .bitXor:
            if !(same(t0, type) && same(t1, type)) { fail("operands \(name(t0)), \(name(t1)) not converted to \(name(type))") }
            if !typePool.isArithmetic(type: type.typeId) { fail("non-arithmetic type \(name(type))") }
            if !isPromoted(type) { fail("operands not promoted (\(name(type)))") }
        case .shl, .shr:
            if !same(t0, type) || !isPromoted(t0) || !isPromoted(t1) || !typePool.isInteger(type: t1.typeId) {
                fail("shift operands \(name(t0)), \(name(t1)) not promoted integers of \(name(type))")
            }
        case .eq, .ne, .lt, .le, .gt, .ge:
            if !same(t0, t1) && !(isNullptr(t0) && isNullptr(t1)) { fail("operands \(name(t0)) and \(name(t1)) not converted to a common type") }
            if canonical(type) != .int { fail("result is \(name(type)), not int") }
        case .logicalAnd, .logicalOr:
            if !isBool(t0) || !isBool(t1) { fail("operands \(name(t0)), \(name(t1)) not converted to bool") }
        case .logicalNot:
            if !isBool(t0) { fail("operand \(name(t0)) not converted to bool") }
        case .neg, .bitNot:
            if !same(t0, type) || !isPromoted(t0) { fail("operand \(name(t0)) not promoted to \(name(type))") }
        case .ptrAdd, .ptrSub:
            if !isPointer(t0) || !same(t0, type) { fail("pointer operand \(name(t0)) for \(name(type))") }
            if canonical(t1) != typePool.dataLayout.ptrdiffType { fail("index \(name(t1)) not converted to ptrdiff_t") }
        case .ptrDiff:
            if !isPointer(t0) || !isPointer(t1) { fail("operands \(name(t0)), \(name(t1)) are not pointers") }
        case .assign:
            if !same(t1, t0.unqualified()) { fail("value \(name(t1)) not converted to \(name(t0))") }
        case .compoundAssign:
            let extra = Array(c.block.extra(of: id))
            guard extra.count == 4, let op = SemInstKind(rawValue: UInt16(extra[0])) else { fail("malformed"); return }
            let rhsType = c.block.type(of: SemInstId(extra[1])), computation = QualType(rawValue: extra[2])
            switch op {
            case .ptrAdd, .ptrSub:
                if canonical(rhsType) != typePool.dataLayout.ptrdiffType { fail("index not converted to ptrdiff_t") }
            case .shl, .shr:
                if !isPromoted(rhsType) { fail("shift count not promoted") }
            default:
                if !rhsType.isError && !computation.isError && !same(rhsType, computation) {
                    fail("value \(name(rhsType)) not converted to the computation type \(name(computation))")
                }
            }
        case .lvalueToRvalue:
            if !same(t0, type) || type.qualifiers != 0 { fail("loads \(name(t0)) as \(name(type))") }
        case .arrayToPointer:
            if case .array = typePool.typeInfo(of: canonical(t0)).kind, isPointer(type) {} else { fail("decays \(name(t0)) to \(name(type))") }
        case .functionToPointer:
            if case .function = typePool.typeInfo(of: canonical(t0)).kind, isPointer(type) {} else { fail("decays \(name(t0)) to \(name(type))") }
        case .intPromotion:
            if !typePool.isInteger(type: t0.typeId) || !typePool.isInteger(type: type.typeId) { fail("promotes \(name(t0)) to \(name(type))") }
        case .boolConvert:
            if !isBool(type) || !typePool.isScalar(type: t0.typeId) { fail("tests \(name(t0)) as \(name(type))") }
        case .nullPointerConvert:
            if !isPointer(type) { fail("null pointer of type \(name(type))") }
        case .explicitCast, .arithmeticConvert, .assignConvert, .argPromotion:
            verifyCast(CastKind(rawValue: c.block.arg1[id]), from: t0, to: type, fail: fail)
            if kind == .argPromotion && (!isPromoted(type) || (typePool.isFloating(type: type.typeId) && canonical(type) == .float)) {
                fail("argument promoted to \(name(type))")
            }
        case .deref:
            if !isPointer(t0) { fail("operand \(name(t0)) is not a pointer") }
            else if !same(typePool.pointeeType(of: t0.typeId), type) { fail("\(name(t0)) dereferenced as \(name(type))") }
        case .member, .bitField:
            if case .struct = typePool.typeInfo(of: canonical(t0)).kind {} else { fail("base \(name(t0)) is not a struct or union") }
        case .addrOf:
            if !isPointer(type) { fail("address of type \(name(type))") }
        case .call:
            verifyCall(id, type: type, c, fail: fail)
        case .conditional:
            let extra = Array(c.block.extra(of: id))
            guard extra.count == 3 else { fail("malformed"); return }
            if !isBool(c.block.type(of: SemInstId(extra[0]))) { fail("condition not converted to bool") }
            for arm in extra.dropFirst() where !isVoid(type) && !c.block.type(of: SemInstId(arm)).isError && !same(c.block.type(of: SemInstId(arm)), type) {
                fail("arm \(name(c.block.type(of: SemInstId(arm)))) not converted to \(name(type))")
            }
        case .elvis:
            if !isVoid(type) && !same(t1, type) { fail("arm \(name(t1)) not converted to \(name(type))") }
        case .initList:
            verifyInitList(id, type: type, c, fail: fail)
        case .comma:
            if !same(t1, type) { fail("result \(name(t1)) typed \(name(type))") }
        case .ifStmt, .whileStmt:
            if !isBool(t0) && !t0.isError { fail("condition \(name(t0)) not converted to bool") }
        case .doWhileStmt:
            if !isBool(t1) && !t1.isError { fail("condition \(name(t1)) not converted to bool") }
        case .forStmt:
            let extra = Array(c.block.extra(of: id))
            if extra.count == 4, extra[1] != 0, !isBool(c.block.type(of: SemInstId(extra[1]))) { fail("condition not converted to bool") }
        case .switchStmt:
            if !typePool.isInteger(type: t0.typeId) || !isPromoted(t0) { fail("controlling expression \(name(t0)) not a promoted integer") }
        case .declLocal:
            let decl = DeclId(c.block.arg0[id])
            let declKind = module.declTable.kind(of: decl)
            if declKind == .variable {
                if module.attributes(of: decl).storage != .automatic { fail("'\(module.declTable.name(of: decl))' is not automatic") }
                if let initInst = c.block.extra(of: id).first, initInst != 0 {
                    verifyInitializer(SemInstId(initInst), for: module.declTable.type(of: decl), c, fail: fail)
                }
            } else if declKind != .typedefDecl {
                fail("declares a \(declKind)")
            }
        case .compoundLiteral:
            if a1.isValid { verifyInitializer(a1, for: type, c, fail: fail) }
        default:
            break
        }
        _ = t1
    }

    private func verifyCast(_ kind: CastKind?, from: QualType, to: QualType, fail: (String) -> Void) {
        guard let kind else { fail("invalid cast kind"); return }
        let fromInt = typePool.isInteger(type: from.typeId), toInt = typePool.isInteger(type: to.typeId)
        let fromFloat = typePool.isFloating(type: from.typeId), toFloat = typePool.isFloating(type: to.typeId)
        let fromPtr = isPointer(from), toPtr = isPointer(to)
        let ok: Bool
        switch kind {
        case .noop: ok = true
        case .intToInt: ok = fromInt && toInt
        case .intToFloat: ok = fromInt && toFloat
        case .floatToInt: ok = fromFloat && toInt
        case .floatToFloat: ok = fromFloat && toFloat
        case .pointerToInt: ok = fromPtr && toInt
        case .intToPointer: ok = fromInt && toPtr
        case .pointerToPointer: ok = fromPtr && toPtr
        case .toBool: ok = isBool(to) && typePool.isScalar(type: from.typeId)
        case .nullToPointer: ok = toPtr
        case .toVoid: ok = isVoid(to)
        case .toUnion: ok = typePool.isUnion(to.typeId)
        }
        if !ok { fail("\(kind.name) from \(typePool.name(of: from)) to \(typePool.name(of: to))") }
    }

    private func verifyCall(_ id: SemInstId, type: QualType, _ c: SemInstBlockContainer, fail: (String) -> Void) {
        let callee = SemInstId(c.block.arg0[id])
        let calleeType = c.block.type(of: callee)
        guard isPointer(calleeType), case .function(let ret, let params, let variadic) = typePool.typeInfo(of: canonical(typePool.pointeeType(of: calleeType.typeId))).kind else {
            fail("callee \(typePool.name(of: calleeType)) is not a pointer to a function")
            return
        }
        let extra = Array(c.block.extra(of: id))
        guard extra.count >= 3, Int(extra[2]) == extra.count - 3 else { fail("malformed argument list"); return }
        let args = extra.dropFirst(3).map { SemInstId($0) }
        if Int(extra[1]) != params.count { fail("records \(extra[1]) parameters, the type has \(params.count)") }
        if !same(ret.unqualified(), type) && !ret.isError { fail("returns \(typePool.name(of: type)), the callee \(typePool.name(of: ret))") }
        if args.count < params.count || (args.count > params.count && !variadic) {
            // A call with the wrong number of arguments is diagnosed; this one was accepted, so it is a builtin
            if module.declTable.name(of: DeclId(extra[0])).hasPrefix("__builtin_") == false && !isPoisonedAny(args, c) {
                fail("\(args.count) arguments for \(params.count) parameters")
            }
        }
        for (i, arg) in args.enumerated() where !isPoisoned(arg, c) {
            let t = c.block.type(of: arg)
            if i < params.count {
                if !same(t, params[i].unqualified()) && !params[i].isError { fail("argument \(i + 1) \(typePool.name(of: t)) not converted to \(typePool.name(of: params[i]))") }
            } else if !isPromoted(t) || canonical(t) == .float {
                fail("variadic argument \(i + 1) \(typePool.name(of: t)) not promoted")
            }
        }
    }

    private func isPoisonedAny(_ ids: [SemInstId], _ c: SemInstBlockContainer) -> Bool {
        ids.contains { isPoisoned($0, c) }
    }

    /// An initializer for an object of `type`: a value of the type, a braced `initList` of it, or a string literal
    /// for a character array.
    private func verifyInitializer(_ inst: SemInstId, for type: QualType, _ c: SemInstBlockContainer, fail: (String) -> Void) {
        let kind = c.block.kind(of: inst), t = c.block.type(of: inst)
        if isPoisoned(inst, c) || type.isError { return }
        switch kind {
        case .initList:
            if !same(t, type) && !isArrayOfUnknownSize(type) { fail("initializer list of \(typePool.name(of: t)) for \(typePool.name(of: type))") }
        case .stringLiteral:
            if case .array = typePool.typeInfo(of: canonical(type)).kind {} else { fail("string literal for \(typePool.name(of: type))") }
        default:
            if !same(t, type.unqualified()) { fail("initializer \(typePool.name(of: t)) not converted to \(typePool.name(of: type))") }
        }
    }

    private func isArrayOfUnknownSize(_ t: QualType) -> Bool {
        if case .array(_, 0) = typePool.typeInfo(of: canonical(t)).kind { return true }
        return false
    }

    private func verifyInitList(_ id: SemInstId, type: QualType, _ c: SemInstBlockContainer, fail: (String) -> Void) {
        let extra = Array(c.block.extra(of: id))
        guard extra.count % 3 == 0 else { fail("malformed entries"); return }
        let can = canonical(type)
        let info = typePool.typeInfo(of: can)
        var previousEnd = -1
        var i = 0
        while i + 2 < extra.count {
            let index = Int(extra[i]), count = Int(extra[i + 1]), value = SemInstId(extra[i + 2])
            i += 3
            if index < previousEnd { fail("entry \(index) overlaps the previous one") }
            previousEnd = index + max(1, count)
            var elementType: QualType
            switch info.kind {
            case .array(let element, let n):
                elementType = element
                if n > 0 && UInt64(index + count) > n { fail("element \(index) beyond the array") }
            case .struct(_, let fields, _):
                guard index < fields.count else { fail("member \(index) beyond the struct"); continue }
                elementType = fields[index].type
            default:
                if index != 0 { fail("scalar initializer list with element \(index)") }
                elementType = type
            }
            verifyInitializer(value, for: elementType, c, fail: fail)
        }
    }

    // MARK: - Control flow

    private struct FlowContext {
        var loops = 0
        var switches: [Set<UInt32>] = []  // the labels each enclosing switch lists
    }

    private mutating func verifyFunction(_ f: SemFunction, _ c: SemInstBlockContainer) {
        let blockIndex = Int(f.blockId.rawIndex)
        let root = c.block.root
        guard root.isValid, c.block.kind(of: root) == .compound else {
            report(blockIndex, root, "function '\(f.name)' has no root compound statement")
            return
        }
        var labels: [UInt32: Int] = [:]
        var gotos: [(SemInstId, UInt32)] = []
        var context = FlowContext()
        walkStatement(root, c, blockIndex: blockIndex, context: &context, labels: &labels, gotos: &gotos)
        for (inst, n) in gotos where labels[n] != 1 {
            report(blockIndex, inst, "goto label \(n) ('\(Int(n) < f.labels.count ? f.labels[Int(n)] : "?")') is defined \(labels[n] ?? 0) times")
        }
    }

    private mutating func walkStatement(_ id: SemInstId, _ c: SemInstBlockContainer, blockIndex: Int, context: inout FlowContext,
                                        labels: inout [UInt32: Int], gotos: inout [(SemInstId, UInt32)]) {
        guard id.isValid, id.rawIndex < c.block.count else { return }
        let kind = c.block.kind(of: id)
        guard kind.isStatement || kind == .errorInst else {
            report(blockIndex, id, "\(kind.name) in a statement position")
            return
        }
        let a0 = SemInstId(c.block.arg0[id]), a1 = SemInstId(c.block.arg1[id])
        let extra = Array(c.block.extra(of: id))
        func walk(_ s: SemInstId, _ ctx: inout FlowContext) {
            walkStatement(s, c, blockIndex: blockIndex, context: &ctx, labels: &labels, gotos: &gotos)
        }
        func walkExpression(_ e: SemInstId) {
            // A statement expression's body is a statement
            guard e.isValid, e.rawIndex < c.block.count else { return }
            if c.block.kind(of: e) == .stmtExpr {
                walk(SemInstId(c.block.arg0[e]), &context)
                return
            }
            for (op, _) in operands(e, c) where op.rawIndex < e.rawIndex { walkExpression(op) }
        }
        switch kind {
        case .compound:
            for s in extra { walk(SemInstId(s), &context) }
        case .exprStmt:
            walkExpression(a0)
        case .declLocal:
            if let initInst = extra.first { walkExpression(SemInstId(initInst)) }
        case .ifStmt:
            walkExpression(a0)
            for s in extra where s != 0 { walk(SemInstId(s), &context) }
        case .whileStmt, .doWhileStmt:
            context.loops += 1
            walk(kind == .whileStmt ? a1 : a0, &context)
            context.loops -= 1
            walkExpression(kind == .whileStmt ? a0 : a1)
        case .forStmt:
            guard extra.count == 4 else { report(blockIndex, id, "for: malformed"); return }
            if extra[0] != 0 { walk(SemInstId(extra[0]), &context) }
            walkExpression(SemInstId(extra[1]))
            walkExpression(SemInstId(extra[2]))
            context.loops += 1
            walk(SemInstId(extra[3]), &context)
            context.loops -= 1
        case .switchStmt:
            walkExpression(a0)
            guard extra.count >= 2 else { report(blockIndex, id, "switch: malformed"); return }
            var listed = Set(extra.dropFirst(2))
            if extra[1] != 0 { listed.insert(extra[1]) }
            for label in listed where label >= c.block.count || ![.caseLabel, .caseRange, .defaultLabel].contains(c.block.kind(of: SemInstId(label))) {
                report(blockIndex, id, "switch lists %\(label), not a case or default label")
            }
            context.switches.append(listed)
            walk(SemInstId(extra[0]), &context)
            context.switches.removeLast()
        case .caseLabel, .caseRange, .defaultLabel:
            if context.switches.last?.contains(id.rawIndex) != true {
                report(blockIndex, id, "\(kind.name) not listed by the enclosing switch")
            }
            walk(a0, &context)
        case .label:
            labels[a1.rawIndex, default: 0] += 1
            walk(a0, &context)
        case .gotoStmt:
            gotos.append((id, a0.rawIndex))
        case .breakStmt:
            if context.loops == 0 && context.switches.isEmpty { report(blockIndex, id, "break outside a loop or switch") }
        case .continueStmt:
            if context.loops == 0 { report(blockIndex, id, "continue outside a loop") }
        case .returnStmt, .indirectGoto:
            walkExpression(a0)
        default:
            break
        }
    }
}
