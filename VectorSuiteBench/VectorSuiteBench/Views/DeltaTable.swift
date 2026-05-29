import SwiftUI
import BenchKit

/// 8-column diff table. The Diff-mode counterpart to `CaseTable` —
/// same column manifest, same widths, same atoms (`Pill`, `ImplSwatch`,
/// `VerificationDot`) — but each numeric cell renders the comparison
/// value alongside a polarity-aware `DeltaGlyph` annotation.
///
/// Built against `RunDiff.compare(a: baseline, b: comparison).pairs`
/// and flattened via `DeltaRowBuilder.build(from:)`. Filter state
/// is shared with the single-run table via `CaseTableFilter` (see
/// `DeltaRowFilterLogic` for the adapter).
///
/// **Row identity stays stable across swap.** The row `id` matches
/// `CaseRow`'s convention (`canonicalString|mode`) so a `⇋ Swap`
/// click flips the values without re-laying-out the table — the rows
/// the user is looking at simply re-render in the new direction.
///
/// **Missing-side rendering.** A pair present on only one side still
/// emits a row; its numeric cells render `[ N/A ]` in `text.lo`
/// instead of a value+delta pair. The user can see at a glance that
/// the case "appeared" or "disappeared" between runs — silently
/// dropping it would hide a real regression class
/// ("Item X removed an entire impl").
struct DeltaTable: View {

    /// Pre-built rows. Caller owns the `DeltaRowBuilder.build(from:)`
    /// invocation (typically `DiffPaneView`) so the same row list can
    /// later feed a chart-pane equivalent if one is added.
    let rows: [DeltaRow]
    let filter: CaseTableFilter

    @State private var sortOrder: [KeyPathComparator<DeltaRow>] = []

    var body: some View {
        Table(displayed, sortOrder: $sortOrder) {
            TableColumn("Operation") { row in
                DeltaOperationCell(row: row)
            }
            .width(min: 100, ideal: 110)

            TableColumn("Implementation") { row in
                DeltaImplementationCell(row: row)
            }
            .width(min: 160, ideal: 180)

            TableColumn("Mode · Size") { row in
                DeltaModeSizeCell(row: row)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Median", value: \.medianSortKey) { row in
                DeltaLatencyCell(cell: row.median, row: row, isP999: false)
            }
            .width(min: 130, ideal: 150)

            TableColumn("P99", value: \.p99SortKey) { row in
                DeltaLatencyCell(cell: row.p99, row: row, isP999: false)
            }
            .width(min: 130, ideal: 150)

            TableColumn("P999", value: \.p999SortKey) { row in
                DeltaLatencyCell(cell: row.p999, row: row, isP999: true)
            }
            .width(min: 130, ideal: 150)

            TableColumn("GFLOP/s · GB/s", value: \.gflopsSortKey) { row in
                DeltaThroughputCell(row: row)
            }
            .width(min: 170, ideal: 200)

            TableColumn("Status") { row in
                DeltaStatusCell(row: row)
            }
            .width(min: 150, ideal: 200)
        }
        .background(VSB.Surface.bg)
    }

    private var displayed: [DeltaRow] {
        let filtered = filter.apply(toDelta: rows)
        return sortOrder.isEmpty ? filtered : filtered.sorted(using: sortOrder)
    }
}

// MARK: - Operation cell

private struct DeltaOperationCell: View {
    let row: DeltaRow

    var body: some View {
        HStack(spacing: 4) {
            Text("\(row.workloadID.op.rawValue) \(row.workloadID.dtype.displayGlyph)")
                .vsbBodySemibold()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowTintBackground(row: row))
    }
}

// MARK: - Implementation cell

private struct DeltaImplementationCell: View {
    let row: DeltaRow

    var body: some View {
        HStack(spacing: 6) {
            ImplSwatch(row.workloadID.impl.display, isApproximate: row.isApproximate)
            Text(row.workloadID.impl.display.label)
                .vsbBody(color: row.isApproximate ? VSB.Text.md : VSB.Text.hi)
            if row.isApproximate {
                Pill("APPROX", style: .approx, icon: "~")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowTintBackground(row: row))
    }
}

// MARK: - Mode · Size cell

private struct DeltaModeSizeCell: View {
    let row: DeltaRow

    var body: some View {
        HStack(spacing: 6) {
            Pill(row.mode.pillText, style: .neutral)
            Text(row.workloadID.shape.sizeLabel)
                .vsbMonoSha(color: VSB.Text.md)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowTintBackground(row: row))
    }
}

// MARK: - Latency cell (Median / P99 / P999) — value + DeltaGlyph

private struct DeltaLatencyCell: View {
    let cell: DeltaRow.Cell
    let row: DeltaRow
    let isP999: Bool

    var body: some View {
        Group {
            if row.verification == .failed {
                NumberCell(state: .error)
            } else if let v = cell.value {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    NumberCell(
                        state: .value(v),
                        format: latencyFormat(for: v),
                        unit: "ns",
                        colorOverride: latencyColor(row: row, isP999: isP999)
                    )
                    deltaGlyph(for: cell, polarity: .lowerIsBetter)
                }
            } else {
                naCell
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(rowTintBackground(row: row))
    }
}

// MARK: - Throughput cell (GFLOP/s · GB/s) — value + DeltaGlyph

private struct DeltaThroughputCell: View {
    let row: DeltaRow

    var body: some View {
        Group {
            if row.verification == .failed {
                NumberCell(state: .error)
            } else if row.gflops.value != nil || row.bandwidthGBPerSec.value != nil {
                VStack(alignment: .trailing, spacing: 1) {
                    throughputLine(cell: row.gflops, unit: "GFLOP/s")
                    throughputLine(cell: row.bandwidthGBPerSec, unit: "GB/s")
                }
            } else {
                naCell
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(rowTintBackground(row: row))
    }

    @ViewBuilder
    private func throughputLine(cell: DeltaRow.Cell, unit: String) -> some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if let v = cell.value {
                Text(String(format: "%.1f", v))
                    .vsbMonoSha(color: throughputNumberColor(row: row))
                Text(unit).vsbMonoSha()
                deltaGlyph(for: cell, polarity: .higherIsBetter)
            } else {
                Text("—").vsbMonoSha(color: VSB.Text.lo)
            }
        }
    }

    private func throughputNumberColor(row: DeltaRow) -> Color {
        if row.isApproximate || row.verification == .unverifiable {
            return VSB.Text.md
        }
        return row.isVectorCore ? VSB.Impl.vectorCore : VSB.Text.hi
    }
}

// MARK: - Status cell

private struct DeltaStatusCell: View {
    let row: DeltaRow

    var body: some View {
        HStack(spacing: 5) {
            VerificationDot(row.verification)
            ForEach(flagPills, id: \.text) { pill in
                Pill(pill.text, style: pill.style, icon: pill.icon)
            }
            if row.missingFromComparison {
                Pill("A-ONLY", style: .warn, icon: "!")
            }
            if row.missingFromBaseline {
                Pill("B-ONLY", style: .info, icon: "!")
            }
            if let note = row.verificationNote {
                Text(note)
                    .vsbMonoSha(color: row.verification == .failed ? VSB.Status.fail : VSB.Text.lo)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowTintBackground(row: row))
    }

    private var flagPills: [(text: String, style: PillStyle, icon: Character)] {
        var pills: [(text: String, style: PillStyle, icon: Character)] = []
        if row.isBimodal     { pills.append((text: "BIMODAL", style: .info,   icon: "⌇")) }
        if row.isTruncated   { pills.append((text: "TRUNC",   style: .warn,   icon: "⏱")) }
        if row.isApproximate { pills.append((text: "APPROX",  style: .approx, icon: "~")) }
        return pills
    }
}

// MARK: - Shared helpers

@ViewBuilder
private func deltaGlyph(for cell: DeltaRow.Cell, polarity: DeltaPolarity) -> some View {
    if let d = cell.delta {
        DeltaGlyph(value: .percent(d * 100), polarity: polarity)
    } else {
        DeltaGlyph(value: .absent, polarity: polarity)
    }
}

private var naCell: some View {
    Text("[ N/A ]")
        .vsbMonoSha(color: VSB.Text.lo)
}

private nonisolated func latencyFormat(for v: Double) -> String {
    v >= 100 ? "%.0f" : "%.1f"
}

private func latencyColor(row: DeltaRow, isP999: Bool) -> Color {
    if isP999 && row.isBimodal {
        return VSB.Status.warn
    }
    if row.isApproximate || row.verification == .unverifiable {
        return VSB.Text.md
    }
    return row.isVectorCore ? VSB.Impl.vectorCore : VSB.Text.hi
}

private func rowTintBackground(row: DeltaRow) -> some View {
    Group {
        if row.isBimodal {
            VSB.Status.warn.opacity(0.06)
        } else {
            Color.clear
        }
    }
}

// MARK: - Sort keys

extension DeltaRow {
    /// Sort by comparison-side value (the visible number). Nil sinks
    /// to the bottom of ascending sorts — mirrors `CaseRow` so the
    /// delta-table column sort feels identical to the single-run table.
    nonisolated var medianSortKey: Double { median.value ?? .greatestFiniteMagnitude }
    nonisolated var p99SortKey: Double    { p99.value    ?? .greatestFiniteMagnitude }
    nonisolated var p999SortKey: Double   { p999.value   ?? .greatestFiniteMagnitude }
    nonisolated var gflopsSortKey: Double { gflops.value ?? -.greatestFiniteMagnitude }
}
