import Testing
import Foundation
import BenchKit
@testable import VectorSuiteBench

/// `DiffSelection` is a `@MainActor @Observable final class`; its
/// load-bearing logic (auto-pick baseline on entry, swap correctness,
/// cross-fingerprint detection, pairing-state transitions) is exposed
/// as pure-function statics or methods on the class so the test suite
/// can exercise them without a SwiftUI runtime. The view layer
/// (`RunPickerView`) is reviewed via physical-device runs per 2.1
/// convention; nothing about Menu chrome is asserted here.
///
/// **Anchor rule** (locked decision §1.5/5 disambiguation, Item 2a):
/// entering Diff mode while viewing run X → `comparison = X`,
/// `baseline = next-older sibling of X`. If X is the oldest run,
/// `baseline = nil` and the view renders the empty-state card.
@MainActor
@Suite("DiffSelection")
struct DiffSelectionTests {

    // MARK: - autoPickBaseline

    @Test("Auto-pick selects the next-older sibling by timestamp")
    func autoPickNextOlder() {
        let summaries = fixture()
        // Selecting the middle run ("mid") should pick the older one
        // ("old") as baseline — not the newer one ("new"), even though
        // both are siblings.
        let picked = DiffSelection.autoPickBaseline(for: "mid", in: summaries)
        #expect(picked == "old",
                Comment(rawValue: "expected baseline=old (next-older sibling), got \(picked ?? "nil")"))
    }

    @Test("Auto-pick returns nil when selection is the oldest run")
    func autoPickAtOldestReturnsNil() {
        let summaries = fixture()
        let picked = DiffSelection.autoPickBaseline(for: "old", in: summaries)
        #expect(picked == nil,
                "oldest run has no older sibling — baseline must be nil so the view falls through to the empty-state card")
    }

    @Test("Auto-pick returns nil when selection is not in the summary list")
    func autoPickWithUnknownSelection() {
        let summaries = fixture()
        let picked = DiffSelection.autoPickBaseline(for: "ghost-run", in: summaries)
        #expect(picked == nil,
                "an unresolvable selection can't anchor a baseline pick — must return nil rather than guess")
    }

    @Test("Auto-pick breaks ties on timestamp by runID lexicographic order")
    func autoPickTimestampTieBreaks() {
        // Two runs at exactly the same timestamp, both older than the
        // anchor. The pick must be deterministic across launches —
        // higher runID wins (lexicographic order, descending), so the
        // pick stays stable when the index is reshuffled.
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let tied = now.addingTimeInterval(-60)
        let summaries: [RunSummary] = [
            makeSummary(id: "anchor", at: now),
            makeSummary(id: "tie-a",  at: tied),
            makeSummary(id: "tie-b",  at: tied),
        ]
        let picked = DiffSelection.autoPickBaseline(for: "anchor", in: summaries)
        #expect(picked == "tie-b",
                Comment(rawValue: "expected lexicographically-greater 'tie-b'; got \(picked ?? "nil")"))
    }

    // MARK: - enterDiffMode

    @Test("enterDiffMode populates comparison from selection and baseline from next-older")
    func enterDiffModePopulates() {
        let sel = DiffSelection()
        sel.enterDiffMode(currentSelection: "mid", summaries: fixture())
        #expect(sel.comparisonRunID == "mid",
                "comparison must equal the selection — that's the 'what you were viewing' anchor")
        #expect(sel.baselineRunID == "old",
                "baseline must be the next-older sibling of the selection")
    }

    @Test("enterDiffMode with nil selection leaves both sides empty")
    func enterDiffModeWithoutSelection() {
        let sel = DiffSelection(baselineRunID: "leftover", comparisonRunID: "stale")
        sel.enterDiffMode(currentSelection: nil, summaries: fixture())
        #expect(sel.comparisonRunID == nil)
        #expect(sel.baselineRunID == nil,
                "entering Diff mode with no sidebar selection must clear stale state, not leave both halves filled")
    }

    // MARK: - swap

    @Test("Swap exchanges baseline and comparison without dropping either side")
    func swapExchanges() {
        let sel = DiffSelection(baselineRunID: "old", comparisonRunID: "mid")
        sel.swap()
        #expect(sel.baselineRunID == "mid")
        #expect(sel.comparisonRunID == "old")
    }

    @Test("Swap is its own inverse")
    func swapInverse() {
        let sel = DiffSelection(baselineRunID: "old", comparisonRunID: "mid")
        sel.swap(); sel.swap()
        #expect(sel.baselineRunID == "old")
        #expect(sel.comparisonRunID == "mid")
    }

    @Test("Swap with one side nil moves the populated side across")
    func swapWithOneNil() {
        // Edge case — user picked one side but not the other yet. Swap
        // should still work (treating nil as a value), not silently
        // refuse. The view layer continues showing the empty-state card
        // because pairing is still incomplete after the swap.
        let sel = DiffSelection(baselineRunID: nil, comparisonRunID: "mid")
        sel.swap()
        #expect(sel.baselineRunID == "mid")
        #expect(sel.comparisonRunID == nil)
    }

    // MARK: - pairing

    @Test("pairing is .valid when both sides resolve and fingerprints match")
    func pairingValid() {
        let sel = DiffSelection(baselineRunID: "old", comparisonRunID: "mid")
        guard case .valid(let baselineID, let comparisonID) = sel.pairing(in: fixture()) else {
            Issue.record("expected .valid pairing for two same-fingerprint runs")
            return
        }
        #expect(baselineID == "old")
        #expect(comparisonID == "mid")
    }

    @Test("pairing is .crossFingerprint when hardware fingerprints disagree")
    func pairingCrossFingerprint() {
        // 'mid' lives on fingerprint "M3max"; 'foreign' lives on
        // "M4ultra". Picking them as a pair must surface the refusal
        // banner via .crossFingerprint, not silently render an
        // apples-to-oranges delta table.
        let sel = DiffSelection(baselineRunID: "mid", comparisonRunID: "foreign")
        guard case .crossFingerprint(let bFP, let cFP) = sel.pairing(in: fixture()) else {
            Issue.record("expected .crossFingerprint pairing across different hardware")
            return
        }
        #expect(bFP == "M3max")
        #expect(cFP == "M4ultra")
    }

    @Test("pairing collapses to .empty when both sides resolve to the same run")
    func pairingSameRunCollapses() {
        // Pathological — user picked the same run on both sides. The
        // view should treat this as an incomplete selection (render the
        // empty-state card) rather than producing a wall of "0% ·"
        // deltas that look like a successful but uninteresting compare.
        let sel = DiffSelection(baselineRunID: "mid", comparisonRunID: "mid")
        #expect(sel.pairing(in: fixture()) == .empty)
    }

    @Test("pairing is .empty when either ID is nil or unresolvable")
    func pairingEmptyOnIncomplete() {
        let onlyBase = DiffSelection(baselineRunID: "old", comparisonRunID: nil)
        #expect(onlyBase.pairing(in: fixture()) == .empty)

        let unresolvable = DiffSelection(baselineRunID: "ghost", comparisonRunID: "mid")
        #expect(unresolvable.pairing(in: fixture()) == .empty,
                "an unresolvable ID collapses to empty so the view doesn't render a half-loaded diff")
    }

    // MARK: - hasComparableRuns

    @Test("hasComparableRuns requires at least two summaries")
    func hasComparableRunsThreshold() {
        #expect(DiffSelection.hasComparableRuns(in: []) == false)
        #expect(DiffSelection.hasComparableRuns(in: [fixture()[0]]) == false)
        #expect(DiffSelection.hasComparableRuns(in: Array(fixture().prefix(2))) == true)
    }

    // MARK: - Fixtures

    private func fixture() -> [RunSummary] {
        // Three same-fingerprint runs + one foreign-fingerprint run.
        // Timestamps spaced one hour apart so 'next-older' is unambiguous.
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        return [
            makeSummary(id: "new",     at: base.addingTimeInterval( 7200), fingerprint: "M3max"),
            makeSummary(id: "mid",     at: base.addingTimeInterval( 3600), fingerprint: "M3max"),
            makeSummary(id: "old",     at: base,                            fingerprint: "M3max"),
            makeSummary(id: "foreign", at: base.addingTimeInterval(10800), fingerprint: "M4ultra"),
        ]
    }

    private func makeSummary(
        id: String,
        at timestamp: Date,
        fingerprint: String = "M3max"
    ) -> RunSummary {
        RunSummary(
            runID: id,
            timestamp: timestamp,
            gitSha: "abc1234",
            branch: "main",
            preset: "standard",
            caseCount: 87,
            completedCaseCount: 87,
            hardwareFingerprint: fingerprint,
            thermalEscalations: 0,
            wallTimeNanos: 5_000_000_000
        )
    }
}
