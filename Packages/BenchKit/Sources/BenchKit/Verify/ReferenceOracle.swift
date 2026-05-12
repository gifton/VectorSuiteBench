import Foundation

/// A pluggable, type-erased reference oracle for a workload. Operates on raw
/// `[Float]` (or `UnsafeBufferPointer<Float>`) buffers regardless of the
/// candidate's vector flavor — the runner unwraps `Vector<DimN>`,
/// `VectorNOptimized`, and `DynamicVector` to their underlying contiguous
/// storage before invoking the oracle.
///
/// The oracle returns a `ReferenceValue` (typically `Double` or `[Double]`)
/// and exposes a `compare` closure that does the ULP-window check against the
/// candidate's unwrapped output, returning a `VerificationResult`.
///
/// **Sign-awareness.** For dot product, the oracle's `compare` is wired up by
/// the workload author to expect `+a·b` for `Vector.dot()`-class candidates
/// and `−a·b` for `DotProductDistance`-class candidates (selected via
/// `WorkloadID.params["api"]`). Mis-wiring this is a guaranteed silent
/// verification failure on correct implementations — covered by a unit test.
public struct ReferenceOracle: Sendable {
    public let compute: @Sendable (_ input: Any) -> ReferenceValue
    public let compare: @Sendable (
        _ candidate: Any,
        _ reference: ReferenceValue,
        _ ulpWindow: UInt32
    ) -> VerificationResult

    public init(
        compute: @Sendable @escaping (_ input: Any) -> ReferenceValue,
        compare: @Sendable @escaping (
            _ candidate: Any,
            _ reference: ReferenceValue,
            _ ulpWindow: UInt32
        ) -> VerificationResult
    ) {
        self.compute = compute
        self.compare = compare
    }
}

/// A type-erased reference result. Candidates produce a comparable form
/// (typically by widening Float32 to Double for scalar values, or unwrapping
/// vector types to `[Float]` buffers and then comparing element-wise).
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
