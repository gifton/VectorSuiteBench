import Foundation
import simd
import BenchKit

/// Apple `simd` framework squared L2 distance via `simd_distance_squared`
/// over `simd_float4` chunks. Walks the input buffers in 16-byte loads,
/// computes the per-chunk squared distance via SIMD, accumulates a vector
/// sum, then horizontally reduces.
///
/// For N not divisible by 4, the remainder is summed scalar via raw
/// pointers (skipping Swift's bounds-checked subscript).
public struct SimdL2DistWorkload: BorrowingWorkload {
    public typealias Input = RawFloatL2Input
    public typealias Output = Float

    public let n: Int

    public init(n: Int) { self.n = n }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .simd, op: .l2dist, shape: .vector(n: n))
        return WorkloadID(
            op: .l2dist, impl: .simd, implClass: .standard,
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
        let count = input.a.count
        let chunks = count / 4
        var acc = simd_float4(repeating: 0)
        var tailSum: Float = 0
        input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                let aRaw = UnsafeRawPointer(aPtr.baseAddress!)
                let bRaw = UnsafeRawPointer(bPtr.baseAddress!)
                // Each iteration: 16B load × 2, sub, square (mul self),
                // add to accumulator.
                for i in 0..<chunks {
                    let offset = i &* MemoryLayout<simd_float4>.stride
                    let av = aRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    let bv = bRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    let d = av - bv
                    acc = simd_muladd(d, d, acc)
                }
                // Tail (0..3 elements) via raw pointers — no bounds-check overhead.
                let tailStart = chunks &* 4
                let aTyped = aPtr.baseAddress!
                let bTyped = bPtr.baseAddress!
                for i in tailStart..<count {
                    let d = aTyped[i] - bTyped[i]
                    tailSum += d * d
                }
            }
        }
        return simd_reduce_add(acc) + tailSum
    }
}
