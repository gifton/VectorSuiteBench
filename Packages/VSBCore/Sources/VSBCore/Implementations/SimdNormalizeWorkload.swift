import Foundation
import simd
import BenchKit

/// Apple `simd` framework out-of-place L2 normalize, composed in two
/// passes over `simd_float4` chunks: first accumulates `Σaᵢ²`, then
/// `simd_muladd`-multiplies each chunk by `1/mag` into an output buffer.
///
/// Single-pass alternatives that interleave the two would require knowing
/// the inverse-magnitude up front; computing it as we go is undefined for
/// the first elements. The two-pass form matches what
/// `simd.framework.normalize` does internally and is the canonical baseline.
public struct SimdNormalizeWorkload: BorrowingWorkload {
    public typealias Input = RawFloatNormalizeInput
    public typealias Output = [Float]

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .simd, op: .normalize, shape: .vector(n: n))
        return WorkloadID(
            op: .normalize, impl: .simd, implClass: .standard,
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
        let chunks = count / 4
        var out = [Float](repeating: 0, count: count)

        // Pass 1: ‖a‖² via SIMD accumulator.
        var sqAcc = simd_float4(repeating: 0)
        var sqTail: Float = 0
        input.a.withUnsafeBufferPointer { aPtr in
            let aRaw = UnsafeRawPointer(aPtr.baseAddress!)
            for i in 0..<chunks {
                let offset = i &* MemoryLayout<simd_float4>.stride
                let av = aRaw.load(fromByteOffset: offset, as: simd_float4.self)
                sqAcc = simd_muladd(av, av, sqAcc)
            }
            let tailStart = chunks &* 4
            let aTyped = aPtr.baseAddress!
            for i in tailStart..<count {
                sqTail += aTyped[i] * aTyped[i]
            }
        }
        let normSq = simd_reduce_add(sqAcc) + sqTail
        let invMag = 1.0 / normSq.squareRoot()
        let invMagVec = simd_float4(repeating: invMag)

        // Pass 2: out = a · invMag, vectorized.
        input.a.withUnsafeBufferPointer { aPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                let aRaw = UnsafeRawPointer(aPtr.baseAddress!)
                let outRaw = UnsafeMutableRawPointer(outPtr.baseAddress!)
                for i in 0..<chunks {
                    let offset = i &* MemoryLayout<simd_float4>.stride
                    let av = aRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    let scaled = av * invMagVec
                    outRaw.storeBytes(of: scaled, toByteOffset: offset, as: simd_float4.self)
                }
                let tailStart = chunks &* 4
                let aTyped = aPtr.baseAddress!
                let outTyped = outPtr.baseAddress!
                for i in tailStart..<count {
                    outTyped[i] = aTyped[i] * invMag
                }
            }
        }
        return out
    }
}
