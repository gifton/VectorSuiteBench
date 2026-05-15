import Foundation
import BenchKit
import VectorCore

/// `DynamicVector(dimension:).dotProduct(_:)` — VectorCore's runtime-
/// dimension heap-backed path. Available at any N. Returns `+a·b`.
///
/// This flavor is the one to use when you need typed VectorCore semantics
/// at a dimension VectorCore doesn't ship as `Dim<N>` static type — e.g.,
/// N=4096 in our size set, where `Vector<Dim4096>` does not exist.
public struct VectorCoreDynamicDotWorkload: BorrowingWorkload {
    public struct Input {
        public var a: DynamicVector
        public var b: DynamicVector
        public var aRaw: [Float]
        public var bRaw: [Float]
    }
    public typealias Output = Float

    public let n: Int

    public init(n: Int) {
        precondition(n > 0, "DynamicVector dimension must be > 0")
        self.n = n
    }

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "dynamic", "api": "raw"],
            impl: .vectorCore, op: .dot, shape: .vector(n: n)
        )
        return WorkloadID(
            op: .dot, impl: .vectorCore, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    public var bytesMoved: Int { DotMetadata.bytesMoved(n: n) }
    public var flops: Int { DotMetadata.flops(n: n) }
    public var inputDistribution: InputDistribution { .uniform }

    public var referenceOracle: ReferenceOracle<Input, Output>? {
        makeDotOracle(extractInput: { ($0.aRaw, $0.bRaw) })
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        var aBuf = [Float](repeating: 0, count: n)
        var bBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        return Input(
            a: DynamicVector(aBuf),
            b: DynamicVector(bBuf),
            aRaw: aBuf,
            bRaw: bBuf
        )
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.a.dotProduct(input.b)
    }
}
