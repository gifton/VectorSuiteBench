import SwiftUI
import BenchKit

/// Window-level toolbar — the "Standard macOS chrome" called out in
/// design doc §04. Four primary buttons on the trailing edge plus the
/// `LiveStateChip` showing harness liveness + hardware.
///
/// **Scope in 3d.** All four buttons are placeholder chrome: visually
/// present, disabled, with `.help(_:)` tooltips explaining what they
/// will do and which phase wires them. Reserves the chrome real estate
/// per plan §3d so 4a (New Run modal), 2.2 (Compare mode), and later
/// items don't have to re-shuffle the layout. Keyboard shortcuts are
/// declared even on disabled buttons — SwiftUI suppresses the action
/// while `.disabled(true)` is in effect, but the shortcut is "claimed"
/// so it can't be accidentally bound elsewhere; when an item lands,
/// flipping `.disabled(false)` activates the same shortcut on the same
/// button without retraining users.
///
/// **Phase mapping** (kept here for review-doc traceability):
/// - `+ New Run` (⌘N)     → Item 4a
/// - `⇋ Compare` (⌘⇧C)    → Phase 2.2 (per plan §6 — locked decision §1.5/4 pins the visual)
/// - `↓ Export CSV` (⌘E)  → Phase 2.2 (CSVExporter exists in BenchKit; just needs UI invocation)
/// - `⌖ Calibrate`        → Future. Item 5 covered first-launch calibration; manual re-calibration is unplanned.
///
/// **Placement.** Four buttons in a `ToolbarItemGroup(.primaryAction)`
/// land on the trailing edge of the window's titlebar; the
/// `LiveStateChip` is a separate `ToolbarItem(.primaryAction)` so it
/// flows after the buttons and reads as a status-line tail. macOS will
/// collapse to overflow menus if the window is narrower than the
/// content — native behavior, no manual handling required.
struct AppToolbar: ToolbarContent {

    let hardware: HardwareInventory
    let liveState: LiveState
    /// Action for the `+ New Run` button. Wired by `AppRoot` to flip
    /// the sheet-presented state.
    let onNewRun: () -> Void
    /// Action for the `◼ Cancel` button (replaces `+ New Run` while a
    /// run is in flight, per locked decision §4c). Wired by `AppRoot`
    /// to invoke `RunInvocation.cancel()`.
    let onCancel: () -> Void
    /// Diff-mode flag — true while `RunDetailView` is showing
    /// `DiffPaneView`. Drives the `⇋ Compare` button's
    /// pressed-state styling.
    let isDiffMode: Bool
    /// Action for the `⇋ Compare` button. Wired by `AppRoot` to enter
    /// or leave Diff mode (Item 2c).
    let onToggleDiff: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            primaryActionButton
            compareButton
            exportButton
            calibrateButton
        }
        ToolbarItem(placement: .primaryAction) {
            LiveStateChip(state: liveState, hardware: hardware)
        }
    }

    // MARK: - Primary action (New Run / Cancel swap)

    /// `+ New Run` when idle / failed; `◼ Cancel` when a run is in
    /// flight (per locked decision §4c — same toolbar position, same
    /// `⌘.` cancel convention swapping for `⌘N`). The disabled-failed
    /// state still shows New Run so the user can retry.
    @ViewBuilder
    private var primaryActionButton: some View {
        if liveState == .running {
            cancelButton
        } else {
            newRunButton
        }
    }

    /// **`+ New Run`**: opens the `RunConfigView` sheet to configure a
    /// benchmark run.
    private var newRunButton: some View {
        Button(action: onNewRun) {
            Label("New Run", systemImage: "plus")
        }
        .help("Configure and start a new benchmark run")
        .keyboardShortcut("n", modifiers: .command)
    }

    /// **`◼ Cancel`**: cooperatively cancels the in-flight run via the
    /// `CancellationToken` plumbed through `RunInvocation`. Per spec
    /// §8, a cancelled run produces a valid partial `RunDocument` on
    /// disk — the sidebar still picks it up.
    private var cancelButton: some View {
        Button(action: onCancel) {
            Label("Cancel", systemImage: "stop.fill")
        }
        .help("Cancel the in-flight run (produces a valid partial document on disk)")
        .keyboardShortcut(".", modifiers: .command)
    }

    /// **`⇋ Compare`** — toggles `RunDetailView` between single-run
    /// mode and Diff mode. Entering Diff mode auto-fills the
    /// `DiffSelection`'s baseline as the next-older sibling of the
    /// currently selected run (§1.5/5 + Item 2a Q&A). Click again
    /// to exit. Enabled in every state — even with 0 or 1 runs, per
    /// Item 2c's "no-comparable-runs" Q&A: a click enters Diff mode
    /// and the body renders the §1.5/6 empty-state card. Discovers
    /// the feature for new users before they have enough data for it.
    private var compareButton: some View {
        Button(action: onToggleDiff) {
            Label("Compare", systemImage: "arrow.left.arrow.right")
        }
        .help(isDiffMode
              ? "Exit Diff mode (return to single-run view)"
              : "Diff two runs side-by-side")
        .keyboardShortcut("c", modifiers: [.command, .shift])
        // Subtle pressed-state visual when active. SwiftUI's toolbar
        // doesn't surface a "pressed" affordance on standard buttons,
        // so we layer a faint accent tint on the label.
        .foregroundStyle(isDiffMode ? VSB.Impl.vectorCore : VSB.Text.hi)
    }

    /// **`↓ Export CSV`** — wired in Phase 2.2 alongside Compare.
    /// `BenchKit.CSVExporter` writes the canonical schema; the UI just
    /// needs a save-panel invocation.
    private var exportButton: some View {
        Button {
            // Wired in Phase 2.2 — invokes NSSavePanel + CSVExporter.
        } label: {
            Label("Export CSV", systemImage: "square.and.arrow.down")
        }
        .disabled(true)
        .help("Export the selected run as CSV (coming in Phase 2.2)")
        .keyboardShortcut("e", modifiers: .command)
    }

    /// **`⌖ Calibrate`** — re-measures hardware peaks (compute + bandwidth)
    /// for the current fingerprint. Item 5 implemented the first-launch
    /// calibration flow; this button would re-invoke it on demand. No
    /// item currently scheduled; deferred until a user asks for manual
    /// re-calibration.
    ///
    /// **No keyboard shortcut.** Re-calibration is a rare deliberate
    /// action; muscle-memory shortcuts here would risk an accidental
    /// 30-second peak-measurement run mid-session.
    private var calibrateButton: some View {
        Button {
            // Wired in a future item — re-runs PeakMeasurement.
        } label: {
            Label("Calibrate", systemImage: "scope")
        }
        .disabled(true)
        .help("Re-measure hardware peaks (manual re-calibration coming soon)")
    }
}
