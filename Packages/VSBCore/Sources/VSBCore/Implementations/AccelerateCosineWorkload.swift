import Foundation
import Accelerate
import BenchKit

/// Apple Accelerate cosine similarity, composed from three BLAS calls:
/// `cblas_sdot(a, b)` for the dot product, `cblas_snrm2(a)` and
/// `cblas_snrm2(b)` for the L2 norms (returns the sqrt'd norm directly,
/// not the squared form). Terminal divide.
///
/// This is the "vDSP-composed" baseline from spec §9. No single Accelerate
/// call computes cosine similarity directly — composing three is the
/// idiomatic path and the one a real user of the framework takes.
public struct AccelerateCosineWorkload: BorrowingWorkload {
    public typealias Input = RawFloatCosineInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .accelerate, op: .cosine, shape: .vector(n: n))
        return WorkloadID(
            op: .cosine, impl: .accelerate, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { CosineMetadata.bytesMoved(n: n) }
    public var flops: Int { CosineMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeCosineOracle(extractInput: { ($0.a, $0.b) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        RawFloatCosineInput(n: n, rng: &rng)
    }

    public func invoke(_ input: borrowing Input) -> Output {
        let count = Int32(input.a.count)
        return input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                let dot = cblas_sdot(count, aPtr.baseAddress!, 1, bPtr.baseAddress!, 1)
                let aNorm = cblas_snrm2(count, aPtr.baseAddress!, 1)
                let bNorm = cblas_snrm2(count, bPtr.baseAddress!, 1)
                return dot / (aNorm * bNorm)
            }
        }
    }
}
