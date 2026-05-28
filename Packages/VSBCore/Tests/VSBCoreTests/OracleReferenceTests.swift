import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit

/// Unit tests for the Float64 Kahan-Neumaier reference functions in
/// `KahanFloat64Reference.swift`. Each new function (Phase 2.2 Item 0d)
/// gets coverage against small hand-computed inputs where the expected
/// answer is obvious by inspection. Phase 1's `dot` reference is already
/// covered by `DotWorkloadTests` round-tripping through its candidates; no
/// duplicate dot test here.
@Suite("KahanFloat64Reference — new oracles")
struct OracleReferenceTests {

    // MARK: - L2 squared

    @Test("L2Squared: 3-4-5 triangle in 2D returns 25 exactly")
    func l2SquaredHand() {
        let a: [Float] = [0, 0]
        let b: [Float] = [3, 4]
        let d = kahanFloat64L2Squared(a, b)
        #expect(d == 25.0)
    }

    @Test("L2Squared: identical vectors give 0")
    func l2SquaredIdentical() {
        let a: [Float] = [1.5, -2.5, 7]
        #expect(kahanFloat64L2Squared(a, a) == 0.0)
    }

    @Test("L2Squared: argument order doesn't matter (symmetry)")
    func l2SquaredSymmetric() {
        let a: [Float] = [1, 2, 3, 4]
        let b: [Float] = [4, 3, 2, 1]
        #expect(kahanFloat64L2Squared(a, b) == kahanFloat64L2Squared(b, a))
    }

    // MARK: - Cosine similarity

    @Test("Cosine: orthogonal unit vectors → 0")
    func cosineOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        #expect(kahanFloat64Cosine(a, b) == 0.0)
    }

    @Test("Cosine: parallel vectors (same direction) → 1")
    func cosineParallel() {
        let a: [Float] = [1, 2, 3, 4]
        let b: [Float] = [2, 4, 6, 8]   // 2× a, same direction
        // Allow a single ULP of slack — three reductions + a division can
        // shave a bit off Float64 exactness.
        let cos = kahanFloat64Cosine(a, b)
        #expect(abs(cos - 1.0) < 1e-15, Comment(rawValue: "expected ~1.0; got \(cos)"))
    }

    @Test("Cosine: anti-parallel vectors → -1")
    func cosineAntiParallel() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        let cos = kahanFloat64Cosine(a, b)
        #expect(abs(cos - (-1.0)) < 1e-15)
    }

    // MARK: - Normalize

    @Test("Normalize: unit vector in 2D returns itself")
    func normalizeAlreadyUnit() {
        let a: [Float] = [1, 0]
        let result = kahanFloat64Normalize(a)
        #expect(result == [1.0, 0.0])
    }

    @Test("Normalize: (3, 4) → (0.6, 0.8)")
    func normalizeHand() {
        let a: [Float] = [3, 4]
        let result = kahanFloat64Normalize(a)
        #expect(result.count == 2)
        #expect(abs(result[0] - 0.6) < 1e-15)
        #expect(abs(result[1] - 0.8) < 1e-15)
    }

    // MARK: - AXPY

    @Test("AXPY: α=2 · x + y for small vectors returns 2x + y element-wise")
    func axpyHand() {
        let x: [Float] = [1, 2, 3]
        let y: [Float] = [10, 20, 30]
        let result = kahanFloat64Axpy(alpha: 2.0, x: x, y: y)
        #expect(result == [12.0, 24.0, 36.0])
    }

    @Test("AXPY: α=0 returns y unchanged (just widened to Double)")
    func axpyAlphaZero() {
        let x: [Float] = [1, 2, 3]
        let y: [Float] = [5, 6, 7]
        let result = kahanFloat64Axpy(alpha: 0.0, x: x, y: y)
        #expect(result == [5.0, 6.0, 7.0])
    }

    // MARK: - Top-K

    @Test("TopK: 4-point dataset, k=2 finds two nearest by squared L2")
    func topKHand() {
        // Query at origin in 2D. Dataset:
        //   idx 0: (3, 4)  → sq dist 25
        //   idx 1: (1, 0)  → sq dist 1
        //   idx 2: (0, 2)  → sq dist 4
        //   idx 3: (10, 0) → sq dist 100
        // Top-2 (ascending): idx 1 (dist 1), idx 2 (dist 4).
        let query: [Float] = [0, 0]
        let dataset: [[Float]] = [[3, 4], [1, 0], [0, 2], [10, 0]]
        let top = kahanFloat64TopK(query: query, dataset: dataset, k: 2)
        #expect(top.count == 2)
        #expect(top[0].index == 1 && top[0].squaredDistance == 1.0)
        #expect(top[1].index == 2 && top[1].squaredDistance == 4.0)
    }

    @Test("TopK: ties tie-broken by index ascending (deterministic)")
    func topKTieBreak() {
        // Indices 5, 1, 3 all sit at distance 4; index 0 sits at distance 0.
        let query: [Float] = [0, 0]
        // distance² values: idx0=0, idx1=4, idx2=9, idx3=4, idx4=9, idx5=4
        let dataset: [[Float]] = [
            [0, 0], [2, 0], [3, 0], [0, 2], [0, 3], [-2, 0]
        ]
        let top = kahanFloat64TopK(query: query, dataset: dataset, k: 4)
        #expect(top.count == 4)
        #expect(top[0].index == 0)
        // Ties at distance 4 → indices 1, 3, 5 in ascending order.
        #expect(top[1].index == 1 && top[1].squaredDistance == 4.0)
        #expect(top[2].index == 3 && top[2].squaredDistance == 4.0)
        #expect(top[3].index == 5 && top[3].squaredDistance == 4.0)
    }

    @Test("TopK: k=0 returns empty; k>dataset.count truncates")
    func topKBoundary() {
        let query: [Float] = [0, 0]
        let dataset: [[Float]] = [[1, 0], [0, 1]]
        #expect(kahanFloat64TopK(query: query, dataset: dataset, k: 0).isEmpty)
        let truncated = kahanFloat64TopK(query: query, dataset: dataset, k: 100)
        #expect(truncated.count == 2, Comment(rawValue: "k>dataset.count should truncate to dataset size"))
    }

    // MARK: - Pairwise / distanceMatrix

    @Test("PairwiseDistances: 2×3 hand-computed matrix is row-major")
    func pairwiseHand() {
        // left:  L0=(0,0), L1=(1,1)
        // right: R0=(0,0), R1=(3,4), R2=(1,1)
        // Squared distances row-major:
        //   L0-R0=0,  L0-R1=25, L0-R2=2
        //   L1-R0=2,  L1-R1=(1-3)²+(1-4)²=4+9=13, L1-R2=0
        let left: [[Float]] = [[0, 0], [1, 1]]
        let right: [[Float]] = [[0, 0], [3, 4], [1, 1]]
        let m = kahanFloat64PairwiseDistances(left: left, right: right)
        #expect(m == [0, 25, 2, 2, 13, 0])
    }

    @Test("DistanceMatrix is an alias of PairwiseDistances")
    func distanceMatrixAlias() {
        let left: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let right: [[Float]] = [[7, 8, 9], [10, 11, 12], [1, 2, 3]]
        let viaPairwise = kahanFloat64PairwiseDistances(left: left, right: right)
        let viaDistanceMatrix = kahanFloat64DistanceMatrix(left: left, right: right)
        #expect(viaPairwise == viaDistanceMatrix)
    }

    @Test("Pairwise: empty left or right yields empty output")
    func pairwiseEmpty() {
        let v: [[Float]] = [[1, 2, 3]]
        #expect(kahanFloat64PairwiseDistances(left: [], right: v).isEmpty)
        #expect(kahanFloat64PairwiseDistances(left: v, right: []).isEmpty)
    }
}
