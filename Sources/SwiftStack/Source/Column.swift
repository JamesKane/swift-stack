// Sources/SwiftStack/Source/Column.swift

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A growable, arena-backed column of trivially copyable rows, indexed by a typed handle.
/// Backed by a reserved virtual-address range that is committed on demand, so growth
/// never moves existing rows (addresses stay stable across appends).
///
/// Principle 7: Row 0 is the nil row, initialized to zero.
@frozen
public struct Column<Id: TypedId, Element: BitwiseCopyable>: ~Copyable {
    @usableFromInline
    let base: UnsafeMutablePointer<Element>
    @usableFromInline
    var committedBytes: Int
    @usableFromInline
    let reservedBytes: Int
    @usableFromInline
    var _count: UInt32

    @inlinable
    public var count: UInt32 { _count }

    @usableFromInline
    static var pageSize: Int { 4096 }

    @usableFromInline
    static var elementStride: Int {
        let stride = MemoryLayout<Element>.stride
        return stride > 0 ? stride : 1
    }

    /// Initializes a column by reserving virtual address space and committing row 0.
    ///
    /// - Parameters:
    ///   - reservedCapacity: The maximum number of elements the column can reserve address space for.
    ///   - defaultNilValue: Optional custom value for row 0. If nil, row 0 is zero-initialized.
    public init(reservedCapacity: Int = 16_777_216, defaultNilValue: Element? = nil) {
        let stride = Self.elementStride
        let minBytes = max(reservedCapacity * stride, Self.pageSize)
        // Round up reserved bytes to page multiple
        self.reservedBytes = (minBytes + Self.pageSize - 1) & ~(Self.pageSize - 1)

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let mapFlags = MAP_PRIVATE | MAP_ANON
        #else
        let mapFlags = MAP_PRIVATE | MAP_ANONYMOUS
        #endif

        let rawPtr = mmap(nil, self.reservedBytes, PROT_NONE, mapFlags, -1, 0)
        guard rawPtr != MAP_FAILED, let validPtr = rawPtr else {
            fatalError("Column.init: failed to reserve virtual address space of \(self.reservedBytes) bytes")
        }

        self.base = validPtr.bindMemory(to: Element.self, capacity: self.reservedBytes / stride)
        self.committedBytes = 0
        self._count = 0

        // Commit at least the first page for row 0
        self.commitMemory(upToBytes: Self.pageSize)

        // Initialize Row 0 (Nil Row)
        if let defaultNilValue = defaultNilValue {
            self.base[0] = defaultNilValue
        } else {
            // Memory newly committed from PROT_NONE is already zero-filled by the OS
            // But we explicitly initialize to guarantee state
            let rawBytePtr = UnsafeMutableRawPointer(self.base)
            rawBytePtr.initializeMemory(as: UInt8.self, repeating: 0, count: stride)
        }
        self._count = 1
    }

    deinit {
        let rawPtr = UnsafeMutableRawPointer(base)
        munmap(rawPtr, reservedBytes)
    }

    @usableFromInline
    mutating func commitMemory(upToBytes neededBytes: Int) {
        guard neededBytes > committedBytes else { return }
        guard neededBytes <= reservedBytes else {
            fatalError("Column: required bytes (\(neededBytes)) exceeds reserved address space (\(reservedBytes))")
        }

        // Commit in page-aligned increments, doubling or at least 64 KiB
        let chunkMin = max(65536, Self.pageSize)
        var targetCommit = max(committedBytes * 2, committedBytes + chunkMin)
        if targetCommit < neededBytes {
            targetCommit = neededBytes
        }
        targetCommit = (targetCommit + Self.pageSize - 1) & ~(Self.pageSize - 1)
        if targetCommit > reservedBytes {
            targetCommit = reservedBytes
        }

        let bytesToCommit = targetCommit - committedBytes
        let commitPtr = UnsafeMutableRawPointer(base).advanced(by: committedBytes)

        let result = mprotect(commitPtr, bytesToCommit, PROT_READ | PROT_WRITE)
        guard result == 0 else {
            fatalError("Column: mprotect commit failed with error code \(result)")
        }
        committedBytes = targetCommit
    }

    /// Appends a single element to the column and returns its handle.
    @inlinable
    @discardableResult
    public mutating func append(_ value: Element) -> Id {
        let index = _count
        let neededBytes = Int(index + 1) * Self.elementStride
        if _slowPath(neededBytes > committedBytes) {
            commitMemory(upToBytes: neededBytes)
        }
        base[Int(index)] = value
        _count = index + 1
        return Id(rawIndex: index)
    }

    /// Appends a range of elements in bulk.
    @inlinable
    public mutating func appendRange(_ buffer: UnsafeBufferPointer<Element>) -> (start: Id, count: UInt32) {
        let appendCount = UInt32(buffer.count)
        if appendCount == 0 {
            return (start: Id(rawIndex: _count), count: 0)
        }
        let startIndex = _count
        let neededBytes = Int(startIndex + appendCount) * Self.elementStride
        if neededBytes > committedBytes {
            commitMemory(upToBytes: neededBytes)
        }
        if let srcBase = buffer.baseAddress {
            base.advanced(by: Int(startIndex)).initialize(from: srcBase, count: buffer.count)
        }
        _count = startIndex + appendCount
        return (start: Id(rawIndex: startIndex), count: appendCount)
    }

    /// Pre-commits memory to accommodate at least `minimumCapacity` elements without re-committing.
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        let neededBytes = minimumCapacity * Self.elementStride
        if neededBytes > committedBytes {
            commitMemory(upToBytes: neededBytes)
        }
    }

    /// Accesses an element by its typed handle.
    /// Handle 0 returns harmless defaults (row 0) instead of trapping.
    @inlinable
    public subscript(id: Id) -> Element {
        @inline(__always)
        get {
            let idx = id.rawIndex
            if _slowPath(idx >= _count) {
                // Harmless default for invalid/out-of-bounds handle
                return base[0]
            }
            return base[Int(idx)]
        }
        @inline(__always)
        set {
            let idx = id.rawIndex
            guard idx < _count else { return }
            base[Int(idx)] = newValue
        }
    }

    /// Accesses an element by raw 32-bit index.
    @inlinable
    public subscript(rawIndex: UInt32) -> Element {
        @inline(__always)
        get {
            if _slowPath(rawIndex >= _count) {
                return base[0]
            }
            return base[Int(rawIndex)]
        }
        @inline(__always)
        set {
            guard rawIndex < _count else { return }
            base[Int(rawIndex)] = newValue
        }
    }

    /// Accesses an element by integer index.
    @inlinable
    public subscript(index: Int) -> Element {
        @inline(__always)
        get {
            if _slowPath(index < 0 || index >= _count) {
                return base[0]
            }
            return base[index]
        }
        @inline(__always)
        set {
            guard index >= 0 && index < _count else { return }
            base[index] = newValue
        }
    }

    /// Runs a closure with a borrowed buffer pointer over valid rows.
    @inlinable
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        let buffer = UnsafeBufferPointer(start: base, count: Int(_count))
        return try body(buffer)
    }

    /// Runs a closure with a mutable buffer pointer over valid rows.
    @inlinable
    public mutating func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<Element>) throws -> R) rethrows -> R {
        let buffer = UnsafeMutableBufferPointer(start: base, count: Int(_count))
        return try body(buffer)
    }

    /// Runs a closure with a mutable buffer pointer over all committed capacity.
    @inlinable
    public mutating func withCommittedBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<Element>) throws -> R) rethrows -> R {
        let capacity = committedBytes / Self.elementStride
        let buffer = UnsafeMutableBufferPointer(start: base, count: capacity)
        return try body(buffer)
    }

    /// Sets the count of valid rows directly (e.g. after mutating committed memory).
    @inlinable
    public mutating func setCount(_ newCount: UInt32) {
        let neededBytes = Int(newCount) * Self.elementStride
        if neededBytes > committedBytes {
            commitMemory(upToBytes: neededBytes)
        }
        _count = newCount
    }

    /// The number of rows in the column (including the nil row at index 0).
    @inlinable
    public var rowCount: UInt32 { _count }

    /// The number of elements currently committed in physical memory.
    @inlinable
    public var capacity: Int { committedBytes / Self.elementStride }

    /// The number of bytes of physical memory committed for this column.
    @inlinable
    public var bytesCommitted: Int { committedBytes }

    /// The number of bytes of virtual address space reserved for this column.
    @inlinable
    public var bytesReserved: Int { reservedBytes }
}
