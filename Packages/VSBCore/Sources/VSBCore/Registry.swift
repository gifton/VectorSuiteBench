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
        L2DistanceFamily(),
        CosineFamily(),
        NormalizeFamily(),
        NormalizeInPlaceFamily(),
    ]

    /// All workloads as type-erased `RunnableWorkload`. Concrete types are
    /// kept distinct internally so the Runner dispatches with static
    /// specialization at call sites; the `RunnableWorkload` parent protocol
    /// lets RunController pick the right runner per case without an open
    /// `switch` on protocol kind.
    public static let workloads: [any RunnableWorkload] = families.flatMap { $0.workloads }

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

    public static let naiveL2Dist512 = NaiveL2DistWorkload(n: 512)
    public static let accelerateL2Dist512 = AccelerateL2DistWorkload(n: 512)
    public static let simdL2Dist512 = SimdL2DistWorkload(n: 512)
    public static let vectorCoreOptimizedL2Dist512 = VectorCoreOptimizedL2DistWorkload<Vector512Optimized>()
    public static let vectorCoreOptimizedL2Dist1536 = VectorCoreOptimizedL2DistWorkload<Vector1536Optimized>()

    public static let naiveCosine512 = NaiveCosineWorkload(n: 512)
    public static let accelerateCosine512 = AccelerateCosineWorkload(n: 512)
    public static let simdCosine512 = SimdCosineWorkload(n: 512)
    public static let vectorCoreOptimizedCosine512 = VectorCoreOptimizedCosineWorkload<Vector512Optimized>()
    public static let vectorCoreOptimizedCosine1536 = VectorCoreOptimizedCosineWorkload<Vector1536Optimized>()

    public static let naiveNormalize512 = NaiveNormalizeWorkload(n: 512)
    public static let accelerateNormalize512 = AccelerateNormalizeWorkload(n: 512)
    public static let simdNormalize512 = SimdNormalizeWorkload(n: 512)
    public static let vectorCoreOptimizedNormalize512 = VectorCoreOptimizedNormalizeWorkload<Vector512Optimized>()
    public static let vectorCoreOptimizedNormalize1536 = VectorCoreOptimizedNormalizeWorkload<Vector1536Optimized>()
    public static let vectorCoreGenericNormalize512 = VectorCoreGenericNormalizeWorkload<Dim512>()
    public static let vectorCoreDynamicNormalize512 = VectorCoreDynamicNormalizeWorkload(n: 512)
    public static let vectorCoreDynamicNormalize4096 = VectorCoreDynamicNormalizeWorkload(n: 4096)

    public static let naiveNormalizeInPlace512 = NaiveNormalizeInPlaceWorkload(n: 512)
    public static let accelerateNormalizeInPlace512 = AccelerateNormalizeInPlaceWorkload(n: 512)
    public static let vectorCoreGenericNormalizeInPlace512 = VectorCoreGenericNormalizeInPlaceWorkload<Dim512>()
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

    public var workloads: [any RunnableWorkload] {
        var all: [any RunnableWorkload] = []

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

/// L2-squared distance family — `Σ(aᵢ - bᵢ)²`. Phase 2.2 Item 1a.
///
/// **VectorCore flavor coverage:** Optimized only. `Vector<D>` and
/// `DynamicVector` do not expose `euclideanDistanceSquared(to:)` (verified
/// against VectorCore at Phase 2.2 Item 1a); only the
/// `Vector{384,512,768,1536}Optimized` types do. Synthesizing the missing
/// flavors via `EuclideanDistance().distance(_,_).squared` would measure
/// sqrt + square overhead a real user doesn't pay when targeting the
/// typed Optimized path, so we omit them rather than ship a misleading
/// comparison row.
///
/// Of the 5 baseline sizes {64, 256, 512, 1536, 4096}, only 512 and 1536
/// are available for the Optimized flavor (mirrors DotFamily's choice).
public struct L2DistanceFamily: WorkloadFamily {
    public init() {}
    public var name: String { "l2dist" }

    public var workloads: [any RunnableWorkload] {
        var all: [any RunnableWorkload] = []

        // 1. Baseline (non-VectorCore) impls × 5 sizes = 15
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(NaiveL2DistWorkload(n: n))
            all.append(AccelerateL2DistWorkload(n: n))
            all.append(SimdL2DistWorkload(n: n))
        }

        // 2. VectorCore-optimized at the dims VectorCore ships an
        //    Optimized type for and we sweep: 512 and 1536.
        all.append(VectorCoreOptimizedL2DistWorkload<Vector512Optimized>())
        all.append(VectorCoreOptimizedL2DistWorkload<Vector1536Optimized>())

        return all
        // Total: 15 + 2 = 17 L2Distance cases.
    }
}

/// Cosine similarity family — `(a·b) / (‖a‖₂ · ‖b‖₂)`. Phase 2.2 Item 1b.
///
/// **VectorCore flavor coverage:** Optimized only. `Vector<D>` and
/// `DynamicVector` do not expose `cosineSimilarity(to:)` (verified at
/// Phase 2.2 Item 1b); only the `Vector{384,512,768,1536}Optimized` types
/// do. Same omission rationale as `L2DistanceFamily` — synthesizing the
/// missing flavors via `CosineDistance().distance(_,_)` would measure a
/// different value space (distance = 1 − similarity, not similarity), so
/// shipping it as a cosine-similarity case would be misleading.
///
/// **No api: raw | metric split.** Unlike dot — where `Vector.dot()` and
/// `DotProductDistance.distance(_,_)` differ by a pure sign flip — cosine
/// similarity and `CosineDistance.distance(_,_)` differ by a value
/// transform (`1 − x`). That's a separate op shape, not a metric variant.
/// Phase 2.2 ships similarity only; cosine distance, if benchmarked, gets
/// its own family in a later phase.
public struct CosineFamily: WorkloadFamily {
    public init() {}
    public var name: String { "cosine" }

    public var workloads: [any RunnableWorkload] {
        var all: [any RunnableWorkload] = []

        // 1. Baseline (non-VectorCore) impls × 5 sizes = 15
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(NaiveCosineWorkload(n: n))
            all.append(AccelerateCosineWorkload(n: n))
            all.append(SimdCosineWorkload(n: n))
        }

        // 2. VectorCore-optimized at the dims VectorCore ships an
        //    Optimized type for and we sweep: 512 and 1536.
        all.append(VectorCoreOptimizedCosineWorkload<Vector512Optimized>())
        all.append(VectorCoreOptimizedCosineWorkload<Vector1536Optimized>())

        return all
        // Total: 15 + 2 = 17 Cosine cases.
    }
}

/// Out-of-place L2 normalize family — `aᵢ ← aᵢ / ‖a‖₂` returning a fresh
/// vector. Phase 2.2 Item 1c.
///
/// **VectorCore flavor coverage:** all three (Optimized + Generic +
/// Dynamic). Unlike L2DistanceFamily and CosineFamily — where the Generic
/// and Dynamic paths lack a typed API — normalize ships on every flavor
/// via these idiomatic methods:
/// - Optimized → `normalizedUnchecked()` (skips zero-check, returns Self).
/// - Generic   → `normalizedFast()` (reciprocal multiply, returns Self).
/// - Dynamic   → `try! normalized().get()` (Result-returning; no
///   Self-returning variant exists).
///
/// Per-flavor API divergence is deliberate (Item 1c locked decision —
/// "most idiomatic per flavor"). Each method is the canonical user-facing
/// call on that vector type; using a forcibly-uniform API everywhere
/// would either bias the Generic case (missing its fast path) or trade
/// coverage (dropping Dynamic entirely).
public struct NormalizeFamily: WorkloadFamily {
    public init() {}
    public var name: String { "normalize" }

    public var workloads: [any RunnableWorkload] {
        var all: [any RunnableWorkload] = []

        // 1. Baseline (non-VectorCore) impls × 5 sizes = 15
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(NaiveNormalizeWorkload(n: n))
            all.append(AccelerateNormalizeWorkload(n: n))
            all.append(SimdNormalizeWorkload(n: n))
        }

        // 2. VectorCore-optimized at {512, 1536} = 2
        all.append(VectorCoreOptimizedNormalizeWorkload<Vector512Optimized>())
        all.append(VectorCoreOptimizedNormalizeWorkload<Vector1536Optimized>())

        // 3. VectorCore-generic across every static Dim VectorCore declares
        //    of our 5-size set: 64, 256, 512, 1536 (no Dim4096) = 4
        all.append(VectorCoreGenericNormalizeWorkload<Dim64>())
        all.append(VectorCoreGenericNormalizeWorkload<Dim256>())
        all.append(VectorCoreGenericNormalizeWorkload<Dim512>())
        all.append(VectorCoreGenericNormalizeWorkload<Dim1536>())

        // 4. VectorCore-dynamic across every size = 5
        for n in VSBCoreRegistry.baselineDotSizes {
            all.append(VectorCoreDynamicNormalizeWorkload(n: n))
        }

        return all
        // Total: 15 + 2 + 4 + 5 = 26 Normalize cases.
    }
}
