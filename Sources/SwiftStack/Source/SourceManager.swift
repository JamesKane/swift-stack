// Sources/SwiftStack/Source/SourceManager.swift
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Line table for a single source file, built lazily using SWAR scanning for '\n'.
public struct LineTable: Sendable {
    /// 0-indexed byte offsets where each line begins.
    /// Index 0 is always offset 0 (line 1 start).
    public let lineStarts: [UInt32]

    public init(lineStarts: [UInt32]) {
        self.lineStarts = lineStarts
    }

    /// Translates a byte offset into 1-based (line, column).
    public func lineAndColumn(at offset: UInt32) -> (line: Int, column: Int) {
        guard !lineStarts.isEmpty else { return (1, 1) }

        var low = 0
        var high = lineStarts.count - 1
        var lineIndex = 0

        while low <= high {
            let mid = low + (high - low) / 2
            if lineStarts[mid] <= offset {
                lineIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let line = lineIndex + 1
        let col = Int(offset - lineStarts[lineIndex]) + 1
        return (line, col)
    }

    /// Builds a LineTable by SWAR scanning buffer bytes for '\n' (0x0A).
    public static func build(for buffer: UnsafeBufferPointer<UInt8>) -> LineTable {
        guard let base = buffer.baseAddress, buffer.count > 0 else {
            return LineTable(lineStarts: [0])
        }

        var starts: [UInt32] = [0]
        starts.reserveCapacity(max(16, buffer.count / 40)) // rough estimate ~40 chars per line

        let count = buffer.count
        var i = 0

        // SWAR scan 8 bytes at a time
        let wordCount = count / 8
        let u64Ptr = UnsafeRawPointer(base).bindMemory(to: UInt64.self, capacity: wordCount)
        let nlMask: UInt64 = 0x0A0A_0A0A_0A0A_0A0A
        let loBits: UInt64 = 0x0101_0101_0101_0101
        let hiBits: UInt64 = 0x8080_8080_8080_8080

        for w in 0..<wordCount {
            let word = u64Ptr[w]
            let diff = word ^ nlMask
            let match = (diff &- loBits) & ~diff & hiBits
            if match != 0 {
                // At least one newline in this 8-byte word
                let baseOffset = UInt32(w * 8)
                for b in 0..<8 {
                    if base[Int(baseOffset) + b] == 0x0A {
                        let nextStart = baseOffset + UInt32(b) + 1
                        if Int(nextStart) < count {
                            starts.append(nextStart)
                        }
                    }
                }
            }
        }

        i = wordCount * 8
        while i < count {
            if base[i] == 0x0A {
                let nextStart = UInt32(i + 1)
                if Int(nextStart) < count {
                    starts.append(nextStart)
                }
            }
            i += 1
        }

        return LineTable(lineStarts: starts)
    }
}

/// Information and buffer for a single source file.
public final class SourceFile: @unchecked Sendable {
    public let id: FileId
    public let path: String
    /// Base pointer to buffer, includes 64 zero sentinel bytes past `length`.
    public let buffer: UnsafeBufferPointer<UInt8>
    public let length: Int
    public let baseLocation: SourceLocation
    private var cachedLineTable: LineTable?
    private let lock = Mutex()

    public init(id: FileId, path: String, buffer: UnsafeBufferPointer<UInt8>, length: Int, baseLocation: SourceLocation = .zero) {
        self.id = id
        self.path = path
        self.buffer = buffer
        self.length = length
        self.baseLocation = baseLocation
        self.cachedLineTable = nil
    }

    deinit {
        if let base = buffer.baseAddress {
            UnsafeMutableRawPointer(mutating: base).deallocate()
        }
    }

    /// Returns the file's line table, computing it lazily on the first request.
    public func lineTable() -> LineTable {
        return lock.withLock {
            if let table = cachedLineTable {
                return table
            }
            let table = LineTable.build(for: UnsafeBufferPointer(start: buffer.baseAddress, count: length))
            cachedLineTable = table
            return table
        }
    }
}

/// SourceManager manages loaded source files with 64 zero-sentinel bytes.
/// Indexed by 32-bit FileId, with FileId(0) being the nil file (Principles 2 and 7).
public final class SourceManager: @unchecked Sendable {
    private var files: [SourceFile?] = []
    private var nextBaseLocation: UInt32 = 0
    private let lock = Mutex()

    public init() {
        // Nil file at index 0 (Principle 7: Zero is nil)
        let nilBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        nilBuffer.initialize(repeating: 0, count: 64)
        let nilFile = SourceFile(
            id: FileId(0),
            path: "<nil>",
            buffer: UnsafeBufferPointer(start: nilBuffer, count: 64),
            length: 0,
            baseLocation: .zero
        )
        self.files.append(nilFile)
    }

    deinit {
    }

    /// Adds an in-memory buffer, appending 64 zero-sentinel bytes.
    @discardableResult
    public func addBuffer(bytes: [UInt8], path: String) -> FileId {
        return bytes.withUnsafeBufferPointer { buf in
            addBuffer(buf, path: path)
        }
    }

    /// Adds an in-memory buffer pointer, copying into an allocation with 64 zero-sentinel bytes.
    @discardableResult
    public func addBuffer(_ buffer: UnsafeBufferPointer<UInt8>, path: String) -> FileId {
        let length = buffer.count
        let total = length + 64
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
        if let src = buffer.baseAddress, length > 0 {
            ptr.initialize(from: src, count: length)
        }
        // 64 zero bytes of sentinel padding
        (ptr + length).initialize(repeating: 0, count: 64)

        return lock.withLock {
            let fileId = FileId(UInt32(files.count))
            let baseLoc = SourceLocation(nextBaseLocation)
            nextBaseLocation += UInt32(length + 1)
            let sourceFile = SourceFile(
                id: fileId,
                path: path,
                buffer: UnsafeBufferPointer(start: ptr, count: total),
                length: length,
                baseLocation: baseLoc
            )
            files.append(sourceFile)
            return fileId
        }
    }

    /// Loads a source file from disk into a buffer with 64 zero sentinel bytes.
    public func loadFile(path: String) throws -> FileId {
        let existingId: FileId? = lock.withLock {
            for file in files {
                if let file = file, file.path == path {
                    return file.id
                }
            }
            return nil
        }
        if let existingId = existingId {
            return existingId
        }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        defer { close(fd) }

        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let length = Int(statBuf.st_size)
        let total = length + 64
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: total)

        var bytesRead = 0
        while bytesRead < length {
            let n = read(fd, ptr.advanced(by: bytesRead), length - bytesRead)
            if n < 0 {
                if errno == EINTR { continue }
                ptr.deallocate()
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            bytesRead += n
        }

        // Sentinel padding
        (ptr + bytesRead).initialize(repeating: 0, count: 64)

        return lock.withLock {
            let fileId = FileId(UInt32(files.count))
            let baseLoc = SourceLocation(nextBaseLocation)
            nextBaseLocation += UInt32(bytesRead + 1)
            let sourceFile = SourceFile(
                id: fileId,
                path: path,
                buffer: UnsafeBufferPointer(start: ptr, count: total),
                length: bytesRead,
                baseLocation: baseLoc
            )
            files.append(sourceFile)
            return fileId
        }
    }

    /// Finds the source file containing a given global source location, and its relative offset.
    public func file(containing location: SourceLocation) -> (file: SourceFile, offset: UInt32)? {
        let loc = location.rawValue
        return lock.withLock {
            // Files are appended with strictly increasing base locations, so binary-search for the last
            // file whose base is <= loc (index 0 is the nil file).
            var lo = 1, hi = files.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                guard let f = files[mid] else { lo = mid + 1; continue }
                if f.baseLocation.rawValue <= loc { found = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            guard found > 0, let file = files[found], file.id.isValid else { return nil }
            let start = file.baseLocation.rawValue
            let end = start + UInt32(file.length)
            if loc < end || (file.length == 0 && loc == start) {
                return (file, loc - start)
            }
            return nil
        }
    }

    /// Source text of the half-open location range `[start, end)`, from whichever buffer contains it.
    public func text(from start: SourceLocation, to end: SourceLocation) -> String? {
        guard end.rawValue >= start.rawValue, let (file, off) = file(containing: start) else { return nil }
        let len = Int(end.rawValue - start.rawValue)
        guard let base = file.buffer.baseAddress, Int(off) + len <= file.length else { return nil }
        return String(decoding: UnsafeBufferPointer(start: base + Int(off), count: len), as: UTF8.self)
    }

    /// Accesses a source file by FileId. FileId(0) returns the nil file.
    public subscript(fileId: FileId) -> SourceFile {
        return lock.withLock {
            let idx = Int(fileId.rawIndex)
            if idx >= 0 && idx < files.count, let file = files[idx] {
                return file
            }
            return files[0]! // Nil file fallback
        }
    }

    /// The number of registered files.
    public var count: Int {
        return lock.withLock {
            files.count
        }
    }
}
