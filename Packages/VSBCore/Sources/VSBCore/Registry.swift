import Foundation
import BenchKit

/// Declarative enumeration of the VSBCore workload registry.
///
/// Phase 1 starting set: Dot product across naïve / Accelerate / simd /
/// VectorCore (optimized raw + metric) at dim 512. Subsequent commits
/// expand sizes (64, 256, 1536, 4096) and add the other op families.
public enum VSBCoreRegistry {
    /// All workloads as type-erased `WorkloadMetadata`. Concrete workload
    /// types are kept distinct internally so the Runner can dispatch with
    /// static specialization at call sites.
    public static let workloads: [any WorkloadMetadata] = [
        NaiveDotWorkload(n: 512),
        AccelerateDotWorkload(n: 512),
        SimdDotWorkload(n: 512),
        VectorCoreOptimizedDotWorkload(),
        VectorCoreMetricDotWorkload(),
    ]

    /// Concrete typed accessors so callers can dispatch through `Runner.run`
    /// with static type information preserved.
    public static let naiveDot512 = NaiveDotWorkload(n: 512)
    public static let accelerateDot512 = AccelerateDotWorkload(n: 512)
    public static let simdDot512 = SimdDotWorkload(n: 512)
    public static let vectorCoreOptimizedDot512 = VectorCoreOptimizedDotWorkload()
    public static let vectorCoreMetricDot512 = VectorCoreMetricDotWorkload()
}
