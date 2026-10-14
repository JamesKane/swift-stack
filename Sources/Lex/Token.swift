// Sources/Lex/Token.swift
import Source

/// Struct-of-Arrays token buffer representing tokens in 10 bytes each.
public struct TokenBuffer: ~Copyable {
    public var kinds: UnsafeMutablePointer<UInt8>
    public var flags: UnsafeMutablePointer<UInt8>
    public var starts: UnsafeMutablePointer<UInt32>
    public var ends: UnsafeMutablePointer<UInt32>
    public private(set) var count: Int
    public private(set) var capacity: Int

    public init(capacity: Int = 1024) {
        self.capacity = max(16, capacity)
        self.count = 0
        self.kinds = .allocate(capacity: self.capacity)
        self.flags = .allocate(capacity: self.capacity)
        self.starts = .allocate(capacity: self.capacity)
        self.ends = .allocate(capacity: self.capacity)
    }

    public mutating func append(kind: UInt8, flag: UInt8, start: UInt32, end: UInt32) {
        if count >= capacity {
            grow()
        }
        kinds[count] = kind
        flags[count] = flag
        starts[count] = start
        ends[count] = end
        count += 1
    }

    private mutating func grow() {
        let newCap = capacity * 2
        let newKinds = UnsafeMutablePointer<UInt8>.allocate(capacity: newCap)
        let newFlags = UnsafeMutablePointer<UInt8>.allocate(capacity: newCap)
        let newStarts = UnsafeMutablePointer<UInt32>.allocate(capacity: newCap)
        let newEnds = UnsafeMutablePointer<UInt32>.allocate(capacity: newCap)

        newKinds.initialize(from: kinds, count: count)
        newFlags.initialize(from: flags, count: count)
        newStarts.initialize(from: starts, count: count)
        newEnds.initialize(from: ends, count: count)

        kinds.deallocate()
        flags.deallocate()
        starts.deallocate()
        ends.deallocate()

        kinds = newKinds
        flags = newFlags
        starts = newStarts
        ends = newEnds
        capacity = newCap
    }

    deinit {
        kinds.deallocate()
        flags.deallocate()
        starts.deallocate()
        ends.deallocate()
    }
}
