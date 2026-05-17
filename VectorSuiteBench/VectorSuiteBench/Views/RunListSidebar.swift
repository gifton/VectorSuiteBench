import SwiftUI
import BenchKit

/// Run-history sidebar — the navigation primitive of the app (design doc §04).
///
/// **Row anatomy** (three lines, ~62 px tall, locked decision §1.5/1):
/// ```
/// ┌─────────────────────────────────────────┐
/// │ 14:32                              [⚠]  │   line 1 · time of day  · throttle slot
/// │ [SMOKE] main · abc1234                  │   line 2 · preset pill  · branch · short SHA
/// │ 5m 23s · 342 cases                      │   line 3 · duration · case count
/// └─────────────────────────────────────────┘
/// ```
///
/// **Sectioning.** Rows are bucketed by relative date via
/// `RunSummaryGrouping.group(_:now:)`. Section headers read "Today" /
/// "Yesterday" / "May 13" — design doc §04 DO list, item 1.
///
/// **`now` refresh — `TimelineView(.periodic)`**. The sidebar needs the
/// "Today / Yesterday" labels to stay honest across midnight even when
/// no new run lands. A `TimelineView(.periodic(...))` re-evaluates the
/// body every minute, recomputing buckets against a fresh `Date()`. The
/// cost is one O(n) grouping pass per minute over a ≤ few-hundred-row
/// index — sub-millisecond.
///
/// Tests pin a specific `now` via the `now:` initializer parameter,
/// which short-circuits the TimelineView and runs the content once
/// against the supplied date.
///
/// **API shape — data, not coordinator.** The view takes `[RunSummary]`
/// directly rather than a `RunStoreCoordinator`. Two payoffs:
/// 1. Populated previews are trivial (just hand-build an array).
/// 2. The view is decoupled from the data-layer's Observable type, so
///    test fixtures or future alternative loaders don't have to mimic
///    the coordinator's whole surface.
///
/// **What this view does NOT do:**
/// - No sort controls. The design doc is silent on a sidebar sort UI; the
///   default newest-first ordering (already guaranteed by
///   `RunStore.updateIndex`) is what ships. Sort UI lands in a follow-up
///   if/when a real user need surfaces it.
/// - No filter / search box. Out of scope for 2.1.
/// - No in-progress row treatment. `RunController` invocation lands in
///   Item 4c; the `ThrottleDot.inflight` state is there but unused for now.
/// - No stale-selection clearing. If the selected run is pruned while the
///   sidebar is open, `selection` retains the orphaned runID. Item 3a's
///   detail-pane wiring is the right place to add an `onChange` cleanup.
struct RunListSidebar: View {
    let summaries: [RunSummary]
    @Binding var selection: String?

    /// Pin `now` to a specific date (tests / time-stable previews). `nil`
    /// drives the TimelineView path that refreshes `now` once per minute.
    let pinnedNow: Date?

    init(
        summaries: [RunSummary],
        selection: Binding<String?>,
        now: Date? = nil
    ) {
        self.summaries = summaries
        self._selection = selection
        self.pinnedNow = now
    }

    var body: some View {
        if let pinnedNow {
            content(now: pinnedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let buckets = RunSummaryGrouping.group(summaries, now: now)
        List(selection: $selection) {
            ForEach(buckets) { bucket in
                Section {
                    ForEach(bucket.summaries, id: \.runID) { summary in
                        RunRow(summary: summary)
                            .tag(summary.runID)
                    }
                } header: {
                    Text(RunSummaryGrouping.formatSectionHeader(for: bucket.section, now: now))
                        .vsbCaption()
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Run History")
        .overlay {
            if summaries.isEmpty {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No runs yet").vsbBody(color: VSB.Text.md)
            Text("Run `swift run vsb-run --preset smoke` or wait for the in-app New Run sheet.")
                .vsbMonoSha()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// One row in the sidebar. Extracted from `RunListSidebar.body` so the
/// row layout is testable in isolation via the `#Preview` at the bottom
/// of this file.
private struct RunRow: View {
    let summary: RunSummary

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                // Line 1 — time of day.
                Text(RunSummaryGrouping.formatTimeOfDay(summary.timestamp))
                    .vsbBody(color: VSB.Text.hi)

                // Line 2 — preset pill · branch · short SHA. Separators are
                // their own Text views (not baked into adjacent strings) so
                // an empty branch or SHA simply omits its own Text rather
                // than leaving an orphan separator floating in the row.
                HStack(spacing: 6) {
                    Pill(
                        RunSummaryGrouping.presetPillText(for: summary.preset),
                        style: RunSummaryGrouping.presetPillStyle(for: summary.preset)
                    )
                    if !summary.branch.isEmpty {
                        Text(summary.branch)
                            .vsbBody(color: VSB.Text.md)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let shortSha = Self.shortSha(summary.gitSha) {
                        if !summary.branch.isEmpty {
                            Text("·").vsbMonoSha(color: VSB.Text.dim)
                        }
                        Text(shortSha).vsbMonoSha()
                    }
                }

                // Line 3 — duration · case count.
                HStack(spacing: 4) {
                    Text(RunSummaryGrouping.formatDuration(nanos: summary.wallTimeNanos))
                        .vsbMonoSha()
                    Text("·").vsbMonoSha(color: VSB.Text.dim)
                    Text(RunSummaryGrouping.formatCaseCount(
                        completed: summary.completedCaseCount,
                        total: summary.caseCount
                    ))
                    .vsbMonoSha()
                }
            }

            ThrottleDot(escalations: summary.thermalEscalations)
                .padding(.top, 4)
                .padding(.trailing, 2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Short SHA per design doc §04 DO #2 — "Surface SHA before commit
    /// message". 7 chars is the git-standard short form. Returns `nil`
    /// for empty input so the caller can omit the SHA fragment cleanly
    /// (synthetic test data / pre-git runs).
    private static func shortSha(_ sha: String) -> String? {
        sha.isEmpty ? nil : String(sha.prefix(7))
    }
}

// MARK: - Previews

#Preview("RunListSidebar — populated") {
    NavigationSplitView {
        RunListSidebar(
            summaries: previewSummaries,
            selection: .constant("smoke-today-1"),
            now: previewNow
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
        Text("Detail").vsbCaption()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VSB.Surface.bg)
    }
    .frame(width: 900, height: 700)
}

#Preview("RunListSidebar — empty") {
    NavigationSplitView {
        RunListSidebar(
            summaries: [],
            selection: .constant(nil),
            now: previewNow
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
        Text("Detail").vsbCaption()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VSB.Surface.bg)
    }
    .frame(width: 900, height: 700)
}

#Preview("RunRow — every variant") {
    VStack(alignment: .leading, spacing: 12) {
        RunRow(summary: previewSummary(preset: "smoke", thermal: 0, wallSec: 28))
        RunRow(summary: previewSummary(preset: "standard", thermal: 0, wallSec: 320))
        RunRow(summary: previewSummary(preset: "full", thermal: 2, wallSec: 4_320))
        RunRow(summary: previewSummary(preset: "custom", thermal: 0, completed: 142, total: 600))
        RunRow(summary: previewSummary(preset: "smoke", thermal: 0, wallNanos: nil))
    }
    .padding(16)
    .frame(width: 280)
    .background(VSB.Surface.s0)
}

// MARK: - Preview fixtures (private; only compiled under #if DEBUG implicitly)

private let previewNow: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 5; c.day = 17; c.hour = 14; c.minute = 0
    c.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: c)!
}()

private var previewSummaries: [RunSummary] {
    [
        previewSummary(id: "smoke-today-1",  offsetHours: -1,  preset: "smoke",    sha: "abc1234"),
        previewSummary(id: "std-today",      offsetHours: -3,  preset: "standard", sha: "def5678", thermal: 1),
        previewSummary(id: "smoke-yest",     offsetHours: -26, preset: "smoke",    sha: "9876fed"),
        previewSummary(id: "full-may13",     offsetHours: -96, preset: "full",     sha: "1111aaa", wallSec: 2_640),
        previewSummary(id: "custom-may13",   offsetHours: -100, preset: "custom",  sha: "2222bbb",
                       completed: 87, total: 600),
    ]
}

private func previewSummary(
    id: String = "preview",
    offsetHours: Int = 0,
    preset: String = "smoke",
    sha: String = "abc1234",
    thermal: Int = 0,
    completed: Int = 342,
    total: Int = 342,
    wallSec: Int = 320,
    wallNanos: UInt64? = nil
) -> RunSummary {
    let nanos: UInt64? = wallNanos ?? UInt64(wallSec) * 1_000_000_000
    return RunSummary(
        runID: id,
        timestamp: previewNow.addingTimeInterval(TimeInterval(offsetHours * 3600)),
        gitSha: sha,
        branch: "main",
        preset: preset,
        caseCount: total,
        completedCaseCount: completed,
        hardwareFingerprint: "preview",
        thermalEscalations: thermal,
        wallTimeNanos: nanos
    )
}
