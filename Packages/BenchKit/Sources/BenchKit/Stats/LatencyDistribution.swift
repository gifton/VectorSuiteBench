import Foundation

/// Raw per-sample nanosecond observations for a single measurement mode.
/// Samples are kept full-fidelity (≤8 KB per case at the default N=1000) so
/// any later statistic can be recomputed without re-running the workload.
/// Stored sorted ascending to make percentile lookups O(1).
public struct LatencyDistribution: Codable, Sendable, Equatable {
    /// Sorted ascending. Empty arrays are not encoded.
    public let samples: [UInt64]

    public init(samples: [UInt64]) {
        // Defensive copy + sort. Caller may pass unsorted; we always store sorted.
        self.samples = samples.sorted()
    }

    public var count: Int { samples.count }
    public var isEmpty: Bool { samples.isEmpty }

    public var min: UInt64? { samples.first }
    public var max: UInt64? { samples.last }

    public var p50: UInt64? { percentile(0.50) }
    public var p99: UInt64? { percentile(0.99) }
    public var p999: UInt64? { percentile(0.999) }

    /// Percentile in [0, 1]. Uses nearest-rank with ceiling.
    public func percentile(_ p: Double) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        precondition((0.0...1.0).contains(p), "percentile out of range: \(p)")
        let rank = Int((p * Double(samples.count)).rounded(.up))
        let idx = Swift.min(Swift.max(rank - 1, 0), samples.count - 1)
        return samples[idx]
    }

    // Detect bimodality (a heuristic for P/E-core migration). Returns true
    // when the two halves of the sorted distribution have median ratio > 1.5.
    public var looksBimodal: Bool {
        guard samples.count >= 20 else { return false }
        let half = samples.count / 2
        let lowerMedian = samples[half / 2]
        let upperMedian = samples[half + (samples.count - half) / 2]
        guard lowerMedian > 0 else { return false }
        return Double(upperMedian) / Double(lowerMedian) > 1.5
    }
}
