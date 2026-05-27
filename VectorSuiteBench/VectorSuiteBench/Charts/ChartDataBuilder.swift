import Foundation
import SwiftUI
import BenchKit

/// One bar of the throughput chart. Each bar maps 1:1 to a `CaseRow` whose
/// mode is `.amortized` and whose derived `gflops` / `bandwidthGBPerSec`
/// are populated — single-shot rows carry neither metric per
/// `CaseResult`'s contract (deriving them from single-shot data at the
/// ~41.6 ns Apple Silicon timebase floor is noise).
///
/// `categoryLabel` is the X axis key: `"dot ƒ32 n=512"`. Including the
/// dtype + shape in the category means we don't silently aggregate across
/// sizes — different vector lengths land on different X categories with
/// their own bars per impl. The alternative (X = op alone, aggregated
/// somehow) hides perf-vs-size scaling, which is exactly what a perf
/// engineer scans this chart to see.
///
/// `id` is the workload's canonical string — same dedup key as the table,
/// so a future "show me where this bar is in the table" affordance can
/// hop directly without re-deriving identity.
struct ChartBar: Identifiable, Sendable, Hashable {

    let workloadID: WorkloadID
    let categoryLabel: String       // X axis category
    let impl: ImplKind              // color / grouping axis
    let implLabel: String           // legend label
    let isApproximate: Bool
    let isVectorCore: Bool
    /// Median GFLOP/s from the amortized loop. `nil` rows are filtered
    /// out at build time, so the field is non-nil on every emitted bar
    /// when `ThroughputMetric.gflops` is selected.
    let gflops: Double?
    /// Median GB/s from the amortized loop. `nil` filtered as above.
    let bandwidthGBPerSec: Double?

    var id: String { workloadID.canonicalString }
}

/// Y-axis metric for the throughput chart. The toggle is in the chart
/// header per design doc §06 (right-aligned pill).
nonisolated enum ThroughputMetric: String, Hashable, CaseIterable, Sendable {
    case gflops    = "GFLOP/s"
    case bandwidth = "GB/s"

    /// Human-readable Y-axis unit string.
    var unit: String { rawValue }

    /// Extract this metric's value from a bar. `nil` when the bar's
    /// underlying case didn't produce this metric — defensive: the
    /// builder already filters bars with both metrics nil, but a single
    /// metric can be nil while the other is present (a bandwidth-only
    /// memory-bound case is conceivable in later phases).
    func value(in bar: ChartBar) -> Double? {
        switch self {
        case .gflops:    return bar.gflops
        case .bandwidth: return bar.bandwidthGBPerSec
        }
    }
}

/// Pure-function chart data builder. Takes the same `[CaseRow]` list that
/// `CaseTable` consumes (the design seam locked in by Item 3b — chart and
/// table read the same row stream so cohort state stays in lockstep) and
/// emits the `[ChartBar]` array Swift Charts iterates over.
///
/// **Filters applied at build time** (in addition to whatever
/// `CaseTableFilter` already restricted upstream):
/// - Mode must be `.amortized`. SHOT rows have no derived throughput.
/// - At least one of `gflops` / `bandwidthGBPerSec` must be populated.
///   A LOOP row whose oracle threw before throughput derivation would
///   carry both nils; emitting it would create a phantom zero-height bar.
///
/// **`nonisolated`** for the same reason as `CaseRowBuilder` and
/// `CaseTableFilterLogic`: pure values-in / values-out, tests run without
/// MainActor ceremony.
nonisolated enum ChartDataBuilder {

    /// Build bars from a (typically already-filtered) row list. Input
    /// order is preserved on the output for predictable legend ordering
    /// in chart series.
    static func build(from rows: [CaseRow]) -> [ChartBar] {
        rows.compactMap(bar(from:))
    }

    /// Lower one row to a bar, or `nil` if the row doesn't carry
    /// throughput data. Exposed for tests so they can pin the
    /// per-row mapping without going through the full builder.
    static func bar(from row: CaseRow) -> ChartBar? {
        guard row.mode == .amortized else { return nil }
        guard row.gflops != nil || row.bandwidthGBPerSec != nil else { return nil }
        return ChartBar(
            workloadID: row.workloadID,
            categoryLabel: categoryLabel(for: row.workloadID),
            impl: row.workloadID.impl,
            implLabel: row.workloadID.impl.display.label,
            isApproximate: row.isApproximate,
            isVectorCore: row.isVectorCore,
            gflops: row.gflops,
            bandwidthGBPerSec: row.bandwidthGBPerSec
        )
    }

    /// `"dot ƒ32 n=512"` — op + dtype glyph + shape label. The same glyph
    /// the table uses (`DType.displayGlyph`) and the same shape label
    /// (`Shape.sizeLabel`), so a number under `"dot ƒ32 n=512"` in the
    /// table reads as the same row that owns the chart bar at the same X
    /// category.
    static func categoryLabel(for id: WorkloadID) -> String {
        "\(id.op.rawValue) \(id.dtype.displayGlyph) \(id.shape.sizeLabel)"
    }

    // MARK: - Series-color mapping

    /// Explicit color for an impl label. Drives Swift Charts'
    /// `.chartForegroundStyleScale(domain:range:)` so VectorCore is the
    /// only saturated cyan and the other impls render at graphite per
    /// design principle P-02. `nonisolated`-but-MainActor-token-accessing:
    /// these tokens are MainActor under the app target's default; this
    /// helper is consumed from the chart view body which is MainActor.
    @MainActor static func color(forImplLabel label: String) -> Color {
        switch label {
        case ImplDisplayKind.vectorCore.label: return VSB.Impl.vectorCore
        case ImplDisplayKind.accelerate.label: return VSB.Impl.accelerate
        case ImplDisplayKind.vDSP.label:       return VSB.Impl.vDSP
        case ImplDisplayKind.metal.label:      return VSB.Impl.metal
        case ImplDisplayKind.naive.label:      return VSB.Impl.naive
        case ImplDisplayKind.simd.label:       return VSB.Impl.simd
        default:                               return VSB.Text.md
        }
    }
}
