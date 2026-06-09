import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit
import VectorCore

/// Phase 2.2 Item 1c — `NormalizeFamily` correctness coverage.
///
/// First vector-output family in 2.2; the oracle's compare path walks
/// element-by-element through the per-element ULP comparison, repurposing
/// the `VerificationResult.failed.sampleIndex` field to encode the failing
/// element index (mirrors `TopKSetVerifier`'s convention).
///
/// All three VectorCore flavors ship here (per Item 1c locked decision):
/// Optimized uses `normalizedUnchecked`, Generic uses `normalizedFast`,
/// Dynamic uses `try! normalized().get()`. Each is the idiomatic call for
/// that flavor; tests verify each path produces a numerically-correct
/// unit vector within the per-shape ULP window.
@Suite("VSBCore Normalize workloads")
struct NormalizeWorkloadTests {

    // MARK: - Per-impl smokes at dim 512

    @Test("Naive normalize verifies and produces samples")
    func naive() async throws {
        let result = await run(VSBCoreRegistry.naiveNormalize512)
        try assertVerified(result, label: "naive")
    }

    @Test("Accelerate normalize (cblas_snrm2 + vDSP_vsmul) verifies and produces samples")
    func accelerate() async throws {
        let result = await run(VSBCoreRegistry.accelerateNormalize512)
        try assertVerified(result, label: "accelerate")
    }

    @Test("Apple simd normalize (two-pass simd_float4) verifies and produces samples")
    func appleSimd() async throws {
        let result = await run(VSBCoreRegistry.simdNormalize512)
        try assertVerified(result, label: "simd")
    }

    @Test("VectorCore optimized normalize at dim 512 verifies (normalizedUnchecked)")
    func vectorCoreOptimized512() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedNormalize512)
        try assertVerified(result, label: "vectorCore-optimized-512")
    }

    @Test("VectorCore optimized normalize at dim 1536 verifies")
    func vectorCoreOptimized1536() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreOptimizedNormalize1536)
        try assertVerified(result, label: "vectorCore-optimized-1536")
    }

    @Test("VectorCore generic normalize at dim 512 verifies (normalizedFast)")
    func vectorCoreGeneric512() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreGenericNormalize512)
        try assertVerified(result, label: "vectorCore-generic-512")
    }

    @Test("VectorCore dynamic normalize at dim 512 verifies (try! normalized().get())")
    func vectorCoreDynamic512() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreDynamicNormalize512)
        try assertVerified(result, label: "vectorCore-dynamic-512")
    }

    @Test("VectorCore dynamic normalize at dim 4096 verifies (only Dynamic covers this size)")
    func vectorCoreDynamic4096() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreDynamicNormalize4096)
        try assertVerified(result, label: "vectorCore-dynamic-4096")
    }

    // MARK: - Baseline size sweeps

    @Test("Naïve normalize verifies at every baseline size")
    func naiveAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(NaiveNormalizeWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "naïve normalize at N=\(n) failed verification — likely a ULP-window mismatch")
            )
        }
    }

    @Test("Accelerate normalize verifies at every baseline size")
    func accelerateAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(AccelerateNormalizeWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "Accelerate normalize at N=\(n) failed verification")
            )
        }
    }

    @Test("Apple simd normalize verifies at every baseline size")
    func simdAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(SimdNormalizeWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "simd normalize at N=\(n) failed verification")
            )
        }
    }

    @Test("VectorCore dynamic normalize verifies at every baseline size")
    func vectorCoreDynamicAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(VectorCoreDynamicNormalizeWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "VC-dynamic normalize at N=\(n) failed verification")
            )
        }
    }

    // MARK: - Registry shape

    @Test("NormalizeFamily contributes 26 OOP normalize cases")
    func normalizeCaseCount() {
        // Item 3a added NormalizeInPlaceFamily whose cases also live
        // under op=.normalize but are disambiguated by
        // params["inplace"]=="true". The OOP family's count is asserted
        // by excluding the IP cases — both filtered checks must hold
        // for the registry to be self-consistent.
        let allNormalize = VSBCoreRegistry.workloads.filter { $0.identifier.op == .normalize }
        let oop = allNormalize.filter { $0.identifier.params["inplace"] != "true" }
        #expect(oop.count == 26, Comment(rawValue: "expected 26 OOP normalize cases; got \(oop.count)"))
    }

    @Test("All registered workloads (dot + l2dist + cosine + normalize) produce distinct WorkloadIDs")
    func distinctIDsAcrossFamilies() {
        let ids = VSBCoreRegistry.workloads.map(\.identifier.canonicalString)
        let set = Set(ids)
        #expect(set.count == ids.count, Comment(rawValue: "duplicate IDs across families: \(ids)"))
    }

    // MARK: - Mathematical invariants

    @Test("Normalized vector has unit magnitude (Naïve)")
    func unitMagnitudeNaive() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.naiveNormalize512.identifier))
        let input = VSBCoreRegistry.naiveNormalize512.makeInput(rng: &rng)
        let result = VSBCoreRegistry.naiveNormalize512.invoke(input)
        // ‖normalized‖² should ≈ 1 to within ~Float32 ULP precision.
        var sumSq: Float = 0
        for x in result { sumSq += x * x }
        let drift = abs(sumSq - 1.0)
        // 512 floats accumulated naïvely → ~O(N·ε_f32) = ~6e-5 worst case.
        #expect(drift < 1e-4, Comment(rawValue: "naïve normalize magnitude drift: \(drift)"))
    }

    @Test("Normalized vector preserves direction (Accelerate)")
    func preservesDirection() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.accelerateNormalize512.identifier))
        let input = VSBCoreRegistry.accelerateNormalize512.makeInput(rng: &rng)
        let result = VSBCoreRegistry.accelerateNormalize512.invoke(input)
        // Element ratios r[i] = result[i] / input[i] should all equal
        // 1/magnitude — the same scalar for every i. Check that the first
        // ratio matches the last ratio within tight Float32 ULPs.
        let r0 = result[0] / input.a[0]
        let rN = result[input.a.count - 1] / input.a[input.a.count - 1]
        let ulps = floatULPDistance(r0, rN)
        #expect(ulps < 8, Comment(rawValue: "per-element scale factor diverged: \(ulps) ULPs"))
    }

    // MARK: - Helpers

    private func run<W: BorrowingWorkload>(_ workload: W) async -> CaseResult {
        let runner = Runner(
            runID: "vsbcore-normalize-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 32, amortizedSamples: 8)
        )
        return await runner.run(workload)
    }

    private func assertVerified(_ result: CaseResult, label: String) throws {
        if case .verified(let maxUlp) = result.verification {
            // Normalize is per-element comparison; per-element ULP at small
            // dims stays in single-digits, at large dims (4096) can reach
            // a few hundred per element. 50K is a generous ceiling that
            // catches drift bugs while accommodating naïve at N=4096.
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
