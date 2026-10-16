// Sources/SwiftStack/Codegen/X86/X86ABI.swift
//
// The System V x86-64 calling convention (04-backend.md §4.7.1; psABI §3.2.3): how each C argument and result
// travels, from the classification of its eightbytes.

import Foundation

public enum X86ABIClass: UInt8, Sendable, Equatable {
    case noClass, integer, sse, sseUp, x87, x87Up, memory

    /// The psABI merge of two classes for one eightbyte.
    func merged(with other: X86ABIClass) -> X86ABIClass {
        if self == other { return self }
        if self == .noClass { return other }
        if other == .noClass { return self }
        if self == .memory || other == .memory { return .memory }
        if self == .integer || other == .integer { return .integer }
        if self == .x87 || self == .x87Up || other == .x87 || other == .x87Up { return .memory }
        return .sse
    }
}

/// How one C value is passed or returned.
public struct X86ABIArgInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// In registers: one part per eightbyte.
        case direct
        /// In memory: on the stack for an argument; through a hidden pointer for a result.
        case memory
        /// On the x87 stack (`long double` result, or a struct holding just one).
        case x87
        /// Not passed at all (an empty struct).
        case ignore
    }

    /// One eightbyte passed in a register: its class (`integer` or `sse`), its offset in the value, and its size.
    public struct Part: Sendable, Equatable {
        public var isSSE: Bool
        public var offset: Int
        public var size: Int
    }

    public var kind: Kind
    public var parts: [Part] = []
    public var size: Int
    public var alignment: Int

    public var gprCount: Int { parts.filter { !$0.isSSE }.count }
    public var sseCount: Int { parts.filter(\.isSSE).count }
}

public struct X86ABI {
    public let types: TypePool

    public init(types: TypePool) { self.types = types }

    public static let gprArgs: [PhysReg] = [.rdi, .rsi, .rdx, .rcx, .r8, .r9]
    public static let sseArgs: [PhysReg] = (0..<8).map { PhysReg.xmm($0) }

    /// The classes of the eightbytes of a value of type `t` (none for an empty one), as psABI §3.2.3 defines them
    /// and as Clang computes them: each field is classified on its own (a nested aggregate as a whole) and merged
    /// into the eightbytes it covers, so the result depends on the nesting as Clang's does.
    public func classify(_ t: TypeId) -> [X86ABIClass] {
        let size = types.size(of: t)
        if size == 0 { return [] }
        if size > 16 { return [.memory] }
        var (lo, hi) = classify(t, offsetBits: 0)
        Self.postMerge(&lo, &hi)
        if lo == .memory { return [.memory] }
        if lo == .noClass && hi == .noClass { return [] }
        return size > 8 ? [lo, hi] : [lo]
    }

    /// The post-merger cleanup (psABI 3.2.3 step 5), which Clang applies to every aggregate it classifies, nested
    /// ones included.
    static func postMerge(_ lo: inout X86ABIClass, _ hi: inout X86ABIClass) {
        if hi == .memory { lo = .memory }
        if hi == .x87Up && lo != .x87 { lo = .memory }
        if hi == .sseUp && lo != .sse { hi = .sse }
    }

    /// The (low, high) eightbyte classes of a value of type `t` at bit offset `offsetBits` in its enclosing object.
    private func classify(_ t: TypeId, offsetBits: Int) -> (X86ABIClass, X86ABIClass) {
        let can = types.canonical(of: t)
        var lo = X86ABIClass.noClass, hi = X86ABIClass.noClass
        let inHigh = offsetBits >= 64
        func set(_ c: X86ABIClass) { if inHigh { hi = c } else { lo = c } }
        switch types.typeInfo(of: can).kind {
        case .bool, .pointer, .nullptr, .enum:
            set(.integer)
        case .int(let width, _):
            if width <= 64 { set(.integer) } else if width <= 128 { lo = .integer; hi = .integer } else { set(.memory) }
        case .float(let width):
            switch width {
            case 80: lo = .x87; hi = .x87Up
            case 128: lo = .sse; hi = .sseUp
            default: set(.sse)
            }
        case .array(let element, let count):
            let size = types.size(of: can)
            let es = types.size(of: element.typeId)
            // A flexible array member, or an empty array, has no class
            guard count > 0, es > 0 else { break }
            if size > 16 { set(.memory); break }
            if offsetBits % (8 * max(1, types.alignment(of: element.typeId))) != 0 { set(.memory); break }
            for k in 0..<Int(count) {
                let (flo, fhi) = classify(element.typeId, offsetBits: offsetBits + 8 * k * es)
                lo = lo.merged(with: flo)
                hi = hi.merged(with: fhi)
                if lo == .memory || hi == .memory { break }
            }
            Self.postMerge(&lo, &hi)
        case .struct(_, let fields, _):
            let size = types.size(of: can)
            if size > 16 { set(.memory); break }
            for f in fields {
                var flo = X86ABIClass.noClass, fhi = X86ABIClass.noClass
                let fieldOffset = offsetBits + 8 * Int(f.offset) + f.bitOffset
                if let bits = f.bitWidth {
                    // Unnamed bit-fields take no part
                    if bits == 0 || f.name.isEmpty { continue }
                    let low = fieldOffset / 64, high = (fieldOffset + bits - 1) / 64
                    if low > 0 { fhi = .integer } else {
                        flo = .integer
                        fhi = high > 0 ? .integer : .noClass
                    }
                } else {
                    // A field not at a multiple of its alignment makes the aggregate MEMORY
                    if types.size(of: f.type.typeId) > 0, fieldOffset % (8 * max(1, types.alignment(of: f.type.typeId))) != 0 {
                        lo = .memory
                        break
                    }
                    (flo, fhi) = classify(f.type.typeId, offsetBits: fieldOffset)
                }
                lo = lo.merged(with: flo)
                hi = hi.merged(with: fhi)
                if lo == .memory || hi == .memory { break }
            }
            Self.postMerge(&lo, &hi)
        default:
            set(.memory)
        }
        return (lo, hi)
    }

    /// How a value of C type `t` is passed as an argument (`isResult` false) or returned.
    public func info(_ t: TypeId, isResult: Bool) -> X86ABIArgInfo {
        let size = types.size(of: t)
        let alignment = max(types.alignment(of: t), 1)
        if types.typeInfo(of: types.canonical(of: t)).kind == .void { return X86ABIArgInfo(kind: .ignore, size: 0, alignment: 1) }
        let classes = classify(t)
        if classes.isEmpty { return X86ABIArgInfo(kind: .ignore, size: 0, alignment: alignment) }
        if classes == [.memory] { return X86ABIArgInfo(kind: .memory, size: size, alignment: alignment) }
        if classes.first == .x87 {
            // An argument of class X87 goes in memory; a result, on the x87 stack (with its X87UP half)
            return X86ABIArgInfo(kind: isResult && classes == [.x87, .x87Up] ? .x87 : .memory, size: size, alignment: alignment)
        }
        var parts: [X86ABIArgInfo.Part] = []
        var i = 0
        while i < classes.count {
            let c = classes[i]
            if c == .sse, i + 1 < classes.count, classes[i + 1] == .sseUp {
                // A 16-byte SSE value (`_Float128`) takes one XMM register
                parts.append(.init(isSSE: true, offset: i * 8, size: 16))
                i += 2
                continue
            }
            if c == .noClass { i += 1; continue }
            parts.append(.init(isSSE: c == .sse, offset: i * 8, size: min(8, size - i * 8)))
            i += 1
        }
        return X86ABIArgInfo(kind: .direct, parts: parts, size: size, alignment: alignment)
    }
}

/// Where each argument of a call (or each parameter of a function) goes.
public struct X86CallLayout: Sendable {
    public enum Location: Sendable, Equatable {
        /// In registers: per part, the register.
        case registers([PhysReg])
        /// On the stack at this offset from the stack pointer at the call (from the CFA - 16 at entry).
        case stack(offset: Int)
        case ignored
    }

    public var args: [Location] = []
    public var argInfo: [X86ABIArgInfo] = []
    public var result: X86ABIArgInfo
    /// The result goes through memory: the hidden pointer is the first integer argument.
    public var resultInMemory: Bool { result.kind == .memory }
    public var stackBytes = 0
    public var sseRegistersUsed = 0
    public var gprRegistersUsed = 0

    /// Lays out arguments of `infos` and a result of `result`.
    public init(args infos: [X86ABIArgInfo], result: X86ABIArgInfo) {
        self.result = result
        self.argInfo = infos
        var gpr = result.kind == .memory ? 1 : 0, sse = 0, stack = 0
        for info in infos {
            switch info.kind {
            case .ignore:
                args.append(.ignored)
            case .direct where gpr + info.gprCount <= 6 && sse + info.sseCount <= 8:
                var regs: [PhysReg] = []
                for p in info.parts {
                    if p.isSSE { regs.append(X86ABI.sseArgs[sse]); sse += 1 } else { regs.append(X86ABI.gprArgs[gpr]); gpr += 1 }
                }
                args.append(.registers(regs))
            default:
                // In memory, or in registers that ran out: on the stack, in 8-byte units, aligned to 16 if the type is
                let align = info.alignment > 8 ? 16 : 8
                stack = (stack + align - 1) / align * align
                args.append(.stack(offset: stack))
                stack += (info.size + 7) / 8 * 8
            }
        }
        stackBytes = (stack + 15) / 16 * 16
        sseRegistersUsed = sse
        gprRegistersUsed = gpr
    }
}
