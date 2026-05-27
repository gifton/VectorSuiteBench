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

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            newRunButton
            compareButton
            exportButton
            calibrateButton
        }
        ToolbarItem(placement: .primaryAction) {
            LiveStateChip(state: liveState, hardware: hardware)
        }
    }

    // MARK: - Buttons

    /// **`+ New Run`** — wired in Item 4a. Primary action of the entire
    /// app: opens a sheet to configure and start a benchmark run.
    private var newRunButton: some View {
        Button {
            // Wired in Item 4a — opens RunConfigView modal.
        } label: {
            Label("New Run", systemImage: "plus")
        }
        .disabled(true)
        .help("Configure and start a new benchmark run (coming in Item 4a)")
        .keyboardShortcut("n", modifiers: .command)
    }

    /// **`⇋ Compare`** — wired in Phase 2.2. Diff two runs side-by-side
    /// via the merged delta-table visual (locked decision §1.5/4).
    /// `BenchKit.RunDiff` is already implemented; 2.2 just adds the
    /// picker UI + diff view.
    private var compareButton: some View {
        Button {
            // Wired in Phase 2.2 — opens diff picker.
        } label: {
            Label("Compare", systemImage: "arrow.left.arrow.right")
        }
        .disabled(true)
        .help("Diff two runs side-by-side (coming in Phase 2.2)")
        .keyboardShortcut("c", modifiers: [.command, .shift])
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
