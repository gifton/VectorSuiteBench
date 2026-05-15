import Foundation
import Accelerate
import BenchKit

/// Apple Accelerate (vDSP/BLAS) Float32 dot via `cblas_sdot`. This is the
/// "industry standard-bearer" baseline for Phase 1 — the comparison VectorCore
/// has to match or beat to justify its existence.
public struct AccelerateDotWorkload: BorrowingWorkload {
    public typealias Input = RawFloatDotInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .accelerate, op: .dot, shape: .vector(n: n))
        return WorkloadID(
            op: .dot, impl: .accelerate, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { DotMetadata.bytesMoved(n: n) }
    public var flops: Int { DotMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeDotOracle(extractInput: { ($0.a, $0.b) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        RawFloatDotInput(n: n, rng: &rng)
    }

    public func invoke(_ input: borrowing Input) -> Output {
        // cblas_sdot uses pairwise summation and lives in the same accuracy
        // class as our Kahan-Neumaier oracle modulo log₂(N)·ε drift.
        let count = Int32(input.a.count)
        return input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                cblas_sdot(count, aPtr.baseAddress!, 1, bPtr.baseAddress!, 1)
            }
        }
    }
}
