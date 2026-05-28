import Testing
import Foundation
@testable import BenchKit

/// Unit tests for `TopKSetVerifier`. Exercises every branch of the three-step
/// protocol from design spec §5:
///   1. cardinality + empty handling
///   2. multiset equality in squared-distance space (incl. tie handling +
///      sqrt'd-candidate normalization)
///   3. index-validity re-check via the recompute closure
///
/// Tests use small hand-built inputs — multisets of 3-5 distances — so the
/// expected ULPs are obvious by inspection and the closures can map indices
/// to distances inline.
@Suite("TopKSetVerifier")
struct TopKSetVerifierTests {

    // MARK: - Helpers

    /// Build a closure that returns the squared distance for known indices
    /// and a deliberately-out-of-range value (1e30) for unknown ones, so
    /// "missing index" tests can verify the closure path catches them.
    private func recomputer(_ map: [Int: Double]) -> (Int) -> Double {
        { idx in map[idx] ?? 1e30 }
    }

    /// Build a reference array from (index, squaredDistance) pairs.
    private func reference(_ pairs: [(Int, Double)]) -> [ReferenceValue.TopKResult] {
        pairs.map { ReferenceValue.TopKResult(index: $0.0, squaredDistance: $0.1) }
    }

    // MARK: - Cardinality + empty

    @Test("k = 0: empty candidate vs empty reference verifies trivially")
    func emptyVerifies() {
        let result = TopKSetVerifier.verify(
            candidate: [],
            reference: [],
            candidateReturnsSquared: true,
            ulpWindow: 8,
            recomputeSquaredDistance: { _ in .nan }
        )
        #expect(result == .verified(maxUlpObserved: 0))
    }

    @Test("Cardinality mismatch fails immediately")
    func cardinalityMismatchFails() {
        let result = TopKSetVerifier.verify(
            candidate: [(index: 0, score: 1.0)],
            reference: reference([(0, 1.0), (1, 2.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 8,
            recomputeSquaredDistance: recomputer([0: 1.0, 1: 2.0])
        )
        if case .failed(let observed, let window, _) = result {
            #expect(observed == .max, Comment(rawValue: "k mismatch should saturate observed ULPs"))
            #expect(window == 8)
        } else {
            Issue.record(Comment(rawValue: "expected .failed for cardinality mismatch; got \(result)"))
        }
    }

    // MARK: - Multiset equality (step 2)

    @Test("Single-element k=1 with exact match verifies")
    func singleElementVerifies() {
        let result = TopKSetVerifier.verify(
            candidate: [(index: 7, score: 4.0)],
            reference: reference([(7, 4.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 8,
            recomputeSquaredDistance: recomputer([7: 4.0])
        )
        #expect(result.isVerified)
    }

    @Test("All-ties: every distance identical → multiset trivially equal")
    func allTiesVerify() {
        // 5 candidate indices, all with the same squared distance.
        // Indices 10..14 all live at distance 2.25.
        let result = TopKSetVerifier.verify(
            candidate: (10...14).map { (index: $0, score: Float(2.25)) },
            reference: reference((10...14).map { ($0, 2.25) }),
            candidateReturnsSquared: true,
            ulpWindow: 4,
            recomputeSquaredDistance: recomputer(Dictionary(uniqueKeysWithValues: (10...14).map { ($0, 2.25) }))
        )
        #expect(result.isVerified)
    }

    @Test("Tie-breaking divergence: same multiset, different index ordering verifies")
    func tieBreakingDivergenceVerifies() {
        // Reference returns (0, 1.0), (1, 1.0), (2, 4.0). Candidate returns
        // the same indices in DIFFERENT order: (2, 4.0), (1, 1.0), (0, 1.0).
        // Multiset equality should ignore order — both yield sorted [1.0,
        // 1.0, 4.0].
        let result = TopKSetVerifier.verify(
            candidate: [(2, 4.0), (1, 1.0), (0, 1.0)],
            reference: reference([(0, 1.0), (1, 1.0), (2, 4.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 4,
            recomputeSquaredDistance: recomputer([0: 1.0, 1: 1.0, 2: 4.0])
        )
        #expect(result.isVerified)
    }

    @Test("Sqrt'd candidate is squared before comparison")
    func sqrtCandidateGetsSquared() {
        // Reference holds squared distances {1.0, 4.0, 9.0}. Candidate
        // returns sqrt'd distances {1.0, 2.0, 3.0}. The verifier should
        // square the candidate (giving {1, 4, 9}) and match.
        let result = TopKSetVerifier.verify(
            candidate: [(0, 1.0), (1, 2.0), (2, 3.0)],
            reference: reference([(0, 1.0), (1, 4.0), (2, 9.0)]),
            candidateReturnsSquared: false,
            ulpWindow: 4,
            recomputeSquaredDistance: recomputer([0: 1.0, 1: 4.0, 2: 9.0])
        )
        #expect(result.isVerified)
    }

    @Test("Multiset mismatch (wrong distances) fails")
    func multisetMismatchFails() {
        // Reference {1.0, 4.0, 9.0} vs candidate {1.0, 4.0, 16.0} — last
        // distance differs by many ULPs (Float(9.0) vs Float(16.0)).
        let result = TopKSetVerifier.verify(
            candidate: [(0, 1.0), (1, 4.0), (2, 16.0)],
            reference: reference([(0, 1.0), (1, 4.0), (2, 9.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 8,
            recomputeSquaredDistance: recomputer([0: 1.0, 1: 4.0, 2: 9.0])
        )
        if case .failed(let observed, let window, let sampleIndex) = result {
            #expect(observed > window, Comment(rawValue: "observed ULPs must exceed window for the failure case; observed=\(observed) window=\(window)"))
            #expect(window == 8)
            #expect(sampleIndex == 0, Comment(rawValue: "multiset-step failures use sampleIndex=0 (no offending candidate idx)"))
        } else {
            Issue.record(Comment(rawValue: "expected .failed for multiset mismatch; got \(result)"))
        }
    }

    // MARK: - ULP boundary

    @Test("Just-within-window passes; just-outside fails")
    func ulpBoundaryBehavior() {
        // Construct a candidate and reference that differ by exactly N ULPs
        // at Float32 precision. Take a finite Float ref, then nudge the
        // bit-pattern by `nudge` to construct the candidate. The verifier
        // should pass at window=nudge and fail at window=nudge-1.
        let refF: Float = 4.0
        let nudge: UInt32 = 5
        let candidateF = Float(bitPattern: refF.bitPattern &+ nudge)
        let observedULPs = float32ULPDistance(refF, candidateF)
        #expect(observedULPs == nudge, Comment(rawValue: "test invariant: handcrafted nudge should be exactly \(nudge) ULPs"))

        // Within: window == nudge → passes.
        let pass = TopKSetVerifier.verify(
            candidate: [(0, candidateF)],
            reference: reference([(0, Double(refF))]),
            candidateReturnsSquared: true,
            ulpWindow: nudge,
            recomputeSquaredDistance: recomputer([0: Double(refF)])
        )
        #expect(pass.isVerified)

        // Outside: window == nudge - 1 → fails.
        let fail = TopKSetVerifier.verify(
            candidate: [(0, candidateF)],
            reference: reference([(0, Double(refF))]),
            candidateReturnsSquared: true,
            ulpWindow: nudge - 1,
            recomputeSquaredDistance: recomputer([0: Double(refF)])
        )
        if case .failed(let observed, _, _) = fail {
            #expect(observed == nudge)
        } else {
            Issue.record(Comment(rawValue: "expected .failed at window=nudge-1; got \(fail)"))
        }
    }

    // MARK: - Index-validity re-check (step 3)

    @Test("Wrong index — recomputed distance not in reference multiset fails")
    func wrongIndexCaughtByRecompute() {
        // Multiset step passes: candidate returned {1.0, 4.0, 9.0} matching
        // the reference multiset exactly. BUT the candidate returned index
        // 99 (a wrong neighbor) which, when re-evaluated against the
        // dataset, produces 25.0 — a distance not in the reference's
        // multiset of {1.0, 4.0, 9.0}. The index-validity step catches it.
        //
        // Indices 0, 1, 99 are returned. Recompute map says 0→1.0, 1→4.0,
        // 99→25.0. Reference multiset is {1.0, 4.0, 9.0}. Index 99's
        // recomputed distance 25.0 is nowhere near any reference value.
        let result = TopKSetVerifier.verify(
            candidate: [(0, 1.0), (1, 4.0), (99, 9.0)],
            reference: reference([(0, 1.0), (1, 4.0), (2, 9.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 8,
            recomputeSquaredDistance: recomputer([0: 1.0, 1: 4.0, 99: 25.0])
        )
        if case .failed(_, _, let sampleIndex) = result {
            #expect(sampleIndex == 99, Comment(rawValue: "sampleIndex must encode the offending candidate index"))
        } else {
            Issue.record(Comment(rawValue: "expected .failed for wrong-index case; got \(result)"))
        }
    }

    @Test("Valid alternate index — multiset matches and recomputed distance is in reference set")
    func validAlternateIndexVerifies() {
        // Reference: (0, 1.0), (1, 1.0), (2, 4.0). Two indices (0 and 1)
        // are tied at distance 1.0 — a third dataset entry at index 7 may
        // also tie. Candidate returns (7, 1.0), (0, 1.0), (2, 4.0) —
        // legitimate; index 7's recomputed distance is also 1.0.
        let result = TopKSetVerifier.verify(
            candidate: [(7, 1.0), (0, 1.0), (2, 4.0)],
            reference: reference([(0, 1.0), (1, 1.0), (2, 4.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 4,
            recomputeSquaredDistance: recomputer([0: 1.0, 7: 1.0, 2: 4.0])
        )
        #expect(result.isVerified)
    }

    // MARK: - Smoke

    @Test("Small hand-computed: 3 query-neighbor distances pass end-to-end")
    func handComputedSmoke() {
        // Query = (0, 0). Dataset:
        //   idx 0: (1, 0)   → squared distance 1
        //   idx 1: (0, 2)   → squared distance 4
        //   idx 2: (3, 4)   → squared distance 25
        //   idx 3: (5, 12)  → squared distance 169
        // Top-3 by squared distance: indices 0, 1, 2 with distances {1, 4, 25}.
        let dataset: [(Double, Double)] = [(1, 0), (0, 2), (3, 4), (5, 12)]
        let query: (Double, Double) = (0, 0)
        let result = TopKSetVerifier.verify(
            candidate: [(0, 1.0), (1, 4.0), (2, 25.0)],
            reference: reference([(0, 1.0), (1, 4.0), (2, 25.0)]),
            candidateReturnsSquared: true,
            ulpWindow: 4,
            recomputeSquaredDistance: { idx in
                let dx = dataset[idx].0 - query.0
                let dy = dataset[idx].1 - query.1
                return dx * dx + dy * dy
            }
        )
        #expect(result.isVerified)
    }
}
