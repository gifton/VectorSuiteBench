import SwiftUI
import BenchKit

/// Top-level scene. `NavigationSplitView` with a sidebar (`RunListSidebar`,
/// Item 2) and a detail pane that switches between the first-launch
/// calibration empty state (Item 5) and the run-detail placeholder
/// (replaced in Item 3a).
///
/// **Detail routing.** If `coordinator.peaksExist(for: hardware)` is
/// false, the detail pane renders `FirstLaunchView` so the user calibrates
/// before doing anything else. Once peaks land, the next body invocation
/// — triggered by `CalibrationStatus.phase` flipping to `.complete` —
/// re-checks `peaksExist`, returns true, and the detail swaps in. No
/// explicit notification plumbing required; the Observation framework
/// re-evaluates body when any observed property changes.
///
/// **Hardware fingerprint** is probed once at init and held for the
/// lifetime of the scene. Recomputing per-body would be wasteful, and a
/// hardware change while the app is open (dual-boot? hot-swap CPU?) is
/// out of scope for 2.1.
///
/// **Traffic-lights reservation.** macOS draws the Red/Yellow/Green
/// window controls in the top-left of the window. SwiftUI's
/// `NavigationSplitView` automatically reserves space for them in the
/// sidebar's toolbar slot — `RunListSidebar` uses the standard `List` +
/// `.navigationTitle(_:)` pattern and renders correctly with the inset.
struct AppRoot: View {
    @State private var coordinator = RunStoreCoordinator.makeDefault()
    @State private var selectedRunID: String? = nil
    @State private var calibration = CalibrationStatus()
    private let hardware: HardwareInventory = HardwareInventory.probe()

    var body: some View {
        NavigationSplitView {
            RunListSidebar(
                summaries: coordinator.index.runs,
                selection: $selectedRunID
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detailPane
        }
        .onAppear {
            coordinator.startWatching()
        }
        .onDisappear {
            coordinator.stopWatching()
        }
        .environment(coordinator)
    }

    // MARK: - Detail routing

    @ViewBuilder
    private var detailPane: some View {
        if coordinator.peaksExist(for: hardware) {
            detailPlaceholder
        } else {
            FirstLaunchView(
                hardware: hardware,
                store: coordinator.store,
                calibration: calibration
            )
        }
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
