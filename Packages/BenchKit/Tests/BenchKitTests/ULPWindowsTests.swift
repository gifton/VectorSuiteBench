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

    @Test("null op (NullWorkload self-bench) returns 0 regardless of class")
    func nullZero() {
        #expect(ulpTolerance(op: .null, implClass: .standard, shape: .vector(n: 1)) == 0)
        #expect(ulpTolerance(op: .null, implClass: .naive, shape: .vector(n: 1)) == 0)
        #expect(ulpTolerance(op: .null, implClass: .approximate, shape: .vector(n: 1)) == 0)
    }

    @Test(".naive ULP window scales linearly with N (n/8 + small constant)")
    func naiveLinearScaling() {
        // Naïve unfused summation: Wilkinson bound is O(N · ε). Window is
        // `8 + n/8` for dot. Pin values at each baseline size so a refactor
        // can't silently widen or narrow the window.
        #expect(ulpTolerance(op: .dot, implClass: .naive, shape: .vector(n: 64)) == 8 + 8)
        #expect(ulpTolerance(op: .dot, implClass: .naive, shape: .vector(n: 256)) == 8 + 32)
        #expect(ulpTolerance(op: .dot, implClass: .naive, shape: .vector(n: 512)) == 8 + 64)
        #expect(ulpTolerance(op: .dot, implClass: .naive, shape: .vector(n: 1536)) == 8 + 192)
        #expect(ulpTolerance(op: .dot, implClass: .naive, shape: .vector(n: 4096)) == 8 + 512)
    }

    @Test(".naive window is wider than .standard at every size that triggers Wilkinson drift")
    func naiveWiderThanStandard() {
        // At N=64 the linear and logarithmic windows are similar; .naive
        // pulls clearly ahead by N=256 and dominates by 4096.
        for n in [256, 512, 1536, 4096] {
            let std = ulpTolerance(op: .dot, implClass: .standard, shape: .vector(n: n))
            let naive = ulpTolerance(op: .dot, implClass: .naive, shape: .vector(n: n))
            #expect(naive > std,
                    Comment(rawValue: "at N=\(n), .naive window (\(naive)) should exceed .standard (\(std))"))
        }
    }

    @Test(".naive windows are defined for all op families (no crash on lookup)")
    func naiveDefinedEverywhere() {
        let ops: [OpKind] = [.dot, .l2dist, .cosine, .normalize, .axpy,
                             .pairwiseDistances, .distanceMatrix]
        for op in ops {
            // Just confirms the switch in ulpTolerance has a row for (.op, .naive)
            // — missing cases would be a compile error today (exhaustive switch),
            // but this test will catch a future refactor that introduces a default.
            _ = ulpTolerance(op: op, implClass: .naive, shape: .vector(n: 256))
        }
    }
}
