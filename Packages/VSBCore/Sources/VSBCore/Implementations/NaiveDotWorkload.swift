import Foundation
import BenchKit

/// Naïve Float32 left-to-right dot product baseline. Establishes the
/// performance floor for the Dot row.
public struct NaiveDotWorkload: BorrowingWorkload {
    public typealias Input = RawFloatDotInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: n))
        return WorkloadID(
            op: .dot, impl: .naive, implClass: .standard,
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
        var sum: Float = 0
        for i in 0..<input.a.count {
            sum += input.a[i] * input.b[i]
        }
        return sum
    }
}
