import Foundation

/// Result of an Amortized (K-iteration tight-loop) sample. Per-batch wall
/// times are stored as a `LatencyDistribution`; `nanosPerOp` is derived from
/// the median batch time.
///
/// **Renamed from "BatchedResult"** to avoid collision with VectorCore's
/// `BatchOperations` namespace. The harness's K-iteration loop and a
/// VectorCore "batch operation" are very different things — never let them
/// share a name.
public struct AmortizedResult: Codable, Sendable, Equatable {
    /// K — number of `invoke` calls per timed loop. Auto-tuned so each loop
    /// runs ≥100 µs (well above clock resolution).
    public let iterationsPerBatch: Int

    /// Per-loop wall time in nanoseconds.
    public let batchNanos: LatencyDistribution

    public init(iterationsPerBatch: Int, batchNanos: LatencyDistribution) {
        precondition(iterationsPerBatch > 0, "iterationsPerBatch must be > 0")
        self.iterationsPerBatch = iterationsPerBatch
        self.batchNanos = batchNanos
    }

    /// Derived: nanoseconds per operation, computed from the median batch time.
    public var nanosPerOp: Double? {
        guard let medianBatch = batchNanos.p50 else { return nil }
        return Double(medianBatch) / Double(iterationsPerBatch)
    }
}
