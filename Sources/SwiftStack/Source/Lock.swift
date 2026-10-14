// Sources/SwiftStack/Source/Lock.swift

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A cross-platform mutex wrapping pthread_mutex_t.
public final class Mutex: @unchecked Sendable {
    @usableFromInline
    internal let mutexPtr: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        self.mutexPtr = .allocate(capacity: 1)
        pthread_mutex_init(mutexPtr, nil)
    }

    deinit {
        pthread_mutex_destroy(mutexPtr)
        mutexPtr.deallocate()
    }

    @inlinable
    public func lock() {
        pthread_mutex_lock(mutexPtr)
    }

    @inlinable
    public func unlock() {
        pthread_mutex_unlock(mutexPtr)
    }

    @inlinable
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
