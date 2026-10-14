// Sources/SwiftStack/Profile/Profiler.swift
import CSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A single trace event formatted for Chrome trace JSON / Perfetto (14-measurement-methodology.md §8).
public struct TraceEvent: Sendable {
    public let name: String
    public let category: String
    public let startCycle: UInt64
    public let endCycle: UInt64
    public let laneIndex: Int
    public let args: [String: String]

    public init(name: String, category: String, startCycle: UInt64, endCycle: UInt64, laneIndex: Int, args: [String: String] = [:]) {
        self.name = name
        self.category = category
        self.startCycle = startCycle
        self.endCycle = endCycle
        self.laneIndex = laneIndex
        self.args = args
    }
}

/// Built-in cycle profiler with Chrome trace JSON export (00 Principle 9, 14 §8, 15 §4.7).
public final class Profiler: @unchecked Sendable {
    public static let shared = Profiler()

    public var isEnabled: Bool = false
    private var events: [TraceEvent] = []
    private let lock = Mutex()
    public private(set) var cpuFrequencyHz: Double = 3_500_000_000.0 // Default 3.5 GHz
    private var startEpochCycle: UInt64 = 0

    public init() {
        self.startEpochCycle = Profiler.readCycles()
        calibrate()
    }

    /// Reads the CPU hardware cycle counter directly (rdtsc on x86-64, cntvct_el0 on ARM64).
    @inlinable
    public static func readCycles() -> UInt64 {
        ss_read_cycles()
    }

    /// Calibrates the cycle counter against monotonic nanoseconds.
    public func calibrate() {
        let t0_ns = ss_monotonic_time_ns()
        let c0 = Profiler.readCycles()

        // Busy wait ~10 milliseconds to measure ratio
        var current_ns = t0_ns
        while current_ns - t0_ns < 10_000_000 {
            current_ns = ss_monotonic_time_ns()
        }
        let c1 = Profiler.readCycles()
        let elapsed_ns = Double(current_ns - t0_ns)
        let elapsed_cycles = Double(c1 - c0)

        if elapsed_ns > 0 && elapsed_cycles > 0 {
            self.cpuFrequencyHz = (elapsed_cycles / elapsed_ns) * 1_000_000_000.0
        }
    }

    /// Times a closure execution if profiling is enabled.
    @inlinable
    public func timeBlock<R>(
        name: String,
        category: String = "compiler",
        laneIndex: Int = 0,
        args: [String: String] = [:],
        _ body: () throws -> R
    ) rethrows -> R {
        if _fastPath(!isEnabled) {
            return try body()
        }
        let start = Profiler.readCycles()
        defer {
            let end = Profiler.readCycles()
            record(event: TraceEvent(
                name: name,
                category: category,
                startCycle: start,
                endCycle: end,
                laneIndex: laneIndex,
                args: args
            ))
        }
        return try body()
    }

    public func record(event: TraceEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    /// Clears recorded trace events.
    public func reset() {
        lock.withLock {
            events.removeAll(keepingCapacity: true)
            startEpochCycle = Profiler.readCycles()
        }
    }

    /// Exports recorded trace events as Chrome trace JSON.
    public func exportTraceJSON() -> String {
        return lock.withLock {
            var json = "[\n"
            let count = events.count
            for (idx, e) in events.enumerated() {
                // Microseconds from epoch
                let startUs = (Double(e.startCycle &- startEpochCycle) / cpuFrequencyHz) * 1_000_000.0
                let durUs = (Double(e.endCycle &- e.startCycle) / cpuFrequencyHz) * 1_000_000.0

                json += "  {\"name\": \"\(e.name)\", \"cat\": \"\(e.category)\", \"ph\": \"X\", "
                json += "\"ts\": \(String(format: "%.3f", startUs)), \"dur\": \(String(format: "%.3f", durUs)), "
                json += "\"pid\": 1, \"tid\": \(e.laneIndex)"

                if !e.args.isEmpty {
                    json += ", \"args\": {"
                    var firstArg = true
                    for (k, v) in e.args {
                        if !firstArg { json += ", " }
                        json += "\"\(k)\": \"\(v)\""
                        firstArg = false
                    }
                    json += "}"
                }
                json += "}"
                if idx + 1 < count {
                    json += ",\n"
                } else {
                    json += "\n"
                }
            }
            json += "]\n"
            return json
        }
    }
}
