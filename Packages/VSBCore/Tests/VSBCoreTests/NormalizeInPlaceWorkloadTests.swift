import Testing
import Foundation
@testable import VSBCore
@testable import BenchKit
import VectorCore

/// Phase 2.2 Item 3a — `NormalizeInPlaceFamily` correctness coverage.
///
/// First `MutatingWorkload` family in the VSBCore registry. The
/// runner's K-input-rotation logic is already tested in BenchKit by
/// `NormalizeInPlaceSmokeWorkload` (fixture-only); these tests make
/// the family real end-to-end by exercising the actual production
/// workloads from the registry, against the same Float64 Kahan-Neumaier
/// oracle Item 1c uses.
///
/// **Flavor coverage (locked Item 3a user Q&A):** Generic only —
/// only `Vector<D>` has a true mutating `normalizeFast()`. The
/// Optimized + Dynamic flavors are SKIPPED; the OOP family (Item 1c)
/// covers them with the matching semantics.
///
/// **Verification model.** All three impls return `Output = Float =
/// post-mutation input[0]`. The oracle compares against the Float64
/// Kahan-Neumaier reference's first element. This catches every
/// "wrong magnitude" / "forgot to divide" / "wrote zeros" defect
/// because L2 normalize scales every element by the same `1/mag` —
/// any such bug manifests at index 0 just like at every other index.
/// Tail-of-buffer-only bugs aren't caught here (the OOP family does
/// per-element verification, that's where rigorous bit-for-bit
/// checking lives).
@Suite("VSBCore NormalizeInPlace workloads")
struct NormalizeInPlaceWorkloadTests {

    // MARK: - Per-impl smokes at dim 512

    @Test("Naïve in-place normalize verifies and produces samples")
    func naive() async throws {
        let result = await run(VSBCoreRegistry.naiveNormalizeInPlace512)
        try assertVerified(result, label: "naive")
    }

    @Test("Accelerate in-place normalize (cblas_snrm2 + vDSP_vsmul) verifies and produces samples")
    func accelerate() async throws {
        let result = await run(VSBCoreRegistry.accelerateNormalizeInPlace512)
        try assertVerified(result, label: "accelerate")
    }

    @Test("VectorCore generic in-place normalize (normalizeFast) verifies at dim 512")
    func vectorCoreGeneric512() async throws {
        let result = await run(VSBCoreRegistry.vectorCoreGenericNormalizeInPlace512)
        try assertVerified(result, label: "vectorCore-generic-512")
    }

    @Test("VectorCore generic in-place normalize verifies at dim 1536")
    func vectorCoreGeneric1536() async throws {
        let result = await run(VectorCoreGenericNormalizeInPlaceWorkload<Dim1536>())
        try assertVerified(result, label: "vectorCore-generic-1536")
    }

    // MARK: - Baseline size sweeps

    @Test("Naïve in-place normalize verifies at every baseline size")
    func naiveAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(NaiveNormalizeInPlaceWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "naïve in-place normalize at N=\(n) failed verification — likely a ULP-window mismatch")
            )
        }
    }

    @Test("Accelerate in-place normalize verifies at every baseline size")
    func accelerateAtAllSizes() async throws {
        for n in VSBCoreRegistry.baselineDotSizes {
            let result = await run(AccelerateNormalizeInPlaceWorkload(n: n))
            #expect(
                result.verification.isVerified,
                Comment(rawValue: "Accelerate in-place normalize at N=\(n) failed verification")
            )
        }
    }

    // MARK: - WorkloadID discrimination from OOP

    @Test("In-place WorkloadID is distinct from OOP — carries inplace=true")
    func ipWorkloadIDDistinctFromOOP() {
        let ipID = VSBCoreRegistry.naiveNormalizeInPlace512.identifier
        let oopID = VSBCoreRegistry.naiveNormalize512.identifier
        // Same op, impl, shape, dtype — distinguished by params only.
        // Without the inplace=true param the two cases would collide
        // in the diff view and the registry's dedup check.
        #expect(ipID.op == oopID.op)
        #expect(ipID.impl == oopID.impl)
        #expect(ipID.shape == oopID.shape)
        #expect(ipID.canonicalString != oopID.canonicalString,
                Comment(rawValue: "IP canonicalString must differ from OOP — got \(ipID.canonicalString) vs \(oopID.canonicalString)"))
        #expect(ipID.params["inplace"] == "true")
        #expect(oopID.params["inplace"] == nil)
    }

    @Test("VC Generic in-place WorkloadID carries both vectorflavor and inplace")
    func ipVCGenericParams() {
        let id = VSBCoreRegistry.vectorCoreGenericNormalizeInPlace512.identifier
        #expect(id.params["vectorflavor"] == "generic")
        #expect(id.params["inplace"] == "true")
    }

    // MARK: - Registry shape

    @Test("NormalizeInPlaceFamily contributes 14 cases")
    func normalizeInPlaceCaseCount() {
        let cases = NormalizeInPlaceFamily().workloads
        #expect(cases.count == 14,
                Comment(rawValue: "expected 14 normalize-in-place cases (10 baseline + 4 VC-generic); got \(cases.count)"))
    }

    @Test("Every NormalizeInPlace case has op=.normalize AND params[inplace]=true")
    func everyCaseFlaggedInPlace() {
        for workload in NormalizeInPlaceFamily().workloads {
            let id = workload.identifier
            #expect(id.op == .normalize,
                    Comment(rawValue: "expected op=normalize on every case; got \(id.op) on \(id.canonicalString)"))
            #expect(id.params["inplace"] == "true",
                    Comment(rawValue: "expected inplace=true on every case; missing on \(id.canonicalString)"))
        }
    }

    @Test("All registered workloads (dot + l2dist + cosine + normalize OOP + IP) produce distinct WorkloadIDs")
    func distinctIDsAcrossFamilies() {
        let ids = VSBCoreRegistry.workloads.map(\.identifier.canonicalString)
        let set = Set(ids)
        #expect(set.count == ids.count, Comment(rawValue: "duplicate IDs across families: \(ids)"))
    }

    // MARK: - Mathematical invariants

    @Test("In-place normalize produces a unit vector (Naïve invariant check)")
    func unitMagnitudeAfterInPlace() {
        var rng = SplitMix64(seed: SeedTable.seed(for: VSBCoreRegistry.naiveNormalizeInPlace512.identifier))
        let workload = VSBCoreRegistry.naiveNormalizeInPlace512
        var inputs = workload.makeInputs(count: 1, rng: &rng)
        _ = workload.invoke(&inputs[0])
        // Post-mutation buffer should have ‖a‖² ≈ 1 (Float32 accumulated
        // naïvely → ~O(N·ε_f32) ≈ 6e-5 worst case at N=512).
        var sumSq: Float = 0
        for x in inputs[0].a { sumSq += x * x }
        let drift = abs(sumSq - 1.0)
        #expect(drift < 1e-4, Comment(rawValue: "in-place normalize magnitude drift: \(drift)"))
    }

    @Test("In-place mutation actually mutates input (post-state ≠ pre-state)")
    func actuallyMutatesInput() {
        // Sanity check for the K-input-rotation contract: invoke MUST
        // visibly modify the buffer, or the runner's snapshot-restore
        // pattern would silently rotate identical state across
        // iterations and the measurement would be meaningless.
        var rng = SplitMix64(seed: 0xDEADBEEF)
        let workload = AccelerateNormalizeInPlaceWorkload(n: 512)
        var inputs = workload.makeInputs(count: 1, rng: &rng)
        let pre = inputs[0].a
        _ = workload.invoke(&inputs[0])
        let post = inputs[0].a
        // Pre values are in `[0.01, 1.01)` (well above 1/sqrt(512)
        // ≈ 0.044 baseline), so the normalize must rescale every
        // element. Comparing the first 16 indices is sufficient.
        var anyDifferent = false
        for i in 0..<16 where pre[i] != post[i] { anyDifferent = true; break }
        #expect(anyDifferent, "invoke must mutate input.a in place; no per-element difference observed")
    }

    @Test("In-place verification accepts identical magnitude across impls (cross-impl ULP smoke)")
    func crossImplMagnitudeAgreement() {
        // Seed-determinism guarantees the same input bytes when the
        // identifier matches. Across DIFFERENT impl identifiers the
        // seeds differ, but the underlying distribution does not, so
        // the post-normalize magnitude must converge to 1.0 within
        // tight ULPs for both Naive and Accelerate.
        var rng = SplitMix64(seed: 0xCAFE_BABE)
        let naive = NaiveNormalizeInPlaceWorkload(n: 512)
        let accel = AccelerateNormalizeInPlaceWorkload(n: 512)
        var naiveInputs = naive.makeInputs(count: 1, rng: &rng)
        var rng2 = SplitMix64(seed: 0xCAFE_BABE)
        var accelInputs = accel.makeInputs(count: 1, rng: &rng2)
        _ = naive.invoke(&naiveInputs[0])
        _ = accel.invoke(&accelInputs[0])

        var sumSqNaive: Float = 0
        var sumSqAccel: Float = 0
        for x in naiveInputs[0].a { sumSqNaive += x * x }
        for x in accelInputs[0].a { sumSqAccel += x * x }
        // Both impls must produce unit vectors; the per-impl reductions
        // can drift by ~O(N·ε_f32) but the magnitudes converge.
        #expect(abs(sumSqNaive - sumSqAccel) < 1e-4,
                Comment(rawValue: "cross-impl magnitude drift too large: naive \(sumSqNaive) vs accel \(sumSqAccel)"))
    }

    // MARK: - Helpers

    private func run<W: MutatingWorkload>(_ workload: W) async -> CaseResult {
        let runner = Runner(
            runID: "vsbcore-normalize-inplace-test",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 32, amortizedSamples: 8)
        )
        return await runner.run(workload)
    }

    private func assertVerified(_ result: CaseResult, label: String) throws {
        if case .verified(let maxUlp) = result.verification {
            // First-element ULP at small dims stays single-digit; at
            // larger dims the accumulated reduction error in Float32
            // can push it higher but rarely above ~100 ULPs. 50K is
            // a generous ceiling consistent with Item 1c's OOP tests
            // (they check per-element, this checks element 0 — same
            // tolerance is fine).
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

// MARK: - VerificationResult convenience (mirrors NormalizeWorkloadTests)

extension VerificationResult {
    fileprivate var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}
