import Foundation

/// A type-parameterized reference oracle for a workload. `Input` is the
/// workload's concrete `Input` type; `Output` is its `Output`. The oracle
/// computes a `ReferenceValue` from the same input the candidate sees, then
/// compares the candidate's output against that reference within a
/// shape-dependent ULP window.
///
/// **Why generic, not `Any`:** an earlier draft erased to `Any` so the oracle
/// could be exposed on `WorkloadMetadata` for the registry's existential.
/// That made a future workload's type-mismatch indistinguishable from a real
/// numeric divergence. Carrying `Input` and `Output` here, and exposing the
/// oracle on each typed Workload protocol (not on the metadata existential),
/// restores compile-time safety. The Runner is already generic over the
/// concrete workload type, so it can call the typed oracle directly — no
/// `Any` casts on the verification path.
///
/// **Buffer convention.** Per §5 of the design spec, the oracle works on raw
/// `[Float]` (or `UnsafeBufferPointer<Float>`) regardless of the candidate's
/// vector flavor. Workloads that wrap a typed vector (e.g.,
/// `Vector512Optimized`) carry the underlying Float buffer alongside the
/// typed value in `Input` so the oracle sees the same bytes.
///
/// **Sign-awareness.** The `compute` closure encodes the expected sign of
/// the candidate's output (e.g., negate the Float64 Kahan reference when the
/// candidate is `DotProductDistance` returning `−a·b`). This is per-workload,
/// not per-oracle-type.
public struct ReferenceOracle<Input, Output>: Sendable {
    public let compute: @Sendable (Input) -> ReferenceValue
    public let compare: @Sendable (Output, ReferenceValue, UInt32) -> VerificationResult

    public init(
        compute: @Sendable @escaping (Input) -> ReferenceValue,
        compare: @Sendable @escaping (Output, ReferenceValue, UInt32) -> VerificationResult
    ) {
        self.compute = compute
        self.compare = compare
    }
}

/// A reference result. Candidates produce a comparable form (scalar widened
/// to Double; vector unwrapped to `[Float]` and lifted to `[Double]`; etc.).
public enum ReferenceValue: Sendable, Equatable {
    case scalar(Double)
    case vector([Double])
    /// For Top-K, the reference holds the ordered (index, squaredDistance)
    /// pairs that the set-based verifier consumes.
    case topK(results: [TopKResult])

    public struct TopKResult: Sendable, Equatable {
        public let index: Int
        public let squaredDistance: Double

        public init(index: Int, squaredDistance: Double) {
            self.index = index
            self.squaredDistance = squaredDistance
        }
    }
}
