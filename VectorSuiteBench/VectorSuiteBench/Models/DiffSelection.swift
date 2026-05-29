import Foundation
import BenchKit
import Observation

/// Diff-mode selection state. Holds the two run IDs (`baselineRunID` =
/// older anchor, `comparisonRunID` = newer "what changed") plus the
/// pure-function logic for auto-picking the baseline on entry and
/// detecting cross-fingerprint pairings.
///
/// **Anchor convention** (locked decision §1.5/5): baseline is the
/// older run, comparison is the newer one. Negative deltas under
/// `lowerIsBetter` polarity mean comparison improved over baseline —
/// i.e. things got faster, which matches the natural reading of "−12% ▼"
/// as a speedup.
///
/// **Auto-pick rule.** Entering Diff mode while viewing run X:
///   `comparison = X`, `baseline = next-older sibling of X`.
/// If X is the oldest run in the sidebar, `baseline == nil` and the
/// view layer renders the empty-state card (§1.5/6). Mirrors GitHub's
/// PR-compare convention where the run you were inspecting becomes the
/// "head" side and the auto-pick fills in the "base".
///
/// **Cross-fingerprint runs are selectable, not filtered.** The picker
/// still lists them (greyed) so the user can deliberately pick one and
/// learn *why* the diff refuses to render — silently hiding them would
/// make the refusal banner look like a bug.
///
/// **Side decisions are pure-function on this class, not on the view.**
/// `autoPickBaseline(for:in:)`, `swap()`, and `pairing(in:)` all run
/// without a SwiftUI runtime so the test suite can exercise the
/// load-bearing logic with hand-built `RunSummary` fixtures.
@MainActor
@Observable
final class DiffSelection {

    /// Older run (left pane, anchor). `nil` while the user hasn't picked
    /// one yet — view layer renders the empty-state card from §1.5/6
    /// in that case.
    var baselineRunID: String?

    /// Newer run (right pane, "what changed"). Always set once Diff
    /// mode is entered with a valid sidebar selection; nil only in the
    /// pathological "Diff mode entered with no selection at all" path,
    /// which the view layer also routes through the empty state.
    var comparisonRunID: String?

    init(baselineRunID: String? = nil, comparisonRunID: String? = nil) {
        self.baselineRunID = baselineRunID
        self.comparisonRunID = comparisonRunID
    }

    // MARK: - Entry / mutation

    /// Populate the selection from a fresh Diff-mode entry. Sets
    /// `comparison = selection` and `baseline = next-older sibling`.
    /// Pass `nil` selection (no sidebar row picked) to leave both fields
    /// nil — the view renders the empty-state card.
    func enterDiffMode(currentSelection: String?, summaries: [RunSummary]) {
        comparisonRunID = currentSelection
        baselineRunID = Self.autoPickBaseline(for: currentSelection, in: summaries)
    }

    /// Exchange baseline and comparison. Used by the `⇋ Swap` button in
    /// the diff toolbar — invariant-preserving (the order in the picker
    /// always shows whatever the user last picked, never silently
    /// re-sorted by timestamp).
    func swap() {
        let prevBaseline = baselineRunID
        baselineRunID = comparisonRunID
        comparisonRunID = prevBaseline
    }

    // MARK: - Pure-function logic (testable without UI)

    /// Returns the run ID of the next-older sibling of `selection` in
    /// `summaries`, or `nil` if `selection` is the oldest run (or
    /// missing entirely from `summaries`).
    ///
    /// "Next-older" is computed against `RunSummary.timestamp`, not
    /// sidebar position — the sidebar's sectioning ("Today" / "Yesterday")
    /// breaks adjacency in a way that would surprise the user. A run
    /// from "Today 09:00" should auto-pick "Yesterday 23:59" as
    /// baseline if that's chronologically closest, not skip it because
    /// they're in different sidebar sections.
    static func autoPickBaseline(for selection: String?, in summaries: [RunSummary]) -> String? {
        guard let selection,
              let anchor = summaries.first(where: { $0.runID == selection })
        else { return nil }

        // Find the run whose timestamp is the largest still < anchor.timestamp.
        // Ties on timestamp are broken by runID lexicographic order so the
        // pick is deterministic across launches.
        let older = summaries
            .filter { $0.timestamp < anchor.timestamp }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
                return lhs.runID > rhs.runID
            }
        return older.first?.runID
    }

    /// Snapshot of the current pairing against a summary list. Used by
    /// the view layer to decide which of {empty-state, refusal, valid}
    /// branch to render — and by tests to assert state transitions
    /// without a render path.
    func pairing(in summaries: [RunSummary]) -> Pairing {
        guard let baselineRunID, let comparisonRunID else { return .empty }
        guard let baseline = summaries.first(where: { $0.runID == baselineRunID }),
              let comparison = summaries.first(where: { $0.runID == comparisonRunID })
        else { return .empty }
        if baseline.hardwareFingerprint != comparison.hardwareFingerprint {
            return .crossFingerprint(
                baseline: baseline.hardwareFingerprint,
                comparison: comparison.hardwareFingerprint
            )
        }
        if baseline.runID == comparison.runID {
            // Pathological — user picked the same run on both sides. Treat
            // as empty so the view renders the empty-state card rather
            // than a wall of "0% ·" deltas.
            return .empty
        }
        return .valid(baselineID: baseline.runID, comparisonID: comparison.runID)
    }

    /// Are there at least two runs the user *could* compare? Drives the
    /// "compare button enabled even with 0/1 runs" decision — per locked
    /// UX (Item 2a Q4), the button stays enabled and the body renders
    /// the empty-state card. View layer doesn't actually consult this
    /// flag; it's exposed so tests can assert the contract without
    /// instantiating SwiftUI.
    static func hasComparableRuns(in summaries: [RunSummary]) -> Bool {
        summaries.count >= 2
    }

    enum Pairing: Equatable, Sendable {
        /// One or both sides not selected, or the pair degenerates to
        /// the same run. View renders the §1.5/6 empty-state card.
        case empty
        /// Both sides selected and resolvable, but their hardware
        /// fingerprints disagree. View renders the refusal banner
        /// (§7 measurement-integrity rule).
        case crossFingerprint(baseline: String, comparison: String)
        /// Ready to render the DeltaTable.
        case valid(baselineID: String, comparisonID: String)
    }
}
