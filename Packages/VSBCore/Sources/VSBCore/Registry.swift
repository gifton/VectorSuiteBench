import Foundation
import BenchKit
import VectorCore

/// Declarative enumeration of the VSBCore workload registry.
///
/// Phase 1.5 final shape: Dot at five sizes (64, 256, 512, 1536, 4096)
/// across three baseline impls plus three VectorCore flavors.
///
/// **VectorCore flavor coverage map:**
/// | N    | Optimized | Generic Vector<Dim{N}> | DynamicVector |
/// |------|-----------|------------------------|---------------|
/// | 64   | —         | ✓ (Vector<Dim64>)      | ✓             |
/// | 256  | —         | ✓ (Vector<Dim256>)     | ✓             |
/// | 512  | ✓         | ✓ (Vector<Dim512>)     | ✓             |
/// | 1536 | ✓         | ✓ (Vector<Dim1536>)    | ✓             |
/// | 4096 | —         | — (no Dim4096)         | ✓             |
///
/// VectorCore-metric (DotProductDistance) stays at dim 512 — its job is to
/// demonstrate sign-convention handling, not characterize the metric API's
/// perf across sizes. Phase 2 can expand if/when that becomes a focus.
public enum VSBCoreRegistry {
    /// Sizes used by the baseline (non-VectorCore) Dot workloads.
    public static let baselineDotSizes: [Int] = [64, 256, 512, 1536, 4096]

    /// All workloads as type-erased `WorkloadMetadata`. Concrete workload
    /// types are kept distinct internally so the Runner dispatches with
    /// static specialization at call sites.
    public static let workloads: [any WorkloadMetadata] = makeWorkloads()

    private static func makeWorkloads() -> [any WorkloadMetadata] {
        var all: [any WorkloadMetadata] = []

        // 1. Baseline (non-VectorCore) Dot impls × 5 sizes = 15
        for n in baselineDotSizes {
            all.append(NaiveDotWorkload(n: n))
            all.append(AccelerateDotWorkload(n: n))
            all.append(SimdDotWorkload(n: n))
        }

        // 2. VectorCore-optimized: only at the dims VectorCore ships a
        //    specialized Optimized type for. Of our 5 sizes: 512 and 1536.
        all.append(VectorCoreOptimizedDotWorkload())          // dim 512
        all.append(VectorCore1536OptimizedDotWorkload())      // dim 1536

        // 3. VectorCore-generic: every static dim VectorCore declares.
        //    `Dim4096` does NOT exist in VectorCore, so we stop at 1536.
        all.append(VectorCoreGenericDotWorkload<Dim64>())
        all.append(VectorCoreGenericDotWorkload<Dim256>())
        all.append(VectorCoreGenericDotWorkload<Dim512>())
        all.append(VectorCoreGenericDotWorkload<Dim1536>())

        // 4. VectorCore-dynamic: always available (runtime dimension).
        for n in baselineDotSizes {
            all.append(VectorCoreDynamicDotWorkload(n: n))
        }

        // 5. VectorCore-metric (DotProductDistance): single representative
        //    size to demonstrate sign-convention handling.
        all.append(VectorCoreMetricDotWorkload())

        return all
        // Total: 15 + 2 + 4 + 5 + 1 = 27 Dot cases.
    }

    // MARK: - Typed accessors for tests

    public static let naiveDot512 = NaiveDotWorkload(n: 512)
    public static let accelerateDot512 = AccelerateDotWorkload(n: 512)
    public static let simdDot512 = SimdDotWorkload(n: 512)
    public static let vectorCoreOptimizedDot512 = VectorCoreOptimizedDotWorkload()
    public static let vectorCoreOptimizedDot1536 = VectorCore1536OptimizedDotWorkload()
    public static let vectorCoreGenericDot512 = VectorCoreGenericDotWorkload<Dim512>()
    public static let vectorCoreDynamicDot512 = VectorCoreDynamicDotWorkload(n: 512)
    public static let vectorCoreDynamicDot4096 = VectorCoreDynamicDotWorkload(n: 4096)
    public static let vectorCoreMetricDot512 = VectorCoreMetricDotWorkload()
}
