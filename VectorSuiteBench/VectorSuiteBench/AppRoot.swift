import SwiftUI
import BenchKit

/// Top-level scene. `NavigationSplitView` with a sidebar (Run History,
/// implemented as a placeholder until Item 2 lands the real
/// `RunListSidebar`) and a detail pane (placeholder until Item 3a lands
/// the `RunSummaryHeader` + `RunDetailView`).
///
/// **Traffic-lights reservation.** macOS draws the Red/Yellow/Green
/// window controls in the top-left of the window. SwiftUI's
/// `NavigationSplitView` automatically reserves space for them in the
/// sidebar's toolbar slot — sidebar content using the standard `List` +
/// `.navigationTitle(_:)` pattern (Item 2) renders correctly. The
/// placeholder content here uses `safeAreaInset(edge: .top)` only when
/// needed; the simple VStack starts below the system-provided inset.
struct AppRoot: View {
    @State private var coordinator = RunStoreCoordinator.makeDefault()
    @State private var selectedRunID: String? = nil

    var body: some View {
        NavigationSplitView {
            sidebarPlaceholder
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detailPlaceholder
        }
        .onAppear {
            coordinator.startWatching()
        }
        .onDisappear {
            coordinator.stopWatching()
        }
        .environment(coordinator)
    }

    // MARK: - Placeholder UI (replaced in Items 2 and 3a)

    private var sidebarPlaceholder: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run History").vsbCaption()

            if coordinator.index.runs.isEmpty {
                Text("No runs yet.")
                    .vsbBody(color: VSB.Text.md)
                Text("Drop a smoke run on disk with `swift run vsb-run --preset smoke` or wait for Item 4c's in-app New Run sheet.")
                    .vsbMonoSha()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(coordinator.index.runs.count) run\(coordinator.index.runs.count == 1 ? "" : "s") on disk")
                    .vsbBody(color: VSB.Text.md)
                // Temporary tappable list so we can poke `selectedRunID`
                // before Item 2 lands. Removed in Item 2.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.index.runs, id: \.runID) { summary in
                            Button {
                                selectedRunID = summary.runID
                            } label: {
                                HStack(spacing: 8) {
                                    Text(summary.preset.uppercased())
                                        .vsbMonoBadge(
                                            color: selectedRunID == summary.runID
                                                ? VSB.Impl.vectorCore
                                                : VSB.Text.md
                                        )
                                    Text(summary.gitSha.prefix(7))
                                        .vsbMonoSha()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VSB.Surface.s0)
    }

    private var detailPlaceholder: some View {
        VStack(spacing: 12) {
            Text("Detail").vsbCaption()
            Spacer()
            if let id = selectedRunID {
                VStack(spacing: 6) {
                    Text("Selected run").vsbCaption(color: VSB.Text.md)
                    Text(id).vsbMonoSha(color: VSB.Text.hi)
                    if let doc = try? coordinator.loadRun(id: id) {
                        Text("\(doc.cases.count) case\(doc.cases.count == 1 ? "" : "s")")
                            .vsbBody(color: VSB.Text.md)
                    }
                }
            } else {
                Text("Select a run").vsbBody(color: VSB.Text.md)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSB.Surface.bg)
    }
}

#Preview("AppRoot — empty store") {
    AppRoot()
        .frame(width: 1100, height: 720)
}
