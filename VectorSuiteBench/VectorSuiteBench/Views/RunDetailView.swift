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

    /// Filter state shared with Item 3c's chart. Owned by `RunDetailView`
    /// so swapping runs resets the filter — a filter that survived run
    /// changes would silently drop rows when the user clicks a different
    /// run that doesn't contain the previously-selected impl, which reads
    /// as "the table is broken".
    @State private var filter = CaseTableFilter()

    /// Body view mode. Defaults to `.table` per plan §3b — the
    /// "did my change regress something?" workflow scans the table first.
    @State private var bodyMode: BodyMode = .table

    /// Built once per `runID` change and held in this view so both the
    /// table and the chart pane consume the same row list — locked
    /// cohort seam from Item 3b. The expansion is one-time per run;
    /// re-running it inside each consumer would duplicate work and risk
    /// drift if the builder ever became side-effecting.
    @State private var rows: [CaseRow] = []

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
            bodyToggle
            Divider().background(VSB.Surface.hair)
            switch bodyMode {
            case .table:
                CaseTable(rows: rows, filter: filter)
            case .charts:
                ChartsPane(rows: rows, filter: filter)
            }
        }
        .task(id: document.runMetadata.runID) {
            rows = CaseRowBuilder.build(from: document.cases)
        }
    }

    /// Two-position segmented control between the header and the body.
    /// `Table` default per plan §3b. Sits in its own strip so the
    /// affordance is visible regardless of which mode the body is in.
    private var bodyToggle: some View {
        HStack(spacing: 0) {
            ForEach(BodyMode.allCases) { mode in
                Button {
                    bodyMode = mode
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.iconName)
                            .imageScale(.small)
                        Text(mode.label)
                            .vsbMonoBadge(color: mode == bodyMode ? VSB.Impl.vectorCore : VSB.Text.md)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(mode == bodyMode ? VSB.Impl.vectorCore : VSB.Text.md)
                    .background(mode == bodyMode ? VSB.accentSoft : Color.clear)
                    .overlay(
                        Rectangle()
                            .fill(mode == bodyMode ? VSB.Impl.vectorCore : Color.clear)
                            .frame(height: 1),
                        alignment: .bottom
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .background(VSB.Surface.s0)
    }

    /// Detail-pane body modes. Persisting selection across runs would
    /// only matter if users care — punt to a future preference if it
    /// comes up. For now, every run starts in Table mode.
    private enum BodyMode: String, Identifiable, CaseIterable {
        case table
        case charts

        var id: String { rawValue }

        var label: String {
            switch self {
            case .table:  return "TABLE"
            case .charts: return "CHARTS"
            }
        }

        var iconName: String {
            switch self {
            case .table:  return "tablecells"
            case .charts: return "chart.bar"
            }
        }
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
