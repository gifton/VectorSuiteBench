import Foundation
import simd
import BenchKit

/// Apple `simd` framework Dot via `simd_dot` on SIMD8<Float> chunks. The
/// language-level SIMD path — distinct from VectorCore (which builds on top
/// of similar primitives but adds buffer management + dispatch).
///
/// For N not divisible by 8, the remainder is summed scalar.
public struct SimdDotWorkload: BorrowingWorkload {
    public typealias Input = RawFloatDotInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .simd, op: .dot, shape: .vector(n: n))
        return WorkloadID(
            op: .dot, impl: .simd, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { DotMetadata.bytesMoved(n: n) }
    public var flops: Int { DotMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle? {
        makeDotOracle(
            extractInput: { (input: RawFloatDotInput) -> (a: [Float], b: [Float])? in
                (input.a, input.b)
            }
        )
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        RawFloatDotInput(n: n, rng: &rng)
    }

    public func invoke(_ input: borrowing Input) -> Output {
        let count = input.a.count
        var acc = SIMD8<Float>(repeating: 0)
        let chunks = count / 8
        input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                let a = aPtr.baseAddress!
                let b = bPtr.baseAddress!
                for i in 0..<chunks {
                    let av = SIMD8<Float>(
                        a[i * 8 + 0], a[i * 8 + 1], a[i * 8 + 2], a[i * 8 + 3],
                        a[i * 8 + 4], a[i * 8 + 5], a[i * 8 + 6], a[i * 8 + 7]
                    )
                    let bv = SIMD8<Float>(
                        b[i * 8 + 0], b[i * 8 + 1], b[i * 8 + 2], b[i * 8 + 3],
                        b[i * 8 + 4], b[i * 8 + 5], b[i * 8 + 6], b[i * 8 + 7]
                    )
                    acc += av * bv
                }
            }
        }
        var sum = acc.sum()
        let tail = chunks * 8
        if tail < count {
            for i in tail..<count {
                sum += input.a[i] * input.b[i]
            }
        }
        return sum
    }
}
