import Foundation
@testable import BenchKit

/// Minimal `BorrowingWorkload` used to smoke-test the Runner end-to-end.
/// Naïve Float32 dot of two N-element arrays, with a Float64 Kahan-Neumaier
/// reference oracle.
struct DotSmokeWorkload: BorrowingWorkload {
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

    func makeInput(rng: inout SplitMix64) -> Input {
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            a[i] = rng.nextFloat()
            b[i] = rng.nextFloat()
        }
        return Input(a: a, b: b)
    }

    func invoke(_ input: borrowing Input) -> Output {
        var sum: Float = 0
        for i in 0..<input.a.count {
            sum += input.a[i] * input.b[i]
        }
        return sum
    }
}

func floatULPDistance(_ a: Float, _ b: Float) -> UInt32 {
    let ai = a.bitPattern
    let bi = b.bitPattern
    let aBiased = ai & 0x8000_0000 != 0 ? 0x8000_0000 &- ai : ai | 0x8000_0000
    let bBiased = bi & 0x8000_0000 != 0 ? 0x8000_0000 &- bi : bi | 0x8000_0000
    return aBiased > bBiased ? aBiased - bBiased : bBiased - aBiased
}
