import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// Tests for the data table's row builder and filter. Filter logic is
/// pure-function (`CaseTableFilterLogic.apply(...)`) so we exercise it
/// directly without spinning up a MainActor context. Row-builder tests
/// cover the (case × mode) expansion, the default ordering that
/// interleaves `.approximate` next to its exact counterpart per locked
/// decision §1.5/3, and the row-level treatment derivation.
@Suite("CaseTableFilter and CaseRowBuilder")
struct CaseTableFilterTests {

    // MARK: - Row builder: (case × mode) expansion

    @Test("Case with both modes produces two rows, SHOT then LOOP")
    func bothModes() throws {
        let c = makeCase(op: .dot, impl: .vectorCore, implClass: .standard,
                         shape: .vector(n: 512), flavor: "optimized",
                         singleShotSamples: [110, 120, 140, 200, 800],
                         amortizedK: 100,
                         amortizedBatchSamples: [10_000, 11_000, 12_500, 22_000],
                         gflops: 26.04, bandwidth: 104.1)
        let rows = CaseRowBuilder.expand(c)
        #expect(rows.count == 2, Comment(rawValue: "expected 2 rows, got \(rows.count)"))
        #expect(rows[0].mode == .singleShot)
        #expect(rows[1].mode == .amortized)
        // SHOT row carries single-shot percentiles directly.
        #expect(rows[0].medianNanos == 120)
        // LOOP row converts batch → per-op (divide by K).
        let expectedLoopMedian = 11_000.0 / 100.0
        #expect(rows[1].medianNanos == expectedLoopMedian)
        // Bandwidth/GFLOP/s live only on the LOOP row.
        #expect(rows[0].gflops == nil)
        #expect(rows[1].gflops == 26.04)
        #expect(rows[1].bandwidthGBPerSec == 104.1)
    }

    @Test("Case with only singleShot produces one SHOT row")
    func onlySingleShot() {
        let c = makeCase(op: .dot, impl: .accelerate, implClass: .standard,
                         shape: .vector(n: 512), flavor: nil,
                         singleShotSamples: [200, 250, 300, 1000],
                         amortizedK: nil)
        let rows = CaseRowBuilder.expand(c)
        #expect(rows.count == 1)
        #expect(rows[0].mode == .singleShot)
        #expect(rows[0].gflops == nil)
    }

    @Test("Case with only amortized produces one LOOP row")
    func onlyAmortized() {
        let c = makeCase(op: .dot, impl: .accelerate, implClass: .standard,
                         shape: .vector(n: 512), flavor: nil,
                         singleShotSamples: nil,
                         amortizedK: 50,
                         amortizedBatchSamples: [5_000, 5_500, 6_000, 12_000])
        let rows = CaseRowBuilder.expand(c)
        #expect(rows.count == 1)
        #expect(rows[0].mode == .amortized)
        #expect(rows[0].medianNanos == 5_500.0 / 50.0)
    }

    @Test("Case with no samples at all still produces one placeholder SHOT row")
    func neitherMode() {
        let c = makeCase(op: .dot, impl: .accelerate, implClass: .standard,
                         shape: .vector(n: 512), flavor: nil,
                         singleShotSamples: nil, amortizedK: nil)
        let rows = CaseRowBuilder.expand(c)
        #expect(rows.count == 1, Comment(rawValue: "verification-failed cases that abort before sampling must still surface in the table"))
        #expect(rows[0].mode == .singleShot)
        #expect(rows[0].medianNanos == nil)
    }

    @Test("Truncated flag redacts P999 only; median/P99 stand")
    func truncatedRedactsP999() {
        let c = makeCase(op: .dot, impl: .accelerate, implClass: .standard,
                         shape: .vector(n: 512), flavor: nil,
                         singleShotSamples: [100, 110, 120, 130, 1000],
                         amortizedK: nil,
                         flags: [.truncated])
        let rows = CaseRowBuilder.expand(c)
        #expect(rows.count == 1)
        #expect(rows[0].medianNanos != nil)
        #expect(rows[0].p99Nanos != nil)
        #expect(rows[0].p999Nanos == nil, Comment(rawValue: "TRUNC must redact P999 per design doc §04"))
        #expect(rows[0].isTruncated)
    }

    // MARK: - Row builder: default ordering interleaves approximate

    @Test("Default order interleaves approximate next to exact counterpart")
    func approximateInterleaved() {
        // Three impls of the same op + dtype + shape: VectorCore standard,
        // VectorCore approximate, naïve.  §1.5/3 says approximate sits
        // next to its exact counterpart — so the order must be
        // [VC.standard, VC.approximate, naive].
        let cases: [CaseResult] = [
            // Intentionally out of order — the builder must re-sort.
            makeCase(op: .dot, impl: .naive,      implClass: .naive,
                     shape: .vector(n: 512), flavor: nil,
                     singleShotSamples: [100], amortizedK: nil),
            makeCase(op: .dot, impl: .vectorCore, implClass: .approximate,
                     shape: .vector(n: 512), flavor: "optimized",
                     singleShotSamples: [100], amortizedK: nil),
            makeCase(op: .dot, impl: .vectorCore, implClass: .standard,
                     shape: .vector(n: 512), flavor: "optimized",
                     singleShotSamples: [100], amortizedK: nil),
        ]
        let rows = CaseRowBuilder.build(from: cases)
        #expect(rows.count == 3)
        #expect(rows[0].workloadID.impl == .vectorCore)
        #expect(rows[0].workloadID.implClass == .standard)
        #expect(rows[1].workloadID.impl == .vectorCore)
        #expect(rows[1].workloadID.implClass == .approximate)
        #expect(rows[2].workloadID.impl == .naive)
    }

    @Test("Default order: op alphabetical, then shape by inner dim, then impl, then mode")
    func defaultOrderingFullCascade() {
        let cases: [CaseResult] = [
            // dot · n=1024 · VectorCore standard
            makeCase(op: .dot, impl: .vectorCore, implClass: .standard,
                     shape: .vector(n: 1024), flavor: "optimized",
                     singleShotSamples: [100],
                     amortizedK: 100, amortizedBatchSamples: [10_000]),
            // dot · n=512 · VectorCore standard
            makeCase(op: .dot, impl: .vectorCore, implClass: .standard,
                     shape: .vector(n: 512), flavor: "optimized",
                     singleShotSamples: [100], amortizedK: nil),
        ]
        let rows = CaseRowBuilder.build(from: cases)
        // n=512 sorts before n=1024.
        #expect(rows[0].workloadID.shape.summationDepth == 512)
        // Then within n=1024, SHOT precedes LOOP.
        let n1024Rows = rows.filter { $0.workloadID.shape.summationDepth == 1024 }
        #expect(n1024Rows.map(\.mode) == [.singleShot, .amortized])
    }

    // MARK: - Verification display lowering

    @Test("Verification: verified → no note; failed → ulp>NNNN; unverifiable → truncated reason")
    func verificationDisplay() {
        let (s1, n1) = CaseRowBuilder.displayVerification(.verified(maxUlpObserved: 3))
        #expect(s1 == .verified)
        #expect(n1 == nil)

        let (s2, n2) = CaseRowBuilder.displayVerification(.failed(maxUlpObserved: 2048, window: 1024, sampleIndex: 5))
        #expect(s2 == .failed)
        #expect(n2 == "ulp>1024")

        let longReason = "no oracle declared for this exotic-shape async case"
        let (s3, n3) = CaseRowBuilder.displayVerification(.unverifiable(reason: longReason))
        #expect(s3 == .unverifiable)
        // Truncated at 24 chars with an ellipsis suffix.
        #expect((n3 ?? "").count <= 24)
        #expect((n3 ?? "").hasSuffix("…"))
    }

    // MARK: - Filter axes (logic — pure function)

    @Test("Empty filter is identity: all rows pass")
    func emptyFilter() {
        let rows = sampleRows()
        let filtered = CaseTableFilterLogic.apply(rows, ops: [], impls: [], verifications: [], modes: [])
        #expect(filtered.count == rows.count)
        // Order preserved.
        #expect(filtered.map(\.id) == rows.map(\.id))
    }

    @Test("Op axis filters to the selected op")
    func opAxis() {
        let rows = sampleRows()
        let dotOnly = CaseTableFilterLogic.apply(rows, ops: [.dot], impls: [], verifications: [], modes: [])
        #expect(!dotOnly.isEmpty)
        #expect(dotOnly.allSatisfy { $0.workloadID.op == .dot })
    }

    @Test("Impl axis filters to the selected impl")
    func implAxis() {
        let rows = sampleRows()
        let vcOnly = CaseTableFilterLogic.apply(rows, ops: [], impls: [.vectorCore], verifications: [], modes: [])
        #expect(!vcOnly.isEmpty)
        #expect(vcOnly.allSatisfy { $0.workloadID.impl == .vectorCore })
    }

    @Test("Verification axis filters to the selected state")
    func verificationAxis() {
        let rows = sampleRows()
        let failedOnly = CaseTableFilterLogic.apply(rows, ops: [], impls: [], verifications: [.failed], modes: [])
        #expect(failedOnly.allSatisfy { $0.verification == .failed })
        #expect(!failedOnly.isEmpty, Comment(rawValue: "sample fixture seeds at least one failed row"))
    }

    @Test("Mode axis filters to SHOT or LOOP")
    func modeAxis() {
        let rows = sampleRows()
        let shotOnly = CaseTableFilterLogic.apply(rows, ops: [], impls: [], verifications: [], modes: [.singleShot])
        #expect(shotOnly.allSatisfy { $0.mode == .singleShot })
        #expect(!shotOnly.isEmpty)
    }

    @Test("Combined axes intersect (AND across axes)")
    func combinedAxes() {
        let rows = sampleRows()
        let filtered = CaseTableFilterLogic.apply(
            rows,
            ops: [.dot],
            impls: [.vectorCore],
            verifications: [],
            modes: [.amortized]
        )
        #expect(filtered.allSatisfy { $0.workloadID.op == .dot })
        #expect(filtered.allSatisfy { $0.workloadID.impl == .vectorCore })
        #expect(filtered.allSatisfy { $0.mode == .amortized })
    }

    // MARK: - Filter axes (via @MainActor instance, smoke)

    @MainActor
    @Test("CaseTableFilter.apply delegates to the same pure logic")
    func filterInstanceDelegates() {
        let rows = sampleRows()
        let filter = CaseTableFilter(ops: [.dot])
        let viaInstance = filter.apply(to: rows)
        let viaLogic    = CaseTableFilterLogic.apply(rows, ops: [.dot], impls: [], verifications: [], modes: [])
        #expect(viaInstance.map(\.id) == viaLogic.map(\.id))
    }

    @MainActor
    @Test("isUnfiltered reflects whether any axis carries a selection")
    func unfiltered() {
        let filter = CaseTableFilter()
        #expect(filter.isUnfiltered)
        filter.ops.insert(.dot)
        #expect(!filter.isUnfiltered)
        filter.clearAll()
        #expect(filter.isUnfiltered)
    }

    // MARK: - Fixtures

    /// Synthetic row set spanning three impls × two ops × two modes plus a
    /// failed row so every filter axis has at least one positive case.
    private func sampleRows() -> [CaseRow] {
        let cases: [CaseResult] = [
            // dot · VectorCore standard · both modes
            makeCase(op: .dot, impl: .vectorCore, implClass: .standard,
                     shape: .vector(n: 512), flavor: "optimized",
                     singleShotSamples: [100, 110, 130],
                     amortizedK: 100,
                     amortizedBatchSamples: [10_000, 11_000, 13_000]),
            // dot · Accelerate · single-shot only
            makeCase(op: .dot, impl: .accelerate, implClass: .standard,
                     shape: .vector(n: 512), flavor: nil,
                     singleShotSamples: [200, 210, 230], amortizedK: nil),
            // l2dist · naïve · both modes · verification failed
            makeCase(op: .l2dist, impl: .naive, implClass: .naive,
                     shape: .vector(n: 512), flavor: nil,
                     singleShotSamples: [300, 310, 330],
                     amortizedK: 100,
                     amortizedBatchSamples: [30_000, 31_000, 33_000],
                     verification: .failed(maxUlpObserved: 2048, window: 1024, sampleIndex: 7)),
        ]
        return CaseRowBuilder.build(from: cases)
    }

    /// Build a synthetic `CaseResult` with the smallest necessary surface.
    /// Avoids depending on BenchKit's registry helpers — keeps this test
    /// file self-contained.
    private func makeCase(
        op: OpKind,
        impl: ImplKind,
        implClass: ImplClass,
        shape: Shape,
        flavor: String?,
        singleShotSamples: [UInt64]?,
        amortizedK: Int?,
        amortizedBatchSamples: [UInt64] = [],
        gflops: Double? = nil,
        bandwidth: Double? = nil,
        verification: VerificationResult = .verified(maxUlpObserved: 1),
        flags: Set<CaseFlag> = []
    ) -> CaseResult {
        var rawParams: [String: String] = [:]
        if let flavor { rawParams["vectorflavor"] = flavor }
        let params = try! CanonicalParams(rawParams, impl: impl, op: op, shape: shape)
        let workloadID = WorkloadID(
            op: op, impl: impl, implClass: implClass,
            dtype: .f32, shape: shape, params: params
        )
        let shot = singleShotSamples.map { LatencyDistribution(samples: $0) }
        let amort = amortizedK.map { k in
            AmortizedResult(
                iterationsPerBatch: k,
                batchNanos: LatencyDistribution(samples: amortizedBatchSamples)
            )
        }
        var allFlags = flags
        if implClass == .approximate { allFlags.insert(.approximate) }
        return CaseResult(
            id: workloadID,
            singleShot: shot,
            amortized: amort,
            bandwidthGBPerSec: bandwidth,
            gflops: gflops,
            preSampleRSS: 0, postSampleRSS: 0,
            memoryTrace: [],
            thermalEvents: [],
            timerOverheadNanos: 41.6,
            verification: verification,
            flags: allFlags,
            runID: "test-run"
        )
    }
}
