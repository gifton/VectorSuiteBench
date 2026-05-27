import SwiftUI
import BenchKit

/// 8-column data table for the run-detail body. The first moment the app is
/// materially useful (plan §2.5 step 8). Composes the existing atoms (`Pill`,
/// `ImplSwatch`, `NumberCell`, `VerificationDot`) inside a native macOS
/// `Table` so we get sortable column heads, zebra striping, and selection
/// for free.
///
/// **Data flow.** `RunDetailView` hands us the `RunDocument.cases` list +
/// a `CaseTableFilter`. We expand the cases via `CaseRowBuilder.build(...)`
/// once per document, then on every render apply the filter and the
/// user's column sort. The expanded list is held in `@State` keyed by
/// runID so changing runs rebuilds without leaking the prior run's rows.
///
/// **Row treatments** (design doc §04 "Row-level integrity treatments" —
/// composed; multiple can apply to the same row):
/// - `.failed` → all perf cells render as `ERR` in `--fail`; Operation +
///   Implementation cells stay readable so the row remains findable.
/// - `.unverifiable` → perf numbers in `text-md`; Operation stays `text-hi`.
/// - `.bimodal` flag → faint amber row tint; P999 cell colored `--warn`.
/// - `.truncated` flag → P999 cell redacted to `—`.
/// - `.approximate` impl class → Implementation cell hatched + dashed,
///   row text demoted to `text-md`.
///
/// **Number coloring.** VectorCore rows render perf numbers in
/// `VSB.Impl.vectorCore` per design principle P-02 (VectorCore owns the
/// only saturated color in the app). Other impls render at `text.hi` —
/// or `text.md` when the row is approximate or unverifiable.
///
/// **In-flight seam.** `VerificationDisplayState.inflight` is already a
/// case on the dot; Item 4c will populate it when `RunController` streams
/// rows mid-run. No wiring here.
struct CaseTable: View {

    /// Pre-built rows. The caller (typically `RunDetailView`) owns the
    /// `CaseRowBuilder.build(...)` invocation so the same row list can
    /// feed both this table and `ChartsPane` — the cohort seam locked
    /// in by Item 3b.
    let rows: [CaseRow]
    let filter: CaseTableFilter

    @State private var sortOrder: [KeyPathComparator<CaseRow>] = []

    var body: some View {
        Table(displayed, sortOrder: $sortOrder) {
            TableColumn("Operation") { row in
                OperationCell(row: row)
            }
            .width(min: 100, ideal: 110)

            TableColumn("Implementation") { row in
                ImplementationCell(row: row)
            }
            .width(min: 160, ideal: 180)

            TableColumn("Mode · Size") { row in
                ModeSizeCell(row: row)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Median", value: \.medianSortKey) { row in
                LatencyCell(value: row.medianNanos, row: row, isP999: false)
            }
            .width(min: 90, ideal: 100)

            TableColumn("P99", value: \.p99SortKey) { row in
                LatencyCell(value: row.p99Nanos, row: row, isP999: false)
            }
            .width(min: 90, ideal: 100)

            TableColumn("P999", value: \.p999SortKey) { row in
                LatencyCell(value: row.p999Nanos, row: row, isP999: true)
            }
            .width(min: 90, ideal: 100)

            TableColumn("GFLOP/s · GB/s", value: \.gflopsSortKey) { row in
                ThroughputCell(row: row)
            }
            .width(min: 130, ideal: 150)

            TableColumn("Status") { row in
                StatusCell(row: row)
            }
            .width(min: 150, ideal: 200)
        }
        .background(VSB.Surface.bg)
    }

    /// Filtered + sorted rows. Filter applied first (cohort intent); the
    /// SwiftUI `Table`'s column-header sort then layers on top. When the
    /// user hasn't clicked a column, the default `CaseRowBuilder` order
    /// stands — that's the ordering that interleaves approximate next to
    /// exact per §1.5/3.
    private var displayed: [CaseRow] {
        let filtered = filter.apply(to: rows)
        return sortOrder.isEmpty ? filtered : filtered.sorted(using: sortOrder)
    }
}

// MARK: - Operation cell

/// `dot ƒ32` — kernel name + dtype glyph. Stays at `text-hi` even on
/// FAILED rows so the row remains findable when an engineer scans the
/// table for the case that broke (design doc §04: "Operation cell stays
/// at text-hi"). Approximate rows demote everything *except* this column.
private struct OperationCell: View {
    let row: CaseRow

    var body: some View {
        HStack(spacing: 4) {
            Text("\(row.workloadID.op.rawValue) \(row.workloadID.dtype.displayGlyph)")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(VSB.Text.hi)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowTintBackground(row: row))
    }
}

// MARK: - Implementation cell

/// 10×10 swatch + library name + optional `~ APPROX` pill. The swatch and
/// the (optional) dashed border live inside `ImplSwatch` — passing
/// `isApproximate: row.isApproximate` enables the hatched fill.
private struct ImplementationCell: View {
    let row: CaseRow

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

/// `SHOT n=512` capsule. Mode pill always present per locked decision
/// §1.5/2. The size string lives in `Shape.sizeLabel` so the rule for
/// pairwise/matrix renderings stays in one place.
private struct ModeSizeCell: View {
    let row: CaseRow

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

// MARK: - Latency cell (Median / P99 / P999)

/// Right-aligned ns/op cell. State derivation:
/// - **failed verification** → `NumberCell.error` (renders `ERR` in `--fail`).
/// - **value present** → `NumberCell.value(...)`. Color is accent-cyan
///   when the row is VectorCore, `text.md` when the row is approximate
///   or unverifiable, `text.hi` otherwise. The P999 cell on a bimodal
///   row colors `--warn` to draw the eye to the tail.
/// - **value nil** (TRUNC for P999, or no data at all) → `NumberCell.missing`.
private struct LatencyCell: View {
    let value: Double?
    let row: CaseRow
    let isP999: Bool

    var body: some View {
        Group {
            if row.verification == .failed {
                NumberCell(state: .error)
            } else if let v = value {
                NumberCell(
                    state: .value(v),
                    format: latencyFormat(for: v),
                    unit: nil,
                    isAccent: row.isVectorCore && !row.isApproximate && row.verification != .unverifiable
                )
                .foregroundStyle(latencyColor(row: row, isP999: isP999))
            } else {
                NumberCell(state: .missing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(rowTintBackground(row: row))
    }
}

/// `"%.0f"` for values ≥ 100 ns; `"%.1f"` for values below. The split keeps
/// sub-100-ns latencies (where the half-nanosecond matters) readable
/// without burning precision on long-tail percentiles where the integer is
/// enough.
private nonisolated func latencyFormat(for v: Double) -> String {
    v >= 100 ? "%.0f" : "%.1f"
}

/// Color for a perf number cell, accounting for VectorCore accent + the
/// approximate / unverifiable text demotion + the bimodal-P999 warn tint.
/// MainActor-isolated because it reads `VSB.*` tokens which live under
/// the app target's MainActor default; the only callers are SwiftUI body
/// blocks (also MainActor) so the isolation is free.
private func latencyColor(row: CaseRow, isP999: Bool) -> Color {
    if isP999 && row.isBimodal {
        return VSB.Status.warn
    }
    if row.isApproximate || row.verification == .unverifiable {
        return VSB.Text.md
    }
    return row.isVectorCore ? VSB.Impl.vectorCore : VSB.Text.hi
}

// MARK: - Throughput cell (GFLOP/s · GB/s)

/// GFLOP/s primary + GB/s context. SHOT rows always render `—` here —
/// derived bandwidth/GFLOP/s are LOOP-only per `CaseResult` contract.
/// Failed rows render `ERR`.
private struct ThroughputCell: View {
    let row: CaseRow

    var body: some View {
        Group {
            if row.verification == .failed {
                NumberCell(state: .error)
            } else if row.gflops != nil || row.bandwidthGBPerSec != nil {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        Spacer(minLength: 0)
                        if let g = row.gflops {
                            Text(String(format: "%.1f", g))
                                .vsbMonoNumber(color: numberColor(row: row))
                            Text("GFLOP/s").vsbMonoSha()
                        } else {
                            Text("—").vsbMonoNumber(color: VSB.Text.lo)
                        }
                    }
                    HStack(spacing: 3) {
                        Spacer(minLength: 0)
                        if let bw = row.bandwidthGBPerSec {
                            Text(String(format: "%.1f", bw))
                                .vsbMonoSha(color: numberColor(row: row))
                            Text("GB/s").vsbMonoSha()
                        } else {
                            Text("—").vsbMonoSha(color: VSB.Text.lo)
                        }
                    }
                }
            } else {
                NumberCell(state: .missing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(rowTintBackground(row: row))
    }

    private func numberColor(row: CaseRow) -> Color {
        if row.isApproximate || row.verification == .unverifiable {
            return VSB.Text.md
        }
        return row.isVectorCore ? VSB.Impl.vectorCore : VSB.Text.hi
    }
}

// MARK: - Status cell

/// `VerificationDot` + (optional) flag pills + (optional) note. The dot
/// is the load-bearing signal — color + an a11y label both encode the
/// state, so the cell satisfies §1.5/6 (color-blind paths layer
/// non-hue signals).
private struct StatusCell: View {
    let row: CaseRow

    var body: some View {
        HStack(spacing: 5) {
            VerificationDot(row.verification)
            ForEach(flagPills, id: \.text) { pill in
                Pill(pill.text, style: pill.style, icon: pill.icon)
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

    /// Flag pill descriptors. Approximate appears here too even though the
    /// Implementation cell carries its own pill — the redundancy is
    /// deliberate: the Status column is the canonical "what's notable
    /// about this row" surface and a CSV export of just (op, impl, status)
    /// should still tell you the row is approximate.
    private var flagPills: [(text: String, style: PillStyle, icon: Character)] {
        var pills: [(String, PillStyle, Character)] = []
        if row.isBimodal   { pills.append(("BIMODAL", .info,   "⌇")) }
        if row.isTruncated { pills.append(("TRUNC",   .warn,   "⏱")) }
        if row.isApproximate { pills.append(("APPROX", .approx, "~")) }
        return pills.map { ($0.0, $0.1, $0.2) }
    }
}

// MARK: - Row tint background

/// Faint amber tint for bimodal rows. Other treatments live in cell-level
/// foreground colors. Using a per-cell background (rather than a single
/// row-level overlay) is what SwiftUI's `Table` allows without dropping
/// to a custom row container — the cost is a single shared modifier on
/// every cell which is cheap.
private func rowTintBackground(row: CaseRow) -> some View {
    Group {
        if row.isBimodal {
            VSB.Status.warn.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
