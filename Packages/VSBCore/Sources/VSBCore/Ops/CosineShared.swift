import Foundation
import BenchKit

/// Shared input type for cosine similarity workloads. Two N-element Float
/// buffers, deterministic per `WorkloadID` via the runner's `SeedTable`.
/// Structurally identical to `RawFloatDotInput` / `RawFloatL2Input` (same
/// `(a, b)` shape); kept as a parallel type for documentation; a later
/// polish pass can collapse the three into a shared `RawFloatPairInput`
/// once the duplication crosses the cost-of-DRY threshold.
public struct RawFloatCosineInput {
    public var a: [Float]
    public var b: [Float]

    public init(n: Int, rng: inout SplitMix64) {
        var aBuf = [Float](repeating: 0, count: n)
        var bBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        self.a = aBuf
        self.b = bBuf
    }
}

/// Shared metadata for cosine similarity workloads. Same `bytesMoved` as
/// dot/L2 (read 2N floats), higher `flops`: three reductions (dot, ‖a‖²,
/// ‖b‖²) plus the terminal sqrt + mul + divide. Reductions dominate;
/// the terminal constant-time ops are folded in as a single round number.
public enum CosineMetadata {
    public static func bytesMoved(n: Int) -> Int { 2 * n * MemoryLayout<Float>.size }
    public static func flops(n: Int) -> Int { 6 * n }   // 3 reductions × (n muls + n adds)
}

// MARK: - Oracle factory

/// Typed scalar-oracle factory for cosine similarity workloads. Returns
/// `(a·b) / (‖a‖₂ · ‖b‖₂)` in Float64 via three Kahan-Neumaier reductions
/// per `kahanFloat64Cosine`. ULP-compares the candidate (Float32) against
/// the reference rounded to Float.
///
/// **Zero-vector handling**: `kahanFloat64Cosine` returns NaN for zero
/// inputs (1/0 propagates). Candidate impls handle this differently —
/// VectorCore's typed `cosineSimilarity(to:)` returns 0, the naïve baseline
/// produces NaN, etc. Our default uniform `.uniform` input distribution
/// produces positive-magnitude vectors with probability ≈1 at any N ≥ 1,
/// so this divergence doesn't bite Phase 1's standard cases. A future
/// `.adversarial(.zeros)` distribution would need a per-impl zero-aware
/// compare; flagged here so the seam isn't lost.
public func makeCosineOracle<Input>(
    extractInput: @Sendable @escaping (Input) -> (a: [Float], b: [Float])
) -> ReferenceOracle<Input, Float> {
    ReferenceOracle(
        compute: { input in
            let unwrapped = extractInput(input)
            let raw = kahanFloat64Cosine(unwrapped.a, unwrapped.b)
            return .scalar(raw)
        },
        compare: { candidate, reference, window in
            guard case .scalar(let refD) = reference else {
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
