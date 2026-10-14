// Sources/SwiftStack/Sem/SemInstBlock.swift
import Foundation

/// SemIR instruction kind shared between C and Swift (10-semantic-ir-and-name-resolution.md §4.1).
@frozen
public enum SemInstKind: UInt16, BitwiseCopyable, Sendable {
    case nilInst = 0

    // Literals
    case intLiteral = 1
    case floatLiteral = 2
    case stringLiteral = 3
    case nullptrLiteral = 4
    case boolLiteral = 5

    // References
    case declRef = 10
    case memberRef = 11

    // Unary operations
    case unaryNeg = 20
    case unaryBitNot = 21
    case unaryLogicalNot = 22
    case addrOf = 23
    case deref = 24
    case preInc = 25
    case preDec = 26
    case postInc = 27
    case postDec = 28

    // Binary operations
    case add = 30
    case sub = 31
    case mul = 32
    case div = 33
    case mod = 34
    case shl = 35
    case shr = 36
    case bitAnd = 37
    case bitOr = 38
    case bitXor = 39
    case eq = 40
    case ne = 41
    case lt = 42
    case le = 43
    case gt = 44
    case ge = 45
    case logicalAnd = 46
    case logicalOr = 47

    // Assignments
    case assign = 50
    case compoundAssign = 51

    // Casts & conversions
    case explicitCast = 60
    case lvalueToRvalue = 61
    case intPromotion = 62
    case arithmeticConvert = 63
    case arrayToPointer = 64
    case functionToPointer = 65

    // Calls & subexpressions
    case call = 70
    case subscriptOp = 71
    case conditional = 72

    // Control flow
    case returnInst = 80
    case branch = 81
    case branchCond = 82
    case block = 83

    // C23 specific
    case genericSelection = 90
    case errorInst = 99
}

/// A flat, Column-backed block of SemIR instructions for a function or compound body (10-semantic-ir-and-name-resolution.md §4.1).
/// SemInstId 0 is universally reserved as the nil instruction (Principle 7).
public struct SemInstBlock: ~Copyable {
    public var kinds: Column<SemInstId, UInt16>
    public var types: Column<SemInstId, QualType>
    public var arg0: Column<SemInstId, UInt32>
    public var arg1: Column<SemInstId, UInt32>
    public var nodes: Column<SemInstId, UInt32>

    // Side storage for auxiliary data
    public private(set) var extraOperands: [UInt32] = []
    public private(set) var intConstants: [Int64] = []
    public private(set) var floatConstants: [Double] = []
    public private(set) var stringConstants: [String] = []

    public init(reservedCapacity: Int = 65_536) {
        self.kinds = Column<SemInstId, UInt16>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.types = Column<SemInstId, QualType>(reservedCapacity: reservedCapacity, defaultNilValue: .error)
        self.arg0 = Column<SemInstId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.arg1 = Column<SemInstId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.nodes = Column<SemInstId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
    }

    public var count: UInt32 {
        kinds.count
    }

    @discardableResult
    public mutating func append(
        kind: SemInstKind,
        type: QualType,
        arg0: UInt32 = 0,
        arg1: UInt32 = 0,
        node: NodeId = .nilId
    ) -> SemInstId {
        let id = SemInstId(kinds.count)
        _ = kinds.append(kind.rawValue)
        _ = types.append(type)
        _ = self.arg0.append(arg0)
        _ = self.arg1.append(arg1)
        _ = nodes.append(node.rawIndex)
        return id
    }

    @discardableResult
    public mutating func appendIntLiteral(value: Int64, type: QualType, node: NodeId = .nilId) -> SemInstId {
        let idx = UInt32(intConstants.count)
        intConstants.append(value)
        return append(kind: .intLiteral, type: type, arg0: idx, arg1: 0, node: node)
    }

    @discardableResult
    public mutating func appendFloatLiteral(value: Double, type: QualType, node: NodeId = .nilId) -> SemInstId {
        let idx = UInt32(floatConstants.count)
        floatConstants.append(value)
        return append(kind: .floatLiteral, type: type, arg0: idx, arg1: 0, node: node)
    }

    @discardableResult
    public mutating func appendStringLiteral(value: String, type: QualType, node: NodeId = .nilId) -> SemInstId {
        let idx = UInt32(stringConstants.count)
        stringConstants.append(value)
        return append(kind: .stringLiteral, type: type, arg0: idx, arg1: 0, node: node)
    }

    @discardableResult
    public mutating func appendCall(callee: SemInstId, args: [SemInstId], type: QualType, node: NodeId = .nilId) -> SemInstId {
        let offset = UInt32(extraOperands.count)
        for arg in args {
            extraOperands.append(arg.rawIndex)
        }
        return append(kind: .call, type: type, arg0: callee.rawIndex, arg1: offset, node: node)
    }

    public func kind(of id: SemInstId) -> SemInstKind {
        SemInstKind(rawValue: kinds[id]) ?? .nilInst
    }

    public func type(of id: SemInstId) -> QualType {
        types[id]
    }
}
