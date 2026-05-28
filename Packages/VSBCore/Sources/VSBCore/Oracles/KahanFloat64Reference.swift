import Foundation
import BenchKit

// MARK: - Dot product

/// Float64 Kahan-Neumaier compensated summation for dot product. Used by
/// every Dot workload's `ReferenceOracle.compute` closure.
///
/// **Sign convention**: returns `+a·b` (mathematical convention). Workloads
/// that compare against a metric returning `−a·b` (e.g., `DotProductDistance`)
/// negate via the `expectedSignTransform` parameter of `makeDotOracle`.
public func kahanFloat64Dot(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count, "dot: vector lengths differ")
    var sum = 0.0
    var c = 0.0
    for i in 0..<a.count {
        let y = Double(a[i]) * Double(b[i]) - c
        let t = sum + y
        c = (t - sum) - y
        sum = t
    }
    return sum
}

// MARK: - L2 squared distance

/// Squared Euclidean distance `Σ (aᵢ − bᵢ)²` in Float64 via Kahan-Neumaier
/// compensated summation. Returns squared (no sqrt) — matches the
/// "squared-distance space" convention used by `TopKSetVerifier` and the
/// codebase's `ReferenceValue.TopKResult.squaredDistance` field. Callers
/// that need true Euclidean distance can `.squareRoot()` the result.
public func kahanFloat64L2Squared(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count, "l2dist²: vector lengths differ")
    var sum = 0.0
    var c = 0.0
    for i in 0..<a.count {
        let d = Double(a[i]) - Double(b[i])
        let y = d * d - c
        let t = sum + y
        c = (t - sum) - y
        sum = t
    }
    return sum
}

// MARK: - Cosine similarity

/// Cosine similarity `(a·b) / (‖a‖₂ · ‖b‖₂)` in Float64. Three independent
/// Kahan reductions (dot, ‖a‖², ‖b‖²) keep the numerator and the two norm
/// factors each bounded to ~2·ε_f64. Returns Double in `[-1, 1]`; zero
/// vectors produce `Double.nan` (no special-casing — the candidate must
/// match the same NaN by IEEE bit semantics or fail verification).
public func kahanFloat64Cosine(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count, "cosine: vector lengths differ")
    let dot = kahanFloat64Dot(a, b)
    let aNormSq = kahanFloat64Dot(a, a)
    let bNormSq = kahanFloat64Dot(b, b)
    return dot / (aNormSq.squareRoot() * bNormSq.squareRoot())
}

// MARK: - L2 normalize

/// L2-normalize `a` into a fresh Float64 vector: `aᵢ / ‖a‖₂`. The norm is
/// computed via Kahan summation in Float64; the element-wise divide is
/// straight Float64. Zero vectors produce all-NaN output (same rationale as
/// `kahanFloat64Cosine`).
public func kahanFloat64Normalize(_ a: [Float]) -> [Double] {
    let normSq = kahanFloat64Dot(a, a)
    let inv = 1.0 / normSq.squareRoot()
    return a.map { Double($0) * inv }
}

// MARK: - AXPY

/// `y ← αx + y` in Float64, returning the fresh result vector. No reduction,
/// so Kahan compensation isn't relevant here — the Float64 widen + FMA is
/// already exact to within 1 ULP per element against the Float32 candidate.
/// Pure function (does NOT mutate `y`); the workload's compare closure walks
/// element-wise.
public func kahanFloat64Axpy(alpha: Float, x: [Float], y: [Float]) -> [Double] {
    precondition(x.count == y.count, "axpy: vector lengths differ")
    var out = [Double](repeating: 0, count: x.count)
    let a = Double(alpha)
    for i in 0..<x.count {
        out[i] = a * Double(x[i]) + Double(y[i])
    }
    return out
}

// MARK: - Top-K nearest neighbors

/// Top-K nearest neighbors by **squared** Euclidean distance. Computes
/// `kahanFloat64L2Squared(query, dataset[i])` for every `i`, sorts ascending,
/// returns the first `k` as `ReferenceValue.TopKResult` pairs. The squared
/// space matches `TopKSetVerifier`'s expectations (sqrt-skipping is one of
/// the valid candidate-impl optimizations spec §5 names).
///
/// **Tie-breaking**: distances tie-broken by **index** (ascending) so the
/// reference is deterministic across runs. Candidate impls are free to break
/// ties differently — `TopKSetVerifier` accepts any valid ordering.
///
/// **Empty cases**: `k == 0` returns `[]`; `dataset.isEmpty` precondition
/// fails (an empty dataset with `k > 0` is unverifiable, not "verified with
/// 0 results"). `k > dataset.count` truncates to dataset size.
public func kahanFloat64TopK(
    query: [Float],
    dataset: [[Float]],
    k: Int
) -> [ReferenceValue.TopKResult] {
    precondition(k >= 0, "topK: k must be non-negative")
    if k == 0 { return [] }
    precondition(!dataset.isEmpty, "topK: dataset must be non-empty when k > 0")
    let effectiveK = min(k, dataset.count)
    let distances: [(index: Int, squaredDistance: Double)] = dataset.enumerated().map { (i, v) in
        (i, kahanFloat64L2Squared(query, v))
    }
    let sorted = distances.sorted { lhs, rhs in
        if lhs.squaredDistance != rhs.squaredDistance {
            return lhs.squaredDistance < rhs.squaredDistance
        }
        return lhs.index < rhs.index    // deterministic tie-break
    }
    return sorted.prefix(effectiveK).map {
        ReferenceValue.TopKResult(index: $0.index, squaredDistance: $0.squaredDistance)
    }
}

// MARK: - Pairwise / matrix distances

/// M × N matrix of squared Euclidean distances between every pair drawn from
/// `left` (M vectors) and `right` (N vectors), row-major: `out[i * N + j]`
/// is the squared distance from `left[i]` to `right[j]`. Float64 throughout
/// via `kahanFloat64L2Squared`.
///
/// Used as the reference for both `BatchOperations.pairwiseDistances`
/// (Phase 2.2 Item 5a) and `Operations.distanceMatrix` (Item 5b) — those two
/// workloads differ in their candidate implementation strategies (naive
/// nested loop vs `cblas_sgemm`-trick), not in the answer they're supposed
/// to produce. `kahanFloat64DistanceMatrix` is provided as a named alias so
/// each workload's oracle wiring reads naturally without the alias having
/// to know which family is calling.
public func kahanFloat64PairwiseDistances(
    left: [[Float]],
    right: [[Float]]
) -> [Double] {
    let m = left.count
    let n = right.count
    if m == 0 || n == 0 { return [] }
    let d = left[0].count
    var out = [Double](repeating: 0, count: m * n)
    for i in 0..<m {
        precondition(left[i].count == d, "pairwise: left[\(i)] dim mismatch")
        for j in 0..<n {
            precondition(right[j].count == d, "pairwise: right[\(j)] dim mismatch")
            out[i * n + j] = kahanFloat64L2Squared(left[i], right[j])
        }
    }
    return out
}

/// Named alias of `kahanFloat64PairwiseDistances`; see that function's doc.
/// Two names exist so per-workload oracle wiring in Items 5a/5b reads
/// naturally without naming the wrong family.
public func kahanFloat64DistanceMatrix(
    left: [[Float]],
    right: [[Float]]
) -> [Double] {
    kahanFloat64PairwiseDistances(left: left, right: right)
}

// MARK: - ULP comparison + oracle factories

/// Float32 ULP distance between two finite values. Used by oracle compare
/// closures to score candidate vs reference.
public func floatULPDistance(_ a: Float, _ b: Float) -> UInt32 {
    let ai = a.bitPattern
    let bi = b.bitPattern
    let aBiased = ai & 0x8000_0000 != 0 ? 0x8000_0000 &- ai : ai | 0x8000_0000
    let bBiased = bi & 0x8000_0000 != 0 ? 0x8000_0000 &- bi : bi | 0x8000_0000
    return aBiased > bBiased ? aBiased - bBiased : bBiased - aBiased
}

/// Typed scalar-oracle factory for dot-product workloads. Builds a
/// `ReferenceOracle<Input, Float>` that:
/// 1. Projects the candidate's `Input` down to `(a: [Float], b: [Float])`
///    via the supplied `extractInput` (still useful when `Input` is a struct
///    wrapping typed vectors plus raw buffers, e.g.,
///    `VectorCoreOptimizedDotWorkload.Input`).
/// 2. Computes the Float64 Kahan dot.
/// 3. Applies `expectedSignTransform` (identity for `+a·b` candidates,
///    negation for `DotProductDistance`-style metric candidates).
/// 4. ULP-compares the candidate (Float32) against the transformed reference
///    rounded to Float.
///
/// `Input` is the workload's typed `Input`. `Output` is always `Float`. No
/// `Any` casts — the typed Workload protocol guarantees the oracle and the
/// candidate agree on `Input`/`Output` at compile time.
public func makeDotOracle<Input>(
    extractInput: @Sendable @escaping (Input) -> (a: [Float], b: [Float]),
    expectedSignTransform: @Sendable @escaping (Double) -> Double = { $0 }
) -> ReferenceOracle<Input, Float> {
    ReferenceOracle(
        compute: { input in
            let unwrapped = extractInput(input)
            let raw = kahanFloat64Dot(unwrapped.a, unwrapped.b)
            return .scalar(expectedSignTransform(raw))
        },
        compare: { candidate, reference, window in
            guard case .scalar(let refD) = reference else {
                // ReferenceValue case mismatch — the workload constructed
                // the oracle with the wrong shape. This is a programmer
                // error caught at first run.
                return .failed(maxUlpObserved: .max, window: window, sampleIndex: 0)
            }
            let refF = Float(refD)
            let diff = floatULPDistance(candidate, refF)
            if diff <= window {
                return .verified(maxUlpObserved: diff)
            } else {
                return .failed(maxUlpObserved: diff, window: window, sampleIndex: 0)
            }
        }
    )
}
