import Foundation
import BenchKit
import VectorCore

/// `V.cosineSimilarity(to:)` — VectorCore's Optimized cosine fast path,
/// generic over the concrete Optimized type via `OptimizedCosineVectorType`.
/// Returns the similarity in `[-1, 1]` directly.
///
/// **Flavor coverage.** CosineFamily ships this Optimized path only:
/// `Vector<D>` and `DynamicVector` don't expose `cosineSimilarity(to:)`
/// (verified at Phase 2.2 Item 1b). The Generic and Dynamic flavors are
/// intentionally absent from the registry rather than synthesized via
/// `CosineDistance().distance(_,_)`, which returns `1 - similarity`
/// (different value space; would require a metric-aware oracle and
/// measures a different cost profile than the typed similarity API).
public struct VectorCoreOptimizedCosineWorkload<V: OptimizedCosineVectorType>: BorrowingWorkload {
    public struct Input {
        public var a: V
        public var b: V
        public var aRaw: [Float]
        public var bRaw: [Float]
    }
    public typealias Output = Float

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "optimized"],
            impl: .vectorCore, op: .cosine, shape: .vector(n: V.dim)
        )
        return WorkloadID(
            op: .cosine, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: V.dim), params: params
        )
    }

    public var bytesMoved: Int { CosineMetadata.bytesMoved(n: V.dim) }
    public var flops: Int { CosineMetadata.flops(n: V.dim) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeCosineOracle(extractInput: { ($0.aRaw, $0.bRaw) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        var aBuf = [Float](repeating: 0, count: V.dim)
        var bBuf = [Float](repeating: 0, count: V.dim)
        for i in 0..<V.dim {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        return Input(
            a: try! V(aBuf),
            b: try! V(bBuf),
            aRaw: aBuf,
            bRaw: bBuf
        )
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.a.cosineSimilarity(to: input.b)
    }
}
