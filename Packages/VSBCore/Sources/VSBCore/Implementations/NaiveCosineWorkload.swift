import Foundation
import BenchKit

/// Naïve Float32 left-to-right cosine similarity baseline. Single-pass loop
/// accumulating three independent reductions (dot, ‖a‖², ‖b‖²) before the
/// terminal sqrt + divide.
///
/// Establishes the performance floor for the cosine row; the three-in-one
/// pass is intentional because that's what an unoptimized "for i in 0..<n"
/// implementation would look like — separating into three independent
/// loops would have better cache behavior at the cost of three memory
/// passes, a different naïve and out of scope here.
public struct NaiveCosineWorkload: BorrowingWorkload {
    public typealias Input = RawFloatCosineInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .cosine, shape: .vector(n: n))
        return WorkloadID(
            op: .cosine, impl: .naive, implClass: .naive,
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
        var dot: Float = 0
        var aNormSq: Float = 0
        var bNormSq: Float = 0
        for i in 0..<input.a.count {
            let ai = input.a[i]
            let bi = input.b[i]
            dot += ai * bi
            aNormSq += ai * ai
            bNormSq += bi * bi
        }
        return dot / (aNormSq.squareRoot() * bNormSq.squareRoot())
    }
}
