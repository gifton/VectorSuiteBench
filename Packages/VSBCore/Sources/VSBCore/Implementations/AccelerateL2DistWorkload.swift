import Foundation
import Accelerate
import BenchKit

/// Apple Accelerate squared L2 distance via `vDSP_distancesq`. The vDSP
/// signature returns the squared distance directly — no separate sub +
/// square + sum chain in user code.
public struct AccelerateL2DistWorkload: BorrowingWorkload {
    public typealias Input = RawFloatL2Input
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .accelerate, op: .l2dist, shape: .vector(n: n))
        return WorkloadID(
            op: .l2dist, impl: .accelerate, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { L2DistanceMetadata.bytesMoved(n: n) }
    public var flops: Int { L2DistanceMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeL2SquaredOracle(extractInput: { ($0.a, $0.b) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        RawFloatL2Input(n: n, rng: &rng)
    }

    public func invoke(_ input: borrowing Input) -> Output {
        var result: Float = 0
        let count = vDSP_Length(input.a.count)
        input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                vDSP_distancesq(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &result, count)
            }
        }
        return result
    }
}
