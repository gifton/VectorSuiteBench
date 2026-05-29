import Foundation
import BenchKit

/// One row of the Diff-mode delta table. Mirrors `CaseRow`'s 8-column
/// manifest but each numeric cell carries **two** pieces of data — the
/// comparison-side value (what to show) and the fractional delta vs the
/// baseline (the `DeltaGlyph` annotation). Polarity is implicit per
/// column (`lowerIsBetter` for ns/op; `higherIsBetter` for GFLOP/s and
/// GB/s) and applied at render time by the cell, not stored here.
///
/// **`missingFromBaseline` / `missingFromComparison`** carry the
/// "case present in only one run" state so the view can render `[ N/A ]`
/// in the absent side's number cells while keeping the row's identity
/// columns (Operation, Implementation, Mode·Size) populated. A row
/// missing from comparison still appears so the user can see that
/// something existed in baseline but vanished — silently dropping such
/// rows would mask regressions like "Item X removed an entire impl".
///
/// `Identifiable.id` matches `CaseRow`'s convention
/// (`"<canonicalString>|<mode>"`) so SwiftUI Table's row diff stays
/// stable across baseline/comparison swap.
struct DeltaRow: Identifiable, Sendable, Hashable {

    let workloadID: WorkloadID
    let mode: Mode

    // MARK: - Numeric cells (comparison value + delta vs baseline)

    /// Per-cell value-and-delta. `value` is the comparison-side number
    /// (what the cell renders front-and-center). `delta` is the
    /// fractional change vs baseline (`(comparison - baseline) / baseline`)
    /// — `nil` when either side lacks data or the baseline is zero.
    struct Cell: Hashable, Sendable {
        let value: Double?
        let delta: Double?
        /// `nonisolated` so the builders (which run pure-function on
        /// arbitrary actors) can reference it without inheriting the
        /// app target's MainActor default.
        nonisolated static let absent = Cell(value: nil, delta: nil)
    }

    let median: Cell
    let p99: Cell
    let p999: Cell
    let gflops: Cell
    let bandwidthGBPerSec: Cell

    // MARK: - Identity / status

    /// Comparison-side verification state. Mirrors `CaseRow.verification`
    /// for filter compatibility. When the comparison side is absent,
    /// holds the baseline's verification so the row is still filterable
    /// by the existing chips.
    let verification: VerificationDisplayState
    let verificationNote: String?
    let flags: Set<CaseFlag>

    let isVectorCore: Bool
    let isApproximate: Bool
    let isBimodal: Bool
    let isTruncated: Bool

    let missingFromBaseline: Bool
    let missingFromComparison: Bool

    var id: String { "\(workloadID.canonicalString)|\(mode.rawValue)" }
}

// MARK: - DeltaRowBuilder

/// Pure-function builder that flattens a `RunDiff` into `[DeltaRow]`.
/// Expansion logic mirrors `CaseRowBuilder.expand(_:)`: one row per
/// (case × measurement-mode), so the diff table reads at the same
/// granularity as the single-run table.
///
/// **One-sided pairs** still emit rows. A case present only in baseline
/// expands using the baseline's modes (and renders the comparison side
/// as `[ N/A ]`); a case present only in comparison expands using its
/// own modes. Both paths set `missingFromBaseline` / `missingFromComparison`
/// flags so the view can color the absent cells correctly.
///
/// **Delta polarity.** Computed at render time in the cell views via
/// `DeltaPolarity.lowerIsBetter` (latency) / `.higherIsBetter`
/// (throughput, bandwidth). The builder stores the raw fractional
/// delta only; no polarity is baked in.
///
/// `nonisolated` because every input is a plain value (`RunDocument`,
/// `RunDiff.Pair`) and the builder produces values out — same posture
/// as `CaseRowBuilder`.
nonisolated enum DeltaRowBuilder {

    /// Build + default-order the row list from a diff.
    static func build(from diff: RunDiff) -> [DeltaRow] {
        var rows: [DeltaRow] = []
        rows.reserveCapacity(diff.pairs.count * 2)
        for pair in diff.pairs {
            rows.append(contentsOf: expand(pair))
        }
        return rows.sorted(by: defaultOrdering)
    }

    /// Expand a single pair into 0/1/2 rows (one per measurement mode
    /// present on either side). Pairs with neither side carrying a
    /// SHOT or LOOP distribution still emit one defensive SHOT row
    /// so the case stays visible in the table (mirrors
    /// `CaseRowBuilder.expand`'s last-resort branch).
    static func expand(_ pair: RunDiff.Pair) -> [DeltaRow] {
        let modes = modesPresent(in: pair)
        let effectiveModes = modes.isEmpty ? [Mode.singleShot] : modes
        return effectiveModes.map { mode in row(for: pair, mode: mode) }
    }

    /// Determine which modes appear on either side of the pair. A mode
    /// is "present" if at least one of {baseline, comparison} carries a
    /// non-empty distribution for it. Ordered (singleShot, amortized)
    /// to match `CaseRowBuilder.modeRank`.
    static func modesPresent(in pair: RunDiff.Pair) -> [Mode] {
        var modes: [Mode] = []
        if pair.a?.singleShot?.isEmpty == false || pair.b?.singleShot?.isEmpty == false {
            modes.append(.singleShot)
        }
        if pair.a?.amortized != nil || pair.b?.amortized != nil {
            modes.append(.amortized)
        }
        return modes
    }

    private static func row(for pair: RunDiff.Pair, mode: Mode) -> DeltaRow {
        // The pair's id is always populated (it's how RunDiff keyed the
        // pair), but the result-bearing side may be missing. Use whichever
        // side has data to source flags / verification — the comparison
        // side wins when both are present so the row's "what is true now"
        // signals reflect the right-hand (newer) run.
        let resultForDisplay = pair.b ?? pair.a!
        let isVC = (pair.id.impl == .vectorCore)
        let isApprox = (pair.id.implClass == .approximate)
        let isBimodal = resultForDisplay.flags.contains(.bimodal)
        let isTrunc = resultForDisplay.flags.contains(.truncated)
        let (verification, note) = CaseRowBuilder.displayVerification(resultForDisplay.verification)

        let median = cell(
            extract: { mode == .singleShot ? medianFromSingleShot($0) : medianFromAmortized($0) },
            pair: pair
        )
        let p99 = cell(
            extract: { mode == .singleShot ? p99FromSingleShot($0) : p99FromAmortized($0) },
            pair: pair
        )
        let p999 = cell(
            extract: { mode == .singleShot ? p999FromSingleShot($0, isTrunc: isTrunc) : p999FromAmortized($0, isTrunc: isTrunc) },
            pair: pair
        )
        // GFLOP/s + GB/s only exist for the amortized mode per CaseResult
        // contract. SHOT rows carry `.absent` so the throughput column
        // renders the same `—` placeholder the single-run table uses.
        let gflops: DeltaRow.Cell = mode == .amortized
            ? cell(extract: { $0.gflops }, pair: pair)
            : .absent
        let bandwidth: DeltaRow.Cell = mode == .amortized
            ? cell(extract: { $0.bandwidthGBPerSec }, pair: pair)
            : .absent

        return DeltaRow(
            workloadID: pair.id,
            mode: mode,
            median: median,
            p99: p99,
            p999: p999,
            gflops: gflops,
            bandwidthGBPerSec: bandwidth,
            verification: verification,
            verificationNote: note,
            flags: resultForDisplay.flags,
            isVectorCore: isVC,
            isApproximate: isApprox,
            isBimodal: isBimodal,
            isTruncated: isTrunc,
            missingFromBaseline: pair.isMissingFromA,
            missingFromComparison: pair.isMissingFromB
        )
    }

    /// Pure-function cell builder. Pulls baseline/comparison values via
    /// the supplied extractor, then wraps them in `Cell(value:delta:)`.
    /// The extractor returns `nil` for missing data; the resulting cell
    /// then carries `.absent` semantics that the view layer turns into
    /// `[ N/A ]`.
    static func cell(
        extract: (CaseResult) -> Double?,
        pair: RunDiff.Pair
    ) -> DeltaRow.Cell {
        let baselineValue = pair.a.flatMap(extract)
        let comparisonValue = pair.b.flatMap(extract)
        let delta = fractionalDelta(baseline: baselineValue, comparison: comparisonValue)
        return DeltaRow.Cell(value: comparisonValue, delta: delta)
    }

    /// `(comparison - baseline) / baseline`. Returns nil when either
    /// side is missing, baseline is zero (avoids `Inf`), or the result
    /// would be non-finite. Display layer maps the resulting nil to
    /// `DeltaGlyph.Value.absent` (a `—` glyph in `text.lo`).
    static func fractionalDelta(baseline: Double?, comparison: Double?) -> Double? {
        guard let baseline, let comparison, baseline != 0 else { return nil }
        let raw = (comparison - baseline) / baseline
        return raw.isFinite ? raw : nil
    }

    // MARK: - Per-cell extractors (SHOT / LOOP)

    private static func medianFromSingleShot(_ c: CaseResult) -> Double? {
        c.singleShot?.p50.map(Double.init)
    }
    private static func p99FromSingleShot(_ c: CaseResult) -> Double? {
        c.singleShot?.p99.map(Double.init)
    }
    private static func p999FromSingleShot(_ c: CaseResult, isTrunc: Bool) -> Double? {
        // Mirror CaseRowBuilder.expand: truncated rows redact p999 so the
        // cell renders the truncation marker rather than a partial sample.
        isTrunc ? nil : c.singleShot?.p999.map(Double.init)
    }
    private static func medianFromAmortized(_ c: CaseResult) -> Double? {
        guard let amort = c.amortized else { return nil }
        let K = Double(amort.iterationsPerBatch)
        return amort.batchNanos.p50.map { Double($0) / K }
    }
    private static func p99FromAmortized(_ c: CaseResult) -> Double? {
        guard let amort = c.amortized else { return nil }
        let K = Double(amort.iterationsPerBatch)
        return amort.batchNanos.p99.map { Double($0) / K }
    }
    private static func p999FromAmortized(_ c: CaseResult, isTrunc: Bool) -> Double? {
        guard let amort = c.amortized, !isTrunc else { return nil }
        let K = Double(amort.iterationsPerBatch)
        return amort.batchNanos.p999.map { Double($0) / K }
    }

    /// Default ordering — same lex shape as `CaseRowBuilder.defaultOrdering`
    /// so the diff table reads in the same row sequence as the single-run
    /// table.
    static func defaultOrdering(_ a: DeltaRow, _ b: DeltaRow) -> Bool {
        if a.workloadID.op.rawValue != b.workloadID.op.rawValue {
            return a.workloadID.op.rawValue < b.workloadID.op.rawValue
        }
        if a.workloadID.dtype.rawValue != b.workloadID.dtype.rawValue {
            return a.workloadID.dtype.rawValue < b.workloadID.dtype.rawValue
        }
        let aShape = CaseRowBuilder.shapeSortKey(a.workloadID.shape)
        let bShape = CaseRowBuilder.shapeSortKey(b.workloadID.shape)
        if aShape != bShape { return aShape < bShape }
        if a.workloadID.impl.rawValue != b.workloadID.impl.rawValue {
            return a.workloadID.impl.rawValue < b.workloadID.impl.rawValue
        }
        let aRank = CaseRowBuilder.implClassRank(a.workloadID.implClass)
        let bRank = CaseRowBuilder.implClassRank(b.workloadID.implClass)
        if aRank != bRank { return aRank < bRank }
        return CaseRowBuilder.modeRank(a.mode) < CaseRowBuilder.modeRank(b.mode)
    }
}

// MARK: - Filter adapter

/// Apply the existing `CaseTableFilter` to a `[DeltaRow]` — same
/// axis-AND / within-axis-OR semantics as `CaseTableFilterLogic`, but
/// reading the row from `DeltaRow` instead of `CaseRow`. Lets the diff
/// table share filter state with the single-run table per Item 2b's
/// plan ("Filter state shared with the existing `CaseTableFilter`").
///
/// Nonisolated for the same reason as `CaseTableFilterLogic` —
/// callers in tests don't need a MainActor.
nonisolated enum DeltaRowFilterLogic {
    static func apply(
        _ rows: [DeltaRow],
        ops: Set<OpKind>,
        impls: Set<ImplKind>,
        verifications: Set<VerificationDisplayState>,
        modes: Set<Mode>
    ) -> [DeltaRow] {
        rows.filter { row in
            (ops.isEmpty           || ops.contains(row.workloadID.op))
            && (impls.isEmpty      || impls.contains(row.workloadID.impl))
            && (verifications.isEmpty || verifications.contains(row.verification))
            && (modes.isEmpty      || modes.contains(row.mode))
        }
    }
}

extension CaseTableFilter {
    /// MainActor convenience that mirrors `apply(to:)` for `CaseRow` —
    /// keeps callers on the same instance whether they're rendering the
    /// single-run table or the delta table.
    func apply(toDelta rows: [DeltaRow]) -> [DeltaRow] {
        DeltaRowFilterLogic.apply(
            rows,
            ops: ops,
            impls: impls,
            verifications: verifications,
            modes: modes
        )
    }
}

