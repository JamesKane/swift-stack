// Sources/SwiftStack/Profile/RepetitionTester.swift
import CSupport

/// Result metrics from a RepetitionTester run (14-measurement-methodology.md §8).
public struct RepetitionResult: Sendable, CustomStringConvertible {
    public let kernelName: String
    public let totalBytesProcessed: Int
    public let totalItemsProcessed: Int
    public let iterations: Int
    public let bestCycles: UInt64
    public let meanCycles: Double
    public let bestCyclesPerByte: Double
    public let meanCyclesPerByte: Double
    public let bestCyclesPerItem: Double
    public let bandwidthMBs: Double
    public let speedOfLightRatio: Double // ratio of bestCyclesPerByte to speed-of-light estimate

    public var description: String {
        var str = "=== Repetition Test: \(kernelName) ===\n"
        str += "Iterations:           \(iterations)\n"
        str += "Best Cycles:          \(bestCycles)\n"
        str += "Mean Cycles:          \(String(format: "%.1f", meanCycles))\n"
        if totalBytesProcessed > 0 {
            str += "Best Cycles/Byte:     \(String(format: "%.3f", bestCyclesPerByte))\n"
            str += "Mean Cycles/Byte:     \(String(format: "%.3f", meanCyclesPerByte))\n"
            str += "Effective Bandwidth:  \(String(format: "%.2f", bandwidthMBs)) MB/s\n"
            str += "Speed of Light Ratio: \(String(format: "%.2fx", speedOfLightRatio))\n"
        }
        if totalItemsProcessed > 0 {
            str += "Best Cycles/Item:     \(String(format: "%.3f", bestCyclesPerItem))\n"
        }
        return str
    }
}

/// Harness for testing inner loop kernels repeatedly until best time stabilizes (14-measurement-methodology.md §8).
public struct RepetitionTester {
    public let targetDurationSeconds: Double
    public let maxIterations: Int
    public let speedOfLightCyclesPerByte: Double // Default ~1.5 cycles/byte ceiling

    public init(
        targetDurationSeconds: Double = 0.5,
        maxIterations: Int = 1000,
        speedOfLightCyclesPerByte: Double = 1.5
    ) {
        self.targetDurationSeconds = targetDurationSeconds
        self.maxIterations = maxIterations
        self.speedOfLightCyclesPerByte = speedOfLightCyclesPerByte
    }

    /// Runs a kernel repeatedly and measures cycle throughput.
    public func testKernel(
        name: String,
        byteCount: Int,
        itemCount: Int = 0,
        kernel: () -> Void
    ) -> RepetitionResult {
        let profiler = Profiler.shared
        let cpuFreq = profiler.cpuFrequencyHz

        // 2 Warm-up runs
        kernel()
        kernel()

        var bestCycles: UInt64 = UInt64.max
        var totalCycles: UInt64 = 0
        var runs = 0

        let start_ns = ss_monotonic_time_ns()
        let target_ns = UInt64(targetDurationSeconds * 1_000_000_000.0)

        while runs < maxIterations {
            let c0 = Profiler.readCycles()
            kernel()
            let c1 = Profiler.readCycles()

            let elapsed = c1 &- c0
            if elapsed < bestCycles {
                bestCycles = elapsed
            }
            totalCycles += elapsed
            runs += 1

            let now_ns = ss_monotonic_time_ns()
            if now_ns >= start_ns &+ target_ns && runs >= 10 {
                break
            }
        }

        let meanCycles = runs > 0 ? Double(totalCycles) / Double(runs) : 0.0
        let bestCpb = byteCount > 0 ? Double(bestCycles) / Double(byteCount) : 0.0
        let meanCpb = byteCount > 0 ? meanCycles / Double(byteCount) : 0.0
        let bestCpi = itemCount > 0 ? Double(bestCycles) / Double(itemCount) : 0.0

        // Bandwidth: (byteCount / (bestCycles / cpuFreq)) / 1_000_000
        let bestSeconds = Double(bestCycles) / cpuFreq
        let bandwidth = (bestSeconds > 0 && byteCount > 0) ? (Double(byteCount) / bestSeconds) / 1_000_000.0 : 0.0
        let solRatio = speedOfLightCyclesPerByte > 0 && bestCpb > 0 ? bestCpb / speedOfLightCyclesPerByte : 1.0

        return RepetitionResult(
            kernelName: name,
            totalBytesProcessed: byteCount,
            totalItemsProcessed: itemCount,
            iterations: runs,
            bestCycles: bestCycles,
            meanCycles: meanCycles,
            bestCyclesPerByte: bestCpb,
            meanCyclesPerByte: meanCpb,
            bestCyclesPerItem: bestCpi,
            bandwidthMBs: bandwidth,
            speedOfLightRatio: solRatio
        )
    }
}
