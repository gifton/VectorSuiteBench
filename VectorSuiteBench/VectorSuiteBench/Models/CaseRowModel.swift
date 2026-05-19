import Foundation
import BenchKit

/// One row of the data table. A `CaseResult` produces **1 or 2** rows — one
/// per measurement mode it carries — because locked decision §1.5/2 pins
/// "mode pill stays in every row" so each row is self-documenting when it
/// leaves the window as a CSV export or a screenshot in a PR.
///
/// The row carries pre-flattened display data: percentile values converted
/// to ns/op for the LOOP mode (`batchNanos / iterationsPerBatch`), the
/// derived GFLOP/s and GB/s for LOOP rows, and a small set of boolean
/// "treatment" flags so the cell views can switch on stored state instead
/// of recomputing from the underlying `CaseResult` per render.
///
/// `Identifiable.id` is `"<workloadID.canonicalString>|<mode>"` — unique
/// because the canonical string is the dedup key across runs and the mode
/// disambiguates the (case × mode) expansion. Used by `Table`'s row diff.
struct CaseRow: Identifiable, Sendable, Hashable {

    let workloadID: WorkloadID
    let mode: Mode

    /// Median in **ns/op**. For SHOT this is the single-shot p50; for LOOP
    /// it's `amortized.batchNanos.p50 / iterationsPerBatch` so the column
    /// reads consistently across modes (per-op latency).
    let medianNanos: Double?
    let p99Nanos: Double?
    /// `nil` when the case carries the `.truncated` flag — the test hit a
    /// timeout before the p999 sample bucket filled. Median/P99 stand.
    let p999Nanos: Double?

    /// LOOP-only. Single-shot never derives bandwidth / GFLOP/s per
    /// `CaseResult` contract — at the ~41.6 ns Apple Silicon timebase
    /// floor, per-sample arithmetic on single-shot data is noise.
    let gflops: Double?
    let bandwidthGBPerSec: Double?

    let verification: VerificationDisplayState
    /// Status-cell note: `"ulp>NNNN"` for `.failed`, truncated reason for
    /// `.unverifiable`, `nil` for `.verified`.
    let verificationNote: String?

    let flags: Set<CaseFlag>

    // MARK: Derived display state (cached at build time)

    /// `true` when this row's impl is VectorCore. Drives accent-coloring of
    /// the perf cells per design principle P-02.
    let isVectorCore: Bool
    /// `true` when the impl class is `.approximate`. Drives hatched swatch,
    /// dashed border, and `text-md` row demotion per design doc §04.
    let isApproximate: Bool
    /// `true` when the sample histogram looks bimodal (P/E-core migration).
    /// Adds an amber row tint and colors the P999 cell `--warn`.
    let isBimodal: Bool
    /// `true` when sample collection ran out of budget. P999 redacts.
    let isTruncated: Bool

    var id: String { "\(workloadID.canonicalString)|\(mode.rawValue)" }
}

// MARK: - Mode

/// Measurement-mode pill in every row. `SHOT` = single-shot (one `invoke`
/// per sample); `LOOP` = amortized (K iterations per timed loop).
///
/// **`nonisolated`** — pure value enum; the app target's MainActor default
/// would otherwise pin its auto-synthesized `Equatable`/`Hashable` to
/// MainActor and trip Swift 6 warnings in nonisolated test contexts.
nonisolated enum Mode: String, Hashable, CaseIterable, Sendable {
    case singleShot = "shot"
    case amortized  = "loop"

    /// All-caps three/four letter form for the pill text.
    var pillText: String {
        switch self {
        case .singleShot: return "SHOT"
        case .amortized:  return "LOOP"
        }
    }
}

// MARK: - CaseRowBuilder

/// Pure-function row builder. Expands `[CaseResult]` into `[CaseRow]` (one
/// per case × mode) and applies the default ordering.
///
/// **Default order** (locked decision §1.5/3 — approximate adjacent to exact):
/// `(op, dtype, shape, impl, implClassRank, mode)`. `implClassRank` is
/// `.standard < .approximate < .naive`, so the approximate variant of a
/// given impl sits directly under its exact counterpart. Column-header
/// sort from the SwiftUI `Table` overrides this at runtime.
///
/// **`nonisolated`** for the same reason as `RunSummaryGrouping`: pure
/// values-in / values-out, no MainActor reason.
nonisolated enum CaseRowBuilder {

    /// Build + default-order the row list for a run document's cases.
    static func build(from cases: [CaseResult]) -> [CaseRow] {
        var rows: [CaseRow] = []
        rows.reserveCapacity(cases.count * 2)
        for c in cases {
            rows.append(contentsOf: expand(c))
        }
        return rows.sorted(by: defaultOrdering)
    }

    /// Expand one `CaseResult` into 1 or 2 rows. If both modes are nil
    /// (defensive — happens for verification-failed cases that aborted
    /// before sampling), emit a single SHOT row with every perf cell nil
    /// so the case remains visible and sortable in the table.
    static func expand(_ c: CaseResult) -> [CaseRow] {
        let isVC = (c.id.impl == .vectorCore)
        let isApprox = (c.id.implClass == .approximate)
        let isBimodal = c.flags.contains(.bimodal)
        let isTrunc = c.flags.contains(.truncated)
        let (verification, note) = displayVerification(c.verification)

        var out: [CaseRow] = []

        if let dist = c.singleShot, !dist.isEmpty {
            out.append(CaseRow(
                workloadID: c.id,
                mode: .singleShot,
                medianNanos: dist.p50.map(Double.init),
                p99Nanos:    dist.p99.map(Double.init),
                p999Nanos:   isTrunc ? nil : dist.p999.map(Double.init),
                gflops: nil,
                bandwidthGBPerSec: nil,
                verification: verification,
                verificationNote: note,
                flags: c.flags,
                isVectorCore: isVC,
                isApproximate: isApprox,
                isBimodal: isBimodal,
                isTruncated: isTrunc
            ))
        }

        if let amort = c.amortized {
            let K = Double(amort.iterationsPerBatch)
            out.append(CaseRow(
                workloadID: c.id,
                mode: .amortized,
                medianNanos: amort.batchNanos.p50.map { Double($0) / K },
                p99Nanos:    amort.batchNanos.p99.map { Double($0) / K },
                p999Nanos:   isTrunc ? nil : amort.batchNanos.p999.map { Double($0) / K },
                gflops: c.gflops,
                bandwidthGBPerSec: c.bandwidthGBPerSec,
                verification: verification,
                verificationNote: note,
                flags: c.flags,
                isVectorCore: isVC,
                isApproximate: isApprox,
                isBimodal: isBimodal,
                isTruncated: isTrunc
            ))
        }

        if out.isEmpty {
            out.append(CaseRow(
                workloadID: c.id,
                mode: .singleShot,
                medianNanos: nil, p99Nanos: nil, p999Nanos: nil,
                gflops: nil, bandwidthGBPerSec: nil,
                verification: verification, verificationNote: note,
                flags: c.flags,
                isVectorCore: isVC, isApproximate: isApprox,
                isBimodal: isBimodal, isTruncated: isTrunc
            ))
        }

        return out
    }

    /// Default lexicographic ordering — `(op, dtype, shape, impl, implClass-rank, mode)`.
    /// Exposed so tests can pin the comparator directly.
    static func defaultOrdering(_ a: CaseRow, _ b: CaseRow) -> Bool {
        if a.workloadID.op.rawValue != b.workloadID.op.rawValue {
            return a.workloadID.op.rawValue < b.workloadID.op.rawValue
        }
        if a.workloadID.dtype.rawValue != b.workloadID.dtype.rawValue {
            return a.workloadID.dtype.rawValue < b.workloadID.dtype.rawValue
        }
        let aShape = shapeSortKey(a.workloadID.shape)
        let bShape = shapeSortKey(b.workloadID.shape)
        if aShape != bShape { return aShape < bShape }
        if a.workloadID.impl.rawValue != b.workloadID.impl.rawValue {
            return a.workloadID.impl.rawValue < b.workloadID.impl.rawValue
        }
        let aRank = implClassRank(a.workloadID.implClass)
        let bRank = implClassRank(b.workloadID.implClass)
        if aRank != bRank { return aRank < bRank }
        return modeRank(a.mode) < modeRank(b.mode)
    }

    /// Lexicographic key for a `Shape`. Vector-shaped cases sort before
    /// pairwise/matrix; within each, by inner dim then batch dim.
    static func shapeSortKey(_ shape: Shape) -> (Int, Int, Int) {
        switch shape {
        case .vector(let n):          return (0, 0, n)
        case .pairwise(let b, let n): return (1, b, n)
        case .matrix(let b, let n):   return (2, b, n)
        }
    }

    /// `.standard` < `.approximate` < `.naive`. Approximate sitting between
    /// standard and naïve is what places the approximate variant of an impl
    /// directly under its exact counterpart in the default order.
    static func implClassRank(_ c: ImplClass) -> Int {
        switch c {
        case .standard:    return 0
        case .approximate: return 1
        case .naive:       return 2
        }
    }

    static func modeRank(_ m: Mode) -> Int {
        switch m {
        case .singleShot: return 0
        case .amortized:  return 1
        }
    }

    /// Lower a `VerificationResult` to its display state + an optional
    /// status-cell note string.
    static func displayVerification(_ v: VerificationResult) -> (VerificationDisplayState, String?) {
        switch v {
        case .verified:
            return (.verified, nil)
        case .unverifiable(let reason):
            // Truncate so a long reason doesn't blow the Status cell width.
            // Full reason still lives in the underlying CaseResult.
            let trimmed = reason.count <= 24 ? reason : String(reason.prefix(22)) + "…"
            return (.unverifiable, trimmed)
        case .failed(_, let window, _):
            return (.failed, "ulp>\(window)")
        }
    }
}

// MARK: - BenchKit ↔ display adapters
//
// Pinned per `ImplSwatch.swift` / `VerificationDot.swift` docs:
// - `accelerate` (BenchKit's `cblas_sdot` via BLAS) → `.accelerate`, NOT
//   `.vDSP`. vDSP is reserved for Phase 2.2 / 2.3+.
// - `.metal` is reserved for Phase 2.3+.
// - `VerificationResult` associated values (ULP / window / sample index)
//   are intentionally discarded by the dot; the Status column's flag
//   pill + note consume them via `displayVerification(_:)` above.

extension ImplKind {
    nonisolated var display: ImplDisplayKind {
        switch self {
        case .vectorCore: return .vectorCore
        case .accelerate: return .accelerate
        case .naive:      return .naive
        case .simd:       return .simd
        }
    }
}

extension VerificationResult {
    nonisolated var displayState: VerificationDisplayState {
        switch self {
        case .verified:     return .verified
        case .unverifiable: return .unverifiable
        case .failed:       return .failed
        }
    }
}

// MARK: - Shape / DType formatting helpers

extension Shape {
    /// Short rendering for the Mode·Size table cell. `vector(1024)` →
    /// `"n=1024"`; pairwise/matrix use a middle-dot separator so the cell
    /// width stays tight: `"b=64·n=768"`.
    nonisolated var sizeLabel: String {
        switch self {
        case .vector(let n):          return "n=\(n)"
        case .pairwise(let b, let n): return "b=\(b)·n=\(n)"
        case .matrix(let b, let n):   return "b=\(b)·n=\(n)"
        }
    }
}

extension DType {
    /// Math-italic ƒ glyph + bit width — `dot ƒ32`. Pinned in the design
    /// doc §04: the dtype suffix is what disambiguates `dot ƒ32` from a
    /// future `dot ƒ16` without padding the column with a "DType" head.
    nonisolated var displayGlyph: String {
        switch self {
        case .f32: return "ƒ32"
        case .f16: return "ƒ16"
        case .f64: return "ƒ64"
        }
    }
}

// MARK: - CaseRow sort keys

extension CaseRow {
    /// Sort key for the Median column. `nil` rows sort last (mapped to
    /// `.greatestFiniteMagnitude`) so empty cells don't crowd the top of
    /// an ascending sort by latency. `nonisolated` so `KeyPathComparator`
    /// — which the SwiftUI Table builds at the call site — doesn't try to
    /// inherit MainActor.
    nonisolated var medianSortKey: Double { medianNanos ?? .greatestFiniteMagnitude }
    nonisolated var p99SortKey: Double    { p99Nanos    ?? .greatestFiniteMagnitude }
    nonisolated var p999SortKey: Double   { p999Nanos   ?? .greatestFiniteMagnitude }
    nonisolated var gflopsSortKey: Double { gflops      ?? -.greatestFiniteMagnitude }
}
