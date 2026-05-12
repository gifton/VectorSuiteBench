import Testing
@testable import BenchKit

@Suite("SplitMix64")
struct SplitMix64Tests {
    @Test("Same seed produces same sequence")
    func deterministic() {
        var a = SplitMix64(seed: 0xDEAD_BEEF)
        var b = SplitMix64(seed: 0xDEAD_BEEF)
        for _ in 0..<100 {
            #expect(a.next() == b.next())
        }
    }

    @Test("Different seeds diverge")
    func divergent() {
        var a = SplitMix64(seed: 1)
        var b = SplitMix64(seed: 2)
        let xs = (0..<100).map { _ in a.next() }
        let ys = (0..<100).map { _ in b.next() }
        #expect(xs != ys)
    }

    @Test("nextFloat in [0, 1)")
    func unitInterval() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<1000 {
            let f = rng.nextFloat()
            #expect(f >= 0)
            #expect(f < 1)
        }
    }
}
