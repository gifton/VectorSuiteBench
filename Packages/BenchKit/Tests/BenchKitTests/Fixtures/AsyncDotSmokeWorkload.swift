import Foundation
@testable import BenchKit

/// Smoke test for the AsyncRunner — wraps a naïve dot in async to verify the
/// async path measures correctly without deadlock/hang.
struct AsyncDotSmokeWorkload: AsyncWorkload {
    struct Input {
        var a: [Float]
        var b: [Float]
    }
    typealias Output = Float

    let n: Int

    var identifier: WorkloadID {
        let params = try! CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: n))
        return WorkloadID(
            op: .dot, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: n), params: params
        )
    }

    var bytesMoved: Int { 2 * n * MemoryLayout<Float>.size }
    var flops: Int { 2 * n }
    var inputDistribution: InputDistribution { .uniform }

    var referenceOracle: ReferenceOracle? {
        ReferenceOracle(
            compute: { input in
                guard let typed = input as? Input else { return .scalar(.nan) }
                var sum = 0.0
                var c = 0.0
                for i in 0..<typed.a.count {
                    let y = Double(typed.a[i]) * Double(typed.b[i]) - c
                    let t = sum + y
                    c = (t - sum) - y
                    sum = t
                }
                return .scalar(sum)
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

    func makeInput(rng: inout SplitMix64) async -> Input {
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            a[i] = rng.nextFloat()
            b[i] = rng.nextFloat()
        }
        return Input(a: a, b: b)
    }

    func invoke(_ input: inout Input) async throws -> Output {
        var sum: Float = 0
        for i in 0..<input.a.count {
            sum += input.a[i] * input.b[i]
        }
        return sum
    }
}
