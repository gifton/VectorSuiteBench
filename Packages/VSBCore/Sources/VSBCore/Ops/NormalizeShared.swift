import Foundation
import BenchKit

/// Shared input type for out-of-place L2 normalize workloads. One N-element
/// Float buffer, deterministic per `WorkloadID` via the runner's `SeedTable`.
public struct RawFloatNormalizeInput {
    public var a: [Float]

    public init(n: Int, rng: inout SplitMix64) {
        var aBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
        }
        self.a = aBuf
    }
}

/// Shared metadata for normalize workloads. Reads N floats, writes N floats.
/// Flops: 1 reduction (~2N) + 1 sqrt + N divides counted as ~N = ~3N.
/// The sqrt is constant overhead; folded into the per-element terms.
public enum NormalizeMetadata {
    public static func bytesMoved(n: Int) -> Int { 2 * n * MemoryLayout<Float>.size }
    public static func flops(n: Int) -> Int { 3 * n }
}

// MARK: - Oracle factory

/// Typed vector-oracle factory for out-of-place normalize. Builds a
/// `ReferenceOracle<Input, Output>` where `Output` is whatever vector type
/// the workload returns (typed `Vector{N}Optimized`, `Vector<D>`, `DynamicVector`,
/// or raw `[Float]`). The two extract closures convert Input and Output to
/// raw `[Float]` buffers for the Float64 reference and the per-element ULP
/// compare; both run **once per case** (verification phase), not per sample,
/// so the conversion cost stays outside the timing window.
///
/// **Per-element comparison.** Walks the candidate's [Float] output against
/// the reference's [Double] output element-by-element. On a mismatch, the
/// failing element index is encoded in the VerificationResult.failed's
/// `sampleIndex` field (mirrors `TopKSetVerifier`'s convention of repurposing
/// sampleIndex for the offending-position telemetry). Vector-output ops can't
/// honestly use sampleIndex as "which sample" because verification runs once.
public func makeNormalizeOracle<Input, Output>(
    extractInput: @Sendable @escaping (Input) -> [Float],
    extractOutput: @Sendable @escaping (Output) -> [Float]
) -> ReferenceOracle<Input, Output> {
    ReferenceOracle(
        compute: { input in
            let raw = extractInput(input)
            let refDoubles = kahanFloat64Normalize(raw)
            return .vector(refDoubles)
        },
        compare: { candidate, reference, window in
            guard case .vector(let refD) = reference else {
                return .failed(maxUlpObserved: .max, window: window, sampleIndex: 0)
            }
            let candidateF = extractOutput(candidate)
            guard candidateF.count == refD.count else {
                return .failed(maxUlpObserved: .max, window: window, sampleIndex: 0)
            }
            var maxObs: UInt32 = 0
            for i in 0..<candidateF.count {
                let refF = Float(refD[i])
                let diff = floatULPDistance(candidateF[i], refF)
                if diff > maxObs { maxObs = diff }
                if diff > window {
                    return .failed(maxUlpObserved: diff, window: window, sampleIndex: i)
                }
            }
            return .verified(maxUlpObserved: maxObs)
        }
    )
}
