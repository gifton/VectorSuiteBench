import SwiftUI
import BenchKit

/// Diff-mode toolbar control. Two side-by-side capsules — left=baseline
/// (older), right=comparison (newer) — with a `⇋` swap button between
/// them. Each capsule taps to open a SwiftUI `Menu` listing every run
/// in chronological order, cross-fingerprint entries greyed but still
/// selectable (selecting one routes to the refusal banner from 2c).
///
/// **Why both sides use the same capsule shape**: the polarity convention
/// is load-bearing (`baseline=older, comparison=newer`) but visually the
/// two sides are peers — neither dominates. A loud "swap" affordance
/// between them gives the user a single gesture to flip role without
/// re-opening either Menu.
///
/// **Cross-fingerprint runs are not filtered out**, only greyed via the
/// `⊘` glyph and `VSB.Text.lo` color. Hiding them would make the refusal
/// banner from 2c look like a bug ("I picked it, where did it go?");
/// surfacing them but warning the user keeps the model legible.
///
/// **No SwiftUI `#Preview`** per Phase 2.1 convention — visuals are
/// validated on physical-device runs. The pure-function pieces of the
/// picker live on `DiffSelection` (auto-pick, pairing detection); this
/// view is just the menu chrome.
struct RunPickerView: View {

    @Bindable var selection: DiffSelection
    let summaries: [RunSummary]

    var body: some View {
        HStack(spacing: 8) {
            sideCapsule(
                role: .baseline,
                currentID: selection.baselineRunID,
                placeholder: "Pick baseline"
            )
            swapButton
            sideCapsule(
                role: .comparison,
                currentID: selection.comparisonRunID,
                placeholder: "Pick comparison"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(VSB.Surface.s0)
    }

    // MARK: - Capsule

    @ViewBuilder
    private func sideCapsule(role: Role, currentID: String?, placeholder: String) -> some View {
        let current = currentID.flatMap { id in summaries.first(where: { $0.runID == id }) }
        Menu {
            ForEach(summariesNewestFirst, id: \.runID) { summary in
                Button {
                    pick(summary, for: role)
                } label: {
                    menuRowLabel(for: summary, currentID: currentID)
                }
            }
        } label: {
            capsuleLabel(role: role, current: current, placeholder: placeholder)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(accessibilityLabel(role: role, current: current))
    }

    private func capsuleLabel(role: Role, current: RunSummary?, placeholder: String) -> some View {
        HStack(spacing: 6) {
            Text(role.shortLabel)
                .vsbMonoBadge(color: VSB.Text.dim)
            if let current {
                Text(Self.capsuleText(for: current))
                    .vsbMonoSha(color: VSB.Text.hi)
            } else {
                Text(placeholder)
                    .vsbBody(color: VSB.Text.lo)
            }
            Image(systemName: "chevron.down")
                .imageScale(.small)
                .foregroundStyle(VSB.Text.dim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VSB.Surface.s0)
        .overlay(
            RoundedRectangle(cornerRadius: VSB.Radius.pill, style: .continuous)
                .strokeBorder(VSB.Surface.hair2, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: VSB.Radius.pill, style: .continuous))
    }

    // MARK: - Menu row

    @ViewBuilder
    private func menuRowLabel(for summary: RunSummary, currentID: String?) -> some View {
        let isSelected = summary.runID == currentID
        let isCross = isCrossFingerprint(summary)
        let leading: String = isCross ? "⊘ " : (isSelected ? "◉ " : "○ ")
        // Native SwiftUI Menu items render plain text best — we keep
        // styling out of the row and rely on the leading glyph to
        // signal selection and cross-fingerprint state. Greyed-out
        // visual treatment isn't reliably honored inside a Menu's
        // private chrome.
        Text("\(leading)\(Self.capsuleText(for: summary))")
    }

    // MARK: - Swap

    private var swapButton: some View {
        Button {
            selection.swap()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .imageScale(.medium)
                .foregroundStyle(VSB.Text.md)
                .padding(6)
        }
        .buttonStyle(.borderless)
        .help("Swap baseline and comparison")
        .accessibilityLabel("Swap baseline and comparison")
        .disabled(selection.baselineRunID == nil && selection.comparisonRunID == nil)
    }

    // MARK: - Helpers

    /// `"2026-05-28 · def5678 · standard"` — three load-bearing facts in
    /// chronological-first order so a user scanning the picker can find
    /// the right run by date primarily. SHA is the git short form (7
    /// chars), matching the sidebar.
    static func capsuleText(for summary: RunSummary) -> String {
        let date: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: summary.timestamp)
        }()
        let sha = summary.gitSha.isEmpty ? "—" : String(summary.gitSha.prefix(7))
        return "\(date) · \(sha) · \(summary.preset)"
    }

    private var summariesNewestFirst: [RunSummary] {
        summaries.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.runID > rhs.runID
        }
    }

    private func isCrossFingerprint(_ candidate: RunSummary) -> Bool {
        // A run is "cross-fingerprint" relative to whatever's on the
        // OPPOSITE side. If nothing's picked yet on the opposite side,
        // there's no cross-fingerprint relationship to flag.
        let opposite: RunSummary?
        if candidate.runID == selection.baselineRunID || selection.baselineRunID == nil {
            opposite = selection.comparisonRunID
                .flatMap { id in summaries.first(where: { $0.runID == id }) }
        } else {
            opposite = selection.baselineRunID
                .flatMap { id in summaries.first(where: { $0.runID == id }) }
        }
        guard let opposite else { return false }
        return opposite.hardwareFingerprint != candidate.hardwareFingerprint
    }

    private func pick(_ summary: RunSummary, for role: Role) {
        switch role {
        case .baseline:   selection.baselineRunID   = summary.runID
        case .comparison: selection.comparisonRunID = summary.runID
        }
    }

    private func accessibilityLabel(role: Role, current: RunSummary?) -> Text {
        if let current {
            return Text("\(role.spokenLabel): \(Self.capsuleText(for: current))")
        }
        return Text("\(role.spokenLabel): not selected")
    }

    // MARK: - Role

    enum Role {
        case baseline
        case comparison

        var shortLabel: String {
            switch self {
            case .baseline:   return "BASE"
            case .comparison: return "COMP"
            }
        }
        var spokenLabel: String {
            switch self {
            case .baseline:   return "Baseline run"
            case .comparison: return "Comparison run"
            }
        }
    }
}
