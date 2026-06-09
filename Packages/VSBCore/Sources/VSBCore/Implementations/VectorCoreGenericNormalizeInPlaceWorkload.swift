import Foundation
import BenchKit
import VectorCore

/// `Vector<D>.normalizeFast()` — VectorCore's mutating reciprocal-
/// multiplication normalize, the only Vector flavor that ships a
/// genuine in-place mutation (Optimized + Dynamic flavors only expose
/// the Result-returning OOP `normalized()`; wrapping those would
/// measure an OOP + assign, not in-place — per Item 3a's locked
/// Q&A, those flavors are skipped here).
///
/// **Input shape.** Carries both `v: Vector<D>` (the working data, mutated
/// in place) and `raw: [Float]` (the pre-state mirror, captured at
/// construction). The oracle reads `raw` from the **pre-snapshot** in
/// `verifyMutating` — VectorCore's mutating normalize doesn't expose
/// the post-state outside of the Vector itself, and we need to compute
/// the Float64 Kahan-Neumaier reference from the pre-state buffer.
/// `raw` is **not** kept in sync after the mutating call; it's only
/// touched at construction (cheap) and at oracle compute time
/// (verification phase, outside the timed window).
///
/// **API choice (locked via Item 3a Q&A).** `normalizeFast()` is the
/// canonical mutating normalize on `Vector<D>`. Has an early-return
/// fast path that triggers when `|mag - 1.0| < 1e-6`; on uniformly
/// `[0.01, 1.01)` inputs the magnitude is far from 1 (e.g., dim 64
/// → magnitude ~4.6), so the fast path effectively never triggers
/// and doesn't bias the measurement.
///
/// **Output = Float** = post-mutation `v[0]`. Free to read (Vector<D>
/// subscript is O(1)); symmetric with `NaiveNormalizeInPlaceWorkload`
/// and `AccelerateNormalizeInPlaceWorkload` so the verification path
/// is identical across all three impls.
public struct VectorCoreGenericNormalizeInPlaceWorkload<D: StaticDimension>: MutatingWorkload
where D.Storage: VectorStorageOperations {
    public struct Input {
        public var v: Vector<D>
        /// Pre-state snapshot. Captured at construction; **not** mutated
        /// by `invoke`. Read by the oracle's `extractInput` closure at
        /// verification time so the Float64 reference matches the
        /// pre-state of `v`.
        public var raw: [Float]
    }
    public typealias Output = Float

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "generic", "inplace": "true"],
            impl: .vectorCore, op: .normalize, shape: .vector(n: D.value)
        )
        return WorkloadID(
            op: .normalize, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: D.value), params: params
        )
    }

    public var bytesMoved: Int { NormalizeMetadata.bytesMoved(n: D.value) }
    public var flops: Int { NormalizeMetadata.flops(n: D.value) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        // `extractInput` returns the pre-state mirror, which the
        // verifyMutating snapshot still holds verbatim (it COW-copies
        // the entire Input struct including `raw` before the mutating
        // invoke). Safe.
        makeNormalizeInPlaceFirstElementOracle(extractInput: { $0.raw })
    }

    public func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input] {
        let n = D.value
        var inputs: [Input] = []
        inputs.reserveCapacity(K)
        for _ in 0..<K {
            var aBuf = [Float](repeating: 0, count: n)
            for i in 0..<n {
                aBuf[i] = rng.nextFloat() + 0.01
            }
            inputs.append(Input(v: try! Vector<D>(aBuf), raw: aBuf))
        }
        return inputs
    }

    @inline(__always)
    public func invoke(_ input: inout Input) -> Output {
        input.v.normalizeFast()
        return input.v[0]
    }
}
