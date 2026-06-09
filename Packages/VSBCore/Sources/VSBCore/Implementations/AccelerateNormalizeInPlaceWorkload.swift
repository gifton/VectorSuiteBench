import Foundation
import Accelerate
import BenchKit

/// Apple Accelerate in-place L2 normalize. `cblas_snrm2` derives the L2
/// magnitude in one read pass; `vDSP_vsmul` then scales the same buffer
/// in place (source and destination pointers both bound to `input.a`'s
/// storage). Two Accelerate calls; both touch the buffer once each.
///
/// **Spec §9 baseline.** Phase 1 calls for `vDSP_*` in-place chain.
/// We use `cblas_snrm2` because it returns the norm directly as a
/// scalar (saving a redundant load); the alternative `vDSP_vnrm2`
/// writes through an in/out pointer with the same numerical behavior.
/// Either is acceptable spec-wise; `cblas_snrm2` is the tighter call.
///
/// **In-place is honest here.** Unlike a hypothetical
/// `vDSP_vsdiv` chain that would write into a fresh output buffer,
/// `vDSP_vsmul(src, ..., src_as_dst, ..., n)` mutates source bytes
/// directly — `Output` carries the post-mutation `input.a[0]` so the
/// runner observes the in-place write.
public struct AccelerateNormalizeInPlaceWorkload: MutatingWorkload {
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
            impl: .accelerate, op: .normalize, shape: .vector(n: n)
        )
        return WorkloadID(
            op: .normalize, impl: .accelerate, implClass: .standard,
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
        let count = input.a.count
        let lenI32 = Int32(count)
        var head: Float = 0
        input.a.withUnsafeMutableBufferPointer { aPtr in
            let norm = cblas_snrm2(lenI32, aPtr.baseAddress!, 1)
            var inv = norm > 0 ? 1.0 / norm : 0
            // Source == destination → genuine in-place scale.
            vDSP_vsmul(aPtr.baseAddress!, 1, &inv, aPtr.baseAddress!, 1, vDSP_Length(count))
            head = aPtr[0]
        }
        return head
    }
}
