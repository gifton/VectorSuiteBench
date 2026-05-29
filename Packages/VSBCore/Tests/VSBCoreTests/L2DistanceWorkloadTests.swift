import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit
import VectorCore

/// Phase 2.2 Item 1a — `L2DistanceFamily` correctness coverage.
///
/// Mirrors `DotWorkloadTests` but for squared L2 distance. Each impl
/// (`NaiveL2DistWorkload`, `AccelerateL2DistWorkload`, `SimdL2DistWorkload`,
/// `VectorCoreOptimizedL2DistWorkload<V>`) verifies against the Item 0d
/// oracle `kahanFloat64L2Squared`. The Generic and Dynamic VectorCore
/// flavors are intentionally absent from the registry (see
/// `L2DistanceFamily` doc); this test file does not exercise them.
@Suite("VSBCore L2-squared workloads")
struct L2DistanceWorkloadTests {

    // MARK: - Per-impl smokes at dim 512

    @Test("Naive L2 verifies and produces samples")
    func naive() async throws {
        let result = await run(VSBCoreRegistry.naiveL2Dist512)
        try assertVerified(result, label: "naive")
    }

    @Test("Accelerate L2 (vDSP_distancesq) verifies and produces samples")
    func accelerate() async throws {
        let result = await run(VSBCoreRegistry.accelerateL2Dist512)
        try assertVerified(result, label: "accelerate")
    }

    @Test("Apple simd L2 (simd_float4 muladd) verifies and produces samples")
    func appleSimd() async throws {
        let result = await run(VSBCoreRegistry.simdL2Dist512)
        try assertVerified(result, label: "simd")
    }

    @Test("VectorCore optimized L2 at dim 512 verifies")
    func vectorCoreOptimized512() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedL2Dist512)
        try assertVerified(result, label: "vectorCore-optimized-512")
    }

    @Test("VectorCore optimized L2 at dim 1536 verifies")
    func vectorCoreOptimized1536() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedL2Dist1536)
        try assertVerified(result, label: "vectorCore-optimized-1536")
    }

    // MARK: - Baseline size sweeps

    @Test("Naïve L2 verifies at every baseline size")
    func naiveAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(NaiveL2DistWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "naïve L2 at N=\(n) failed verification — likely a ULP-window mismatch")
            )
        }
    }

    @Test("Accelerate L2 verifies at every baseline size")
    func accelerateAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(AccelerateL2DistWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "Accelerate L2 at N=\(n) failed verification")
            )
        }
    }

    @Test("Apple simd L2 verifies at every baseline size")
    func simdAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(SimdL2DistWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "simd L2 at N=\(n) failed verification")
            )
        }
    }

    // MARK: - Registry shape

    @Test("L2DistanceFamily contributes 17 L2 cases")
    func l2CaseCount() {
        let l2Cases = VSBCoreRegistry.workloads.filter { $0.identifier.op == .l2dist }
        #expect(l2Cases.count == 17, Comment(rawValue: "expected 17 l2dist cases; got \(l2Cases.count)"))
    }

    @Test("All registered workloads (dot + l2dist) produce distinct WorkloadIDs")
    func distinctIDsAcrossFamilies() {
        let ids = VSBCoreRegistry.workloads.map(\.identifier.canonicalString)
        let set = Set(ids)
        #expect(set.count == ids.count, Comment(rawValue: "duplicate IDs across families: \(ids)"))
    }

    // MARK: - Mathematical invariants

    @Test("L2² of identical vectors is 0 (Naïve)")
    func identicalVectorsZeroNaive() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.naiveL2Dist512.identifier))
        var input = VSBCoreRegistry.naiveL2Dist512.makeInput(rng: &rng)
        input.b = input.a   // alias so b == a element-wise
        #expect(VSBCoreRegistry.naiveL2Dist512.invoke(input) == 0)
    }

    @Test("L2² is symmetric: a→b == b→a (Accelerate)")
    func symmetricAccelerate() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.accelerateL2Dist512.identifier))
        let input = VSBCoreRegistry.accelerateL2Dist512.makeInput(rng: &rng)
        let ab = VSBCoreRegistry.accelerateL2Dist512.invoke(input)
        let ba = VSBCoreRegistry.accelerateL2Dist512.invoke(RawFloatL2Input.swapped(input))
        #expect(ab == ba, Comment(rawValue: "a→b=\(ab) ≠ b→a=\(ba); vDSP_distancesq should be symmetric"))
    }

    // MARK: - Helpers

    private func run<W: BorrowingWorkload>(_ workload: W) async -> CaseResult {
        let runner = Runner(
            runID: "vsbcore-l2-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 32, amortizedSamples: 8)
        )
        return await runner.run(workload)
    }

    private func assertVerified(_ result: CaseResult, label: String) throws {
        if case .verified(let maxUlp) = result.verification {
            // For L2² of 512 uniform-random Float32 values, expected ULP
            // distance is typically <100 against a Kahan-Float64 reference;
            // the .standard window for l2dist at N=512 is 8 + 4·log2(512)
            // = 44. Some impls may exceed — in which case .failed is
            // recorded and this branch doesn't run.
            #expect(maxUlp < 50_000, Comment(rawValue: "\(label) ULP drift too large: \(maxUlp)"))
        } else {
            Issue.record(Comment(rawValue: "\(label) failed verification: \(result.verification)"))
        }
        let single = try #require(result.singleShot)
        #expect(single.samples.count == 32)
        let amortized = try #require(result.amortized)
        #expect(amortized.iterationsPerBatch > 0)
        #expect((result.gflops ?? 0) > 0)
        #expect((result.bandwidthGBPerSec ?? 0) > 0)
    }
}

private extension RawFloatL2Input {
    /// Return a copy with `a` and `b` swapped — for symmetry checks.
    static func swapped(_ input: RawFloatL2Input) -> RawFloatL2Input {
        var copy = input
        let tmp = copy.a
        copy.a = copy.b
        copy.b = tmp
        return copy
    }
}
