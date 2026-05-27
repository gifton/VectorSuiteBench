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
    @State private var coordinator: RunStoreCoordinator
    @State private var selectedRunID: String? = nil
    @State private var calibration = CalibrationStatus()
    /// New Run sheet presentation flag. Driven by the toolbar's
    /// `+ New Run` button; `RunConfigView` calls `dismiss()` to flip
    /// it back. Owned here (not inside `AppToolbar`) because the
    /// toolbar is `ToolbarContent` and can't host a `.sheet(_:)`
    /// modifier.
    @State private var isNewRunSheetPresented = false
    /// In-flight benchmark orchestrator. Shares the coordinator's
    /// `RunStore` so the run's output lands in the same directory the
    /// sidebar polls. State drives the toolbar's `LiveStateChip` color
    /// + the `+ New Run` ↔ `◼ Cancel` button swap.
    @State private var invocation: RunInvocation
    private let hardware: HardwareInventory = HardwareInventory.probe()

    /// All `@State` properties without property-declaration defaults are
    /// initialized here so `RunStoreCoordinator.makeDefault()` runs
    /// exactly once. Earlier the property declaration had a default
    /// initializer AND `init()` reassigned `_coordinator`, which fired
    /// `makeDefault()` twice per AppRoot construction (the default ran
    /// first, then was discarded). `makeDefault()` opens a RunStore and
    /// scans index.json off disk; not free.
    init() {
        let coordinator = RunStoreCoordinator.makeDefault()
        _coordinator = State(initialValue: coordinator)
        _invocation = State(initialValue: RunInvocation(store: coordinator.store))
    }

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
        .toolbar {
            // Window-level chrome (design doc §04 "Toolbar"). `+ New
            // Run` opens the modal (Item 4a); `◼ Cancel` replaces it
            // while a run is in flight (Item 4c). `liveState` is now
            // driven by `RunInvocation` — green idle, blue running,
            // red on failure.
            AppToolbar(
                hardware: hardware,
                liveState: invocation.liveState,
                onNewRun: { isNewRunSheetPresented = true },
                onCancel: { invocation.cancel() }
            )
        }
        .sheet(isPresented: $isNewRunSheetPresented) {
            // `RunConfigView` dismisses itself via `@Environment(\.dismiss)`,
            // which auto-flips this binding to false through the sheet
            // presentation mechanism. The `invocation` argument
            // outlives the sheet — Start dismisses the sheet but the
            // run keeps executing under `invocation`'s Task.
            RunConfigView(invocation: invocation)
        }
    }

    // MARK: - Detail routing

    @ViewBuilder
    private var detailPane: some View {
        if coordinator.peaksExist(for: hardware) {
            runDetailOrHint
        } else {
            FirstLaunchView(
                hardware: hardware,
                store: coordinator.store,
                calibration: calibration
            )
        }
    }

    // MARK: - Run-detail routing

    /// Shown when peaks exist and a sidebar row is selected. The "no
    /// selection" hint is the empty state before any row is clicked;
    /// `RunDetailView` is the real surface from Item 3a onward.
    @ViewBuilder
    private var runDetailOrHint: some View {
        if let id = selectedRunID {
            RunDetailView(runID: id, coordinator: coordinator)
        } else {
            VStack(spacing: 8) {
                Text("Select a run").vsbBody(color: VSB.Text.md)
                Text("Pick a row from the sidebar to inspect its summary, table, and charts.")
                    .vsbMonoSha()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VSB.Surface.bg)
        }
    }
}

#Preview("AppRoot — empty store") {
    AppRoot()
        .frame(width: 1100, height: 720)
}
