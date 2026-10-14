// Sources/SwiftStack/Source/SourceLocation.swift

/// A 32-bit offset into the compilation unit's local location space (01-frontend.md §4.3).
@frozen
public struct SourceLocation: Hashable, Equatable, Sendable, BitwiseCopyable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32

    @inlinable
    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    @inlinable
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let zero = SourceLocation(0)
    public static let invalid = SourceLocation(UInt32.max)

    @inlinable
    public var isValid: Bool {
        rawValue != UInt32.max
    }

    @inlinable
    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    @inlinable
    public var description: String {
        "Loc(\(rawValue))"
    }
}

/// A global location spanning across compilation units: (UnitId, SourceLocation).
@frozen
public struct GlobalLocation: Hashable, Equatable, Sendable, BitwiseCopyable {
    public let unitId: UnitId
    public let location: SourceLocation

    @inlinable
    public init(unitId: UnitId, location: SourceLocation) {
        self.unitId = unitId
        self.location = location
    }
}

/// The kind of entry in a unit's location space.
@frozen
public enum LocationEntryKind: UInt8, Sendable, BitwiseCopyable {
    case file = 0
    case expansion = 1
    case scratch = 2
    case macroExpansion = 3
}

/// An entry in a unit's location space table, mapping unit-local offsets back to files or expansions.
@frozen
public struct LocationEntry: Sendable, BitwiseCopyable {
    public let startOffset: UInt32
    public let length: UInt32
    public let fileId: FileId
    public let fileOffset: UInt32
    public let kind: LocationEntryKind

    @inlinable
    public init(startOffset: UInt32, length: UInt32, fileId: FileId, fileOffset: UInt32 = 0, kind: LocationEntryKind = .file) {
        self.startOffset = startOffset
        self.length = length
        self.fileId = fileId
        self.fileOffset = fileOffset
        self.kind = kind
    }
}

/// Unit-local location space managing mapping between 32-bit SourceLocation and underlying files.
public struct LocationSpace: ~Copyable {
    public private(set) var entries: [LocationEntry]
    public private(set) var currentOffset: UInt32

    public init() {
        self.entries = []
        self.currentOffset = 0
    }

    /// Adds a file range into the location space, returning the start SourceLocation.
    public mutating func addFile(fileId: FileId, length: UInt32) -> SourceLocation {
        let start = currentOffset
        let entry = LocationEntry(startOffset: start, length: length, fileId: fileId, fileOffset: 0, kind: .file)
        entries.append(entry)
        currentOffset += length
        return SourceLocation(start)
    }

    /// Resolves a SourceLocation to its corresponding file ID and byte offset in that file.
    public func resolve(_ location: SourceLocation) -> (fileId: FileId, offset: UInt32)? {
        guard !entries.isEmpty else { return nil }
        let loc = location.rawValue

        // Binary search for the entry containing this location
        var low = 0
        var high = entries.count - 1
        var matchIndex = -1

        while low <= high {
            let mid = low + (high - low) / 2
            let entry = entries[mid]
            if entry.startOffset <= loc {
                if loc < entry.startOffset + entry.length {
                    matchIndex = mid
                    break
                }
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        if matchIndex >= 0 {
            let entry = entries[matchIndex]
            let offsetInEntry = loc - entry.startOffset
            return (entry.fileId, entry.fileOffset + offsetInEntry)
        }

        // Fallback for last entry if pointing at EOF
        if let last = entries.last, loc == last.startOffset + last.length {
            return (last.fileId, last.fileOffset + last.length)
        }

        return nil
    }
}
