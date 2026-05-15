import Foundation
import BenchKit

/// Float64 Kahan-Neumaier compensated summation for dot product. Used by
/// every Dot workload's `ReferenceOracle.compute` closure.
///
/// **Sign convention**: returns `+a·b` (mathematical convention). Workloads
/// that compare against a metric returning `−a·b` (e.g., `DotProductDistance`)
/// negate via the `expectedSignTransform` parameter of `makeDotOracle`.
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

/// Typed scalar-oracle factory for dot-product workloads. Builds a
/// `ReferenceOracle<Input, Float>` that:
/// 1. Projects the candidate's `Input` down to `(a: [Float], b: [Float])`
///    via the supplied `extractInput` (still useful when `Input` is a struct
///    wrapping typed vectors plus raw buffers, e.g.,
///    `VectorCoreOptimizedDotWorkload.Input`).
/// 2. Computes the Float64 Kahan dot.
/// 3. Applies `expectedSignTransform` (identity for `+a·b` candidates,
///    negation for `DotProductDistance`-style metric candidates).
/// 4. ULP-compares the candidate (Float32) against the transformed reference
///    rounded to Float.
///
/// `Input` is the workload's typed `Input`. `Output` is always `Float`. No
/// `Any` casts — the typed Workload protocol guarantees the oracle and the
/// candidate agree on `Input`/`Output` at compile time.
public func makeDotOracle<Input>(
    extractInput: @Sendable @escaping (Input) -> (a: [Float], b: [Float]),
    expectedSignTransform: @Sendable @escaping (Double) -> Double = { $0 }
) -> ReferenceOracle<Input, Float> {
    ReferenceOracle(
        compute: { input in
            let unwrapped = extractInput(input)
            let raw = kahanFloat64Dot(unwrapped.a, unwrapped.b)
            return .scalar(expectedSignTransform(raw))
        },
        compare: { candidate, reference, window in
            guard case .scalar(let refD) = reference else {
                // ReferenceValue case mismatch — the workload constructed
                // the oracle with the wrong shape. This is a programmer
                // error caught at first run.
                return .failed(maxUlpObserved: .max, window: window, sampleIndex: 0)
            }
            let refF = Float(refD)
            let diff = floatULPDistance(candidate, refF)
            if diff <= window {
                return .verified(maxUlpObserved: diff)
            } else {
                return .failed(maxUlpObserved: diff, window: window, sampleIndex: 0)
            }
        }
    )
}
