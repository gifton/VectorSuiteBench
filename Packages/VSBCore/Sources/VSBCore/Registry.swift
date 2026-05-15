import Foundation
import BenchKit
import VectorCore

/// Declarative enumeration of the VSBCore workload registry.
///
/// Registry composition uses the `WorkloadFamily` pattern (per BenchKit):
/// each op family owns its own enumeration logic and contributes via
/// `WorkloadFamily.workloads`. The top-level `VSBCoreRegistry.workloads`
/// is the `flatMap` of every registered family. This keeps the registry
/// scalable as Phase 2 adds L2 distance, cosine, normalize, AXPY, Top-K,
/// pairwiseDistances, and distanceMatrix families.
public enum VSBCoreRegistry {
    /// Sizes used by the baseline (non-VectorCore) Dot workloads. Spans
    /// the embedding-vector regime (256–1536) plus the small-vector floor
    /// (64) and the cache-busting end (4096) where naïve summation hits
    /// its Wilkinson worst case.
    public static let baselineDotSizes: [Int] = [64, 256, 512, 1536, 4096]

    /// All registered op families. Phase 2 adds more here.
    public static let families: [any WorkloadFamily] = [
        DotFamily(),
    ]

    /// All workloads as type-erased `WorkloadMetadata`. Concrete types are
    /// kept distinct internally so the Runner dispatches with static
    /// specialization at call sites.
    public static let workloads: [any WorkloadMetadata] = families.flatMap { $0.workloads }

    // MARK: - Typed accessors for tests

    public static let naiveDot512 = NaiveDotWorkload(n: 512)
    public static let accelerateDot512 = AccelerateDotWorkload(n: 512)
    public static let simdDot512 = SimdDotWorkload(n: 512)
    public static let vectorCoreOptimizedDot512 = VectorCoreOptimizedDotWorkload<Vector512Optimized>()
    public static let vectorCoreOptimizedDot1536 = VectorCoreOptimizedDotWorkload<Vector1536Optimized>()
    public static let vectorCoreGenericDot512 = VectorCoreGenericDotWorkload<Dim512>()
    public static let vectorCoreDynamicDot512 = VectorCoreDynamicDotWorkload(n: 512)
    public static let vectorCoreDynamicDot4096 = VectorCoreDynamicDotWorkload(n: 4096)
    public static let vectorCoreMetricDot512 = VectorCoreMetricDotWorkload()
}

/// Dot family — all variants of the dot product, across baseline impls
/// and VectorCore flavors.
///
/// **VectorCore flavor coverage map:**
/// | N    | Optimized              | Generic Vector<Dim{N}>  | DynamicVector |
/// |------|------------------------|-------------------------|---------------|
/// | 64   | —                      | ✓ (Vector<Dim64>)       | ✓             |
/// | 256  | —                      | ✓ (Vector<Dim256>)      | ✓             |
/// | 512  | ✓ (Vector512Optimized) | ✓ (Vector<Dim512>)      | ✓             |
/// | 1536 | ✓ (Vector1536Optimized)| ✓ (Vector<Dim1536>)     | ✓             |
/// | 4096 | —                      | — (no Dim4096)          | ✓             |
///
/// VectorCore-metric (`DotProductDistance`) stays at dim 512 — its job is
/// to demonstrate sign-convention handling, not characterize the metric
/// API's perf across sizes.
public struct DotFamily: WorkloadFamily {
    public init() {}
    public var name: String { "dot" }

    public var workloads: [any WorkloadMetadata] {
        var all: [any WorkloadMetadata] = []

        // 1. Baseline (non-VectorCore) Dot impls × 5 sizes = 15
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(NaiveDotWorkload(n: n))
            all.append(AccelerateDotWorkload(n: n))
            all.append(SimdDotWorkload(n: n))
        }

        // 2. VectorCore-optimized: only at the dims VectorCore ships a
        //    specialized Optimized type for. Of our 5 sizes: 512 and 1536.
        all.append(VectorCoreOptimizedDotWorkload<Vector512Optimized>())
        all.append(VectorCoreOptimizedDotWorkload<Vector1536Optimized>())

        // 3. VectorCore-generic: every static dim VectorCore declares.
        //    `Dim4096` does NOT exist in VectorCore, so we stop at 1536.
        all.append(VectorCoreGenericDotWorkload<Dim64>())
        all.append(VectorCoreGenericDotWorkload<Dim256>())
        all.append(VectorCoreGenericDotWorkload<Dim512>())
        all.append(VectorCoreGenericDotWorkload<Dim1536>())

        // 4. VectorCore-dynamic: always available (runtime dimension).
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(VectorCoreDynamicDotWorkload(n: n))
        }

        // 5. VectorCore-metric (DotProductDistance): single representative
        //    size to demonstrate sign-convention handling.
        all.append(VectorCoreMetricDotWorkload())

        return all
        // Total: 15 + 2 + 4 + 5 + 1 = 27 Dot cases.
    }
}
