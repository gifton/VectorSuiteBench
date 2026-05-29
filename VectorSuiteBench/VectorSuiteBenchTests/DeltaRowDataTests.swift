import Testing
import Foundation
import BenchKit
@testable import VectorSuiteBench

/// `DeltaRowBuilder` is the pure-function pipeline behind `DeltaTable`.
/// Tests target the synthetic `RunDiff.Pair` → `(value, delta%, polarity)`
/// triples the cell views render — the view layer itself is reviewed
/// via physical-device runs per 2.1 convention.
///
/// Coverage focus:
/// - Per-cell value + delta arithmetic for both modes (SHOT, LOOP).
/// - Missing-side handling (case present in only one run).
/// - Edge cases: zero baseline (no delta), non-finite delta (no delta),
///   truncated rows (p999 redacts).
/// - Filter adapter (`DeltaRowFilterLogic`) honors the same axis-AND /
///   within-axis-OR semantics as the single-run filter.
@MainActor
@Suite("DeltaRowBuilder")
struct DeltaRowDataTests {

    // MARK: - Cell arithmetic

    @Test("Median cell carries comparison value and (comparison − baseline) / baseline delta (SHOT)")
    func shotMedianValueAndDelta() {
        let baseline = makeCase(impl: .vectorCore, singleShotSamples: tightAt(ns: 100))
        let comparison = makeCase(impl: .vectorCore, singleShotSamples: tightAt(ns: 88))
        let pair = pair(baseline: baseline, comparison: comparison)

        let rows = DeltaRowBuilder.expand(pair)
        let shot = try! #require(rows.first(where: { $0.mode == .singleShot }))

        #expect(shot.median.value == 88,
                "comparison-side p50 of the SHOT distribution is the rendered value")
        // (88 − 100) / 100 = −0.12 — a 12% speedup.
        #expect(abs((shot.median.delta ?? .nan) - (-0.12)) < 1e-9,
                Comment(rawValue: "expected median delta ≈ −0.12, got \(shot.median.delta ?? .nan)"))
    }

    @Test("LOOP-mode cells divide batchNanos by iterationsPerBatch before delta-ing")
    func loopModeNormalizesPerOp() {
        // K=1000 in baseline: total batch p50 = 100_000 ns → 100 ns/op.
        // K=1000 in comparison: total batch p50 = 75_000 ns → 75 ns/op.
        // Per-op delta: (75 − 100) / 100 = −0.25 = −25%.
        let baseline = makeCase(impl: .accelerate, amortizedK: 1000, amortizedBatchSamples: tightAt(ns: 100_000))
        let comparison = makeCase(impl: .accelerate, amortizedK: 1000, amortizedBatchSamples: tightAt(ns: 75_000))
        let pair = pair(baseline: baseline, comparison: comparison)

        let rows = DeltaRowBuilder.expand(pair)
        let loop = try! #require(rows.first(where: { $0.mode == .amortized }))

        #expect(loop.median.value == 75,
                "LOOP median value is per-op nanos = batchNanos.p50 / iterationsPerBatch")
        #expect(abs((loop.median.delta ?? .nan) - (-0.25)) < 1e-9,
                Comment(rawValue: "expected −0.25 per-op delta; got \(loop.median.delta ?? .nan)"))
    }

    @Test("GFLOP/s and GB/s only carry deltas in LOOP mode; SHOT rows render .absent")
    func throughputOnlyInLoopMode() {
        let baseline = makeCase(
            impl: .vectorCore,
            singleShotSamples: tightAt(ns: 100),
            amortizedK: 1000, amortizedBatchSamples: tightAt(ns: 100_000),
            gflops: 4.0, bandwidth: 50.0
        )
        let comparison = makeCase(
            impl: .vectorCore,
            singleShotSamples: tightAt(ns: 90),
            amortizedK: 1000, amortizedBatchSamples: tightAt(ns: 90_000),
            gflops: 5.0, bandwidth: 60.0
        )
        let pair = pair(baseline: baseline, comparison: comparison)

        let rows = DeltaRowBuilder.expand(pair)
        let shot = try! #require(rows.first(where: { $0.mode == .singleShot }))
        let loop = try! #require(rows.first(where: { $0.mode == .amortized }))

        // SHOT throughput cells stay absent — per-sample throughput numbers
        // are noise at the 41.6 ns Apple Silicon timebase floor per spec §2.3,
        // so we don't render them even when the underlying CaseResult ships
        // a value (which it shouldn't, but defensively).
        #expect(shot.gflops.value == nil)
        #expect(shot.gflops.delta == nil)
        #expect(shot.bandwidthGBPerSec.value == nil)

        // LOOP carries both.
        #expect(loop.gflops.value == 5.0)
        // (5 − 4) / 4 = +0.25 = +25% throughput improvement (polarity is
        // higherIsBetter — rendered green by DeltaGlyph).
        #expect(abs((loop.gflops.delta ?? .nan) - 0.25) < 1e-9)
        #expect(loop.bandwidthGBPerSec.value == 60.0)
        #expect(abs((loop.bandwidthGBPerSec.delta ?? .nan) - 0.2) < 1e-9)
    }

    // MARK: - Missing-side handling

    @Test("Pair missing from baseline emits a row with N/A cells but populated identity")
    func missingFromBaselineKeepsRow() {
        // Case appeared in comparison only — e.g. a new family ships
        // between the two runs. Row must surface so a regression like
        // "Item X added an entire impl" is visible.
        let comparison = makeCase(impl: .vectorCore, singleShotSamples: tightAt(ns: 50))
        let pair = RunDiff.Pair(id: comparison.id, a: nil, b: comparison)
        let rows = DeltaRowBuilder.expand(pair)

        #expect(rows.count == 1, "one mode (SHOT) present → exactly one row")
        let row = rows[0]
        #expect(row.missingFromBaseline == true)
        #expect(row.missingFromComparison == false)
        #expect(row.median.value == 50,
                "comparison-side value still renders; only the delta is absent")
        #expect(row.median.delta == nil,
                "no baseline → no delta")
    }

    @Test("Pair missing from comparison emits a row whose comparison-side cells are absent")
    func missingFromComparisonKeepsRow() {
        // Case disappeared from comparison — could be a registry trim or
        // an outright removal. Row must surface so the user sees what
        // vanished.
        let baseline = makeCase(impl: .naive, singleShotSamples: tightAt(ns: 200))
        let pair = RunDiff.Pair(id: baseline.id, a: baseline, b: nil)
        let rows = DeltaRowBuilder.expand(pair)

        let row = try! #require(rows.first)
        #expect(row.missingFromBaseline == false)
        #expect(row.missingFromComparison == true)
        #expect(row.median.value == nil,
                "comparison value missing → cell renders [ N/A ]")
        #expect(row.median.delta == nil)
    }

    // MARK: - Edge cases on the delta arithmetic

    @Test("Zero baseline collapses the delta to nil so the glyph renders absent")
    func zeroBaselineYieldsNoDelta() {
        // Division by zero would produce ±Inf; we map that to nil so the
        // DeltaGlyph renders `—` rather than a misleading `+Inf%`. The
        // value is still present (comparison ran fine), only the delta
        // is undefined.
        let baseline = makeCase(impl: .naive, singleShotSamples: [0, 0, 0])
        let comparison = makeCase(impl: .naive, singleShotSamples: tightAt(ns: 50))
        let pair = pair(baseline: baseline, comparison: comparison)

        let row = try! #require(DeltaRowBuilder.expand(pair).first)
        #expect(row.median.value == 50)
        #expect(row.median.delta == nil,
                "baseline p50 of 0 → delta is undefined (would be +Inf); render as absent")
    }

    @Test("fractionalDelta is nil when either side is nil or baseline is zero")
    func fractionalDeltaEdges() {
        #expect(DeltaRowBuilder.fractionalDelta(baseline: nil, comparison: 1.0) == nil)
        #expect(DeltaRowBuilder.fractionalDelta(baseline: 1.0, comparison: nil) == nil)
        #expect(DeltaRowBuilder.fractionalDelta(baseline: 0.0, comparison: 1.0) == nil)
        // Sanity: a real arithmetic case still returns a value.
        let d = DeltaRowBuilder.fractionalDelta(baseline: 100, comparison: 88)
        #expect(d != nil)
        #expect(abs((d ?? .nan) - (-0.12)) < 1e-9)
    }

    @Test("Truncated rows redact P999 on both sides — the delta and value both nil")
    func truncatedRowsRedactP999() {
        // The single-run table redacts P999 for truncated cases (the test
        // hit a budget cap before the p999 bucket filled). Diff rows
        // follow the same rule — comparing a partial p999 to a full one
        // would mislead the reader.
        let comparison = makeCase(
            impl: .vectorCore,
            singleShotSamples: tightAt(ns: 80),
            flags: [.truncated]
        )
        let baseline = makeCase(impl: .vectorCore, singleShotSamples: tightAt(ns: 100))
        let pair = pair(baseline: baseline, comparison: comparison)

        let row = try! #require(DeltaRowBuilder.expand(pair).first)
        #expect(row.isTruncated == true)
        #expect(row.median.value == 80,
                "median stands; only p999 redacts under truncation")
        #expect(row.p999.value == nil)
        #expect(row.p999.delta == nil)
    }

    // MARK: - Mode expansion

    @Test("A pair with both modes expands to exactly two rows in CaseRowBuilder order")
    func bothModesExpand() {
        let baseline = makeCase(
            impl: .vectorCore,
            singleShotSamples: tightAt(ns: 100),
            amortizedK: 1000, amortizedBatchSamples: tightAt(ns: 100_000),
            gflops: 4.0
        )
        let comparison = makeCase(
            impl: .vectorCore,
            singleShotSamples: tightAt(ns: 90),
            amortizedK: 1000, amortizedBatchSamples: tightAt(ns: 90_000),
            gflops: 4.5
        )
        let rows = DeltaRowBuilder.expand(pair(baseline: baseline, comparison: comparison))
        #expect(rows.count == 2)
        #expect(rows[0].mode == .singleShot)
        #expect(rows[1].mode == .amortized,
                "default mode ordering must match CaseRowBuilder.modeRank — SHOT before LOOP")
    }

    // MARK: - Filter adapter

    @Test("DeltaRowFilterLogic applies the same axis-AND / within-axis-OR semantics as the single-run filter")
    func filterAdapterAxisSemantics() {
        // Build three rows: dot+VC, l2dist+VC, dot+accelerate. Filtering
        // by op=dot AND impl=vectorCore should leave only the first.
        let r1 = stubRow(op: .dot,    impl: .vectorCore)
        let r2 = stubRow(op: .l2dist, impl: .vectorCore)
        let r3 = stubRow(op: .dot,    impl: .accelerate)
        let filtered = DeltaRowFilterLogic.apply(
            [r1, r2, r3],
            ops: [.dot],
            impls: [.vectorCore],
            verifications: [],
            modes: []
        )
        #expect(filtered.count == 1)
        #expect(filtered[0].workloadID.op == .dot)
        #expect(filtered[0].workloadID.impl == .vectorCore)
    }

    @Test("CaseTableFilter.apply(toDelta:) routes through the shared logic")
    func sharedFilterAcrossTables() {
        let filter = CaseTableFilter(ops: [.dot])
        let rows = [stubRow(op: .dot), stubRow(op: .l2dist)]
        let kept = filter.apply(toDelta: rows)
        #expect(kept.count == 1)
        #expect(kept[0].workloadID.op == .dot)
    }

    // MARK: - Fixtures

    private func pair(baseline: CaseResult, comparison: CaseResult) -> RunDiff.Pair {
        // Both sides share the same identifier (built deterministically
        // from the helper below) so RunDiff.compare-style pairing would
        // pair them automatically. Tests synthesize the Pair directly
        // to avoid building a whole RunDocument when the unit under test
        // is the per-pair expansion.
        RunDiff.Pair(id: comparison.id, a: baseline, b: comparison)
    }

    /// A tight 21-sample distribution — enough that LatencyDistribution's
    /// percentile getters return values, low enough variance that p50 is
    /// the supplied nanos. Used everywhere we want a known-p50 input.
    private func tightAt(ns: UInt64) -> [UInt64] {
        Array(repeating: ns, count: 21)
    }

    private func makeCase(
        op: OpKind = .dot,
        impl: ImplKind,
        implClass: ImplClass = .standard,
        shape: Shape = .vector(n: 512),
        flavor: String? = "optimized",
        singleShotSamples: [UInt64]? = nil,
        amortizedK: Int? = nil,
        amortizedBatchSamples: [UInt64] = [],
        gflops: Double? = nil,
        bandwidth: Double? = nil,
        verification: VerificationResult = .verified(maxUlpObserved: 1),
        flags: Set<CaseFlag> = []
    ) -> CaseResult {
        var rawParams: [String: String] = [:]
        // CanonicalParams requires vectorflavor only for VectorCore impls;
        // rejects it for non-VectorCore. Mirror the registry's contract.
        if impl == .vectorCore, let flavor { rawParams["vectorflavor"] = flavor }
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
            memoryTrace: [], thermalEvents: [],
            timerOverheadNanos: 41.6,
            verification: verification,
            flags: allFlags,
            runID: "test-run"
        )
    }

    /// Lightweight `DeltaRow` constructor for filter-adapter tests where
    /// the numeric values don't matter — only the identity/axis fields.
    private func stubRow(op: OpKind = .dot, impl: ImplKind = .vectorCore) -> DeltaRow {
        var rawParams: [String: String] = [:]
        if impl == .vectorCore { rawParams["vectorflavor"] = "optimized" }
        let params = try! CanonicalParams(rawParams, impl: impl, op: op, shape: .vector(n: 512))
        let id = WorkloadID(
            op: op, impl: impl, implClass: .standard,
            dtype: .f32, shape: .vector(n: 512), params: params
        )
        return DeltaRow(
            workloadID: id, mode: .singleShot,
            median: .absent, p99: .absent, p999: .absent,
            gflops: .absent, bandwidthGBPerSec: .absent,
            verification: .verified, verificationNote: nil,
            flags: [],
            isVectorCore: impl == .vectorCore,
            isApproximate: false, isBimodal: false, isTruncated: false,
            missingFromBaseline: false, missingFromComparison: false
        )
    }
}
