// Sources/SwiftStack/Source/Arena.swift

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A fast bump-pointer arena allocator backed by reserve-then-commit virtual address space.
/// Supports O(1) reset for worker-local scratch allocations (Principle 2).
public final class Arena: @unchecked Sendable {
    private var base: UnsafeMutableRawPointer
    private var reservedBytes: Int
    private var committedBytes: Int
    private var offset: Int
    private var highWater: Int

    private static var pageSize: Int { 4096 }

    public init(reservedCapacity: Int = 64 * 1024 * 1024) {
        let minBytes = max(reservedCapacity, Self.pageSize)
        self.reservedBytes = (minBytes + Self.pageSize - 1) & ~(Self.pageSize - 1)

        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let mapFlags = MAP_PRIVATE | MAP_ANON
        #else
        let mapFlags = MAP_PRIVATE | MAP_ANONYMOUS
        #endif

        let rawPtr = mmap(nil, self.reservedBytes, PROT_NONE, mapFlags, -1, 0)
        guard rawPtr != MAP_FAILED, let validPtr = rawPtr else {
            fatalError("Arena.init: failed to reserve \(self.reservedBytes) bytes")
        }

        self.base = validPtr
        self.committedBytes = 0
        self.offset = 0
        self.highWater = 0

        // Pre-commit initial page
        self.commitMemory(upToBytes: Self.pageSize)
    }

    deinit {
        munmap(base, reservedBytes)
    }

    private func commitMemory(upToBytes neededBytes: Int) {
        guard neededBytes > committedBytes else { return }
        guard neededBytes <= reservedBytes else {
            fatalError("Arena: allocation exceeds reserved address space (\(reservedBytes) bytes)")
        }

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
        let commitPtr = base.advanced(by: committedBytes)

        let result = mprotect(commitPtr, bytesToCommit, PROT_READ | PROT_WRITE)
        guard result == 0 else {
            fatalError("Arena: mprotect failed with error \(result)")
        }
        committedBytes = targetCommit
    }

    /// Allocates a raw buffer of specified bytes and alignment.
    public func allocate(bytes: Int, alignment: Int = 8) -> UnsafeMutableRawPointer {
        guard bytes > 0 else { return base }
        let alignMask = alignment - 1
        let alignedOffset = (offset + alignMask) & ~alignMask
        let neededBytes = alignedOffset + bytes

        if neededBytes > committedBytes {
            commitMemory(upToBytes: neededBytes)
        }

        offset = neededBytes
        if offset > highWater {
            highWater = offset
        }
        return base.advanced(by: alignedOffset)
    }

    /// Allocates an array of uninitialized elements.
    public func allocate<T>(count: Int) -> UnsafeMutableBufferPointer<T> {
        guard count > 0 else {
            return UnsafeMutableBufferPointer(start: nil, count: 0)
        }
        let bytes = count * MemoryLayout<T>.stride
        let raw = allocate(bytes: bytes, alignment: MemoryLayout<T>.alignment)
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return UnsafeMutableBufferPointer(start: typed, count: count)
    }

    /// Copies a UTF-8 string into the arena memory with a terminating zero byte.
    public func allocateString(_ string: String) -> UnsafeBufferPointer<UInt8> {
        let utf8 = string.utf8
        let count = utf8.count
        let ptr = allocate(bytes: count + 1, alignment: 1).assumingMemoryBound(to: UInt8.self)
        var i = 0
        for byte in utf8 {
            ptr[i] = byte
            i += 1
        }
        ptr[count] = 0 // null terminator
        return UnsafeBufferPointer(start: ptr, count: count)
    }

    /// Copies an existing buffer of trivially copyable items into the arena.
    public func allocateCopy<T: BitwiseCopyable>(_ buffer: UnsafeBufferPointer<T>) -> UnsafeBufferPointer<T> {
        guard let src = buffer.baseAddress, buffer.count > 0 else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        let raw = allocate(bytes: buffer.count * MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment)
        let typed = raw.bindMemory(to: T.self, capacity: buffer.count)
        typed.initialize(from: src, count: buffer.count)
        return UnsafeBufferPointer(start: typed, count: buffer.count)
    }

    /// O(1) reset: resets the allocation offset to 0 while keeping committed pages intact.
    public func reset() {
        offset = 0
    }

    public var bytesAllocated: Int { offset }
    public var highWaterMark: Int { highWater }
    public var bytesCommitted: Int { committedBytes }
    public var bytesReserved: Int { reservedBytes }
}
