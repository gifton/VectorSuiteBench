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
/// **What this view does NOT do:**
/// - No sort controls. The design doc is silent on a sidebar sort UI; the
///   default newest-first ordering (already guaranteed by
///   `RunStore.updateIndex`) is what ships. Sort UI lands in a follow-up
///   if/when a real user need surfaces it.
/// - No filter / search box. Out of scope for 2.1.
/// - No in-progress row treatment. `RunController` invocation lands in
///   Item 4c; the `ThrottleDot.inflight` state is there but unused for now.
struct RunListSidebar: View {
    let coordinator: RunStoreCoordinator
    @Binding var selectedRunID: String?

    /// Injectable clock for previews / tests. Production callers omit it
    /// and the view uses `Date()` (which is fine for live UI — relative
    /// labels recompute on each body invocation).
    let now: Date

    init(
        coordinator: RunStoreCoordinator,
        selectedRunID: Binding<String?>,
        now: Date = Date()
    ) {
        self.coordinator = coordinator
        self._selectedRunID = selectedRunID
        self.now = now
    }

    var body: some View {
        List(selection: $selectedRunID) {
            ForEach(buckets) { bucket in
                Section {
                    ForEach(bucket.summaries, id: \.runID) { summary in
                        RunRow(summary: summary)
                            .tag(summary.runID)
                    }
                } header: {
                    sectionHeader(for: bucket.section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Run History")
        .overlay {
            if coordinator.index.runs.isEmpty {
                emptyState
            }
        }
    }

    // MARK: - Derived

    private var buckets: [RunSummaryGrouping.Bucket] {
        RunSummaryGrouping.group(coordinator.index.runs, now: now)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func sectionHeader(for section: RunSummaryGrouping.Section) -> some View {
        Text(RunSummaryGrouping.formatSectionHeader(for: section, now: now))
            .vsbCaption()
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
/// inner layout doesn't compete with the `List`-level wiring above and so
/// it gets its own `#Preview` for visual iteration.
private struct RunRow: View {
    let summary: RunSummary

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                // Line 1 — time of day.
                Text(RunSummaryGrouping.formatTimeOfDay(summary.timestamp))
                    .vsbBody(color: VSB.Text.hi)

                // Line 2 — preset pill · branch · short SHA.
                HStack(spacing: 6) {
                    Pill(
                        RunSummaryGrouping.presetPillText(for: summary.preset),
                        style: RunSummaryGrouping.presetPillStyle(for: summary.preset)
                    )
                    Text(summary.branch)
                        .vsbBody(color: VSB.Text.md)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("· \(shortSha(summary.gitSha))")
                        .vsbMonoSha()
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
    /// message". 7 chars is the git-standard short form.
    private func shortSha(_ sha: String) -> String {
        String(sha.prefix(7))
    }
}

// MARK: - Preview

#Preview("RunListSidebar — populated") {
    let store = RunStore(rootURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("RunListSidebarPreview-\(UUID().uuidString)"))
    let coordinator = RunStoreCoordinator(store: store)
    return RunListSidebar(
        coordinator: coordinator,
        selectedRunID: .constant(nil)
    )
    .frame(width: 280, height: 600)
    .background(VSB.Surface.s0)
}
