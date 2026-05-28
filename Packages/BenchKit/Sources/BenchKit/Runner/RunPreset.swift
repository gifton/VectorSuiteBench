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

    // MARK: - Preset filters

    /// Apply the preset's filter rules to a registry, per design spec §3 plus
    /// Phase 2.2's `§1.5/3` Standard rebaseline (drop VectorCore optimized
    /// from Standard; keep in Full).
    ///
    /// Spec §3 frames presets as "filters over the full registry plus
    /// sampling-and-budget settings." Phase 1 shipped the budget side but not
    /// the filter side; this method closes that gap.
    ///
    /// Smoke selects dot/l2dist/cosine over VectorCore-optimized + Accelerate
    /// + naive at vector dim 512. Standard runs every op but drops the
    /// VectorCore optimized flavor (those still ship in Full) and pins vector
    /// dims to {256, 1536}. Full and Custom are identity — Full because it's
    /// the "entire registry" preset by definition; Custom because the caller
    /// explicitly supplied the workload IDs.
    public func filter(_ workloads: [any RunnableWorkload]) -> [any RunnableWorkload] {
        switch self {
        case .smoke:
            return workloads.filter { Self.matchesSmoke($0.identifier) }
        case .standard:
            return workloads.filter { Self.matchesStandard($0.identifier) }
        case .full, .custom:
            return workloads
        }
    }

    /// Spec §3 Smoke: ops {dot (raw only), l2dist, cosine} × impls
    /// {VectorCore-optimized, Accelerate, naive} × vector dim 512.
    /// `simd` impls and VectorCore generic/dynamic flavors are excluded.
    private static func matchesSmoke(_ id: WorkloadID) -> Bool {
        guard smokeOps.contains(id.op) else { return false }
        guard smokeImpls.contains(id.impl) else { return false }
        guard case .vector(let n) = id.shape, n == smokeVectorSize else { return false }
        if id.impl == .vectorCore, id.params["vectorflavor"] != "optimized" {
            return false
        }
        if id.op == .dot, id.params["api"] == "metric" { return false }
        return true
    }

    /// Spec §3 Standard plus Phase 2.2 §1.5/3 trim: all ops, all impls except
    /// VectorCore optimized; vector dim ∈ {256, 1536}; pairwise/matrix at
    /// inner dim 768 with batch dim ∈ {64, 256} (the spec's M=N=64²/256²
    /// configurations; the larger 1024² and 4096² distanceMatrix cases stay
    /// in Full only).
    private static func matchesStandard(_ id: WorkloadID) -> Bool {
        if id.impl == .vectorCore, id.params["vectorflavor"] == "optimized" {
            return false
        }
        switch id.shape {
        case .vector(let n):
            return standardVectorSizes.contains(n)
        case .pairwise(let b, let n), .matrix(let b, let n):
            return n == standardPairwiseInnerDim && standardPairwiseBatchSizes.contains(b)
        }
    }

    // Pinned constants — spec §3. Kept here (not at file scope) so the
    // filter rules + their rationale stay co-located.
    private static let smokeOps: Set<OpKind> = [.dot, .l2dist, .cosine]
    private static let smokeImpls: Set<ImplKind> = [.vectorCore, .accelerate, .naive]
    private static let smokeVectorSize: Int = 512
    private static let standardVectorSizes: Set<Int> = [256, 1536]
    private static let standardPairwiseInnerDim: Int = 768
    private static let standardPairwiseBatchSizes: Set<Int> = [64, 256]
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
