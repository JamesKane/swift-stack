// Sources/Source/SourceManager.swift

/// Manages source buffers with 64-byte zero-sentinel padding.
public final class SourceManager: @unchecked Sendable {
    public struct FileId: Hashable, Equatable, Sendable {
        public let rawValue: UInt32
        public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    }

    public struct Buffer: ~Copyable {
        public let fileId: FileId
        public let path: String
        public let memory: UnsafeBufferPointer<UInt8>
        public let lengthWithoutSentinel: Int

        public init(fileId: FileId, path: String, memory: UnsafeBufferPointer<UInt8>, length: Int) {
            self.fileId = fileId
            self.path = path
            self.memory = memory
            self.lengthWithoutSentinel = length
        }

        deinit {
            if let base = memory.baseAddress {
                UnsafeMutableRawPointer(mutating: base).deallocate()
            }
        }
    }

    private var buffers: [String: FileId] = [:]

    public init() {}

    /// Allocates an in-memory buffer with 64 zero sentinel bytes past the end.
    public static func allocateWithSentinel(bytes: [UInt8], fileId: FileId, path: String) -> Buffer {
        let total = bytes.count + 64
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
        bytes.withUnsafeBufferPointer { src in
            if let srcBase = src.baseAddress {
                ptr.initialize(from: srcBase, count: bytes.count)
            }
        }
        // Zero-fill the 64-byte sentinel zone
        (ptr + bytes.count).initialize(repeating: 0, count: 64)
        return Buffer(
            fileId: fileId,
            path: path,
            memory: UnsafeBufferPointer(start: ptr, count: total),
            length: bytes.count
        )
    }
}
