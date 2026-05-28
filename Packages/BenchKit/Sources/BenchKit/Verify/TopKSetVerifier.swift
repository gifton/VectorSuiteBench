import Foundation

/// Set-based verifier for Top-K workloads per design spec §5.
///
/// Top-K cannot be verified by strict index identity. Two reasons (spec §5):
///
/// 1. **Sqrt-skipping.** Implementations of Euclidean Top-K often return
///    *squared* distances — a valid ranking-preserving optimization since
///    `argmin sqrt(x) ≡ argmin x` for non-negative `x`. A Float64 oracle
///    computing true Euclidean distance returns the sqrt. Comparing the
///    two as raw scores fails on every case.
/// 2. **Tied distances.** Random datasets routinely produce equidistant
///    neighbors. A min-heap, a partial sort, and a quickselect can all
///    tie-break differently; all orderings are mathematically valid.
///
/// The protocol — codified by `verify(...)` below — does three things:
///
///   1. Lift both sides into a shared **squared-distance space**. The
///      codebase's `ReferenceValue.TopKResult.squaredDistance` field is the
///      canonical reference form (always squared). When the candidate
///      reports the sqrt'd distance, the verifier squares it on the way in.
///   2. **Multiset equality** on the resulting distance arrays within the
///      ULP window of the underlying metric op (e.g., `l2dist²`). Both
///      sides are sorted, then pairwise-compared in Float32 ULPs after
///      narrowing the reference Double to Float (matches the codebase's
///      Float32-window convention; see `makeDotOracle.compare`).
///   3. **Index-validity re-check**. For every index the candidate returned,
///      call the supplied `recomputeSquaredDistance` closure to re-evaluate
///      the distance against the dataset, and confirm the recomputed value
///      is present in the reference multiset within the same ULP window.
///      This catches the failure mode the multiset step alone misses:
///      a candidate that returns the wrong index but with a coincidentally
///      close score.
///
/// The verifier is a pure namespace; it captures no state. It does not
/// own the dataset — the closure is supplied per call so the verifier
/// stays decoupled from any particular workload's input shape.
public enum TopKSetVerifier {

    /// Verify a Top-K candidate result against a Float64 reference.
    ///
    /// - Parameters:
    ///   - candidate: The (index, score) pairs returned by the impl under
    ///     test. Ordering is irrelevant — both sides are sorted before
    ///     comparison.
    ///   - reference: The (index, squaredDistance) pairs from the Float64
    ///     Kahan-Neumaier oracle. Always in squared-distance space.
    ///   - candidateReturnsSquared: Declares the candidate's distance space.
    ///     `true` ⇒ candidate scores are already squared; `false` ⇒ candidate
    ///     scores are sqrt'd and will be squared on the way in. **The
    ///     codebase's convention is that VectorCore's Euclidean Top-K
    ///     returns squared** (per spec §5 #1); a verifier on a true-distance
    ///     impl passes `false`.
    ///   - ulpWindow: ULP tolerance for the **underlying** op (e.g., for
    ///     a Euclidean Top-K, the `l2dist` window for the candidate's
    ///     `implClass` + `shape`). Not the `.topK` window from
    ///     `ulpTolerance(...)`, which is 0 by design (set-based path).
    ///   - recomputeSquaredDistance: Closure that, given a candidate index,
    ///     returns the squared distance from the query to `dataset[idx]`
    ///     re-evaluated by the same metric the impl declares. Used only by
    ///     the index-validity step.
    /// - Returns: `.verified(maxUlpObserved:)` on success;
    ///   `.failed(maxUlpObserved:window:sampleIndex:)` on a multiset
    ///   mismatch (sampleIndex = 0) or an index-validity failure
    ///   (sampleIndex = the offending candidate index, encoded for
    ///   downstream telemetry).
    public static func verify(
        candidate: [(index: Int, score: Float)],
        reference: [ReferenceValue.TopKResult],
        candidateReturnsSquared: Bool,
        ulpWindow: UInt32,
        recomputeSquaredDistance: (Int) -> Double
    ) -> VerificationResult {
        // Cardinality must match. A k-mismatch is a contract violation,
        // not a tie-breaking artifact.
        guard candidate.count == reference.count else {
            return .failed(
                maxUlpObserved: .max,
                window: ulpWindow,
                sampleIndex: 0
            )
        }

        // Trivially verified at k = 0 (empty multiset against empty
        // multiset). Zero observed ULPs — there's nothing to compare.
        if candidate.isEmpty {
            return .verified(maxUlpObserved: 0)
        }

        // -- Step 1: lift candidate into squared-distance space. --
        let candidateSquared: [Double] = candidate.map { pair in
            let score = Double(pair.score)
            return candidateReturnsSquared ? score : (score * score)
        }
        let referenceSquared: [Double] = reference.map(\.squaredDistance)

        // -- Step 2: multiset equality. Sort both, walk pairwise. --
        let sortedCandidate = candidateSquared.sorted()
        let sortedReference = referenceSquared.sorted()

        var maxObserved: UInt32 = 0
        for i in 0..<sortedCandidate.count {
            // Narrow the reference to Float32 before ULP arithmetic —
            // matches the existing oracle compare convention so a window
            // sized for Float32 means the same thing here as it does in
            // makeDotOracle.compare.
            let candF = Float(sortedCandidate[i])
            let refF = Float(sortedReference[i])
            let diff = float32ULPDistance(candF, refF)
            if diff > maxObserved { maxObserved = diff }
            if diff > ulpWindow {
                return .failed(
                    maxUlpObserved: diff,
                    window: ulpWindow,
                    sampleIndex: 0
                )
            }
        }

        // -- Step 3: index-validity re-check. --
        // For each candidate index, re-evaluate the squared distance against
        // the dataset and confirm it lands within `ulpWindow` of *some*
        // reference distance. If no reference matches, the candidate
        // returned a wrong-but-coincidentally-close index — caught here.
        for pair in candidate {
            let recomputed = recomputeSquaredDistance(pair.index)
            let recomputedF = Float(recomputed)
            var closest: UInt32 = .max
            for ref in reference {
                let refF = Float(ref.squaredDistance)
                let diff = float32ULPDistance(recomputedF, refF)
                if diff < closest { closest = diff }
                if diff <= ulpWindow { break } // early exit; this index is good.
            }
            if closest > ulpWindow {
                // Encode the offending candidate index in sampleIndex —
                // existing convention uses sampleIndex = 0 for scalar ops;
                // for Top-K we press it into service to point at which
                // returned index failed the re-check.
                return .failed(
                    maxUlpObserved: closest,
                    window: ulpWindow,
                    sampleIndex: pair.index
                )
            }
            if closest > maxObserved { maxObserved = closest }
        }

        return .verified(maxUlpObserved: maxObserved)
    }
}

// MARK: - Internal helpers

/// Float32 ULP distance between two finite values. Uses the IEEE 754
/// biased-bit-pattern trick so the comparison is well-defined across
/// signs. Mirrors VSBCore's `floatULPDistance(_:_:)` — duplicated here
/// because BenchKit cannot depend on VSBCore.
@inlinable
internal func float32ULPDistance(_ a: Float, _ b: Float) -> UInt32 {
    let ai = a.bitPattern
    let bi = b.bitPattern
    let aBiased = ai & 0x8000_0000 != 0 ? 0x8000_0000 &- ai : ai | 0x8000_0000
    let bBiased = bi & 0x8000_0000 != 0 ? 0x8000_0000 &- bi : bi | 0x8000_0000
    return aBiased > bBiased ? aBiased - bBiased : bBiased - aBiased
}
