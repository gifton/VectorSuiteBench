import Foundation
import BenchKit

/// Naïve Float32 left-to-right L2 normalize baseline. Two passes: first sums
/// `Σaᵢ²` to compute the magnitude, second divides each `aᵢ` by `mag`. Writes
/// the result into a fresh buffer (out-of-place semantics).
public struct NaiveNormalizeWorkload: BorrowingWorkload {
    public typealias Input = RawFloatNormalizeInput
    public typealias Output = [Float]

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .normalize, shape: .vector(n: n))
        return WorkloadID(
            op: .normalize, impl: .naive, implClass: .naive,
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
        var normSq: Float = 0
        for i in 0..<input.a.count {
            normSq += input.a[i] * input.a[i]
        }
        let mag = normSq.squareRoot()
        var out = [Float](repeating: 0, count: input.a.count)
        for i in 0..<input.a.count {
            out[i] = input.a[i] / mag
        }
        return out
    }
}
