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

    /// Filtered + lowered bars. Recomputed when the filter mutates
    /// (Observation framework) or `rows` changes.
    private var bars: [ChartBar] {
        ChartDataBuilder.build(from: filter.apply(to: rows))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(VSB.Surface.hair)
            if bars.isEmpty {
                emptyState
            } else {
                chart
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

    /// The bar chart proper. `position: .automatic` lets Swift Charts
    /// group bars within each X category by impl (the `.foregroundStyle`
    /// dimension); `position: .dodge` would force explicit side-by-side,
    /// but `.automatic` adapts as the impl count varies per category and
    /// reads better at default density.
    private var chart: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Operation", bar.categoryLabel),
                y: .value(metric.unit, metric.value(in: bar) ?? 0)
            )
            .foregroundStyle(by: .value("Impl", bar.implLabel))
            .opacity(bar.isApproximate ? 0.5 : 1.0)
        }
        .chartForegroundStyleScale(domain: implDomain, range: implRange)
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

    /// Domain (legend keys) + range (colors) for the impl color scale.
    /// Pinned per design principle P-02: VectorCore is the only
    /// saturated color, others are graphite. Domain order = legend
    /// order, so VectorCore reads first.
    private var implDomain: [String] {
        // Stable order across renders. Only include impls actually present
        // in the bar set so the legend doesn't show ghosts.
        let present = Set(bars.map(\.implLabel))
        let ordered: [String] = [
            ImplDisplayKind.vectorCore.label,
            ImplDisplayKind.accelerate.label,
            ImplDisplayKind.vDSP.label,
            ImplDisplayKind.simd.label,
            ImplDisplayKind.metal.label,
            ImplDisplayKind.naive.label,
        ]
        return ordered.filter { present.contains($0) }
    }

    private var implRange: [Color] {
        implDomain.map(ChartDataBuilder.color(forImplLabel:))
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
