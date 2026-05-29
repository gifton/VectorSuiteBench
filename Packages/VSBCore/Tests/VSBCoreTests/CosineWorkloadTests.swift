import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit
import VectorCore

/// Phase 2.2 Item 1b — `CosineFamily` correctness coverage.
///
/// Mirrors `L2DistanceWorkloadTests`. Each impl verifies against Item 0d's
/// `kahanFloat64Cosine` Float64 Kahan-Neumaier reference. Generic and
/// Dynamic VectorCore flavors are intentionally absent from the registry
/// (see `CosineFamily` doc).
///
/// **Tolerance note.** Cosine pipelines three reductions and a divide; the
/// ULP window for cosine grows faster with N than for dot (spec §5:
/// `16 + 8·log₂N` standard vs `4 + 2·log₂N` for dot). The
/// `assertVerified` helper accepts up to 50K ULPs to cover all sizes
/// under the same threshold; the real bound is the per-shape window,
/// enforced by the runner.
@Suite("VSBCore Cosine workloads")
struct CosineWorkloadTests {

    // MARK: - Per-impl smokes at dim 512

    @Test("Naive cosine verifies and produces samples")
    func naive() async throws {
        let result = await run(VSBCoreRegistry.naiveCosine512)
        try assertVerified(result, label: "naive")
    }

    @Test("Accelerate cosine (cblas_sdot + cblas_snrm2 ×2) verifies and produces samples")
    func accelerate() async throws {
        let result = await run(VSBCoreRegistry.accelerateCosine512)
        try assertVerified(result, label: "accelerate")
    }

    @Test("Apple simd cosine (single-pass 3-accumulator) verifies and produces samples")
    func appleSimd() async throws {
        let result = await run(VSBCoreRegistry.simdCosine512)
        try assertVerified(result, label: "simd")
    }

    @Test("VectorCore optimized cosine at dim 512 verifies")
    func vectorCoreOptimized512() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedCosine512)
        try assertVerified(result, label: "vectorCore-optimized-512")
    }

    @Test("VectorCore optimized cosine at dim 1536 verifies")
    func vectorCoreOptimized1536() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedCosine1536)
        try assertVerified(result, label: "vectorCore-optimized-1536")
    }

    // MARK: - Baseline size sweeps

    @Test("Naïve cosine verifies at every baseline size")
    func naiveAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(NaiveCosineWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "naïve cosine at N=\(n) failed verification — likely a ULP-window mismatch")
            )
        }
    }

    @Test("Accelerate cosine verifies at every baseline size")
    func accelerateAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(AccelerateCosineWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "Accelerate cosine at N=\(n) failed verification")
            )
        }
    }

    @Test("Apple simd cosine verifies at every baseline size")
    func simdAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(SimdCosineWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "simd cosine at N=\(n) failed verification")
            )
        }
    }

    // MARK: - Registry shape

    @Test("CosineFamily contributes 17 cosine cases")
    func cosineCaseCount() {
        let cases = VSBCoreRegistry.workloads.filter { $0.identifier.op == .cosine }
        #expect(cases.count == 17, Comment(rawValue: "expected 17 cosine cases; got \(cases.count)"))
    }

    @Test("All registered workloads (dot + l2dist + cosine) produce distinct WorkloadIDs")
    func distinctIDsAcrossFamilies() {
        let ids = VSBCoreRegistry.workloads.map(\.identifier.canonicalString)
        let set = Set(ids)
        #expect(set.count == ids.count, Comment(rawValue: "duplicate IDs across families: \(ids)"))
    }

    // MARK: - Mathematical invariants

    @Test("Cosine of vector with itself is 1 (Naïve)")
    func selfCosineIsOne() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.naiveCosine512.identifier))
        var input = VSBCoreRegistry.naiveCosine512.makeInput(rng: &rng)
        input.b = input.a
        let result = VSBCoreRegistry.naiveCosine512.invoke(input)
        // Floating-point cosine of a non-trivial vector with itself isn't
        // bitwise 1.0 — three reductions accumulate to slightly different
        // sums than `dot / (norm * norm)` would algebraically — but should
        // be within a few Float32 ULPs of 1.
        let ulpDistance = floatULPDistance(result, 1.0)
        #expect(ulpDistance < 100, Comment(rawValue: "self-cosine ULP drift from 1.0: \(ulpDistance)"))
    }

    @Test("Cosine is symmetric: a·b == b·a (Accelerate)")
    func symmetricAccelerate() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.accelerateCosine512.identifier))
        let input = VSBCoreRegistry.accelerateCosine512.makeInput(rng: &rng)
        let ab = VSBCoreRegistry.accelerateCosine512.invoke(input)
        var swapped = input
        let tmp = swapped.a
        swapped.a = swapped.b
        swapped.b = tmp
        let ba = VSBCoreRegistry.accelerateCosine512.invoke(swapped)
        #expect(ab == ba, Comment(rawValue: "a·b=\(ab) ≠ b·a=\(ba); cosine must be symmetric"))
    }

    // MARK: - Helpers

    private func run<W: BorrowingWorkload>(_ workload: W) async -> CaseResult {
        let runner = Runner(
            runID: "vsbcore-cosine-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 32, amortizedSamples: 8)
        )
        return await runner.run(workload)
    }

    private func assertVerified(_ result: CaseResult, label: String) throws {
        if case .verified(let maxUlp) = result.verification {
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
