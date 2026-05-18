import SwiftUI
import BenchKit

/// Container view for a selected run. Wraps `RunSummaryHeader` + a body
/// placeholder. The body lights up in subsequent sub-items:
///
/// - Item 3b → `CaseTable` (the 8-column data table).
/// - Item 3c → `ThroughputBarChart` + a Table ⟷ Charts segmented control
///             that swaps the body.
/// - Item 3d → `⇋ Compare` toolbar button (reserved, disabled in 2.1).
///
/// Loading happens lazily on `runID` changes — `RunStoreCoordinator`'s
/// own cache short-circuits repeat loads for the same id.
///
/// **Error path.** `loadRun(id:)` throws when the runID isn't on disk
/// (deleted while selected, file IO error, schema migration failure).
/// We surface a small inline error block rather than crashing the
/// detail pane; the sidebar's selection remains intact so the user
/// can pick a different run.
struct RunDetailView: View {
    let runID: String
    let coordinator: RunStoreCoordinator
    let now: Date

    /// Cached document for the current `runID`. Re-loaded when `runID`
    /// changes (via `.task(id:)`). Optional because the load can fail
    /// or the runID can change mid-load.
    @State private var document: RunDocument?
    @State private var loadError: String?

    init(runID: String, coordinator: RunStoreCoordinator, now: Date = Date()) {
        self.runID = runID
        self.coordinator = coordinator
        self.now = now
    }

    var body: some View {
        Group {
            if let document {
                content(document: document)
            } else if let loadError {
                errorBlock(message: loadError)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSB.Surface.bg)
        .task(id: runID) {
            await loadRun()
        }
    }

    // MARK: - Subviews

    private func content(document: RunDocument) -> some View {
        VStack(spacing: 0) {
            RunSummaryHeader(document: document, now: now)
            bodyPlaceholder
        }
    }

    private var bodyPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Data table").vsbCaption()
            Text("Coming next").vsbBody(color: VSB.Text.md)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBlock(message: String) -> some View {
        VStack(spacing: 12) {
            Pill("LOAD FAILED", style: .fail, icon: "✕")
            Text(message)
                .vsbBody(color: VSB.Text.md)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadRun() async {
        // Clear stale state if the runID just changed; we'll set the new
        // one below.
        if document?.runMetadata.runID != runID {
            document = nil
            loadError = nil
        }
        do {
            let doc = try coordinator.loadRun(id: runID)
            document = doc
            loadError = nil
        } catch {
            document = nil
            loadError = "Couldn't load run \(runID): \(error.localizedDescription)"
        }
    }
}
