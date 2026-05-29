import Foundation
import BenchKit

/// Shared input type for squared L2 distance workloads. Two N-element Float
/// buffers, deterministic per `WorkloadID` via the runner's `SeedTable`.
///
/// Structurally identical to `RawFloatDotInput` — both ops consume two
/// same-length Float arrays. Kept as a parallel type rather than reusing
/// the dot one so the type name documents what the workload measures;
/// a later polish pass can collapse them into a shared `RawFloatPairInput`
/// once 3+ families are using the shape.
public struct RawFloatL2Input {
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

/// Shared metadata helpers for squared L2 distance workloads. Same
/// `bytesMoved` as dot (both read 2N floats), but `flops` is higher: each
/// element does sub + mul + add (vs dot's mul + add).
public enum L2DistanceMetadata {
    public static func bytesMoved(n: Int) -> Int { 2 * n * MemoryLayout<Float>.size }
    public static func flops(n: Int) -> Int { 3 * n }   // n subs + n muls + n adds
}

// MARK: - Oracle factory

/// Typed scalar-oracle factory for squared-L2 workloads. Builds a
/// `ReferenceOracle<Input, Float>` that:
/// 1. Projects the candidate's `Input` down to `(a: [Float], b: [Float])`
///    via the supplied `extractInput` (workloads wrapping typed vectors —
///    e.g., `VectorCoreOptimizedL2DistWorkload.Input` — pass the raw
///    Float buffers alongside the typed value so the oracle is
///    flavor-agnostic).
/// 2. Computes `Σ(aᵢ - bᵢ)²` in Float64 via Kahan-Neumaier.
/// 3. ULP-compares the candidate (Float32) against the reference rounded
///    to Float.
///
/// `Input` is the workload's typed `Input`. `Output` is always `Float`. No
/// `Any` casts — the typed Workload protocol guarantees the oracle and
/// the candidate agree on `Input`/`Output` at compile time.
public func makeL2SquaredOracle<Input>(
    extractInput: @Sendable @escaping (Input) -> (a: [Float], b: [Float])
) -> ReferenceOracle<Input, Float> {
    ReferenceOracle(
        compute: { input in
            let unwrapped = extractInput(input)
            let raw = kahanFloat64L2Squared(unwrapped.a, unwrapped.b)
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
