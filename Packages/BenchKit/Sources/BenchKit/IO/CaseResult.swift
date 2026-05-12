import Foundation

/// The full measurement record for a single workload case. Persisted as one
/// JSON file under `runs/<runID>/cases/<workloadIDHash>.json` (atomic write
/// via temp+rename).
public struct CaseResult: Codable, Sendable {
    public let id: WorkloadID

    /// Single-shot distribution (raw nanoseconds per `invoke`). `nil` when
    /// the op is too long for honest single-shot at the configured budget.
    public let singleShot: LatencyDistribution?

    /// Amortized (K-iteration loop) result. `nil` when the preset disables
    /// Amortized mode (e.g., smoke preset) or when the op is naturally too
    /// long to need it.
    public let amortized: AmortizedResult?

    /// Derived: GB/s from Amortized median (sub-1 % overhead-corrected).
    /// `nil` when no Amortized samples were collected — single-shot data is
    /// **never** used as a fallback per §2.3 / BandwidthEstimator's contract:
    /// at the Apple Silicon ~41.6 ns timebase resolution, per-sample
    /// arithmetic on single-shot data produces nonsense at the noise floor.
    public let bandwidthGBPerSec: Double?

    /// Derived: GFLOP/s from Amortized median. `nil` when no Amortized
    /// samples were collected (see `bandwidthGBPerSec`).
    public let gflops: Double?

    /// `mach_task_basic_info().resident_size` snapshot before sampling.
    public let preSampleRSS: UInt64

    /// `mach_task_basic_info().resident_size` snapshot after sampling.
    public let postSampleRSS: UInt64

    /// Continuous memory trace — populated **only during Amortized sampling**.
    /// Empty for single-shot-only cases (where 100 Hz probes would inject jitter).
    public let memoryTrace: [MemorySample]

    /// Thermal escalations observed during the run.
    public let thermalEvents: [ThermalEvent]

    /// `mach_absolute_time` self-measured overhead (nanoseconds). Recorded as
    /// context metadata; never applied to single-shot raw samples.
    public let timerOverheadNanos: Double

    public let verification: VerificationResult

    public let flags: Set<CaseFlag>

    /// Backpointer to the parent `RunMetadata` (which carries Hardware /
    /// build provenance / FPCR state). Not duplicated here.
    public let runID: String

    public init(
        id: WorkloadID,
        singleShot: LatencyDistribution?,
        amortized: AmortizedResult?,
        bandwidthGBPerSec: Double?,
        gflops: Double?,
        preSampleRSS: UInt64,
        postSampleRSS: UInt64,
        memoryTrace: [MemorySample],
        thermalEvents: [ThermalEvent],
        timerOverheadNanos: Double,
        verification: VerificationResult,
        flags: Set<CaseFlag>,
        runID: String
    ) {
        self.id = id
        self.singleShot = singleShot
        self.amortized = amortized
        self.bandwidthGBPerSec = bandwidthGBPerSec
        self.gflops = gflops
        self.preSampleRSS = preSampleRSS
        self.postSampleRSS = postSampleRSS
        self.memoryTrace = memoryTrace
        self.thermalEvents = thermalEvents
        self.timerOverheadNanos = timerOverheadNanos
        self.verification = verification
        self.flags = flags
        self.runID = runID
    }
}

/// A single point of the continuous memory trace.
public struct MemorySample: Codable, Sendable, Equatable {
    /// Nanoseconds since the start of the sampling loop.
    public let timestampNanos: UInt64
    /// Resident set size in bytes at this point.
    public let residentBytes: UInt64

    public init(timestampNanos: UInt64, residentBytes: UInt64) {
        self.timestampNanos = timestampNanos
        self.residentBytes = residentBytes
    }
}

/// A thermal-state transition observed during a case.
public struct ThermalEvent: Codable, Sendable, Equatable {
    public let timestampNanos: UInt64
    public let from: String     // ProcessInfo.ThermalState raw value
    public let to: String

    public init(timestampNanos: UInt64, from: String, to: String) {
        self.timestampNanos = timestampNanos
        self.from = from
        self.to = to
    }
}
