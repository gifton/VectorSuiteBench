import SwiftUI
import Charts
import BenchKit

/// Grouped bar chart of throughput per (op × dtype × shape), colored by
/// impl. The first real chart in the suite — the other four (Latency
/// Histogram, Latency Percentile, Roofline, Memory Pressure) render as
/// "Coming in 2.3" placeholders inside `ChartsPane` per plan §6.
///
/// **Data flow.** Same `[CaseRow]` list `CaseTable` consumes (so cohort
/// stays in lockstep — locked seam from Item 3b). Filter applied first
/// via the shared `CaseTableFilter`; `ChartDataBuilder` then lowers to
/// `[ChartBar]`. Only LOOP rows produce bars (single-shot has no derived
/// throughput per `CaseResult` contract); if the filter restricts to
/// SHOT only, the empty state explains why.
///
/// **Visual notes** (design doc §06 + spec):
/// - VectorCore bars use `VSB.Impl.vectorCore` (the only saturated color
///   in the app per design principle P-02). Other impls use graphite
///   tokens — distinct enough to identify, quiet enough to not compete
///   with VectorCore.
/// - Y-axis toggleable between GFLOP/s and GB/s via a segmented control
///   in the chart header.
/// - Mode pill in the chart header reads `LOOP` (chart is LOOP-only by
///   data constraint; the pill is metadata, not a filter).
/// - **Approximate impls** render at 50 % opacity. The plan calls for
///   hatched fills with a dashed border, but Swift Charts' `BarMark`
///   doesn't accept arbitrary view modifiers (the `HatchedFillModifier`
///   built in Item 0 operates on Views, not Marks). The opacity demotion
///   + the `~ APPROX` legend pill carries enough signal for the MVP;
///   true hatched fill is a future visual-polish pass.
struct ThroughputBarChart: View {

    let rows: [CaseRow]
    let filter: CaseTableFilter

    @State private var metric: ThroughputMetric = .gflops

    var body: some View {
        // Build the bar list **once per render** and pass it down to the
        // chart-content subview. Previously this was a computed property
        // accessed four times per body (visibility check, Chart(_:), and
        // both legs of the impl-color scale), which ran `filter.apply` +
        // `ChartDataBuilder.build` ~4× per render. Hoisting the let into
        // the body root + threading it through one helper collapses
        // those to one pass.
        //
        // Filtering by `metric.value(in:) != nil` is the H2 fix from the
        // review: a bar with the *other* metric populated (say only
        // `bandwidthGBPerSec`) used to render as a zero-height bar when
        // GFLOP/s was selected — silently misleading. Drop those before
        // the chart sees them.
        let bars = ChartDataBuilder.build(from: filter.apply(to: rows))
        let visible = bars.filter { metric.value(in: $0) != nil }

        return VStack(spacing: 0) {
            header
            Divider().background(VSB.Surface.hair)
            if visible.isEmpty {
                emptyState
            } else {
                chart(visible: visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSB.Surface.bg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Throughput")
                .vsbTitle()
            Pill(metric.unit.uppercased(), style: .accent)
            Spacer()
            metricToggle
            Pill("LOOP", style: .neutral)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(VSB.Surface.s0)
    }

    /// GFLOP/s ↔ GB/s segmented control. The toggle is on the Y axis
    /// metric, not the X axis category — kept in the header because the
    /// design doc places chart-level controls there.
    private var metricToggle: some View {
        Picker("Metric", selection: $metric) {
            ForEach(ThroughputMetric.allCases, id: \.self) { m in
                Text(m.unit).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
    }

    // MARK: - Chart

    /// The bar chart proper. Takes the already-filtered visible bar list
    /// from `body` so this function never re-runs the filter pipeline.
    /// Domain + range are derived from the `present` set of impls in the
    /// visible bars — VectorCore-first ordering means the legend reads
    /// the saturated bar at the top regardless of input ordering.
    private func chart(visible: [ChartBar]) -> some View {
        let presentImpls = orderedPresentImpls(in: visible)
        let domain = presentImpls.map(\.label)
        let range = presentImpls.map(ChartDataBuilder.color(for:))

        return Chart(visible) { bar in
            BarMark(
                x: .value("Operation", bar.categoryLabel),
                y: .value(metric.unit, metric.value(in: bar) ?? 0)
            )
            .foregroundStyle(by: .value("Impl", bar.implLabel))
            .opacity(bar.isApproximate ? 0.5 : 1.0)
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(position: .top, alignment: .trailing, spacing: 12)
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(VSB.Surface.hair)
                AxisTick().foregroundStyle(VSB.Surface.hair2)
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .vsbMonoSha()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(VSB.Surface.hair)
                AxisValueLabel {
                    if let n = value.as(Double.self) {
                        Text(String(format: "%.0f", n))
                            .vsbMonoSha()
                    }
                }
            }
        }
        .padding(16)
    }

    /// `[ImplDisplayKind]` ordered so VectorCore is first in the legend
    /// (design principle P-02) and only impls actually present in the
    /// bar set make it in (no ghost legend entries). The fixed ordering
    /// list is also the seam where future impls (`vDSP`, `metal` are
    /// reserved) slot in without re-shuffling.
    private func orderedPresentImpls(in bars: [ChartBar]) -> [ImplDisplayKind] {
        let present = Set(bars.map { $0.impl.display })
        let ordered: [ImplDisplayKind] = [
            .vectorCore, .accelerate, .vDSP, .simd, .metal, .naive,
        ]
        return ordered.filter { present.contains($0) }
    }

    // MARK: - Empty state

    /// Explains *why* the chart is empty, not just that it is — engineers
    /// hit this when the filter restricts to SHOT-only, or when the
    /// loaded run is a smoke preset that disabled amortized mode.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No throughput data")
                .vsbBody(color: VSB.Text.md)
            Text("GFLOP/s and GB/s are derived from amortized (LOOP) samples only. Adjust the mode filter or run a preset that measures both modes.")
                .vsbMonoSha()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
