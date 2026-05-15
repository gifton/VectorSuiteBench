import Foundation
import BenchKit

/// Declarative enumeration of the VSBCore workload registry.
///
/// Phase 1.5 expansion: Dot at five sizes (64, 256, 512, 1536, 4096) for
/// each of the four baseline impl axes (naïve, Accelerate, Apple `simd`,
/// and three VectorCore flavors — see Item 3). VectorCore-metric stays at
/// dim 512 only (per the spec; its purpose is to demonstrate sign-convention
/// handling, not characterize DotProductDistance perf across sizes).
public enum VSBCoreRegistry {
    /// Sizes used by the baseline (non-VectorCore) Dot workloads. Spans the
    /// embedding-vector regime (256–1536) plus the small-vector floor (64)
    /// and the cache-busting end (4096).
    public static let baselineDotSizes: [Int] = [64, 256, 512, 1536, 4096]

    /// All workloads as type-erased `WorkloadMetadata`. Concrete workload
    /// types are kept distinct internally so the Runner can dispatch with
    /// static specialization at call sites.
    public static let workloads: [any WorkloadMetadata] = makeWorkloads()

    private static func makeWorkloads() -> [any WorkloadMetadata] {
        var all: [any WorkloadMetadata] = []
        // Baseline Dot impls × 5 sizes.
        for n in baselineDotSizes {
            all.append(NaiveDotWorkload(n: n))
            all.append(AccelerateDotWorkload(n: n))
            all.append(SimdDotWorkload(n: n))
        }
        // VectorCore-optimized: only at the dims VectorCore ships specialized
        // types for. Of our 5-size set: 512 and 1536. (Item 3 will add 1536;
        // for now keep the existing 512.)
        all.append(VectorCoreOptimizedDotWorkload())
        // VectorCore-metric: stays at 512 (single representative size).
        all.append(VectorCoreMetricDotWorkload())
        return all
    }

    // MARK: - Typed accessors for tests

    public static let naiveDot512 = NaiveDotWorkload(n: 512)
    public static let accelerateDot512 = AccelerateDotWorkload(n: 512)
    public static let simdDot512 = SimdDotWorkload(n: 512)
    public static let vectorCoreOptimizedDot512 = VectorCoreOptimizedDotWorkload()
    public static let vectorCoreMetricDot512 = VectorCoreMetricDotWorkload()
}
