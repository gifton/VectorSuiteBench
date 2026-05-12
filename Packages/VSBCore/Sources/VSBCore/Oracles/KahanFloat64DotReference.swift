import Foundation
import BenchKit

/// Float64 Kahan-Neumaier compensated summation for dot product. Used by
/// every Dot workload's `ReferenceOracle.compute` closure.
///
/// **Sign convention**: returns `+a·b` (mathematical convention). Workloads
/// that compare against a metric returning `−a·b` (e.g., `DotProductDistance`)
/// negate before comparing.
public func kahanFloat64Dot(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count, "dot: vector lengths differ")
    var sum = 0.0
    var c = 0.0
    for i in 0..<a.count {
        let y = Double(a[i]) * Double(b[i]) - c
        let t = sum + y
        c = (t - sum) - y
        sum = t
    }
    return sum
}

/// Float32 ULP distance between two finite values. Used by oracle compare
/// closures to score candidate vs reference.
public func floatULPDistance(_ a: Float, _ b: Float) -> UInt32 {
    let ai = a.bitPattern
    let bi = b.bitPattern
    let aBiased = ai & 0x8000_0000 != 0 ? 0x8000_0000 &- ai : ai | 0x8000_0000
    let bBiased = bi & 0x8000_0000 != 0 ? 0x8000_0000 &- bi : bi | 0x8000_0000
    return aBiased > bBiased ? aBiased - bBiased : bBiased - aBiased
}

/// Standard scalar-oracle factory. Builds a `ReferenceOracle` that:
/// 1. Computes the Float64 Kahan dot of the input's `a` and `b` Float buffers.
/// 2. Applies the supplied `expectedSignTransform` (identity for +a·b
///    candidates, negation for metric-form candidates).
/// 3. ULP-compares the candidate (Float32) against the transformed reference
///    (rounded to Float).
///
/// Workloads supply `extractInput` to project their concrete `Input` type
/// down to `(a: [Float], b: [Float])` for the oracle.
///
/// **Type-mismatch failure mode is distinct.** If a candidate or reference
/// can't be unwrapped to the expected concrete type, the oracle returns
/// `.unverifiable("oracle type mismatch: ...")` rather than `.failed` —
/// which would be indistinguishable from a real numeric divergence by ~4
/// billion ULPs. (Full type-safety via a generic ReferenceOracle<Input,
/// Output> is the rigorous fix; see Phase-2 deferred work.)
public func makeDotOracle<Input>(
    extractInput: @Sendable @escaping (Input) -> (a: [Float], b: [Float])?,
    expectedSignTransform: @Sendable @escaping (Double) -> Double = { $0 }
) -> ReferenceOracle {
    ReferenceOracle(
        compute: { input in
            guard let typed = input as? Input,
                  let unwrapped = extractInput(typed) else {
                // Sentinel: a quiet NaN here is detected by the compare side
                // as a type mismatch (reference value is NaN AND we have no
                // candidate-side signal yet). Compare-side returns
                // .unverifiable rather than .failed.
                return .scalar(.nan)
            }
            let raw = kahanFloat64Dot(unwrapped.a, unwrapped.b)
            return .scalar(expectedSignTransform(raw))
        },
        compare: { candidate, reference, window in
            guard let candidateF = candidate as? Float else {
                return .unverifiable(reason: "oracle type mismatch: candidate is not Float")
            }
            guard case .scalar(let refD) = reference else {
                return .unverifiable(reason: "oracle type mismatch: reference is not .scalar")
            }
            if refD.isNaN {
                return .unverifiable(reason: "oracle type mismatch: reference returned NaN (extractInput probably failed)")
            }
            let refF = Float(refD)
            let diff = floatULPDistance(candidateF, refF)
            if diff <= window {
                return .verified(maxUlpObserved: diff)
            } else {
                return .failed(maxUlpObserved: diff, window: window, sampleIndex: 0)
            }
        }
    )
}
