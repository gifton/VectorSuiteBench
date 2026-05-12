import Foundation
import BenchKit

/// Shared input type for non-VectorCore Dot implementations (naïve,
/// Accelerate, simd). Two N-element Float buffers, deterministic per
/// `WorkloadID` via the runner's `SeedTable`.
public struct RawFloatDotInput {
    public var a: [Float]
    public var b: [Float]

    public init(n: Int, rng: inout SplitMix64) {
        var aBuf = [Float](repeating: 0, count: n)
        var bBuf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            aBuf[i] = rng.nextFloat()
            bBuf[i] = rng.nextFloat()
        }
        self.a = aBuf
        self.b = bBuf
    }
}

/// Shared metadata helpers for raw Dot workloads (Input == RawFloatDotInput,
/// Output == Float, `+a·b` sign convention).
public enum DotMetadata {
    public static func bytesMoved(n: Int) -> Int { 2 * n * MemoryLayout<Float>.size }
    public static func flops(n: Int) -> Int { 2 * n }   // n muls + n adds
}
