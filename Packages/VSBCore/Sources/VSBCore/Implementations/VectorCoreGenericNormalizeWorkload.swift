import Foundation
import BenchKit
import VectorCore

/// `Vector<D>.normalizedFast()` — VectorCore's reciprocal-multiplication
/// normalize for the typed-static-dim path. Returns a fresh `Vector<D>`.
///
/// **API choice**: `normalizedFast()` is the most canonical Self-returning
/// normalize on `Vector<D>`. It has an early-return-if-already-unit fast
/// path that triggers when `abs(mag - 1.0) < 1e-6`; on uniformly-random
/// `[0, 1)` inputs of any of our 5 sizes, the magnitude is far from 1
/// (e.g., dim 64 → magnitude ~4.6), so the fast path effectively never
/// triggers and doesn't bias the measurement.
///
/// The `where D.Storage: VectorStorageOperations` constraint mirrors the
/// extension that declares `normalizedFast()`; all of {Dim64, Dim256,
/// Dim512, Dim1536} satisfy it (verified at compile time when the
/// registry adds these four cases).
public struct VectorCoreGenericNormalizeWorkload<D: StaticDimension>: BorrowingWorkload
where D.Storage: VectorStorageOperations {
    public struct Input {
        public var v: Vector<D>
        public var raw: [Float]
    }
    public typealias Output = Vector<D>

    public init() {}

    public var identifier: WorkloadID {
        let params = try! CanonicalParams(
            ["vectorflavor": "generic"],
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
        makeNormalizeOracle(
            extractInput: { $0.raw },
            extractOutput: { v in
                // Vector<D> conforms to Collection over Float; Array(v)
                // flattens to a fresh [Float]. Runs once per case at
                // verification, outside the timing window.
                Array(v)
            }
        )
    }

    public func makeInput(rng: inout SplitMix64) -> Input {
        let n = D.value
        var aBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
        }
        return Input(v: try! Vector<D>(aBuf), raw: aBuf)
    }

    @inline(__always)
    public func invoke(_ input: borrowing Input) -> Output {
        input.v.normalizedFast()
    }
}
