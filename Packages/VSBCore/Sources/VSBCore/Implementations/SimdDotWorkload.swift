import Foundation
import simd
import BenchKit

/// Apple `simd` framework Dot baseline. Walks the input buffers in
/// `simd_float4` chunks via `UnsafeRawPointer.load(fromByteOffset:as:)` (a
/// single 16-byte load per chunk, not eight scalar loads constructing the
/// vector), accumulates via the framework's `simd_muladd`, and finishes
/// with a horizontal `reduce_add`.
///
/// For N not divisible by 4, the remainder is summed scalar via raw
/// pointers (skipping Swift's bounds-checked subscript).
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
        let chunks = count / 4
        var acc = simd_float4(repeating: 0)
        var tailSum: Float = 0
        input.a.withUnsafeBufferPointer { aPtr in
            input.b.withUnsafeBufferPointer { bPtr in
                let aRaw = UnsafeRawPointer(aPtr.baseAddress!)
                let bRaw = UnsafeRawPointer(bPtr.baseAddress!)
                // Each iteration: one 16B aligned load per buffer, one FMA.
                for i in 0..<chunks {
                    let offset = i &* MemoryLayout<simd_float4>.stride
                    let av = aRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    let bv = bRaw.load(fromByteOffset: offset, as: simd_float4.self)
                    acc = simd_muladd(av, bv, acc)
                }
                // Tail (0..3 elements) via raw pointers — no bounds-check overhead.
                let tailStart = chunks &* 4
                let aTyped = aPtr.baseAddress!
                let bTyped = bPtr.baseAddress!
                for i in tailStart..<count {
                    tailSum += aTyped[i] * bTyped[i]
                }
            }
        }
        return simd_reduce_add(acc) + tailSum
    }
}
