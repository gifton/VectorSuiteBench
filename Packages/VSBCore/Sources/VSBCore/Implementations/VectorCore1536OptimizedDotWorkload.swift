import Foundation
import BenchKit
import VectorCore

/// `Vector1536Optimized.dotProduct(_:)` — VectorCore's SIMD4-laid-out fused
/// fast path at dim 1536. Returns `+a·b` (raw kernel sign convention).
///
/// Sibling of `VectorCoreOptimizedDotWorkload` (which is hard-coded to 512).
/// VectorCore's Optimized layer only ships at 384/512/768/1536; 1536 is the
/// largest of those and the most interesting for embedding-vector workloads.
public struct VectorCore1536OptimizedDotWorkload: BorrowingWorkload {
    public struct Input {
        public var a: Vector1536Optimized
        public var b: Vector1536Optimized
        public var aRaw: [Float]
        public var bRaw: [Float]
    }
    public typealias Output = Float

    public static let dim: Int = 1536

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "optimized", "api": "raw"],
            impl: .vectorCore, op: .dot, shape: .vector(n: Self.dim)
        )
        return WorkloadID(
            op: .dot, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: Self.dim), params: params
        )
    }

    public var bytesMoved: Int { DotMetadata.bytesMoved(n: Self.dim) }
    public var flops: Int { DotMetadata.flops(n: Self.dim) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeDotOracle(extractInput: { ($0.aRaw, $0.bRaw) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        var aBuf = [Float](repeating: 0, count: Self.dim)
        var bBuf = [Float](repeating: 0, count: Self.dim)
        for i in 0..<Self.dim {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        return Input(
            a: try! Vector1536Optimized(aBuf),
            b: try! Vector1536Optimized(bBuf),
            aRaw: aBuf,
            bRaw: bBuf
        )
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.a.dotProduct(input.b)
    }
}
