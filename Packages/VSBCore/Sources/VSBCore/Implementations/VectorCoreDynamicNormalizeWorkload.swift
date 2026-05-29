import Foundation
import BenchKit
import VectorCore

/// `DynamicVector.normalized()` (Result-returning) followed by `.get()` —
/// the only normalize path on `DynamicVector`. No Self-returning variant
/// exists; the Result unwrap is unavoidable and counted as part of the
/// flavor's measurement.
///
/// `try!` is appropriate here: uniformly-random `[0, 1)` inputs at any
/// dim ≥ 1 have magnitude > 0 with probability ≈ 1, so the only
/// `VectorError` the call could return (.invalidOperation for a zero
/// vector) cannot occur on the registry's standard input distribution.
public struct VectorCoreDynamicNormalizeWorkload: BorrowingWorkload {
    public struct Input {
        public var v: DynamicVector
        public var raw: [Float]
    }
    public typealias Output = DynamicVector

    public let n: Int

    public init(n: Int) {
        precondition(n > 0, "DynamicVector dimension must be > 0")
        self.n = n
    }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "dynamic"],
            impl: .vectorCore, op: .normalize, shape: .vector(n: n)
        )
        return WorkloadID(
            op: .normalize, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { NormalizeMetadata.bytesMoved(n: n) }
    public var flops: Int { NormalizeMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeNormalizeOracle(
            extractInput: { $0.raw },
            extractOutput: { v in Array(v) }
        )
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        var aBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
        }
        return Input(v: DynamicVector(aBuf), raw: aBuf)
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        try! input.v.normalized().get()
    }
}
