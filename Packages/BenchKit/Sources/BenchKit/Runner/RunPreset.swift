import Foundation

/// Filter-and-budget bundle defining a run's scope. Pinned per §3 of the
/// design spec so wall-clock estimates are reproducible across runs.
public enum RunPreset: Codable, Sendable, Equatable {
    /// ~40 cases, ~30 s, single-shot only, 100 samples/case.
    case smoke

    /// ~180 cases, ~5 min, both modes, 500 samples/case. Excludes
    /// `distanceMatrix` ≥ 1024² (Float64 Kahan reference dominates wall time
    /// at that size).
    case standard

    /// ~600 cases (entire registry), ~45 min, both modes, 1000+ samples/case.
    case full

    /// Custom budget + sample count + explicit workload selection.
    case custom(budget: WallClockBudget, sampleCount: SampleCount, ids: [WorkloadID])

    public var defaultBudget: WallClockBudget {
        switch self {
        case .smoke:    return .smoke
        case .standard: return .standard
        case .full:     return .full
        case .custom(let budget, _, _): return budget
        }
    }

    public var label: String {
        switch self {
        case .smoke: return "smoke"
        case .standard: return "standard"
        case .full: return "full"
        case .custom: return "custom"
        }
    }
}

/// Per-case sample count knobs. The runner auto-selects the actual N
/// depending on observed per-iteration cost (large N for fast ops, small N
/// for slow ops); these are upper bounds.
public struct SampleCount: Codable, Sendable, Equatable {
    public let singleShotMax: Int
    public let amortizedSamples: Int

    public init(singleShotMax: Int, amortizedSamples: Int) {
        self.singleShotMax = singleShotMax
        self.amortizedSamples = amortizedSamples
    }

    public static let smoke = SampleCount(singleShotMax: 100, amortizedSamples: 0)
    public static let standard = SampleCount(singleShotMax: 500, amortizedSamples: 100)
    public static let full = SampleCount(singleShotMax: 1000, amortizedSamples: 200)
}
