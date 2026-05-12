import Foundation

/// Deterministic 64-bit PRNG. Same algorithm as VectorCore's bench harness so
/// cross-validation between published VectorCore numbers and ours is direct.
///
/// Reference: Vigna 2015, "Further scramblings of Marsaglia's xorshift
/// generators." Constants below are the standard splitmix64 increment / mix
/// pair.
public struct SplitMix64: Sendable {
    /// Exposed for SeedTable's hash mixing. Direct manipulation is intentional;
    /// the contract is "mix state, then call next()".
    public var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    @inlinable
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }

    /// Float32 in [0, 1).
    @inlinable
    public mutating func nextFloat() -> Float {
        // 24-bit mantissa extraction; divide by 2^24.
        Float(next() &>> 40) / Float(1 &<< 24)
    }

    /// Standard normal via Box-Muller. Allocates a paired-cache lazily.
    public mutating func nextNormal() -> Float {
        if let cached = self.boxMullerCache {
            self.boxMullerCache = nil
            return cached
        }
        var u1: Float = 0
        repeat { u1 = nextFloat() } while u1 < .leastNormalMagnitude
        let u2 = nextFloat()
        let r = (-2.0 * Foundation.log(Double(u1))).squareRoot()
        let theta = 2.0 * .pi * Double(u2)
        let z0 = Float(r * Foundation.cos(theta))
        let z1 = Float(r * Foundation.sin(theta))
        self.boxMullerCache = z1
        return z0
    }

    @usableFromInline
    var boxMullerCache: Float? = nil
}
