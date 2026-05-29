import Foundation
import BenchKit
import VectorCore

/// `V.euclideanDistanceSquared(to:)` — VectorCore's Optimized squared-L2
/// fast path, generic over the concrete Optimized type via
/// `OptimizedL2VectorType`. Returns `Σ(aᵢ - bᵢ)²` directly (no sqrt).
///
/// **Flavor coverage.** L2DistanceFamily ships this Optimized path only:
/// `Vector<D>.euclideanDistanceSquared(to:)` and
/// `DynamicVector.euclideanDistanceSquared(to:)` do NOT exist on
/// VectorCore (verified during Phase 2.2 Item 1a). The Generic and
/// Dynamic L2 flavors are intentionally absent from the registry rather
/// than synthesized via `EuclideanDistance().distance(_,_).squared`,
/// which would measure sqrt + square overhead a real user doesn't pay
/// when targeting the typed Optimized path.
public struct VectorCoreOptimizedL2DistWorkload<V: OptimizedL2VectorType>: BorrowingWorkload {
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
            impl: .vectorCore, op: .l2dist, shape: .vector(n: V.dim)
        )
        return WorkloadID(
            op: .l2dist, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: V.dim), params: params
        )
    }

    public var bytesMoved: Int { L2DistanceMetadata.bytesMoved(n: V.dim) }
    public var flops: Int { L2DistanceMetadata.flops(n: V.dim) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeL2SquaredOracle(extractInput: { ($0.aRaw, $0.bRaw) })
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
        input.a.euclideanDistanceSquared(to: input.b)
    }
}
