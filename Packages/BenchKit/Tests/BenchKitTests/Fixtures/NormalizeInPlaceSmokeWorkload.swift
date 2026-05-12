import Foundation
@testable import BenchKit

/// Naïve in-place L2 normalize. Used to exercise the MutatingWorkload path
/// — re-using one input across iterations would drift, so the runner must
/// rotate through K fresh inputs in Amortized mode.
struct NormalizeInPlaceSmokeWorkload: MutatingWorkload {
    struct Input {
        var v: [Float]
    }
    typealias Output = Float    // returns the original L2 norm for verification

    let n: Int

    var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .normalize, shape: .vector(n: n))
        return WorkloadID(
            op: .normalize, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    var bytesMoved: Int { 2 * n * MemoryLayout<Float>.size }   // read N + write N
    var flops: Int { 3 * n }                                   // n muls + n adds + n divs (approx)
    var inputDistribution: InputDistribution { .uniform }

    var referenceOracle: ReferenceOracle? {
        ReferenceOracle(
            compute: { input in
                guard let typed = input as? Input else { return .scalar(.nan) }
                var sumSq = 0.0
                var c = 0.0
                for x in typed.v {
                    let y = Double(x) * Double(x) - c
                    let t = sumSq + y
                    c = (t - sumSq) - y
                    sumSq = t
                }
                return .scalar(sumSq.squareRoot())
            },
            compare: { candidate, reference, window in
                guard let candidateF = candidate as? Float,
                      case .scalar(let refD) = reference else {
                    return .failed(maxUlpObserved: .max, window: window, sampleIndex: 0)
                }
                let diff = floatULPDistance(candidateF, Float(refD))
                if diff <= window {
                    return .verified(maxUlpObserved: diff)
                } else {
                    return .failed(maxUlpObserved: diff, window: window, sampleIndex: 0)
                }
            }
        )
    }

    func makeInputs(count K: Int, rng: inout SplitMix64) -> [Input] {
        var inputs: [Input] = []
        inputs.reserveCapacity(K)
        for _ in 0..<K {
            var v = [Float](repeating: 0, count: n)
            for i in 0..<n { v[i] = rng.nextFloat() + 0.01 }  // avoid all-zero
            inputs.append(Input(v: v))
        }
        return inputs
    }

    func invoke(_ input: inout Input) -> Output {
        var sumSq: Float = 0
        for x in input.v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        let inv = norm > 0 ? 1 / norm : 0
        for i in 0..<input.v.count { input.v[i] *= inv }
        return norm
    }
}
