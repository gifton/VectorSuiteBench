import SwiftUI
import BenchKit

/// Container for the chart suite. A small segmented picker at the top
/// selects between the five canonical charts; in Phase 2.1 only the
/// `ThroughputBarChart` is real — the other four render placeholders
/// per plan §6 ("ship the slot, not the chart"). Reserving the chrome
/// here means 2.3 lands the real renders without re-shuffling the IA.
///
/// Receives the same `[CaseRow]` + `CaseTableFilter` the `CaseTable`
/// receives so the filter is honored across both surfaces — the design
/// seam locked in by Item 3b.
struct ChartsPane: View {

    let rows: [CaseRow]
    let filter: CaseTableFilter

    @State private var selection: ChartSlot = .throughput

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().background(VSB.Surface.hair)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSB.Surface.bg)
    }

    // MARK: - Chart picker

    /// Horizontal segmented control listing all five charts. The four
    /// not yet implemented are still selectable so the user can read the
    /// "Coming in 2.3" copy and know what's planned — better than hiding
    /// the option entirely, which would imply the spec is smaller than
    /// it is.
    private var picker: some View {
        HStack(spacing: 0) {
            ForEach(ChartSlot.allCases) { slot in
                Button {
                    selection = slot
                } label: {
                    Text(slot.label)
                        .vsbMonoBadge(color: slot == selection ? VSB.Impl.vectorCore : VSB.Text.md)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(slot == selection ? VSB.accentSoft : Color.clear)
                        .overlay(
                            Rectangle()
                                .fill(slot == selection ? VSB.Impl.vectorCore : Color.clear)
                                .frame(height: 1),
                            alignment: .bottom
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .background(VSB.Surface.s0)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .throughput:
            ThroughputBarChart(rows: rows, filter: filter)
        case .latencyHistogram, .latencyPercentile, .roofline, .memoryPressure:
            comingSoon(slot: selection)
        }
    }

    /// Placeholder for charts deferred to Phase 2.3. Center-stacked card
    /// with the chart name + a one-line spec hint. Keeps the surface
    /// visually consistent with the real chart so the toggle doesn't
    /// feel like a dead end.
    private func comingSoon(slot: ChartSlot) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: slot.iconName)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(VSB.Text.lo)
            Text(slot.label)
                .vsbTitle(color: VSB.Text.md)
            Pill("COMING IN 2.3", style: .neutral)
            Text(slot.hint)
                .vsbMonoSha()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The five canonical chart slots. Wire-names not load-bearing (this enum
/// is UI-state only, never persisted), but the order matches the design
/// doc's "five charts mandated by the spec" table.
nonisolated enum ChartSlot: String, Identifiable, CaseIterable, Hashable, Sendable {
    case throughput
    case latencyHistogram
    case latencyPercentile
    case roofline
    case memoryPressure

    var id: String { rawValue }

    /// Tab label. Short enough for the picker's horizontal strip.
    var label: String {
        switch self {
        case .throughput:        return "THROUGHPUT"
        case .latencyHistogram:  return "HISTOGRAM"
        case .latencyPercentile: return "PERCENTILE"
        case .roofline:          return "ROOFLINE"
        case .memoryPressure:    return "MEMORY"
        }
    }

    /// SF Symbol for the placeholder card.
    var iconName: String {
        switch self {
        case .throughput:        return "chart.bar"
        case .latencyHistogram:  return "chart.bar.doc.horizontal"
        case .latencyPercentile: return "chart.xyaxis.line"
        case .roofline:          return "chart.line.uptrend.xyaxis"
        case .memoryPressure:    return "memorychip"
        }
    }

    /// One-line spec hint shown on the placeholder card. Matches the
    /// design doc §06 axis description so the placeholder communicates
    /// what the chart will show without forcing the user to read the spec.
    var hint: String {
        switch self {
        case .throughput:
            return "op · GFLOP/s or GB/s · grouped by impl"
        case .latencyHistogram:
            return "ns (log) · count · P50/P99/P999 rule-lines · bimodal flag"
        case .latencyPercentile:
            return "vector size (log) · ns (log) · median + P99 lines"
        case .roofline:
            return "FLOPS/byte (log) · GFLOP/s (log) · compute and bandwidth ceilings"
        case .memoryPressure:
            return "wall time · RSS (MB) · thermal-event annotation bands"
        }
    }
}
