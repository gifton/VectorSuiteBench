import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit

@Suite("VSBCore Dot workloads")
struct DotWorkloadTests {
    @Test("Naive dot verifies and produces samples")
    func naive() async throws {
        let result = await run(VSBCoreRegistry.naiveDot512)
        try assertVerified(result, label: "naive")
    }

    @Test("Accelerate dot verifies and produces samples")
    func accelerate() async throws {
        let result = await run(VSBCoreRegistry.accelerateDot512)
        try assertVerified(result, label: "accelerate")
    }

    @Test("Apple simd dot verifies and produces samples")
    func appleSimd() async throws {
        let result = await run(VSBCoreRegistry.simdDot512)
        try assertVerified(result, label: "simd")
    }

    @Test("VectorCore optimized dot (raw, +a·b) verifies")
    func vectorCoreOptimized() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedDot512)
        try assertVerified(result, label: "vectorCore-optimized")
    }

    @Test("VectorCore metric dot (-a·b) verifies with negation-aware oracle")
    func vectorCoreMetric() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreMetricDot512)
        try assertVerified(result, label: "vectorCore-metric")
    }

    @Test("All registered Dot impls produce distinct WorkloadIDs")
    func distinctIDs() {
        let ids = VSBCoreRegistry.workloads.map(\.identifier.canonicalString)
        let set = Set(ids)
        #expect(set.count == ids.count, "found duplicate WorkloadIDs: \(ids)")
    }

    @Test("Naïve dot verifies at every baseline size")
    func naiveAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(NaiveDotWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "naïve dot at N=\(n) failed verification — likely a ULP-window mismatch")
            )
        }
    }

    @Test("Accelerate dot verifies at every baseline size")
    func accelerateAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(AccelerateDotWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "Accelerate dot at N=\(n) failed verification")
            )
        }
    }

    @Test("Apple simd dot verifies at every baseline size")
    func simdAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(SimdDotWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "simd dot at N=\(n) failed verification")
            )
        }
    }

    @Test("Raw kernel and metric variants disagree on sign")
    func signConvention() {
        // Both consume the same seeded input bytes; raw should be +x, metric -x.
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.vectorCoreOptimizedDot512.identifier))
        let rawInput = VSBCoreRegistry.vectorCoreOptimizedDot512.makeInput(rng: &rng)
        let raw = VSBCoreRegistry.vectorCoreOptimizedDot512.invoke(rawInput)

        var rng2 = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.vectorCoreMetricDot512.identifier))
        let metricInput = VSBCoreRegistry.vectorCoreMetricDot512.makeInput(rng: &rng2)
        let metric = VSBCoreRegistry.vectorCoreMetricDot512.invoke(metricInput)

        // Different WorkloadIDs => different seeds => not bit-equal inputs. The
        // important property is the *sign relationship* between the two APIs,
        // not exact equality.
        #expect(raw > 0, "raw a·b on uniform [0,1) inputs should be positive, got \(raw)")
        #expect(metric < 0, "metric -a·b on uniform [0,1) inputs should be negative, got \(metric)")
    }

    // MARK: - Helpers

    private func run<W: BorrowingWorkload>(_ workload: W) async -> CaseResult {
        let runner = Runner(
            runID: "vsbcore-dot-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 32, amortizedSamples: 8)
        )
        return await runner.run(workload)
    }

    private func assertVerified(_ result: CaseResult, label: String) throws {
        if case .verified(let maxUlp) = result.verification {
            // For dot of 512 uniform-random Float32 values, expected ULP
            // distance is typically <30 against a Kahan-Float64 reference;
            // the .standard window for dot at N=512 is 4 + 2*log2(512) = 22.
            // Some impls (notably naive left-to-right) may exceed this — in
            // which case verification will report .failed and this branch
            // won't run.
            #expect(maxUlp < 10_000, "\(label) ULP drift too large: \(maxUlp)")
        } else {
            Issue.record("\(label) failed verification: \(result.verification)")
        }
        let single = try #require(result.singleShot)
        #expect(single.count == 32)
        let amortized = try #require(result.amortized)
        #expect(amortized.iterationsPerBatch > 0)
        #expect((result.gflops ?? 0) > 0)
        #expect((result.bandwidthGBPerSec ?? 0) > 0)
    }
}
