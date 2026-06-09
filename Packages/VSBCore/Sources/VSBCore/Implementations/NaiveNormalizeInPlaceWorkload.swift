import Foundation
import BenchKit

/// Naïve Float32 left-to-right in-place L2 normalize. Two passes through
/// the same buffer: first sums `Σaᵢ²` to derive the magnitude, second
/// rewrites each `aᵢ ← aᵢ / mag`. Distinct from `NaiveNormalizeWorkload`
/// (OOP) because the second pass writes back into `input.a` rather than
/// allocating a fresh `out` buffer — the cache-friendly perf win is
/// precisely what we want to measure relative to OOP.
///
/// **Output.** Returns post-normalize `input.a[0]` (a single Float).
/// Returning the whole `[Float]` buffer would be COW-free for the
/// raw-buffer impls but would force an `Array(v)` allocation for
/// `VectorCoreGenericNormalizeInPlaceWorkload` — symmetric `Output
/// = Float` keeps comparison honest across all three impls. See
/// `NormalizeInPlaceShared.swift` for the full rationale.
public struct NaiveNormalizeInPlaceWorkload: MutatingWorkload {
    public typealias Input = RawFloatNormalizeIPInput
    public typealias Output = Float

    public let n: Int

    public init(n: Int) {
        precondition(n > 0, "vector dimension must be > 0")
        self.n = n
    }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["inplace": "true"],
            impl: .naive, op: .normalize, shape: .vector(n: n)
        )
        return WorkloadID(
            op: .normalize, impl: .naive, implClass: .naive,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { NormalizeMetadata.bytesMoved(n: n) }
    public var flops: Int { NormalizeMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeNormalizeInPlaceFirstElementOracle(extractInput: { $0.a })
    }

    public func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input] {
        var inputs: [Input] = []
        inputs.reserveCapacity(K)
        for _ in 0..<K {
            inputs.append(RawFloatNormalizeIPInput(n: n, rng: &rng))
        }
        return inputs
    }

    @inline(__always)
    public func invoke(_ input: inout Input) -> Output {
        var normSq: Float = 0
        for i in 0..<input.a.count {
            normSq += input.a[i] * input.a[i]
        }
        let mag = normSq.squareRoot()
        let inv: Float = mag > 0 ? 1 / mag : 0
        for i in 0..<input.a.count {
            input.a[i] *= inv
        }
        return input.a[0]
    }
}
