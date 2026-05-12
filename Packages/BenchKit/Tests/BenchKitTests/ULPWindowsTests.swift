import Testing
@testable import BenchKit

@Suite("ULP windows")
struct ULPWindowsTests {
    @Test("ULP grows with N (dot standard)")
    func ulpGrowsWithN() {
        let small = ulpTolerance(op: .dot, implClass: .standard, shape: .vector(n: 64))
        let big = ulpTolerance(op: .dot, implClass: .standard, shape: .vector(n: 4096))
        #expect(big > small)
    }

    @Test("approximate has wider window than standard")
    func approxWider() {
        let std = ulpTolerance(op: .dot, implClass: .standard, shape: .vector(n: 512))
        let approx = ulpTolerance(op: .dot, implClass: .approximate, shape: .vector(n: 512))
        #expect(approx > std)
    }

    @Test("normalize approximate has very wide window (rsqrt approx)")
    func normalizeApproxIsHarsh() {
        let std = ulpTolerance(op: .normalize, implClass: .standard, shape: .vector(n: 512))
        let approx = ulpTolerance(op: .normalize, implClass: .approximate, shape: .vector(n: 512))
        #expect(approx >= 1024)
        #expect(approx > std * 10)
    }

    @Test("topK is set-based, returns 0")
    func topKZero() {
        #expect(ulpTolerance(op: .topK, implClass: .standard, shape: .vector(n: 1024)) == 0)
        #expect(ulpTolerance(op: .topK, implClass: .approximate, shape: .vector(n: 1024)) == 0)
    }
}
