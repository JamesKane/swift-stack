// Sources/SwiftStack/Lex/TokenBuffer.swift

/// Struct-of-Arrays (SoA) token buffer with 10 bytes per token across 4 columns (01-frontend.md §4.4).
/// Backed by Column<TokenId, T> with virtual memory reserve-then-commit and nil row 0.
public struct TokenBuffer: ~Copyable {
    public var kinds: Column<TokenId, UInt8>
    public var flags: Column<TokenId, UInt8>
    public var starts: Column<TokenId, UInt32>
    public var ends: Column<TokenId, UInt32>
    /// `#pragma pack` state changes, in token order: from `token` on, the maximum member alignment is `alignment`
    /// (0: the target's default). Written by the C preprocessor, read by struct layout.
    public var packChanges: [(token: TokenId, alignment: Int)] = []

    /// Initializes a TokenBuffer with reserved column capacity.
    public init(reservedCapacity: Int = 67_108_864) {
        self.kinds = Column<TokenId, UInt8>(reservedCapacity: reservedCapacity)
        self.flags = Column<TokenId, UInt8>(reservedCapacity: reservedCapacity)
        self.starts = Column<TokenId, UInt32>(reservedCapacity: reservedCapacity)
        self.ends = Column<TokenId, UInt32>(reservedCapacity: reservedCapacity)
    }

    /// Appends a token to the buffer and returns its TokenId.
    @inlinable
    @discardableResult
    public mutating func append(kind: UInt8, flag: UInt8, start: UInt32, end: UInt32) -> TokenId {
        let id = kinds.append(kind)
        _ = flags.append(flag)
        _ = starts.append(start)
        _ = ends.append(end)
        return id
    }

    /// Appends a Swift token with typed kind and flags.
    @inlinable
    @discardableResult
    public mutating func append(swiftKind: SwiftTokenKind, flags: TokenFlags, start: SourceLocation, end: SourceLocation) -> TokenId {
        append(kind: swiftKind.rawValue, flag: flags.rawValue, start: start.rawValue, end: end.rawValue)
    }

    /// Appends a C token with typed kind and flags.
    @inlinable
    @discardableResult
    public mutating func append(cKind: CTokenKind, flags: TokenFlags, start: SourceLocation, end: SourceLocation) -> TokenId {
        append(kind: cKind.rawValue, flag: flags.rawValue, start: start.rawValue, end: end.rawValue)
    }

    /// Number of tokens in the buffer (including the nil token at row 0).
    @inlinable
    public var count: Int {
        Int(kinds.count)
    }

    /// Accesses the kind byte for a given TokenId.
    @inlinable
    public func kind(of id: TokenId) -> UInt8 {
        kinds[id]
    }

    /// Accesses the flag byte for a given TokenId.
    @inlinable
    public func flag(of id: TokenId) -> UInt8 {
        flags[id]
    }

    /// Accesses the start SourceLocation for a given TokenId.
    @inlinable
    public func start(of id: TokenId) -> SourceLocation {
        SourceLocation(starts[id])
    }

    /// Accesses the end SourceLocation for a given TokenId.
    @inlinable
    public func end(of id: TokenId) -> SourceLocation {
        SourceLocation(ends[id])
    }

    /// The `#pragma pack` alignment in effect at `id` (nil when none is).
    public func packAlignment(at id: TokenId) -> Int? {
        var result = 0
        for change in packChanges {
            if change.token.rawIndex > id.rawIndex { break }
            result = change.alignment
        }
        return result == 0 ? nil : result
    }

    /// Pre-commits capacity across all 4 columns.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        kinds.reserveCapacity(minimumCapacity)
        flags.reserveCapacity(minimumCapacity)
        starts.reserveCapacity(minimumCapacity)
        ends.reserveCapacity(minimumCapacity)
    }

    /// The maximum number of tokens that can fit in currently committed memory across all columns.
    @inlinable
    public var capacity: Int {
        min(kinds.capacity, flags.capacity, starts.capacity, ends.capacity)
    }

    /// Total memory currently committed for all 4 columns in bytes.
    public var bytesCommitted: Int {
        kinds.bytesCommitted + flags.bytesCommitted + starts.bytesCommitted + ends.bytesCommitted
    }

    /// Total memory reserved across all 4 columns in bytes.
    public var bytesReserved: Int {
        kinds.bytesReserved + flags.bytesReserved + starts.bytesReserved + ends.bytesReserved
    }
}
