import SwiftUI
import BenchKit

/// Top-level scene. `NavigationSplitView` with a sidebar (`RunListSidebar`,
/// Item 2) and a detail pane (placeholder until Item 3a lands the
/// `RunSummaryHeader` + `RunDetailView`).
///
/// **Traffic-lights reservation.** macOS draws the Red/Yellow/Green
/// window controls in the top-left of the window. SwiftUI's
/// `NavigationSplitView` automatically reserves space for them in the
/// sidebar's toolbar slot — `RunListSidebar` uses the standard `List` +
/// `.navigationTitle(_:)` pattern and renders correctly with the inset.
struct AppRoot: View {
    @State private var coordinator = RunStoreCoordinator.makeDefault()
    @State private var selectedRunID: String? = nil

    var body: some View {
        NavigationSplitView {
            RunListSidebar(
                coordinator: coordinator,
                selectedRunID: $selectedRunID
            )
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

    // MARK: - Placeholder UI (replaced in Item 3a)

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
