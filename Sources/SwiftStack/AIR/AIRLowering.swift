// Sources/SwiftStack/AIR/AIRLowering.swift
//
// SemIR → AIR (03-intermediate-representation.md §4.1; milestones/M3-plan.md §2, phase 2). Each function body, a
// tree of SemIR instructions, is walked from its root; static objects take their data images from the
// static-initializer evaluator. At `-O0` every named local lives in a stack slot (an `alloca` in the entry block) and
// every temporary is an SSA value; aggregates are handled by address (see `AIRFunction.swift`).

import Foundation

/// A construct AIR lowering cannot express. The module is still produced, with the construct replaced by a trap.
public struct AIRLoweringIssue: CustomStringConvertible, Sendable {
    public let function: String
    public let message: String
    public var description: String { function.isEmpty ? message : "\(function): \(message)" }
}

public final class AIRLowering {
    let sem: SemModule
    public let module: AIRModule
    public private(set) var issues: [AIRLoweringIssue] = []
    var typePool: TypePool { sem.typePool }

    /// The symbol of each declaration referred to.
    private var declSymbols: [DeclId: Int] = [:]
    /// String literals of function bodies (`.str`, `.str.1`, ...), by contents.
    private var stringSymbols: [StringConstant: Int] = [:]
    /// String literals of static initializers (`SemModule.staticStrings`), by index.
    private var staticStringSymbols: [Int: Int] = [:]
    /// Labels whose address a static initializer takes, by function symbol name.
    var staticLabelAddresses: [String: Set<UInt32>] = [:]
    /// Function types of the library functions builtins call.
    private var libraryTypes: [String: TypeId] = [:]

    public init(_ sem: SemModule) {
        self.sem = sem
        self.module = AIRModule(typePool: sem.typePool)
    }

    /// Lowers a module; `issues` lists what could not be lowered.
    public static func lower(_ sem: SemModule) -> AIRLowering {
        let l = AIRLowering(sem)
        l.run()
        return l
    }

    func report(_ function: String, _ message: String) {
        if issues.count < 1000 { issues.append(AIRLoweringIssue(function: function, message: message)) }
    }

    /// Internal definitions not yet emitted, by declaration: emitted when something emitted refers to them.
    private var pendingFunctions: [DeclId: SemFunction] = [:]
    private var pendingObjects: [DeclId: SemGlobal] = [:]
    private var functionQueue: [(SemFunction, Int)] = []
    private var objectQueue: [(SemGlobal, Int)] = []

    /// Emits the external definitions, then, as Clang does, the internal ones (`static` functions and objects,
    /// block-scope statics, compound literals) that something emitted refers to, transitively. Inline-only
    /// definitions are not emitted.
    public func run() {
        module.moduleAsm = sem.moduleAsm
        for g in sem.globals {
            if g.isExternal {
                if module.symbol(named: g.symbol) == nil { objectQueue.append((g, addObject(g))) }
                declSymbols[g.declId] = module.symbol(named: g.symbol)
            } else {
                pendingObjects[g.declId] = g
            }
        }
        for f in sem.functions where !f.isInlineOnly {
            if f.isExternal {
                functionQueue.append((f, addFunction(f)))
            } else {
                pendingFunctions[f.declId] = f
            }
        }
        for g in sem.globals {
            for r in g.image?.relocations ?? [] {
                if case .label(let fn, let label) = r.target { staticLabelAddresses[sem.symbolName(of: fn), default: []].insert(label) }
            }
        }
        while !functionQueue.isEmpty || !objectQueue.isEmpty {
            if let (g, s) = objectQueue.popLast() {
                // The image's relocations may name internal definitions, which this emits in turn
                guard let image = g.image else {
                    report("", "no data image for '\(g.symbol)': \(g.unsupportedReason)")
                    continue
                }
                module.symbols[s].image = convert(image, of: g.symbol)
                // An initialized flexible array member makes the object larger than its type (GNU)
                module.symbols[s].size = max(module.symbols[s].size, image.bytes.count)
                continue
            }
            let (f, s) = functionQueue.removeFirst()
            var lowering = FunctionLowering(self, f, symbol: s)
            let function = lowering.lower()
            module.functions.append(AIRFunctionBox(function))
            module.symbols[s].function = module.functions.count - 1
        }
        resolveLabelRelocations()
    }

    private func addObject(_ g: SemGlobal) -> Int {
        let isLocal = sem.staticSymbols[g.declId] != nil
        let s = module.add(AIRSymbol(
            name: isLocal ? module.uniqueName(g.symbol) : g.symbol, kind: .object, linkage: g.isExternal ? .external : .internal,
            isThreadLocal: g.isThreadLocal, isConstant: isConstant(g.type), cType: g.type, size: typePool.size(of: g.type.typeId),
            alignment: g.alignment, isTentative: g.isTentative, image: nil, function: nil))
        declSymbols[g.declId] = s
        return s
    }

    private func addFunction(_ f: SemFunction) -> Int {
        let name = sem.symbolName(of: f.declId)
        let s: Int
        if let existing = module.symbol(named: name) {
            module.symbols[existing].linkage = f.isExternal ? .external : .internal
            s = existing
        } else {
            s = module.add(AIRSymbol(
                name: name, kind: .function, linkage: f.isExternal ? .external : .internal, isThreadLocal: false, isConstant: true,
                cType: sem.declTable.type(of: f.declId), size: 0, alignment: 1, isTentative: false, image: nil, function: nil))
        }
        declSymbols[f.declId] = s
        return s
    }

    /// Relocations to label addresses, once every function is lowered.
    private var labelRelocations: [(symbol: Int, index: Int, function: Int, label: UInt32)] = []

    private func resolveLabelRelocations() {
        for r in labelRelocations {
            guard let index = module.symbols[r.function].function,
                  let block = module.functions[index].function.labelBlocks[r.label],
                  var image = module.symbols[r.symbol].image else {
                report("", "'\(module.symbols[r.symbol].name)': the address of label \(r.label) of '\(module.symbols[r.function].name)' has no block")
                continue
            }
            let old = image.relocations[r.index]
            image.relocations[r.index] = AIRDataImage.Relocation(offset: old.offset, size: old.size, target: .block(function: index, block: block),
                                                                 addend: old.addend)
            module.symbols[r.symbol].image = image
        }
    }

    /// Whether an object of `type` is read-only: const-qualified, or an array of const-qualified elements.
    func isConstant(_ type: QualType) -> Bool {
        if type.isConst { return true }
        if case .array(let element, _) = typePool.typeInfo(of: typePool.canonical(of: type.typeId)).kind { return isConstant(element) }
        if case .typedef(_, let underlying) = typePool.typeInfo(of: type.typeId).kind { return isConstant(underlying) }
        return false
    }

    private func convert(_ image: DataImage, of name: String) -> AIRDataImage {
        var relocations: [AIRDataImage.Relocation] = []
        let objectSymbol = module.symbol(named: name) ?? -1
        for r in image.relocations {
            let target: AIRDataImage.Target
            switch r.target {
            case .decl(let d):
                target = .symbol(symbol(for: d))
            case .string(let i):
                target = .symbol(staticStringSymbol(i))
            case .label(let fn, let label):
                // Resolved when the function is lowered
                let s = symbol(for: fn)
                labelRelocations.append((objectSymbol, relocations.count, s, label))
                target = .symbol(s)
            }
            relocations.append(AIRDataImage.Relocation(offset: r.offset, size: r.size, target: target, addend: r.addend))
        }
        return AIRDataImage(bytes: image.bytes, relocations: relocations)
    }

    // MARK: - Symbols

    /// The symbol of an object or function: its definition, or an undefined symbol for a declaration.
    func symbol(for decl: DeclId) -> Int {
        if let s = declSymbols[decl] { return s }
        let name = sem.symbolName(of: decl)
        // An internal definition referred to for the first time is emitted (a file-scope one may be referred to
        // through another declaration of the same name)
        if let g = pendingObjects.removeValue(forKey: decl) ?? pendingDefinition(named: name, in: \.pendingObjects) {
            let s = addObject(g)
            objectQueue.append((g, s))
            declSymbols[decl] = s
            return s
        }
        if let f = pendingFunctions.removeValue(forKey: decl) ?? pendingDefinition(named: name, in: \.pendingFunctions) {
            let s = addFunction(f)
            functionQueue.append((f, s))
            declSymbols[decl] = s
            return s
        }
        let s: Int
        if sem.staticSymbols[decl] == nil, let existing = module.symbol(named: name) {
            s = existing
        } else {
            let type = sem.declTable.type(of: decl)
            let isFunction = sem.declTable.kind(of: decl) == .function
            let complete = !type.isError && typePool.isComplete(type.typeId) && !isFunction
            s = module.add(AIRSymbol(
                name: sem.staticSymbols[decl] != nil ? module.uniqueName(name) : name, kind: isFunction ? .function : .object,
                linkage: .undefined, isThreadLocal: sem.attributes(of: decl).isThreadLocal, isConstant: isConstant(type), cType: type,
                size: complete ? typePool.size(of: type.typeId) : 0, alignment: complete ? typePool.alignment(of: type.typeId) : 1,
                isTentative: false, image: nil, function: nil))
        }
        declSymbols[decl] = s
        return s
    }

    /// A pending file-scope definition with symbol `name` (not a block-scope static, whose name is not its symbol).
    private func pendingDefinition<T>(named name: String, in table: ReferenceWritableKeyPath<AIRLowering, [DeclId: T]>) -> T? {
        guard let entry = self[keyPath: table].first(where: { sem.staticSymbols[$0.key] == nil && sem.symbolName(of: $0.key) == name }) else {
            return nil
        }
        self[keyPath: table][entry.key] = nil
        return entry.value
    }

    /// The symbol of a string literal of a function body: a read-only object `.str`, `.str.1`, ... (one per contents).
    func stringSymbol(_ value: StringConstant) -> Int {
        if let s = stringSymbols[value] { return s }
        let s = addString(value)
        stringSymbols[value] = s
        return s
    }

    private func staticStringSymbol(_ index: Int) -> Int {
        if let s = staticStringSymbols[index] { return s }
        let s = stringSymbol(sem.staticStrings[index])
        staticStringSymbols[index] = s
        return s
    }

    private func addString(_ value: StringConstant) -> Int {
        let element: TypeId
        switch value.elementSize {
        case 2: element = .ushort
        case 4: element = .uint
        default: element = .char
        }
        let type = QualType(typeId: typePool.arrayType(elementType: QualType(typeId: element).withConst(),
                                                         count: UInt64(value.bytes.count / max(1, value.elementSize))))
        return module.add(AIRSymbol(
            name: module.uniqueName(".str"), kind: .object, linkage: .internal, isThreadLocal: false, isConstant: true, cType: type,
            size: value.bytes.count, alignment: value.elementSize, isTentative: false,
            image: AIRDataImage(bytes: value.bytes, relocations: []), function: nil))
    }

    /// A library function a builtin becomes (`memcpy`, `sqrt`, ...), declared with its C type.
    func librarySymbol(_ name: String, returns: QualType, params: [QualType]) -> (symbol: Int, type: TypeId) {
        let type: TypeId
        if let t = libraryTypes[name] { type = t } else {
            type = typePool.functionType(returnType: returns, paramTypes: params)
            libraryTypes[name] = type
        }
        if let s = module.symbol(named: name) { return (s, type) }
        let s = module.add(AIRSymbol(name: name, kind: .function, linkage: .undefined, isThreadLocal: false, isConstant: true,
                                     cType: QualType(typeId: type), size: 0, alignment: 1, isTentative: false, image: nil, function: nil))
        return (s, type)
    }
}

/// Where an lvalue designates: memory at an address, or a bit-field in a storage unit.
enum AIRLValue {
    case memory(address: ValueId, alignment: Int, isVolatile: Bool)
    case bitField(unit: ValueId, unitBytes: Int, bitOffset: Int, width: Int, isSigned: Bool, alignment: Int, isVolatile: Bool)
}

/// Lowers one function body.
struct FunctionLowering {
    let parent: AIRLowering
    let sem: SemModule
    let function: SemFunction
    let symbol: Int
    let c: SemInstBlockContainer
    var b = AIRBuilder()
    var typePool: TypePool { sem.typePool }
    var module: AIRModule { parent.module }
    let layout: DataLayout

    var paramTypes: [AIRType] = []
    var paramIsAggregate: [Bool] = []
    var returnCType: QualType = .void

    /// The home of each local object and parameter: its address, and its alignment.
    var locals: [DeclId: (address: ValueId, alignment: Int)] = [:]
    /// A VLA object's address is stored in a slot when its declaration is reached.
    var vlaObjects: [DeclId: ValueId] = [:]
    /// The slot holding the length (`i64`) of each VLA type, stored where the type's size expression is evaluated.
    var vlaLengths: [TypeId: ValueId] = [:]
    /// The block of each label.
    var labels: [UInt32: BlockId] = [:]
    /// The VLA declarations in scope at each label, outermost first (`vlaChain`).
    var labelChains: [UInt32: [SemInstId]] = [:]
    /// The VLA declarations in scope here, outermost first, and the slot each one saved the stack pointer in before
    /// allocating.
    var vlaChain: [SemInstId] = []
    var vlaSaves: [SemInstId: ValueId] = [:]

    struct JumpTarget {
        let breakBlock: BlockId
        let continueBlock: BlockId?
        let vlaDepth: Int
    }
    var jumpTargets: [JumpTarget] = []
    /// The block of each `case`/`default` label of the enclosing `switch` statements.
    var caseBlocks: [SemInstId: BlockId] = [:]
    /// `indirectBr`s, given the address-taken blocks when the body is done.
    var indirectBranches: [ValueId] = []

    init(_ parent: AIRLowering, _ function: SemFunction, symbol: Int) {
        self.parent = parent
        self.sem = parent.sem
        self.function = function
        self.symbol = symbol
        self.c = parent.sem.block(function.blockId)
        self.layout = parent.sem.typePool.dataLayout
    }

    func report(_ message: String) {
        parent.report(function.name, message)
    }

    // MARK: - Types

    func canonicalKind(_ t: QualType) -> CTypeKind { typePool.typeInfo(of: typePool.canonical(of: t.typeId)).kind }

    /// Whether values of `t` live in memory (structs, unions, arrays; functions are designators).
    func isAggregate(_ t: QualType) -> Bool {
        switch canonicalKind(t) {
        case .struct, .array, .function: return true
        default: return false
        }
    }

    func isVoid(_ t: QualType) -> Bool {
        if case .void = canonicalKind(t) { return true }
        return false
    }

    /// The AIR type of a scalar of C type `t` (`ptr` for an aggregate, which is handled by address).
    func airType(_ t: QualType) -> AIRType {
        switch canonicalKind(t) {
        case .void, .error: return .void
        case .bool: return .i1
        case .int(let w, _): return .int(w)
        case .enum(_, let underlying, _): return airType(QualType(typeId: underlying))
        case .float(let w): return .float(w)
        case .pointer, .nullptr, .struct, .array, .function: return .ptr
        case .typedef(_, let u): return airType(u)
        }
    }

    /// The type a scalar of `t` is stored as: its size in bits for integers (`bool` as `i8`, a `_BitInt(N)` in its
    /// storage), else its value type.
    func memoryType(_ t: QualType) -> AIRType {
        let v = airType(t)
        guard v.isInt else { return v }
        return .int(max(8, typePool.size(of: t.typeId) * 8))
    }

    func isSigned(_ t: QualType) -> Bool { typePool.isSignedInteger(type: t.typeId) }
    func isFloating(_ t: QualType) -> Bool { typePool.isFloating(type: t.typeId) }
    func isPointer(_ t: QualType) -> Bool {
        switch canonicalKind(t) {
        case .pointer, .nullptr: return true
        default: return false
        }
    }
    func isBool(_ t: QualType) -> Bool { typePool.canonical(of: t.typeId) == .bool }
    func size(_ t: QualType) -> Int { typePool.size(of: t.typeId) }
    func alignment(_ t: QualType) -> Int { max(1, typePool.alignment(of: t.typeId)) }
    func pointee(_ t: QualType) -> QualType { typePool.pointeeType(of: t.typeId) }

    /// The alignment known for an address `offset` bytes past one aligned to `base`.
    func alignment(_ base: Int, offset: Int) -> Int {
        offset == 0 ? base : min(base, offset & -offset)
    }

    // MARK: - Constants

    mutating func const(_ type: AIRType, _ value: Int64) -> ValueId {
        let n = max(1, (type.width + 63) / 64)
        var words = [UInt64(bitPattern: value)]
        for _ in 1..<n { words.append(value < 0 ? ~0 : 0) }
        return b.constants.intern(type, words)
    }

    mutating func i64(_ value: Int) -> ValueId { const(.i64, Int64(value)) }

    mutating func floatConst(_ type: AIRType, _ value: FloatConstant) -> ValueId {
        b.constants.intern(type, [value.lo, value.hi])
    }

    func floatFormat(_ type: AIRType) -> FloatFormat {
        switch type.width {
        case 16: return .half
        case 32: return .single
        case 80: return .x87Extended
        case 128: return .quad
        default: return .double
        }
    }

    mutating func floatConst(_ type: AIRType, _ value: SoftFloat) -> ValueId {
        floatConst(type, value.constant)
    }

    mutating func floatOne(_ type: AIRType) -> ValueId {
        floatConst(type, SoftFloat.parse("1", format: floatFormat(type)) ?? .zero(floatFormat(type)))
    }

    mutating func zero(_ type: AIRType) -> ValueId {
        type.isFloat ? floatConst(type, SoftFloat.zero(floatFormat(type))) : (type.isPointer ? nullPointer() : const(type, 0))
    }

    mutating func nullPointer() -> ValueId { b.constants.intern(.ptr, [0]) }

    // MARK: - Function

    mutating func lower() -> AIRFunction {
        let fnType = sem.declTable.type(of: function.declId)
        var cParams: [QualType] = []
        if case .function(let ret, let params, _) = canonicalKind(fnType) {
            returnCType = ret
            cParams = params
        }
        paramTypes = cParams.map { airType($0) }
        paramIsAggregate = cParams.map { isAggregate($0) }
        let returnsAggregate = isAggregate(returnCType)

        // Parameters: a scalar is stored to its slot; an aggregate is the address of the callee's copy
        for (i, decl) in function.params.enumerated() where i < cParams.count {
            let t = sem.declTable.type(of: decl)
            if paramIsAggregate[i] {
                locals[decl] = (.parameter(UInt32(i)), alignment(t))
            } else {
                let home = slot(for: decl)
                storeScalar(.parameter(UInt32(i)), to: home.address, type: t, alignment: home.alignment, isVolatile: false)
            }
        }

        let root = c.block.root
        collectLabelChains(root, chain: [])
        statement(root)

        // Falling off the end: `main` returns 0 (C23 5.1.2.3.4), other functions an unspecified value
        if !b.isTerminated {
            if isVoid(returnCType) {
                b.emit(.ret)
            } else if returnsAggregate {
                let t = temporary(returnCType)
                b.emit(.ret, .void, t)
            } else {
                let t = airType(returnCType)
                b.emit(.ret, .void, zero(t))
            }
        }
        let targets = b.addressTaken.map(\.rawIndex)
        for br in indirectBranches { b.setAux(br, b.list(targets)) }
        let symbolName = module.symbols[symbol].name
        return b.finish(symbol: symbol, name: symbolName, cType: typePool.canonical(of: fnType.typeId),
                        returnType: returnsAggregate ? .void : airType(returnCType), returnsAggregate: returnsAggregate,
                        paramTypes: paramTypes, paramIsAggregate: paramIsAggregate)
    }

    /// The stack slot of a local object or parameter (created on first use).
    mutating func slot(for decl: DeclId) -> (address: ValueId, alignment: Int) {
        if let home = locals[decl] { return home }
        let t = sem.declTable.type(of: decl)
        var align = max(alignment(t), sem.objectAlignments[decl] ?? 1)
        if case .array = canonicalKind(t), sem.objectAlignments[decl] == nil {
            align = layout.variableAlignment(arraySize: size(t), typeAlignment: align)
        }
        let address = b.alloca(size: max(1, size(t)), alignment: align, name: sem.declTable.name(of: decl), decl: decl)
        locals[decl] = (address, align)
        return (address, align)
    }

    /// A temporary stack slot for a value of `t`.
    mutating func temporary(_ t: QualType) -> ValueId {
        b.alloca(size: max(1, size(t)), alignment: alignment(t))
    }

    // MARK: - Memory

    mutating func loadScalar(from address: ValueId, type t: QualType, alignment: Int, isVolatile: Bool) -> ValueId {
        let v = airType(t), m = memoryType(t)
        let loaded = b.emit(.load, m, address, aux: AIRMemFlags(alignment: alignment, isVolatile: isVolatile).rawValue)
        return v == m ? loaded : b.emit(.trunc, v, loaded)
    }

    mutating func storeScalar(_ value: ValueId, to address: ValueId, type t: QualType, alignment: Int, isVolatile: Bool) {
        let v = airType(t), m = memoryType(t)
        let stored = v == m ? value : b.emit(isSigned(t) ? .sext : .zext, m, value)
        b.emit(.store, .void, stored, address, aux: AIRMemFlags(alignment: alignment, isVolatile: isVolatile).rawValue)
    }

    mutating func copy(to dst: ValueId, from src: ValueId, size: ValueId, alignment: Int, isVolatile: Bool = false) {
        let list = b.list([size.rawIndex, AIRMemFlags(alignment: alignment, isVolatile: isVolatile).rawValue])
        b.emit(.copy, .void, dst.rawIndex, src.rawIndex, aux: list)
    }

    mutating func fill(_ dst: ValueId, byte: UInt8 = 0, size: ValueId, alignment: Int) {
        let list = b.list([size.rawIndex, AIRMemFlags(alignment: alignment).rawValue])
        let value = const(.i8, Int64(byte))
        b.emit(.fill, .void, dst.rawIndex, value.rawIndex, aux: list)
    }

    mutating func offset(_ address: ValueId, by bytes: Int) -> ValueId {
        bytes == 0 ? address : b.emit(.ptrAdd, .ptr, address, i64(bytes))
    }

    /// The value at an lvalue (`t` is its type): a loaded scalar, an extracted bit-field, or an aggregate's address.
    mutating func load(_ lv: AIRLValue, type t: QualType) -> ValueId {
        switch lv {
        case .memory(let address, let align, let isVolatile):
            if isAggregate(t) { return address }
            return loadScalar(from: address, type: t, alignment: align, isVolatile: isVolatile)
        case .bitField(let unit, let unitBytes, let bitOffset, let width, let isSigned, let align, let isVolatile):
            let ut = AIRType.int(unitBytes * 8)
            var v = b.emit(.load, ut, unit, aux: AIRMemFlags(alignment: align, isVolatile: isVolatile).rawValue)
            if isSigned {
                let left = unitBytes * 8 - bitOffset - width
                if left > 0 { v = b.emit(.shl, ut, v, const(ut, Int64(left))) }
                if unitBytes * 8 - width > 0 { v = b.emit(.ashr, ut, v, const(ut, Int64(unitBytes * 8 - width))) }
            } else {
                if bitOffset > 0 { v = b.emit(.lshr, ut, v, const(ut, Int64(bitOffset))) }
                if width < unitBytes * 8 { v = b.emit(.and, ut, v, mask(ut, width)) }
            }
            return resize(v, from: ut, to: airType(t), signed: isSigned)
        }
    }

    /// Stores `value` (of type `t`) to an lvalue, and returns the value the object then holds (a bit-field's value
    /// is truncated to its width; not computed unless `needsResult`).
    @discardableResult
    mutating func store(_ value: ValueId, to lv: AIRLValue, type t: QualType, needsResult: Bool = true) -> ValueId {
        switch lv {
        case .memory(let address, let align, let isVolatile):
            if isAggregate(t) {
                if address != value { copy(to: address, from: value, size: sizeValue(t), alignment: align, isVolatile: isVolatile) }
                return address
            }
            storeScalar(value, to: address, type: t, alignment: align, isVolatile: isVolatile)
            return value
        case .bitField(let unit, let unitBytes, let bitOffset, let width, let isSigned, let align, let isVolatile):
            let ut = AIRType.int(unitBytes * 8)
            let flags = AIRMemFlags(alignment: align, isVolatile: isVolatile).rawValue
            let widened = resize(value, from: airType(t), to: ut, signed: false)
            let fieldMask = mask(ut, width)
            var bits = b.emit(.and, ut, widened, fieldMask)
            if bitOffset > 0 { bits = b.emit(.shl, ut, bits, const(ut, Int64(bitOffset))) }
            let old = b.emit(.load, ut, unit, aux: flags)
            let keep = b.emit(.and, ut, old, b.emit(.xor, ut, b.emit(.shl, ut, fieldMask, const(ut, Int64(bitOffset))), const(ut, -1)))
            b.emit(.store, .void, b.emit(.or, ut, keep, bits), unit, aux: flags)
            guard needsResult else { return .nilId }
            // The value read back: the low `width` bits, extended
            var stored = widened
            if isSigned {
                if unitBytes * 8 > width {
                    stored = b.emit(.ashr, ut, b.emit(.shl, ut, widened, const(ut, Int64(unitBytes * 8 - width))), const(ut, Int64(unitBytes * 8 - width)))
                }
            } else {
                stored = b.emit(.and, ut, widened, fieldMask)
            }
            return resize(stored, from: ut, to: airType(t), signed: isSigned)
        }
    }

    /// The low `width` bits set, in `type`.
    mutating func mask(_ type: AIRType, _ width: Int) -> ValueId {
        var words = [UInt64](repeating: 0, count: max(1, (type.width + 63) / 64))
        for i in 0..<width { words[i / 64] |= 1 << UInt64(i % 64) }
        return b.constants.intern(type, words)
    }

    /// An integer converted between widths (truncated, or extended by `signed`).
    mutating func resize(_ v: ValueId, from: AIRType, to: AIRType, signed: Bool) -> ValueId {
        if from == to { return v }
        if from.width > to.width { return b.emit(.trunc, to, v) }
        return b.emit(signed && from.width > 1 ? .sext : .zext, to, v)
    }

    // MARK: - Sizes

    /// The size of `t` in bytes as an `i64`: a constant, or computed from the lengths of the VLA types in it.
    mutating func sizeValue(_ t: QualType) -> ValueId {
        guard typePool.isVariablyModified(t.typeId), case .array(let element, let count) = canonicalKind(t) else { return i64(size(t)) }
        let elementSize = sizeValue(element)
        let length: ValueId
        if typePool.isVariableLengthArray(t.typeId) {
            length = vlaLength(typePool.canonical(of: t.typeId))
        } else {
            length = i64(Int(count))
        }
        if case .constant = elementSize.valueTag, b.constants.int64(elementSize.index) == 1 { return length }
        return b.emit(.mul, .i64, length, elementSize)
    }

    /// The length of a VLA type, as evaluated where its declaration was reached.
    mutating func vlaLength(_ type: TypeId) -> ValueId {
        guard let home = vlaLengths[type] else {
            report("the length of a variable length array type is not evaluated before its use")
            return i64(0)
        }
        return b.emit(.load, .i64, home, aux: AIRMemFlags(alignment: 8).rawValue)
    }

    /// Stores the lengths of VLA types: (TypeId, length instruction) pairs, outermost first.
    mutating func evaluateVLALengths(_ pairs: ArraySlice<UInt32>) {
        var i = pairs.startIndex
        while i + 1 < pairs.endIndex {
            let type = typePool.canonical(of: TypeId(pairs[i]))
            let length = value(SemInstId(pairs[i + 1]))
            let home: ValueId
            if let h = vlaLengths[type] { home = h } else {
                home = b.alloca(size: 8, alignment: 8, name: "vla.length")
                vlaLengths[type] = home
            }
            b.emit(.store, .void, resize(length, from: b.type(of: length, params: paramTypes), to: .i64, signed: false), home,
                   aux: AIRMemFlags(alignment: 8).rawValue)
            i += 2
        }
    }

    /// The size of the objects a pointer of type `t` points to (1 for `void` and functions, as GNU C has it).
    mutating func pointeeSize(_ t: QualType) -> ValueId {
        let p = pointee(t)
        switch canonicalKind(p) {
        case .void, .function: return i64(1)
        default: return sizeValue(p)
        }
    }
}
