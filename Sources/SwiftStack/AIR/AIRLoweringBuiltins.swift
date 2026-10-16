// Sources/SwiftStack/AIR/AIRLoweringBuiltins.swift
//
// Calls to compiler builtins: `__builtin_*`, the GNU `__atomic_*` and legacy `__sync_*` atomics, and Clang's
// `__c11_atomic_*`. Each becomes AIR operations, or a call to the library function it names (`memcpy`, `sqrt`).
// Arguments arrive with the default argument promotions (sema declares builtins as `long (...)`); the result type
// is the builtin's own (`CSemanticAnalyzer.builtinResultType`).

import Foundation

extension FunctionLowering {
    /// The value of an integer constant argument (through conversions), if it is one.
    func constantArgument(_ id: SemInstId) -> Int64? {
        var i = id
        while kind(i).isConversion { i = arg0(i) }
        return kind(i) == .intLiteral ? c.block.intConstant(of: i) : nil
    }

    func ordering(_ args: [SemInstId], _ index: Int) -> AIRAtomicOrdering {
        guard index < args.count, let v = constantArgument(args[index]), let o = AIRAtomicOrdering(rawValue: UInt32(truncatingIfNeeded: v)) else {
            return .seqCst
        }
        return o
    }

    /// The bits of a scalar as an integer of its size (for atomics, which work on integers).
    mutating func bits(_ v: ValueId, of t: QualType) -> ValueId {
        let at = airType(t), mt = AIRType.int(max(8, size(t) * 8))
        switch at.kind {
        case .pointer: return resize(b.emit(.ptrtoint, .i64, v), from: .i64, to: mt, signed: false)
        case .float: return resize(b.emit(.bitcast, .int(at.width), v), from: .int(at.width), to: mt, signed: false)
        default: return resize(v, from: at, to: mt, signed: isSigned(t))
        }
    }

    /// A scalar of type `t` from the integer of its size holding its bits.
    mutating func scalar(_ v: ValueId, as t: QualType) -> ValueId {
        let at = airType(t), mt = AIRType.int(max(8, size(t) * 8))
        switch at.kind {
        case .pointer: return b.emit(.inttoptr, .ptr, resize(v, from: mt, to: .i64, signed: false))
        case .float: return b.emit(.bitcast, at, resize(v, from: mt, to: .int(at.width), signed: false))
        default: return resize(v, from: mt, to: at, signed: isSigned(t))
        }
    }

    /// An argument converted from its (promoted) type to `t`.
    mutating func argument(_ id: SemInstId, as t: QualType) -> ValueId {
        let v = value(id)
        return convert(v, from: type(id), to: t, kind: nil)
    }

    /// Lowers a builtin call; nil if the builtin is not supported (it is then reported).
    mutating func builtin(_ name: String, args: [SemInstId], type t: QualType, node: UInt32) -> ValueId? {
        let at = airType(t)
        func need(_ n: Int) -> Bool {
            if args.count >= n { return true }
            report("'\(name)' with \(args.count) arguments")
            return false
        }
        switch name {
        case "__builtin_expect", "__builtin_expect_with_probability":
            guard need(1) else { return zero(at) }
            let v = value(args[0])
            for a in args.dropFirst() { effect(a) }
            return convert(v, from: type(args[0]), to: t, kind: nil)
        case "__builtin_unreachable":
            b.emit(.unreachable)
            return .nilId
        case "__builtin_trap":
            b.emit(.trap)
            return .nilId
        case "__builtin_assume", "__builtin_constant_p", "__builtin_object_size", "__builtin_dynamic_object_size":
            // Operands are not evaluated
            if name.contains("object_size") {
                let kindBits = args.count > 1 ? constantArgument(args[1]) ?? 0 : 0
                return const(at, kindBits & 2 != 0 ? 0 : -1)
            }
            return at.isVoid ? .nilId : zero(at)
        case "__builtin_prefetch", "__builtin___clear_cache":
            for a in args { effect(a) }
            return .nilId
        case "__builtin_bswap16", "__builtin_bswap32", "__builtin_bswap64":
            guard need(1) else { return zero(at) }
            let w = name.hasSuffix("16") ? 16 : (name.hasSuffix("32") ? 32 : 64)
            let v = resize(value(args[0]), from: airType(type(args[0])), to: .int(w), signed: false)
            return resize(b.emit(.bswap, .int(w), v), from: .int(w), to: at, signed: false)
        case "__builtin_clz", "__builtin_clzl", "__builtin_clzll", "__builtin_ctz", "__builtin_ctzl", "__builtin_ctzll",
             "__builtin_popcount", "__builtin_popcountl", "__builtin_popcountll", "__builtin_parity", "__builtin_parityl",
             "__builtin_parityll", "__builtin_ffs", "__builtin_ffsl", "__builtin_ffsll", "__builtin_clrsb", "__builtin_clrsbl",
             "__builtin_clrsbll":
            guard need(1) else { return zero(at) }
            let w = name.hasSuffix("l") ? 64 : 32
            let wt = AIRType.int(w)
            let x = resize(value(args[0]), from: airType(type(args[0])), to: wt, signed: true)
            let r: ValueId
            if name.contains("clz") && !name.contains("clrsb") {
                r = b.emit(.clz, wt, x)
            } else if name.contains("ctz") {
                r = b.emit(.ctz, wt, x)
            } else if name.contains("popcount") {
                r = b.emit(.popcount, wt, x)
            } else if name.contains("parity") {
                r = b.emit(.and, wt, b.emit(.popcount, wt, x), const(wt, 1))
            } else if name.contains("ffs") {
                // 0 for 0, else one more than the index of the lowest set bit
                let isZero = b.emit(.icmp, .i1, x, const(wt, 0), aux: AIRICmp.eq.rawValue)
                let index = b.emit(.add, wt, b.emit(.ctz, wt, x), const(wt, 1))
                r = b.emit(.select, wt, isZero.rawIndex, const(wt, 0).rawIndex, aux: index.rawIndex)
            } else {
                // clrsb: leading bits equal to the sign bit, after it
                let y = b.emit(.xor, wt, x, b.emit(.ashr, wt, x, const(wt, Int64(w - 1))))
                let isZero = b.emit(.icmp, .i1, y, const(wt, 0), aux: AIRICmp.eq.rawValue)
                let count = b.emit(.sub, wt, b.emit(.clz, wt, y), const(wt, 1))
                r = b.emit(.select, wt, isZero.rawIndex, const(wt, Int64(w - 1)).rawIndex, aux: count.rawIndex)
            }
            return resize(r, from: wt, to: at, signed: false)
        case "__builtin_inf", "__builtin_inff", "__builtin_infl", "__builtin_huge_val", "__builtin_huge_valf", "__builtin_huge_vall":
            return floatConst(at, SoftFloat.infinity(floatFormat(at)))
        case "__builtin_nan", "__builtin_nanf", "__builtin_nanl", "__builtin_nans", "__builtin_nansf", "__builtin_nansl":
            return floatConst(at, SoftFloat.nan(floatFormat(at)))
        case "__builtin_fabs", "__builtin_fabsf", "__builtin_fabsl":
            guard need(1) else { return zero(at) }
            return b.emit(.fabs, at, argument(args[0], as: t))
        case "__builtin_copysign", "__builtin_copysignf", "__builtin_copysignl":
            guard need(2) else { return zero(at) }
            let x = argument(args[0], as: t), y = argument(args[1], as: t)
            let it = AIRType.int(at.width)
            let sign = b.constants.intern(it, signBit(at.width))
            let magnitude = b.emit(.and, it, b.emit(.bitcast, it, x), b.emit(.xor, it, sign, const(it, -1)))
            let signOfY = b.emit(.and, it, b.emit(.bitcast, it, y), sign)
            return b.emit(.bitcast, at, b.emit(.or, it, magnitude, signOfY))
        case "__builtin_sqrt", "__builtin_sqrtf", "__builtin_sqrtl":
            guard need(1) else { return zero(at) }
            return libraryCall(String(name.dropFirst("__builtin_".count)), returns: t, params: [t], args: Array(args.prefix(1)))
        case "__builtin_isnan", "__builtin_isinf", "__builtin_isfinite", "__builtin_signbit", "__builtin_signbitf", "__builtin_signbitl":
            guard need(1) else { return zero(at) }
            let xt = type(args[0])
            let x = value(args[0])
            let ft = airType(xt)
            guard ft.isFloat else { report("'\(name)' of a non-floating value"); return zero(at) }
            let r: ValueId
            switch name {
            case "__builtin_isnan":
                r = b.emit(.fcmp, .i1, x, x, aux: AIRFCmp.uno.rawValue)
            case "__builtin_isinf":
                r = b.emit(.fcmp, .i1, b.emit(.fabs, ft, x), floatConst(ft, SoftFloat.infinity(floatFormat(ft))), aux: AIRFCmp.oeq.rawValue)
            case "__builtin_isfinite":
                r = b.emit(.fcmp, .i1, b.emit(.fabs, ft, x), floatConst(ft, SoftFloat.infinity(floatFormat(ft))), aux: AIRFCmp.one.rawValue)
            default:
                let it = AIRType.int(ft.width)
                let top = b.emit(.lshr, it, b.emit(.bitcast, it, x), const(it, Int64(ft.width - 1)))
                r = b.emit(.trunc, .i1, top)
            }
            return resize(r, from: .i1, to: at, signed: false)
        case "__builtin_isgreater", "__builtin_isgreaterequal", "__builtin_isless", "__builtin_islessequal", "__builtin_islessgreater",
             "__builtin_isunordered":
            guard need(2) else { return zero(at) }
            // Both operands in the wider of their types
            let t0 = type(args[0]), t1 = type(args[1])
            let common = size(t0) >= size(t1) ? t0 : t1
            let x = argument(args[0], as: common), y = argument(args[1], as: common)
            let p: AIRFCmp
            switch name {
            case "__builtin_isgreater": p = .ogt
            case "__builtin_isgreaterequal": p = .oge
            case "__builtin_isless": p = .olt
            case "__builtin_islessequal": p = .ole
            case "__builtin_islessgreater": p = .one
            default: p = .uno
            }
            return resize(b.emit(.fcmp, .i1, x, y, aux: p.rawValue), from: .i1, to: at, signed: false)
        case "__builtin_abs", "__builtin_labs", "__builtin_llabs":
            guard need(1) else { return zero(at) }
            let x = argument(args[0], as: t)
            let negative = b.emit(.icmp, .i1, x, const(at, 0), aux: AIRICmp.slt.rawValue)
            let negated = b.emit(.sub, at, const(at, 0), x)
            return b.emit(.select, at, negative.rawIndex, negated.rawIndex, aux: x.rawIndex)
        case "__builtin_memcpy", "__builtin_memmove", "__builtin_memset", "__builtin_strlen", "__builtin_memcmp", "__builtin_strcmp",
             "__builtin_strncmp":
            let voidPtr = QualType(typeId: typePool.pointerTo(.void))
            let constVoidPtr = QualType(typeId: typePool.pointerTo(QualType.cVoid.withConst()))
            let constCharPtr = QualType(typeId: typePool.pointerTo(QualType.char.withConst()))
            let sizeT = QualType(typeId: layout.sizeType)
            let params: [QualType]
            switch name {
            case "__builtin_memcpy", "__builtin_memmove": params = [voidPtr, constVoidPtr, sizeT]
            case "__builtin_memset": params = [voidPtr, .int, sizeT]
            case "__builtin_strlen": params = [constCharPtr]
            case "__builtin_memcmp": params = [constVoidPtr, constVoidPtr, sizeT]
            case "__builtin_strcmp": params = [constCharPtr, constCharPtr]
            default: params = [constCharPtr, constCharPtr, sizeT]
            }
            guard need(params.count) else { return zero(at) }
            return libraryCall(String(name.dropFirst("__builtin_".count)), returns: t, params: params, args: Array(args.prefix(params.count)))
        case "__builtin_alloca", "__builtin_alloca_with_align":
            guard need(1) else { return zero(at) }
            let size = argument(args[0], as: QualType(typeId: layout.sizeType))
            let align = name == "__builtin_alloca" ? 16 : Int((args.count > 1 ? constantArgument(args[1]) ?? 128 : 128) / 8)
            return b.emit(.dynAlloca, .ptr, size, aux: UInt32(max(16, align)))
        case "__builtin_frame_address", "__builtin_return_address":
            let level = args.first.flatMap { constantArgument($0) } ?? 0
            return b.emit(name.contains("frame") ? .frameAddress : .returnAddress, .ptr, aux: UInt32(truncatingIfNeeded: level))
        case "__builtin_assume_aligned", "__builtin_extract_return_addr":
            guard need(1) else { return zero(at) }
            let p = value(args[0])
            for a in args.dropFirst() { effect(a) }
            return p
        case "__builtin_va_start", "__builtin_c23_va_start":
            guard need(1) else { return .nilId }
            b.emit(.vaStart, .void, value(args[0]))
            return .nilId
        case "__builtin_va_end":
            guard need(1) else { return .nilId }
            b.emit(.vaEnd, .void, value(args[0]))
            return .nilId
        case "__builtin_va_copy":
            guard need(2) else { return .nilId }
            let dst = value(args[0]), src = value(args[1])
            b.emit(.vaCopy, .void, dst, src)
            return .nilId
        case "__builtin_add_overflow", "__builtin_sub_overflow", "__builtin_mul_overflow":
            guard need(3) else { return zero(at) }
            return overflowArithmetic(name, args)
        default:
            if let r = atomic(name, args: args, type: t) { return r }
            if let math = CMathBuiltins.lookup(name) {
                guard need(math.arity) else { return zero(at) }
                return libraryCall(math.library, returns: t, params: Array(repeating: t, count: math.arity),
                                   args: Array(args.prefix(math.arity)))
            }
            report("unsupported builtin '\(name)'")
            for a in args { effect(a) }
            b.emit(.trap)
            return isAggregate(t) ? temporary(t) : (at.isVoid ? .nilId : zero(at))
        }
    }

    func signBit(_ width: Int) -> [UInt64] {
        var words = [UInt64](repeating: 0, count: (width + 63) / 64)
        words[(width - 1) / 64] = 1 << UInt64((width - 1) % 64)
        return words
    }

    /// A call to a library function with the C prototype `returns name(params)`, the arguments converted to it.
    mutating func libraryCall(_ name: String, returns t: QualType, params: [QualType], args: [SemInstId]) -> ValueId {
        let (s, fnType) = parent.librarySymbol(name, returns: t, params: params)
        var values: [ValueId] = []
        for (a, p) in zip(args, params) { values.append(argument(a, as: p)) }
        return emitCall(AIRLowering.globalValue(s), functionType: fnType, args: values, result: t)
    }

    /// `__builtin_{add,sub,mul}_overflow(a, b, &r)`: the exact result is computed in an integer wide enough for it,
    /// stored truncated to `*r`'s type, and the result is whether the truncation changed it.
    mutating func overflowArithmetic(_ name: String, _ args: [SemInstId]) -> ValueId {
        let ta = type(args[0]), tb = type(args[1]), tr = pointee(type(args[2]))
        func signedWidth(_ t: QualType) -> Int { airType(t).width + (isSigned(t) ? 0 : 1) }
        let wa = signedWidth(ta), wb = signedWidth(tb), wr = signedWidth(tr)
        var w = name.contains("mul") ? wa + wb : max(wa, wb) + 1
        w = max(w, wr)
        w = w <= 8 ? 8 : (w <= 16 ? 16 : (w <= 32 ? 32 : (w + 63) / 64 * 64))
        let wt = AIRType.int(w)
        let x = resize(value(args[0]), from: airType(ta), to: wt, signed: isSigned(ta))
        let y = resize(value(args[1]), from: airType(tb), to: wt, signed: isSigned(tb))
        let resultAddress = value(args[2])
        let op: AIROpcode = name.contains("add") ? .add : (name.contains("sub") ? .sub : .mul)
        let exact = b.emit(op, wt, x, y)
        let rt = airType(tr)
        let truncated = resize(exact, from: wt, to: rt, signed: false)
        let back = resize(truncated, from: rt, to: wt, signed: isSigned(tr))
        let overflow = b.emit(.icmp, .i1, back, exact, aux: AIRICmp.ne.rawValue)
        storeScalar(truncated, to: resultAddress, type: tr, alignment: alignment(tr), isVolatile: false)
        return overflow
    }

    // MARK: - Atomics

    /// The integer an atomic on objects of type `t` works on, if the size is one the target does lock-free.
    func atomicType(_ t: QualType, _ name: String) -> AIRType? {
        let s = size(t)
        guard [1, 2, 4, 8, 16].contains(s) else { return nil }
        return .int(s * 8)
    }

    mutating func atomicFlags(_ o: AIRAtomicOrdering, _ t: QualType, alignment: Int) -> UInt32 {
        o.rawValue | AIRMemFlags(alignment: alignment, isVolatile: t.isVolatile).rawValue << 8
    }

    /// The read-modify-write operation an atomic builtin's name ends in, and whether it returns the new value.
    func rmwOperation(_ name: String) -> (op: AIRAtomicOp, returnsNew: Bool)? {
        let table: [(String, AIRAtomicOp)] = [("add", .add), ("sub", .sub), ("and", .and), ("or", .or), ("xor", .xor), ("nand", .nand)]
        for (word, op) in table {
            if name.hasSuffix("_fetch_\(word)") || name.hasPrefix("__sync_fetch_and_\(word)") { return (op, false) }
            if name.hasSuffix("_\(word)_fetch") || name.hasPrefix("__sync_\(word)_and_fetch") { return (op, true) }
        }
        return nil
    }

    mutating func atomic(_ name: String, args: [SemInstId], type t: QualType) -> ValueId? {
        let at = airType(t)
        // Fences
        switch name {
        case "__atomic_thread_fence", "__c11_atomic_thread_fence", "__sync_synchronize":
            b.emit(.fence, aux: ordering(args, 0).rawValue)
            return .nilId
        case "__atomic_signal_fence", "__c11_atomic_signal_fence":
            b.emit(.fence, aux: ordering(args, 0).rawValue | 0x100)
            return .nilId
        case "__atomic_always_lock_free", "__atomic_is_lock_free", "__c11_atomic_is_lock_free":
            let s = args.first.flatMap { constantArgument($0) } ?? 0
            for a in args.dropFirst() { effect(a) }
            return const(at, [1, 2, 4, 8].contains(s) ? 1 : 0)
        default:
            break
        }
        guard let first = args.first, isPointer(type(first)) else { return nil }
        let objectType = pointee(type(first)).unqualified()
        let address = value(first)
        let align = alignment(objectType)
        guard let it = atomicType(objectType, name) else {
            report("'\(name)' on an object of \(size(objectType)) bytes")
            for a in args.dropFirst() { effect(a) }
            return at.isVoid ? .nilId : zero(at)
        }
        let isSync = name.hasPrefix("__sync_")
        let isC11 = name.hasPrefix("__c11_atomic_")
        /// The operand at `i` as the object's bits.
        func operand(_ i: Int) -> ValueId {
            let v = argument(args[i], as: objectType)
            return bits(v, of: objectType)
        }
        /// The value at the address in argument `i`, as bits.
        func loadOperand(_ i: Int) -> ValueId {
            b.emit(.load, it, value(args[i]), aux: AIRMemFlags(alignment: align).rawValue)
        }
        let base = name.replacingOccurrences(of: "__c11_atomic_", with: "__atomic_")
        switch base {
        case "__atomic_load_n", "__atomic_load" where isC11:
            let r = b.emit(.atomicLoad, it, address, aux: atomicFlags(ordering(args, 1), pointee(type(first)), alignment: align))
            return scalar(r, as: objectType)
        case "__atomic_load":
            // Generic: (ptr, ret, order)
            guard args.count >= 3 else { return nil }
            let r = b.emit(.atomicLoad, it, address, aux: atomicFlags(ordering(args, 2), pointee(type(first)), alignment: align))
            b.emit(.store, .void, r, value(args[1]), aux: AIRMemFlags(alignment: align).rawValue)
            return .nilId
        case "__atomic_store_n", "__atomic_store" where isC11, "__atomic_init":
            guard args.count >= 2 else { return nil }
            let v = operand(1)
            if base == "__atomic_init" {
                b.emit(.store, .void, v, address, aux: AIRMemFlags(alignment: align).rawValue)
            } else {
                b.emit(.atomicStore, .void, v, address, aux: atomicFlags(ordering(args, 2), pointee(type(first)), alignment: align))
            }
            return .nilId
        case "__atomic_store":
            guard args.count >= 3 else { return nil }
            let v = loadOperand(1)
            b.emit(.atomicStore, .void, v, address, aux: atomicFlags(ordering(args, 2), pointee(type(first)), alignment: align))
            return .nilId
        case "__atomic_exchange_n", "__atomic_exchange" where isC11, "__sync_lock_test_and_set":
            guard args.count >= 2 else { return nil }
            let v = operand(1)
            let o = isSync ? AIRAtomicOrdering.acquire : ordering(args, 2)
            let r = b.emit(.atomicRMW, it, address, v, aux: o.rawValue | AIRAtomicOp.xchg.rawValue << 8)
            return scalar(r, as: objectType)
        case "__atomic_exchange":
            guard args.count >= 4 else { return nil }
            let v = loadOperand(1)
            let r = b.emit(.atomicRMW, it, address, v, aux: ordering(args, 3).rawValue | AIRAtomicOp.xchg.rawValue << 8)
            b.emit(.store, .void, r, value(args[2]), aux: AIRMemFlags(alignment: align).rawValue)
            return .nilId
        case "__sync_lock_release":
            b.emit(.atomicStore, .void, const(it, 0), address, aux: atomicFlags(.release, pointee(type(first)), alignment: align))
            return .nilId
        case "__atomic_test_and_set":
            let r = b.emit(.atomicRMW, .i8, address, const(.i8, 1), aux: ordering(args, 1).rawValue | AIRAtomicOp.xchg.rawValue << 8)
            return resize(b.emit(.icmp, .i1, r, const(.i8, 0), aux: AIRICmp.ne.rawValue), from: .i1, to: at, signed: false)
        case "__atomic_clear":
            b.emit(.atomicStore, .void, const(.i8, 0), address, aux: atomicFlags(ordering(args, 1), pointee(type(first)), alignment: 1))
            return .nilId
        case "__atomic_compare_exchange_n", "__atomic_compare_exchange", "__atomic_compare_exchange_strong",
             "__atomic_compare_exchange_weak":
            // (ptr, expected ptr, desired [value or ptr], [weak,] success order, failure order)
            let generic = base == "__atomic_compare_exchange"
            let hasWeakArgument = !isC11
            guard args.count >= (hasWeakArgument ? 6 : 5) else { return nil }
            let expectedAddress = value(args[1])
            let desired = generic ? loadOperand(2) : operand(2)
            let weak = hasWeakArgument ? (constantArgument(args[3]) ?? 0) != 0 : base.hasSuffix("weak")
            let success = ordering(args, hasWeakArgument ? 4 : 3), failure = ordering(args, hasWeakArgument ? 5 : 4)
            if hasWeakArgument, constantArgument(args[3]) == nil { effect(args[3]) }
            return compareExchange(address, expectedAddress: expectedAddress, desired: desired, type: it, alignment: align, weak: weak,
                                   success: success, failure: failure, result: t)
        case "__sync_val_compare_and_swap", "__sync_bool_compare_and_swap":
            guard args.count >= 3 else { return nil }
            let expected = operand(1), desired = operand(2)
            let list = b.list([desired.rawIndex, AIRAtomicOrdering.seqCst.rawValue, AIRAtomicOrdering.seqCst.rawValue, 0])
            let old = b.emit(.cmpxchg, it, address.rawIndex, expected.rawIndex, aux: list)
            if base == "__sync_val_compare_and_swap" { return scalar(old, as: objectType) }
            return resize(b.emit(.icmp, .i1, old, expected, aux: AIRICmp.eq.rawValue), from: .i1, to: at, signed: false)
        default:
            guard let (op, returnsNew) = rmwOperation(base) else { return nil }
            guard args.count >= 2 else { return nil }
            let v = operand(1)
            let o = isSync ? AIRAtomicOrdering.seqCst : ordering(args, 2)
            let old = b.emit(.atomicRMW, it, address, v, aux: o.rawValue | op.rawValue << 8)
            guard returnsNew else { return scalar(old, as: objectType) }
            let new: ValueId
            switch op {
            case .add: new = b.emit(.add, it, old, v)
            case .sub: new = b.emit(.sub, it, old, v)
            case .and: new = b.emit(.and, it, old, v)
            case .or: new = b.emit(.or, it, old, v)
            case .xor: new = b.emit(.xor, it, old, v)
            case .nand: new = b.emit(.xor, it, b.emit(.and, it, old, v), const(it, -1))
            case .xchg: new = v
            }
            return scalar(new, as: objectType)
        }
    }

    /// A compare-and-exchange: on failure the value found is stored to `*expected`. Result: whether it succeeded.
    mutating func compareExchange(_ address: ValueId, expectedAddress: ValueId, desired: ValueId, type it: AIRType, alignment align: Int,
                                  weak: Bool, success: AIRAtomicOrdering, failure: AIRAtomicOrdering, result t: QualType) -> ValueId {
        let flags = AIRMemFlags(alignment: align).rawValue
        let expected = b.emit(.load, it, expectedAddress, aux: flags)
        let list = b.list([desired.rawIndex, success.rawValue, failure.rawValue, weak ? 1 : 0])
        let old = b.emit(.cmpxchg, it, address.rawIndex, expected.rawIndex, aux: list)
        let succeeded = b.emit(.icmp, .i1, old, expected, aux: AIRICmp.eq.rawValue)
        let storeBlock = b.newBlock(), join = b.newBlock()
        b.emit(.condBr, .void, succeeded.rawIndex, join.rawIndex, aux: storeBlock.rawIndex)
        b.position(at: storeBlock)
        b.emit(.store, .void, old, expectedAddress, aux: flags)
        b.branch(to: join)
        b.position(at: join)
        return resize(succeeded, from: .i1, to: airType(t), signed: false)
    }
}
