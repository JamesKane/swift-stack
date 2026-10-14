// Sources/SwiftStack/Parse/ParseTree.swift
import Foundation

/// Node kinds for C parsing in the postorder parse tree (01-frontend.md §4.6).
@frozen
public enum CNodeKind: UInt8, Sendable, BitwiseCopyable, CustomStringConvertible {
    case nilNode = 0

    // Declarations & Structure
    case translationUnit = 1
    case functionDecl = 2
    case paramList = 3
    case paramDecl = 4
    case varDecl = 5

    // Types
    case typeSpec = 10
    case pointerType = 11

    // Statements
    case compoundStmt = 20
    case returnStmt = 21
    case ifStmt = 22
    case whileStmt = 23
    case exprStmt = 24

    // Expressions
    case assignExpr = 30
    case binaryExpr = 31
    case unaryExpr = 32
    case callExpr = 33
    case argList = 34
    case identExpr = 35
    case intLiteral = 36
    case stringLiteral = 37
    case charLiteral = 38

    // Error recovery
    case errorNode = 255

    public var description: String {
        switch self {
        case .nilNode: return "nilNode"
        case .translationUnit: return "translationUnit"
        case .functionDecl: return "functionDecl"
        case .paramList: return "paramList"
        case .paramDecl: return "paramDecl"
        case .varDecl: return "varDecl"
        case .typeSpec: return "typeSpec"
        case .pointerType: return "pointerType"
        case .compoundStmt: return "compoundStmt"
        case .returnStmt: return "returnStmt"
        case .ifStmt: return "ifStmt"
        case .whileStmt: return "whileStmt"
        case .exprStmt: return "exprStmt"
        case .assignExpr: return "assignExpr"
        case .binaryExpr: return "binaryExpr"
        case .unaryExpr: return "unaryExpr"
        case .callExpr: return "callExpr"
        case .argList: return "argList"
        case .identExpr: return "identExpr"
        case .intLiteral: return "intLiteral"
        case .stringLiteral: return "stringLiteral"
        case .charLiteral: return "charLiteral"
        case .errorNode: return "errorNode"
        }
    }
}

/// A postorder parse tree backed by Struct-of-Arrays (SoA) columns (01-frontend.md §4.6, 18-data-catalog.md §5.1).
///
/// Footprint: 9 bytes per node across three separate columns:
/// - `kinds`: 1 byte (NodeKind)
/// - `tokens`: 4 bytes (TokenId anchor)
/// - `subtreeSizes`: 4 bytes (bit 31 = hasError, bits 0..30 = subtree size including self)
///
/// In postorder layout, a node's children are appended before the node itself.
public struct ParseTree: ~Copyable {
    public var kinds: Column<NodeId, UInt8>
    public var tokens: Column<NodeId, UInt32>
    public var subtreeSizes: Column<NodeId, UInt32>

    @usableFromInline
    static let errorMask: UInt32 = 0x8000_0000
    @usableFromInline
    static let sizeMask: UInt32  = 0x7FFF_FFFF

    public init(reservedCapacity: Int = 1_048_576) {
        self.kinds = Column<NodeId, UInt8>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.tokens = Column<NodeId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.subtreeSizes = Column<NodeId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
    }

    @inlinable
    public var count: UInt32 {
        kinds.count
    }

    @inlinable
    public var bytesCommitted: Int {
        kinds.bytesCommitted + tokens.bytesCommitted + subtreeSizes.bytesCommitted
    }

    @inlinable
    public var bytesReserved: Int {
        kinds.bytesReserved + tokens.bytesReserved + subtreeSizes.bytesReserved
    }

    /// Appends a node to the postorder parse tree.
    @discardableResult
    @inlinable
    public mutating func append(
        kind: CNodeKind,
        token: TokenId,
        subtreeSize: UInt32,
        hasError: Bool = false
    ) -> NodeId {
        let sizeValue = (subtreeSize & Self.sizeMask) | (hasError ? Self.errorMask : 0)
        _ = kinds.append(kind.rawValue)
        _ = tokens.append(token.rawIndex)
        return subtreeSizes.append(sizeValue)
    }

    /// Appends a leaf node (subtree size = 1).
    @discardableResult
    @inlinable
    public mutating func appendLeaf(
        kind: CNodeKind,
        token: TokenId,
        hasError: Bool = false
    ) -> NodeId {
        append(kind: kind, token: token, subtreeSize: 1, hasError: hasError)
    }

    @inlinable
    public func kind(of node: NodeId) -> CNodeKind {
        guard node.isValid, node.rawIndex < count else { return .nilNode }
        return CNodeKind(rawValue: kinds[node]) ?? .nilNode
    }

    @inlinable
    public func token(of node: NodeId) -> TokenId {
        guard node.isValid, node.rawIndex < count else { return .nilId }
        return TokenId(tokens[node])
    }

    @inlinable
    public func subtreeSize(of node: NodeId) -> UInt32 {
        guard node.isValid, node.rawIndex < count else { return 0 }
        return subtreeSizes[node] & Self.sizeMask
    }

    @inlinable
    public func hasError(node: NodeId) -> Bool {
        guard node.isValid, node.rawIndex < count else { return false }
        return (subtreeSizes[node] & Self.errorMask) != 0
    }

    /// Returns the last child of a postorder node, or nilId if the node is a leaf.
    @inlinable
    public func lastChild(of node: NodeId) -> NodeId {
        let sz = subtreeSize(of: node)
        guard sz > 1 else { return .nilId }
        return NodeId(node.rawIndex - 1)
    }

    /// Returns the sibling before child `c`, or nilId if `c` is the first child of its parent.
    @inlinable
    public func prevSibling(of child: NodeId, parent: NodeId) -> NodeId {
        let childSz = subtreeSize(of: child)
        guard child.rawIndex > childSz else { return .nilId }
        let prev = NodeId(child.rawIndex - childSz)
        let parentStart = parent.rawIndex - subtreeSize(of: parent) + 1
        guard prev.rawIndex >= parentStart else { return .nilId }
        return prev
    }

    /// Returns all direct children of `node` in left-to-right source order.
    public func children(of node: NodeId) -> [NodeId] {
        let sz = subtreeSize(of: node)
        guard sz > 1 else { return [] }
        var list: [NodeId] = []
        let parentStart = node.rawIndex - sz + 1
        var curr = NodeId(node.rawIndex - 1)
        while curr.rawIndex >= parentStart && curr.isValid {
            list.append(curr)
            let childSz = subtreeSize(of: curr)
            if curr.rawIndex < childSz || curr.rawIndex - childSz < parentStart {
                break
            }
            curr = NodeId(curr.rawIndex - childSz)
        }
        return list.reversed()
    }
}
