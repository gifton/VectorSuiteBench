import Testing
@testable import BenchKit

@Suite("LatencyDistribution")
struct LatencyDistributionTests {
    @Test("Percentiles on a known distribution")
    func percentiles() {
        let samples: [UInt64] = Array(1...100).map(UInt64.init)
        let dist = LatencyDistribution(samples: samples)
        #expect(dist.min == 1)
        #expect(dist.max == 100)
        #expect(dist.p50 == 50)
        #expect(dist.p99 == 99)
    }

    @Test("Empty distribution returns nils")
    func emptyDist() {
        let dist = LatencyDistribution(samples: [])
        #expect(dist.isEmpty)
        #expect(dist.p50 == nil)
        #expect(dist.p99 == nil)
        #expect(dist.min == nil)
        #expect(dist.max == nil)
    }

    @Test("Bimodal detection on cleanly bimodal input")
    func bimodal() {
        // 50 samples around 100 ns, 50 samples around 500 ns.
        let samples = Array(repeating: UInt64(100), count: 50) + Array(repeating: UInt64(500), count: 50)
        let dist = LatencyDistribution(samples: samples)
        #expect(dist.looksBimodal == true)
    }

    @Test("Unimodal is not flagged bimodal")
    func unimodal() {
        let samples = (1...100).map { _ in UInt64(100) }
        let dist = LatencyDistribution(samples: samples)
        #expect(dist.looksBimodal == false)
    }

    @Test("Storage is always sorted")
    func sorted() {
        let dist = LatencyDistribution(samples: [5, 1, 3, 2, 4])
        #expect(dist.samples == [1, 2, 3, 4, 5])
    }
}
