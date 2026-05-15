import Foundation
import BenchKit
import VectorCore

/// `Vector<D>.dotProduct(_:)` — VectorCore's compile-time-dimension generic
/// path. Static specialization across all dims VectorCore declares as
/// `StaticDimension`. Returns `+a·b`.
///
/// Of our 5-size set, this flavor is available at 64, 256, 512, 1536.
/// VectorCore does not ship a `Dim4096` static dimension; if you need
/// dot at N=4096 with the typed path, use `VectorCoreDynamicDotWorkload`.
public struct VectorCoreGenericDotWorkload<D: StaticDimension>: BorrowingWorkload {
    public struct Input {
        public var a: Vector<D>
        public var b: Vector<D>
        public var aRaw: [Float]
        public var bRaw: [Float]
    }
    public typealias Output = Float

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "generic", "api": "raw"],
            impl: .vectorCore, op: .dot, shape: .vector(n: D.value)
        )
        return WorkloadID(
            op: .dot, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: D.value), params: params
        )
    }

    public var bytesMoved: Int { DotMetadata.bytesMoved(n: D.value) }
    public var flops: Int { DotMetadata.flops(n: D.value) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeDotOracle(extractInput: { ($0.aRaw, $0.bRaw) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        let n = D.value
        var aBuf = [Float](repeating: 0, count: n)
        var bBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        return Input(
            a: try! Vector<D>(aBuf),
            b: try! Vector<D>(bBuf),
            aRaw: aBuf,
            bRaw: bBuf
        )
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.a.dotProduct(input.b)
    }
}
