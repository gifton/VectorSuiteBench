import Foundation
import simd
import BenchKit

/// Apple `simd` framework cosine similarity, composed in a single pass over
/// `simd_float4` chunks: dot, sum-of-squares-a, and sum-of-squares-b are
/// accumulated into three independent SIMD lanes; the terminal sqrt + divide
/// happens once after the horizontal reduction.
///
/// One-pass over the buffers (vs Accelerate's three separate calls) keeps
/// memory bandwidth at 2N floats and shows the SIMD fast-path off when the
/// compiler can hold all three accumulators in vector registers.
public struct SimdCosineWorkload: BorrowingWorkload {
    public typealias Input = RawFloatCosineInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .simd, op: .cosine, shape: .vector(n: n))
        return WorkloadID(
            op: .cosine, impl: .simd, implClass: .standard,
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
        let count = input.a.count
        let chunks = count / 4
        var dotAcc = simd_float4(repeating: 0)
        var aSqAcc = simd_float4(repeating: 0)
        var bSqAcc = simd_float4(repeating: 0)
        var dotTail: Float = 0
        var aSqTail: Float = 0
        var bSqTail: Float = 0
        input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                let aRaw = UnsafeRawPointer(aPtr.baseAddress!)
                let bRaw = UnsafeRawPointer(bPtr.baseAddress!)
                // Each iteration: 16B load × 2, 3 FMAs into independent
                // accumulators.
                for i in 0..<chunks {
                    let offset = i &* MemoryLayout<simd_float4>.stride
                    let av = aRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    let bv = bRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    dotAcc = simd_muladd(av, bv, dotAcc)
                    aSqAcc = simd_muladd(av, av, aSqAcc)
                    bSqAcc = simd_muladd(bv, bv, bSqAcc)
                }
                let tailStart = chunks &* 4
                let aTyped = aPtr.baseAddress!
                let bTyped = bPtr.baseAddress!
                for i in tailStart..<count {
                    let ai = aTyped[i]
                    let bi = bTyped[i]
                    dotTail += ai * bi
                    aSqTail += ai * ai
                    bSqTail += bi * bi
                }
            }
        }
        let dot = simd_reduce_add(dotAcc) + dotTail
        let aNormSq = simd_reduce_add(aSqAcc) + aSqTail
        let bNormSq = simd_reduce_add(bSqAcc) + bSqTail
        return dot / (aNormSq.squareRoot() * bNormSq.squareRoot())
    }
}
