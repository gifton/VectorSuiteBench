import Foundation
import Accelerate
import BenchKit

/// Apple Accelerate out-of-place L2 normalize, composed from `cblas_snrm2`
/// (returns the L2 norm directly) followed by `vDSP_vsmul` (scalar-multiply
/// into output buffer). Two Accelerate calls; one read pass each.
///
/// **Spec §9 baseline**: `vDSP_vnrm2+vDSP_vsmul`. We use `cblas_snrm2` over
/// `vDSP_vnrm2` because the BLAS form returns the norm directly as a
/// scalar, whereas `vDSP_vnrm2` requires an in/out scalar pointer with the
/// same numerical behavior. The two are functionally interchangeable for
/// out-of-place normalize.
public struct AccelerateNormalizeWorkload: BorrowingWorkload {
    public typealias Input = RawFloatNormalizeInput
    public typealias Output = [Float]

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .accelerate, op: .normalize, shape: .vector(n: n))
        return WorkloadID(
            op: .normalize, impl: .accelerate, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { NormalizeMetadata.bytesMoved(n: n) }
    public var flops: Int { NormalizeMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeNormalizeOracle(extractInput: { $0.a }, extractOutput: { $0 })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        RawFloatNormalizeInput(n: n, rng: &rng)
    }

    public func invoke(_ input: borrowing Input) -> Output {
        let count = input.a.count
        let lenI32 = Int32(count)
        var out = [Float](repeating: 0, count: count)
        input.a.withUnsafeBufferPointer { aPtr in
            let norm = cblas_snrm2(lenI32, aPtr.baseAddress!, 1)
            var inv = 1.0 / norm
            out.withUnsafeMutableBufferPointer { outPtr in
                vDSP_vsmul(aPtr.baseAddress!, 1, &inv, outPtr.baseAddress!, 1, vDSP_Length(count))
            }
        }
        return out
    }
}
