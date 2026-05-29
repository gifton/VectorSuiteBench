import Foundation
import BenchKit
import VectorCore

/// `V.normalizedUnchecked()` — VectorCore's Optimized normalize fast path
/// (bypasses the zero-vector check). Generic over the concrete Optimized
/// type via `OptimizedNormalizeVectorType`. Returns a fresh `V` —
/// out-of-place semantics.
///
/// Uniform `[0, 1)` inputs at any N ≥ 1 have magnitude bounded well above
/// zero with probability ≈ 1, so `normalizedUnchecked` is safe here. A
/// future `.adversarial(.zeros)` distribution would require switching to
/// the checked `normalized().get()` form.
public struct VectorCoreOptimizedNormalizeWorkload<V: OptimizedNormalizeVectorType>: BorrowingWorkload {
    public struct Input {
        public var v: V
        public var raw: [Float]
    }
    public typealias Output = V

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "optimized"],
            impl: .vectorCore, op: .normalize, shape: .vector(n: V.dim)
        )
        return WorkloadID(
            op: .normalize, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: V.dim), params: params
        )
    }

    public var bytesMoved: Int { NormalizeMetadata.bytesMoved(n: V.dim) }
    public var flops: Int { NormalizeMetadata.flops(n: V.dim) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeNormalizeOracle(
            extractInput: { $0.raw },
            extractOutput: { $0.toArray() }
        )
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        var aBuf = [Float](repeating: 0, count: V.dim)
        for i in 0..<V.dim {
            aBuf[i] = rng.nextFloat()
        }
        return Input(v: try! V(aBuf), raw: aBuf)
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.v.normalizedUnchecked()
    }
}
