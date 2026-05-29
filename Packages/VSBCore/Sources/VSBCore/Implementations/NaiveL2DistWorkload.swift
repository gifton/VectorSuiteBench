import Foundation
import BenchKit

/// Naïve Float32 left-to-right squared L2 distance baseline. Establishes the
/// performance floor for the L2 row: `Σ(aᵢ - bᵢ)²` accumulated scalar.
public struct NaiveL2DistWorkload: BorrowingWorkload {
    public typealias Input = RawFloatL2Input
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .l2dist, shape: .vector(n: n))
        // .naive (not .standard) — unfused left-to-right summation has
        // O(N · ε) drift, not O(log₂N · ε); ULP window widens accordingly
        // so the baseline doesn't false-fail at large N.
        return WorkloadID(
            op: .l2dist, impl: .naive, implClass: .naive,
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
        var sum: Float = 0
        for i in 0..<input.a.count {
            let d = input.a[i] - input.b[i]
            sum += d * d
        }
        return sum
    }
}
