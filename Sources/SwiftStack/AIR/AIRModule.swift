// Sources/SwiftStack/AIR/AIRModule.swift
import Foundation

/// A module containing lowered AIR functions and global definitions (03-intermediate-representation.md).
public struct AIRModule: ~Copyable {
    private var fnBuffer: UnsafeMutablePointer<AIRFunctionSoA>
    private var fnCapacity: Int
    public private(set) var functionCount: Int
    public var stringLiterals: [String: Int]
    public var orderedStrings: [String]

    public init(stringLiterals: [String: Int] = [:]) {
        self.fnCapacity = 16
        self.fnBuffer = UnsafeMutablePointer<AIRFunctionSoA>.allocate(capacity: 16)
        self.functionCount = 0
        self.stringLiterals = stringLiterals

        var ordered = Array(repeating: "", count: stringLiterals.count)
        for (str, idx) in stringLiterals {
            if idx < ordered.count {
                ordered[idx] = str
            }
        }
        self.orderedStrings = ordered
    }

    deinit {
        for i in 0..<functionCount {
            (fnBuffer + i).deinitialize(count: 1)
        }
        if fnCapacity > 0 {
            fnBuffer.deallocate()
        }
    }

    public mutating func addFunction(_ fn: consuming AIRFunctionSoA) {
        if functionCount >= fnCapacity {
            let newCap = fnCapacity * 2
            let newBuffer = UnsafeMutablePointer<AIRFunctionSoA>.allocate(capacity: newCap)
            for i in 0..<functionCount {
                (newBuffer + i).initialize(to: (fnBuffer + i).move())
            }
            fnBuffer.deallocate()
            fnBuffer = newBuffer
            fnCapacity = newCap
        }
        (fnBuffer + functionCount).initialize(to: fn)
        functionCount += 1
    }

    public func withFunction<R>(_ index: Int, _ body: (borrowing AIRFunctionSoA) throws -> R) rethrows -> R {
        precondition(index >= 0 && index < functionCount, "Function index out of bounds")
        return try body(fnBuffer[index])
    }

    public mutating func withMutableFunction<R>(_ index: Int, _ body: (inout AIRFunctionSoA) throws -> R) rethrows -> R {
        precondition(index >= 0 && index < functionCount, "Function index out of bounds")
        return try body(&fnBuffer[index])
    }

    public var totalInstructions: UInt32 {
        var total: UInt32 = 0
        for i in 0..<functionCount {
            total += fnBuffer[i].instructionCount
        }
        return total
    }

    public var bytesCommitted: Int {
        var total = 0
        for i in 0..<functionCount {
            total += fnBuffer[i].bytesCommitted
        }
        return total
    }

    public var bytesReserved: Int {
        var total = 0
        for i in 0..<functionCount {
            total += fnBuffer[i].bytesReserved
        }
        return total
    }
}
