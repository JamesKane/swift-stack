// Sources/SwiftStack/AIR/AIRModule.swift
//
// An AIR module: the symbols of a translation unit (functions and objects, defined or referenced), the AIR of each
// function defined, and the initial contents of each object defined.

import Foundation

/// A function or object the module defines or refers to. A function or object's address is the global value
/// `ValueId.global(index)`.
public struct AIRSymbol: Sendable {
    public enum Kind: Sendable { case function, object }

    public enum Linkage: Sendable {
        /// Defined here, visible to other units.
        case external
        /// Defined here, local to the unit (`static`, block-scope statics, string literals, compound literals).
        case `internal`
        /// Referred to, defined elsewhere.
        case undefined
    }

    public var name: String
    public var kind: Kind
    public var linkage: Linkage
    public var isThreadLocal: Bool
    /// A read-only object (a string literal, or a `const` object without mutable members).
    public var isConstant: Bool
    /// The C type (a function type for a function).
    public var cType: QualType
    public var size: Int
    public var alignment: Int
    /// A tentative definition with no initializer (C23 6.9.2): zero-initialized.
    public var isTentative: Bool
    /// The initial contents of an object defined here.
    public var image: AIRDataImage?
    /// The index in `AIRModule.functions` of a function defined here.
    public var function: Int?
}

/// The initial contents of an object: its bytes, and relocations for the addresses stored in it.
public struct AIRDataImage: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A symbol's address.
        case symbol(Int)
        /// The address of a block of a function (GNU `&&label` in a static initializer).
        case block(function: Int, block: BlockId)
    }

    public struct Relocation: Sendable, Equatable {
        public let offset: Int
        public let size: Int
        public let target: Target
        public let addend: Int64
    }

    public var bytes: [UInt8]
    public var relocations: [Relocation]

    public var isZero: Bool { relocations.isEmpty && bytes.allSatisfy { $0 == 0 } }
}

/// A function's AIR, shared by reference so that an `AIRModule` can hold many.
public final class AIRFunctionBox: @unchecked Sendable {
    public var function: AIRFunction
    public init(_ function: consuming AIRFunction) { self.function = function }
}

public final class AIRModule: @unchecked Sendable {
    public var symbols: [AIRSymbol] = []
    public var functions: [AIRFunctionBox] = []
    /// `asm` templates, constraints, clobbers and operand names, by index (`AIRAsm`).
    public var strings: [String] = []
    /// File-scope `asm` declarations, in order.
    public var moduleAsm: [String] = []
    /// The C types the module's functions and calls refer to.
    public let typePool: TypePool

    private var symbolIndex: [String: Int] = [:]
    private var stringIndex: [String: UInt32] = [:]

    public init(typePool: TypePool) {
        self.typePool = typePool
    }

    /// The index of the symbol named `name`, if there is one.
    public func symbol(named name: String) -> Int? { symbolIndex[name] }

    /// Adds a symbol and returns its index; the name must be new (`uniqueName` makes one).
    @discardableResult
    public func add(_ symbol: AIRSymbol) -> Int {
        precondition(symbolIndex[symbol.name] == nil, "duplicate AIR symbol \(symbol.name)")
        symbols.append(symbol)
        symbolIndex[symbol.name] = symbols.count - 1
        return symbols.count - 1
    }

    /// `base`, or `base.1`, `base.2`, ... (as Clang numbers local symbols), whichever is not taken.
    public func uniqueName(_ base: String) -> String {
        guard symbolIndex[base] != nil else { return base }
        var n = 1
        while symbolIndex["\(base).\(n)"] != nil { n += 1 }
        return "\(base).\(n)"
    }

    public func intern(string: String) -> UInt32 {
        if let i = stringIndex[string] { return i }
        strings.append(string)
        stringIndex[string] = UInt32(strings.count - 1)
        return UInt32(strings.count - 1)
    }

    public var totalInstructions: Int {
        functions.reduce(0) { $0 + Int($1.function.instructionCount) - 1 }
    }
}
