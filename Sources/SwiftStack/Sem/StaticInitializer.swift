// Sources/SwiftStack/Sem/StaticInitializer.swift
//
// The static-initializer evaluator (02-semantic-analysis.md §4.2.3): folds the SemIR initializer of each object with
// static storage duration into its data image (C23 6.7.10p10, 6.6p7-9). Integers are folded in their type's width
// (`APInt`), floating values in their format (`SoftFloat`, so `long double` is folded as the x87 80-bit type on
// x86-64), and address constants become relocations: `&g`, `&g.f[3]`, functions, string literals and compound
// literals, plus a constant offset. The images match `clang -c` byte for byte (M3SemIRTests).

import Foundation

public struct StaticInitializerEvaluator {
    public enum Outcome {
        case image(DataImage)
        /// The initializer is not a constant expression (diagnosed as Clang does): the reason and its location.
        case notConstant(String, NodeId)
        /// A constant form the evaluator does not fold yet.
        case unsupported(String)
    }

    private enum Failure: Error {
        case notConstant(String, NodeId)
        case unsupported(String)
    }

    /// An object (or function) that an address constant points into, and a string literal's index.
    private enum Base: Equatable {
        case decl(DeclId)
        case string(Int)
        case label(DeclId, UInt32)
    }

    /// A folded scalar.
    private enum Value {
        case integer(APInt)
        case float(SoftFloat)
        /// An address constant `base + offset`; a nil base is a null pointer (offset 0) or an integer cast to a pointer.
        case address(Base?, Int64)
    }

    private let module: SemModule
    private var typePool: TypePool { module.typePool }
    public private(set) var staticStrings: [StringConstant] = []
    private var stringIndex: [StringConstant: Int] = [:]
    private var globalsBySymbol: [String: Int] = [:]
    /// Images of the `const` objects whose values other initializers read (a Clang extension), and the objects being
    /// evaluated (a self-referential read is not constant).
    private var imageCache: [Int: DataImage] = [:]
    private var inProgress: Set<Int> = []

    public init(module: SemModule) {
        self.module = module
        for (i, g) in module.globals.enumerated() where globalsBySymbol[g.symbol] == nil || g.symbol == ".compoundliteral" {
            globalsBySymbol[g.symbol] = i
        }
    }

    public mutating func evaluate(_ global: SemGlobal) -> Outcome {
        guard let index = module.globals.firstIndex(where: { $0.declId == global.declId }) else { return .unsupported("not a static object") }
        do {
            return .image(try image(ofGlobal: index))
        } catch Failure.notConstant(let reason, let node) {
            return .notConstant(reason, node)
        } catch Failure.unsupported(let reason) {
            return .unsupported(reason)
        } catch {
            return .unsupported("\(error)")
        }
    }

    private mutating func image(ofGlobal index: Int) throws -> DataImage {
        if let cached = imageCache[index] { return cached }
        let g = module.globals[index]
        guard !g.type.isError, typePool.isComplete(g.type.typeId) || isArray(g.type) else { throw Failure.unsupported("incomplete type") }
        guard inProgress.insert(index).inserted else { throw Failure.unsupported("initializer reads itself") }
        defer { inProgress.remove(index) }
        var image = DataImage(size: typePool.size(of: g.type.typeId))
        if g.initInst.isValid {
            let container = module.block(g.initBlock)
            try write(g.initInst, type: g.type, at: 0, into: &image, container)
        }
        imageCache[index] = image
        return image
    }

    // MARK: - Writing

    /// Writes the initializer `inst` of an object of `type` at `offset` in `image`.
    private mutating func write(_ inst: SemInstId, type: QualType, at offset: Int, into image: inout DataImage, _ c: SemInstBlockContainer) throws {
        let kind = c.block.kind(of: inst)
        let can = typePool.canonical(of: type.typeId)
        switch kind {
        case .initList:
            let items = Array(c.block.extra(of: inst))
            let fields = typePool.fields(of: can)
            var elementType = QualType.error
            var elementSize = 0
            if case .array(let element, let length) = typePool.typeInfo(of: can).kind {
                elementType = element
                elementSize = typePool.size(of: element.typeId)
                if length == 0 {
                    // A flexible array member initialized statically (a GNU extension): the object grows to hold it
                    var end = 0
                    for j in stride(from: 0, to: items.count - 2, by: 3) { end = max(end, Int(items[j]) + Int(items[j + 1])) }
                    grow(&image, to: offset + end * elementSize)
                }
            }
            var i = 0
            while i + 2 < items.count {
                let index = Int(items[i]), count = Int(items[i + 1]), value = SemInstId(items[i + 2])
                i += 3
                if !fields.isEmpty {
                    guard index < fields.count else { throw Failure.unsupported("member index out of range") }
                    let field = fields[index]
                    if let width = field.bitWidth {
                        guard case .integer(let bits) = try scalar(value, c) else { throw Failure.notConstant("bit-field value is not an integer", nodeOf(value, c)) }
                        insertBits(bits, width: width, at: offset + Int(field.offset), bitOffset: field.bitOffset, into: &image)
                    } else {
                        try write(value, type: field.type, at: offset + Int(field.offset), into: &image, c)
                    }
                } else if elementSize > 0 || !elementType.isError {
                    for k in 0..<count {
                        try write(value, type: elementType, at: offset + (index + k) * elementSize, into: &image, c)
                    }
                }
            }
        case .stringLiteral where isArray(type):
            // A character array initialized by a string literal: as many code units as fit (C23 6.7.10p15)
            let s = c.block.stringConstant(of: inst)
            let size = typePool.size(of: can)
            let n = size == 0 ? s.bytes.count : min(size, s.bytes.count)
            if size == 0 { grow(&image, to: offset + n) }
            try checkBounds(offset, n, image)
            for k in 0..<n { image.bytes[offset + k] = s.bytes[k] }
        default:
            if isStructOrUnion(type) || isArray(type) {
                // A struct or union value: a copy of a constant object (a compound literal, or a `const` object)
                try copyObject(inst, size: typePool.size(of: can), at: offset, into: &image, c)
                return
            }
            try store(try scalar(inst, c), type: type, at: offset, into: &image, node: nodeOf(inst, c))
        }
    }

    /// Stores a scalar of `type` at `offset`.
    private mutating func store(_ value: Value, type: QualType, at offset: Int, into image: inout DataImage, node: NodeId) throws {
        let can = typePool.canonical(of: type.typeId)
        let size = typePool.size(of: can)
        try checkBounds(offset, size, image)
        switch value {
        case .integer(let bits):
            let signed = typePool.isSignedInteger(type: can)
            let bytes = bits.littleEndianBytes(size: size, signed: signed)
            for k in 0..<size { image.bytes[offset + k] = bytes[k] }
        case .float(let f):
            let target = typePool.floatFormat(of: can).map { f.converted(to: $0) } ?? f
            let bytes = target.encoded()
            for k in 0..<min(size, bytes.count) { image.bytes[offset + k] = bytes[k] }
        case .address(let base, let addend):
            guard let base else {
                let bytes = APInt(width: 64, signed: addend).littleEndianBytes(size: size, signed: true)
                for k in 0..<size { image.bytes[offset + k] = bytes[k] }
                return
            }
            // An address fits only a pointer-sized object
            guard size == typePool.dataLayout.pointerSize else {
                throw Failure.notConstant("an address does not fit a \(size)-byte object", node)
            }
            let target: DataRelocation.Target
            switch base {
            case .decl(let d): target = .decl(d)
            case .string(let s): target = .string(s)
            case .label(let f, let n): target = .label(function: f, label: n)
            }
            image.relocations.append(DataRelocation(offset: offset, size: size, target: target, addend: addend))
        }
    }

    private func checkBounds(_ offset: Int, _ size: Int, _ image: DataImage) throws {
        guard offset >= 0, offset + size <= image.bytes.count else { throw Failure.unsupported("initializer beyond the object") }
    }

    /// Extends `image` with zero bytes to at least `size` bytes.
    private func grow(_ image: inout DataImage, to size: Int) {
        if size > image.bytes.count { image.bytes.append(contentsOf: [UInt8](repeating: 0, count: size - image.bytes.count)) }
    }

    /// Sets `width` bits at bit `bitOffset` of the storage unit at byte `offset` (little-endian bit order).
    private func insertBits(_ value: APInt, width: Int, at offset: Int, bitOffset: Int, into image: inout DataImage) {
        let v = value.truncated(to: width)
        for b in 0..<width {
            let bit = bitOffset + b
            let byte = offset + bit / 8
            guard byte < image.bytes.count else { return }
            let mask = UInt8(1) << UInt8(bit % 8)
            if v.bits.bit(b) { image.bytes[byte] |= mask } else { image.bytes[byte] &= ~mask }
        }
    }

    /// Copies a constant object read by `inst` (an lvalue conversion of a compound literal or `const` object).
    private mutating func copyObject(_ inst: SemInstId, size: Int, at offset: Int, into image: inout DataImage, _ c: SemInstBlockContainer) throws {
        guard c.block.kind(of: inst) == .lvalueToRvalue else {
            throw Failure.notConstant("initializer element is not a compile-time constant", nodeOf(inst, c))
        }
        let source = try objectBytes(at: try address(SemInstId(c.block.arg0[inst]), c), size: size, node: nodeOf(inst, c))
        try checkBounds(offset, size, image)
        for k in 0..<size { image.bytes[offset + k] = source.bytes[k] }
        for r in source.relocations {
            image.relocations.append(DataRelocation(offset: offset + r.offset, size: r.size, target: r.target, addend: r.addend))
        }
    }

    /// The bytes of the constant object an address points into (`size` bytes from its offset).
    private mutating func objectBytes(at address: (Base, Int64), size: Int, node: NodeId) throws -> DataImage {
        let whole: DataImage
        switch address.0 {
        case .string(let s):
            // A string literal's characters (`"abc"[1]`)
            whole = DataImage(bytes: staticStrings[s].bytes)
        case .decl(let decl):
            guard let index = constantGlobal(decl) else { throw Failure.notConstant("initializer element is not a compile-time constant", node) }
            whole = try image(ofGlobal: index)
        case .label:
            throw Failure.notConstant("initializer element is not a compile-time constant", node)
        }
        let start = Int(address.1)
        guard start >= 0, start + size <= whole.bytes.count else { throw Failure.notConstant("read outside the object", node) }
        var part = DataImage(size: size)
        for k in 0..<size { part.bytes[k] = whole.bytes[start + k] }
        part.relocations = whole.relocations.filter { $0.offset >= start && $0.offset < start + size }
            .map { DataRelocation(offset: $0.offset - start, size: $0.size, target: $0.target, addend: $0.addend) }
        return part
    }

    /// The global whose value a constant expression may read: a compound literal, or an object of `const`-qualified
    /// type with an initializer (folded as GCC and Clang do).
    private func constantGlobal(_ decl: DeclId) -> Int? {
        let symbol = module.symbolName(of: decl)
        if symbol == ".compoundliteral" {
            return module.globals.firstIndex { $0.declId == decl }
        }
        guard let index = globalsBySymbol[symbol] else { return nil }
        let g = module.globals[index]
        guard g.type.isConst || module.declTable.type(of: decl).isConst, g.initInst.isValid else { return nil }
        return index
    }

    // MARK: - Addresses

    /// The address an lvalue designates: an object with static storage or a function, a string literal, or a
    /// compound literal, plus an offset (C23 6.6p9).
    private mutating func address(_ inst: SemInstId, _ c: SemInstBlockContainer) throws -> (Base, Int64) {
        switch c.block.kind(of: inst) {
        case .declRef:
            let decl = DeclId(c.block.arg0[inst])
            let attrs = module.attributes(of: decl)
            let declKind = module.declTable.kind(of: decl)
            if declKind == .function || attrs.hasStaticStorage { return (.decl(decl), 0) }
            throw Failure.notConstant("refers to an object with automatic storage", nodeOf(inst, c))
        case .stringLiteral:
            return (.string(internString(c.block.stringConstant(of: inst))), 0)
        case .compoundLiteral:
            let decl = DeclId(c.block.arg0[inst])
            guard module.attributes(of: decl).hasStaticStorage else {
                throw Failure.notConstant("refers to a compound literal with automatic storage", nodeOf(inst, c))
            }
            return (.decl(decl), 0)
        case .member:
            let base = try address(SemInstId(c.block.arg0[inst]), c)
            return (base.0, base.1 + Int64(c.block.arg1[inst]))
        case .deref:
            switch try scalar(SemInstId(c.block.arg0[inst]), c) {
            case .address(let base?, let off): return (base, off)
            case .address(nil, let off): return (.decl(.nilId), off)  // `&((T *)0)->m`: an integer address
            default: throw Failure.notConstant("dereferences a non-address", nodeOf(inst, c))
            }
        default:
            throw Failure.notConstant("initializer element is not a compile-time constant", nodeOf(inst, c))
        }
    }

    /// Whether an lvalue designates part of a compound literal reached through a pointer (an array compound literal's
    /// element), which Clang does not fold.
    private func readsCompoundLiteralThroughPointer(_ inst: SemInstId, _ c: SemInstBlockContainer) -> Bool {
        var i = inst
        var throughPointer = false
        while true {
            switch c.block.kind(of: i) {
            case .member, .arrayToPointer, .ptrAdd, .ptrSub, .bitField:
                i = SemInstId(c.block.arg0[i])
            case .deref:
                throughPointer = true
                i = SemInstId(c.block.arg0[i])
            case .compoundLiteral:
                return throughPointer
            default:
                return false
            }
        }
    }

    private mutating func internString(_ s: StringConstant) -> Int {
        if let i = stringIndex[s] { return i }
        staticStrings.append(s)
        stringIndex[s] = staticStrings.count - 1
        return staticStrings.count - 1
    }

    // MARK: - Scalars

    private func nodeOf(_ inst: SemInstId, _ c: SemInstBlockContainer) -> NodeId {
        NodeId(c.block.nodes[inst])
    }

    private func isArray(_ t: QualType) -> Bool {
        if case .array = typePool.typeInfo(of: typePool.canonical(of: t.typeId)).kind { return true }
        return false
    }

    private func isStructOrUnion(_ t: QualType) -> Bool {
        if case .struct = typePool.typeInfo(of: typePool.canonical(of: t.typeId)).kind { return true }
        return false
    }

    private func width(_ t: QualType) -> Int {
        max(1, typePool.integerWidth(t.typeId))
    }

    private func isSigned(_ t: QualType) -> Bool {
        typePool.isSignedInteger(type: t.typeId)
    }

    /// Folds a scalar expression.
    private mutating func scalar(_ inst: SemInstId, _ c: SemInstBlockContainer) throws -> Value {
        let kind = c.block.kind(of: inst)
        let type = c.block.type(of: inst)
        let node = nodeOf(inst, c)
        let a0 = SemInstId(c.block.arg0[inst]), a1 = SemInstId(c.block.arg1[inst])
        switch kind {
        case .intLiteral:
            let v = c.block.intConstant(of: inst)
            return .integer(isSigned(type) ? APInt(width: width(type), signed: v) : APInt(width: width(type), value: UInt64(bitPattern: v)))
        case .floatLiteral:
            guard let format = typePool.floatFormat(of: type.typeId) else { throw Failure.unsupported("float format") }
            return .float(SoftFloat.decode(c.block.floatConstant(of: inst), format: format))
        case .nullptrLiteral:
            return .address(nil, 0)
        case .labelAddress:
            // `&&label` in a block-scope static's initializer: the label of the function whose body holds it
            guard let f = module.functions.first(where: { module.block($0.blockId) === c }) else {
                throw Failure.notConstant("a label address outside a function", node)
            }
            return .address(.label(f.declId, a0.rawIndex), 0)
        case .arrayToPointer, .functionToPointer, .addrOf:
            let (base, off) = try address(a0, c)
            return .address(base == .decl(.nilId) ? nil : base, off)
        case .lvalueToRvalue:
            // A read of a constant object (a Clang extension for `const` objects, and compound literals, but not an
            // element of an array compound literal)
            if readsCompoundLiteralThroughPointer(a0, c) { throw Failure.notConstant("initializer element is not a compile-time constant", node) }
            let size = typePool.size(of: typePool.canonical(of: type.typeId))
            let bytes = try objectBytes(at: try address(a0, c), size: size, node: node)
            return try decode(bytes, type: type, node: node)
        case .explicitCast, .intPromotion, .arithmeticConvert, .assignConvert, .argPromotion, .boolConvert, .nullPointerConvert:
            let from = c.block.type(of: a0)
            return try convert(try scalar(a0, c), from: from, to: type, kind: CastKind(rawValue: c.block.arg1[inst]) ?? .noop, node: node)
        case .ptrAdd, .ptrSub:
            guard case .address(let base, let off) = try scalar(a0, c), case .integer(let index) = try scalar(a1, c),
                  let n = index.int64(signed: true) else { throw Failure.notConstant("pointer arithmetic is not constant", node) }
            let elementSize = Int64(max(1, typePool.size(of: typePool.pointeeType(of: type.typeId).typeId)))
            return .address(base, kind == .ptrAdd ? off &+ n &* elementSize : off &- n &* elementSize)
        case .ptrDiff:
            guard case .address(let b1, let o1) = try scalar(a0, c), case .address(let b2, let o2) = try scalar(a1, c), b1 == b2 else {
                throw Failure.notConstant("pointer difference is not constant", node)
            }
            let elementSize = Int64(max(1, typePool.size(of: typePool.pointeeType(of: c.block.type(of: a0).typeId).typeId)))
            return .integer(APInt(width: width(type), signed: (o1 - o2) / elementSize))
        case .neg, .bitNot:
            switch try scalar(a0, c) {
            case .integer(let v): return .integer(kind == .neg ? v.negated() : v.not())
            case .float(let f) where kind == .neg: return .float(f.negated())
            default: throw Failure.notConstant("operand is not constant", node)
            }
        case .logicalNot:
            return .integer(APInt(width: width(type), value: try truth(try scalar(a0, c), node: node) ? 0 : 1))
        case .logicalAnd, .logicalOr:
            let l = try truth(try scalar(a0, c), node: node)
            if kind == .logicalAnd && !l { return .integer(APInt(width: width(type), value: 0)) }
            if kind == .logicalOr && l { return .integer(APInt(width: width(type), value: 1)) }
            return .integer(APInt(width: width(type), value: try truth(try scalar(a1, c), node: node) ? 1 : 0))
        case .add, .sub, .mul, .div, .mod, .shl, .shr, .bitAnd, .bitOr, .bitXor:
            return try arithmetic(kind, try scalar(a0, c), try scalar(a1, c), type: type, node: node)
        case .eq, .ne, .lt, .le, .gt, .ge:
            let operandType = c.block.type(of: a0)
            return .integer(APInt(width: width(type), value: try compare(kind, try scalar(a0, c), try scalar(a1, c),
                                                                           signed: isSigned(operandType), node: node) ? 1 : 0))
        case .conditional:
            let items = Array(c.block.extra(of: inst))
            guard items.count == 3 else { throw Failure.unsupported("conditional") }
            return try scalar(SemInstId(try truth(try scalar(SemInstId(items[0]), c), node: node) ? items[1] : items[2]), c)
        case .elvis:
            let v = try scalar(a0, c)
            if try truth(v, node: node) { return try convert(v, from: c.block.type(of: a0), to: type, kind: inferredCast(c.block.type(of: a0), type), node: node) }
            return try scalar(a1, c)
        case .initList:
            // `T x = {}` of a scalar type: zero
            if c.block.extra(of: inst).isEmpty { return zero(type) }
            return try scalar(SemInstId(c.block.extra(of: inst)[c.block.extra(of: inst).startIndex + 2]), c)
        case .call:
            return try builtinCall(inst, type: type, c)
        case .errorInst:
            throw Failure.unsupported("an unmodeled construct")
        default:
            throw Failure.notConstant("initializer element is not a compile-time constant", node)
        }
    }

    private func zero(_ type: QualType) -> Value {
        if let format = typePool.floatFormat(of: type.typeId) { return .float(.zero(format)) }
        if typePool.isPointer(type: type.typeId) { return .address(nil, 0) }
        return .integer(APInt.zero(width: width(type)))
    }

    /// The builtins that fold in initializers: `__builtin_inf`/`huge_val`/`nan` (and their `f`/`l` forms) and
    /// `__builtin_expect`.
    private mutating func builtinCall(_ inst: SemInstId, type: QualType, _ c: SemInstBlockContainer) throws -> Value {
        let items = Array(c.block.extra(of: inst))
        let decl = DeclId(items.first ?? 0)
        let name = module.declTable.name(of: decl)
        let args = items.dropFirst(3).map { SemInstId($0) }
        switch name {
        case "__builtin_inf", "__builtin_inff", "__builtin_infl", "__builtin_huge_val", "__builtin_huge_valf", "__builtin_huge_vall":
            return .float(.infinity(name.hasSuffix("f") ? .single : (name.hasSuffix("l") ? (typePool.floatFormat(of: .longdouble) ?? .double) : .double)))
        case "__builtin_nan", "__builtin_nanf", "__builtin_nanl":
            return .float(.nan(name.hasSuffix("f") ? .single : (name.hasSuffix("l") ? (typePool.floatFormat(of: .longdouble) ?? .double) : .double)))
        case "__builtin_expect" where args.count == 2:
            return try scalar(args[0], c)
        default:
            throw Failure.unsupported(decl.isValid ? "call to '\(name)'" : "a call")
        }
    }

    private func inferredCast(_ from: QualType, _ to: QualType) -> CastKind {
        if typePool.isFloating(type: to.typeId) { return typePool.isFloating(type: from.typeId) ? .floatToFloat : .intToFloat }
        if typePool.isPointer(type: to.typeId) { return typePool.isPointer(type: from.typeId) ? .pointerToPointer : .intToPointer }
        if typePool.isFloating(type: from.typeId) { return .floatToInt }
        return .intToInt
    }

    /// Decodes the bytes of a scalar of `type` read from a constant object.
    private func decode(_ bytes: DataImage, type: QualType, node: NodeId) throws -> Value {
        if let r = bytes.relocations.first {
            guard r.offset == 0 else { throw Failure.notConstant("a partial address", node) }
            switch r.target {
            case .decl(let d): return .address(.decl(d), r.addend)
            case .string(let s): return .address(.string(s), r.addend)
            case .label(let f, let n): return .address(.label(f, n), r.addend)
            }
        }
        var limbs = [UInt64](repeating: 0, count: (bytes.bytes.count + 7) / 8)
        for (i, b) in bytes.bytes.enumerated() { limbs[i / 8] |= UInt64(b) << UInt64((i % 8) * 8) }
        if let format = typePool.floatFormat(of: type.typeId) {
            return .float(SoftFloat.decode(FloatConstant(lo: limbs.first ?? 0, hi: limbs.count > 1 ? limbs[1] : 0), format: format))
        }
        if typePool.isPointer(type: type.typeId) { return .address(nil, Int64(bitPattern: limbs.first ?? 0)) }
        return .integer(APInt(width: width(type), bits: BigUInt(limbs: limbs)))
    }

    /// Whether a scalar compares unequal to 0. An address of an object is never null.
    private func truth(_ v: Value, node: NodeId) throws -> Bool {
        switch v {
        case .integer(let i): return !i.isZero
        case .float(let f): return !f.isZero
        case .address(let base, let off): return base != nil || off != 0
        }
    }

    private func convert(_ v: Value, from: QualType, to: QualType, kind: CastKind, node: NodeId) throws -> Value {
        let target = typePool.canonical(of: to.typeId)
        switch kind {
        case .toVoid:
            return v
        case .toBool:
            return .integer(APInt(width: 1, value: try truth(v, node: node) ? 1 : 0))
        case .noop, .pointerToPointer, .nullToPointer, .intToPointer, .pointerToInt, .intToInt:
            switch v {
            case .integer(let i):
                if typePool.isPointer(type: target) {
                    return .address(nil, i.extended(to: 64, signed: isSigned(from)).int64(signed: true) ?? 0)
                }
                return .integer(i.extended(to: width(to), signed: isSigned(from)))
            case .address(nil, let off) where typePool.isInteger(type: target):
                return .integer(APInt(width: width(to), signed: off))
            case .address:
                return v
            case .float:
                return v
            }
        case .intToFloat:
            guard case .integer(let i) = v, let format = typePool.floatFormat(of: target) else { throw Failure.notConstant("conversion", node) }
            let negative = isSigned(from) && i.isNegative
            return .float(SoftFloat.fromInteger(negative ? i.signedMagnitude : i.bits, negative: negative, format: format))
        case .floatToInt:
            // The integral part must be representable (C23 6.3.1.4p1). Clang's Sema accepts an out-of-range value with a
            // warning, and its code generator then fails: it is left unfolded, not diagnosed
            guard case .float(let f) = v, let (negative, magnitude) = f.truncatedInteger() else {
                throw Failure.unsupported("an infinity or NaN converted to an integer")
            }
            let w = width(to)
            let signedTarget = isSigned(to)
            let limit = BigUInt(1) << (signedTarget ? w - 1 : w)
            let fits = negative ? (signedTarget && !(limit < magnitude)) : magnitude < limit
            guard fits || target == .bool else { throw Failure.unsupported("a floating value out of the integer type's range") }
            let value = APInt(width: w, bits: magnitude)
            return .integer(negative ? value.negated() : value)
        case .floatToFloat:
            guard case .float(let f) = v, let format = typePool.floatFormat(of: target) else { throw Failure.notConstant("conversion", node) }
            return .float(f.converted(to: format))
        case .toUnion:
            throw Failure.unsupported("cast to a union")
        }
    }

    private func arithmetic(_ kind: SemInstKind, _ l: Value, _ r: Value, type: QualType, node: NodeId) throws -> Value {
        switch (l, r) {
        case (.integer(let a), .integer(let b)):
            let signed = isSigned(type)
            switch kind {
            case .add: return .integer(a.adding(b))
            case .sub: return .integer(a.subtracting(b))
            case .mul: return .integer(a.multiplied(by: b))
            case .div:
                guard let q = a.divided(by: b, signed: signed) else { throw Failure.notConstant("division by zero", node) }
                return .integer(q)
            case .mod:
                guard let q = a.remainder(dividingBy: b, signed: signed) else { throw Failure.notConstant("division by zero", node) }
                return .integer(q)
            case .shl, .shr:
                // The shift count is in its own (promoted) type; a count of the width or more is undefined
                // (Clang's Sema accepts it, and its code generator then fails: not diagnosed here either)
                guard let n = b.int64(signed: false), n < Int64(a.width) else { throw Failure.unsupported("shift count out of range") }
                return .integer(kind == .shl ? a.shiftedLeft(Int(n)) : a.shiftedRight(Int(n), signed: signed))
            case .bitAnd: return .integer(a.bitAnd(b))
            case .bitOr: return .integer(a.bitOr(b))
            case .bitXor: return .integer(a.bitXor(b))
            default: break
            }
        case (.float(let a), .float(let b)):
            switch kind {
            case .add: return .float(a.adding(b))
            case .sub: return .float(a.subtracting(b))
            case .mul: return .float(a.multiplied(by: b))
            case .div: return .float(a.divided(by: b))
            default: break
            }
        case (.address(let base, let off), .integer(let b)) where kind == .add || kind == .sub:
            // An address cast to an integer, plus or minus a constant
            guard let n = b.int64(signed: isSigned(type)) else { break }
            return .address(base, kind == .add ? off &+ n : off &- n)
        case (.integer(let a), .address(let base, let off)) where kind == .add:
            guard let n = a.int64(signed: isSigned(type)) else { break }
            return .address(base, off &+ n)
        default:
            break
        }
        throw Failure.notConstant("initializer element is not a compile-time constant", node)
    }

    private func compare(_ kind: SemInstKind, _ l: Value, _ r: Value, signed: Bool, node: NodeId) throws -> Bool {
        let order: Int
        switch (l, r) {
        case (.integer(let a), .integer(let b)):
            order = a.compare(b, signed: signed)
        case (.float(let a), .float(let b)):
            guard let o = a.compare(b) else { return kind == .ne }  // unordered: only `!=` holds
            order = o
        case (.address(let b1, let o1), .address(let b2, let o2)):
            if b1 == b2 {
                order = o1 == o2 ? 0 : (o1 < o2 ? -1 : 1)
            } else if kind == .eq || kind == .ne, b1 != nil || o1 == 0, b2 != nil || o2 == 0 {
                return kind == .ne  // distinct objects, or an object against a null pointer, compare unequal
            } else {
                throw Failure.unsupported("comparison of unrelated addresses")
            }
        default:
            throw Failure.notConstant("comparison is not constant", node)
        }
        switch kind {
        case .eq: return order == 0
        case .ne: return order != 0
        case .lt: return order < 0
        case .le: return order <= 0
        case .gt: return order > 0
        default: return order >= 0
        }
    }
}
