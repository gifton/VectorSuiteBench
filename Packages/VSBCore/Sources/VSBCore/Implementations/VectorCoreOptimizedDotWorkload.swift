import Foundation
import BenchKit
import VectorCore

/// `Vector512Optimized.dotProduct(_:)` — VectorCore's SIMD4-laid-out fused
/// fast path. Returns `+a·b` (raw kernel sign convention).
public struct VectorCoreOptimizedDotWorkload: BorrowingWorkload {
    public struct Input {
        public var a: Vector512Optimized
        public var b: Vector512Optimized
        public var aRaw: [Float]     // for oracle
        public var bRaw: [Float]
    }
    public typealias Output = Float

    /// Fixed dimension — the optimized path is dim-specialized.
    public static let dim: Int = 512

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
            a: try! Vector512Optimized(aBuf),
            b: try! Vector512Optimized(bBuf),
            aRaw: aBuf,
            bRaw: bBuf
        )
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.a.dotProduct(input.b)
    }
}

/// `DotProductDistance.distance(_:_:)` — the **metric-form** API on
/// VectorCore. Returns `−a·b` for min-search ordering. Oracle is sign-aware
/// (negates the Float64 Kahan reference before comparing).
public struct VectorCoreMetricDotWorkload: BorrowingWorkload {
    public struct Input {
        public var a: Vector512Optimized
        public var b: Vector512Optimized
        public var aRaw: [Float]
        public var bRaw: [Float]
    }
    public typealias Output = Float

    public static let dim: Int = 512

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "optimized", "api": "metric"],
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
        makeDotOracle(
            extractInput: { ($0.aRaw, $0.bRaw) },
            expectedSignTransform: { -$0 }    // metric returns −a·b
        )
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        var aBuf = [Float](repeating: 0, count: Self.dim)
        var bBuf = [Float](repeating: 0, count: Self.dim)
        for i in 0..<Self.dim {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        return Input(
            a: try! Vector512Optimized(aBuf),
            b: try! Vector512Optimized(bBuf),
            aRaw: aBuf,
            bRaw: bBuf
        )
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        DotProductDistance().distance(input.a, input.b)
    }
}
