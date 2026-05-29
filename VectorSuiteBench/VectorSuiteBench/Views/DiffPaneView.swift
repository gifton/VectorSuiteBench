import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BenchKit

/// Diff-mode body. The "merged delta table" surface called out by locked
/// decision §1.5/4. Replaces the single-run body
/// (`CaseTable` / `ChartsPane`) entirely while `isDiffMode == true`
/// — per user-Q&A choice for Item 2c's "diff entry UX" question.
///
/// **Three end states**, branched off of `DiffSelection.Pairing`:
///   - `.empty` → §1.5/6 empty-state card.
///   - `.crossFingerprint` → §7 refusal banner.
///   - `.valid(baseline, comparison)` → loaded delta table.
///
/// All three keep the diff toolbar (RunPickerView + Export Markdown
/// button) at the top so the user can re-pick without leaving the
/// pane. The Export button is disabled in `.empty` and
/// `.crossFingerprint` — only `.valid` produces something meaningful
/// to export.
struct DiffPaneView: View {

    @Bindable var selection: DiffSelection
    let summaries: [RunSummary]
    let coordinator: RunStoreCoordinator
    let filter: CaseTableFilter

    @State private var loadError: String?
    @State private var loadedDiff: RunDiff?
    @State private var deltaRows: [DeltaRow] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(VSB.Surface.hair)
            body(for: selection.pairing(in: summaries))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSB.Surface.bg)
        .task(id: pairingKey) {
            await reloadDiffIfNeeded()
        }
    }

    /// A stable string key per `(baseline, comparison)` pair. Used to
    /// drive `.task(id:)` so the diff reloads only when the selection
    /// actually changes — re-renders that don't change the pair are
    /// free.
    private var pairingKey: String {
        "\(selection.baselineRunID ?? "_")|\(selection.comparisonRunID ?? "_")"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            RunPickerView(selection: selection, summaries: summaries)
            Spacer(minLength: 0)
            exportMarkdownButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VSB.Surface.s0)
    }

    /// Export Markdown action — lives inside the diff toolbar (per
    /// user-Q&A choice for Item 2c's export-location question) so it
    /// disappears with the diff pane and never appears as orphaned
    /// chrome elsewhere in the app.
    private var exportMarkdownButton: some View {
        Button {
            exportMarkdown()
        } label: {
            Label("Export Markdown", systemImage: "arrow.down.doc")
        }
        .buttonStyle(.borderless)
        .disabled(loadedDiff == nil)
        .help(loadedDiff == nil
              ? "Pick two same-fingerprint runs to enable Markdown export"
              : "Save a Markdown table of the diff (paste into a PR description)")
    }

    // MARK: - Body branch

    @ViewBuilder
    private func body(for pairing: DiffSelection.Pairing) -> some View {
        switch pairing {
        case .empty:
            emptyStateCard
        case .crossFingerprint(let baselineFP, let comparisonFP):
            crossFingerprintBanner(baselineFP: baselineFP, comparisonFP: comparisonFP)
        case .valid:
            validDiffBody
        }
    }

    /// §1.5/6 empty-state card. Centered, mid-prominence — the same
    /// visual language `RunListSidebar`'s "No runs yet" empty state
    /// uses, so the user reads it as a normal "you haven't done X
    /// yet" rather than as an error.
    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1")
                .imageScale(.large)
                .foregroundStyle(VSB.Text.lo)
            Text("Pick a run to compare against")
                .vsbBody(color: VSB.Text.md)
            Text(emptyStateSubtext)
                .vsbMonoSha()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateSubtext: String {
        if DiffSelection.hasComparableRuns(in: summaries) {
            return "Choose a baseline (older) and a comparison (newer) from the pickers above. Same-fingerprint runs only — cross-hardware diffs are refused."
        }
        return "You need at least two runs to compare. Run another preset and the picker will populate."
    }

    /// §7 measurement-integrity refusal. Cross-machine diffs are
    /// misleading enough that this is a hard wall — the user must
    /// pick a same-fingerprint pair to proceed.
    private func crossFingerprintBanner(baselineFP: String, comparisonFP: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.large)
                .foregroundStyle(VSB.Status.fail)
            Text("Cannot compare runs from different hardware fingerprints")
                .vsbBody(color: VSB.Status.fail)
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("Baseline:").vsbMonoSha(color: VSB.Text.dim)
                    Text(baselineFP).vsbMonoSha(color: VSB.Text.hi)
                }
                HStack(spacing: 8) {
                    Text("Comparison:").vsbMonoSha(color: VSB.Text.dim)
                    Text(comparisonFP).vsbMonoSha(color: VSB.Text.hi)
                }
            }
            Text("Re-run both on the same device to enable comparison.")
                .vsbMonoSha()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Loaded-diff body. Three states inside this branch:
    ///   - loading (`loadedDiff == nil && loadError == nil`)
    ///   - load failed (`loadError != nil`)
    ///   - loaded → render DeltaTable
    @ViewBuilder
    private var validDiffBody: some View {
        if let loadError {
            VStack(spacing: 12) {
                Pill("LOAD FAILED", style: .fail, icon: "✕")
                Text(loadError)
                    .vsbBody(color: VSB.Text.md)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadedDiff != nil {
            DeltaTable(rows: deltaRows, filter: filter)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading

    private func reloadDiffIfNeeded() async {
        guard case .valid(let baselineID, let comparisonID) = selection.pairing(in: summaries) else {
            // Pairing not valid — clear any stale diff so the body
            // branch above doesn't render an outdated DeltaTable.
            loadedDiff = nil
            deltaRows = []
            loadError = nil
            return
        }
        loadedDiff = nil
        deltaRows = []
        loadError = nil
        do {
            let baseline = try coordinator.loadRun(id: baselineID)
            let comparison = try coordinator.loadRun(id: comparisonID)
            // `RunDiff.compare(a:b:)` enforces the fingerprint match at
            // the BenchKit layer too, but `.valid` already gate-checked
            // it via DiffSelection.pairing — so this throw is defensive.
            let diff = try RunDiff.compare(a: baseline, b: comparison)
            loadedDiff = diff
            deltaRows = DeltaRowBuilder.build(from: diff)
        } catch {
            loadError = "Couldn't load diff: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    private func exportMarkdown() {
        guard let diff = loadedDiff else { return }
        // `NSSavePanel` is the macOS-native flow per locked plan text.
        // App-modal so the user can't double-fire; default file name
        // baked from the (baseline → comparison) runIDs so paste-ready
        // for a PR description.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = DiffPaneView.defaultExportFilename(
            baselineID: diff.a.runMetadata.runID,
            comparisonID: diff.b.runMetadata.runID
        )
        panel.canCreateDirectories = true
        panel.title = "Export diff as Markdown"
        // beginSheetModal would require a host window we don't easily
        // grab here; runModal is acceptable for a one-shot diff export
        // — it blocks the main run loop only while the panel is up.
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        let markdown = DiffPaneView.markdownExport(for: diff)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Non-fatal — the export window has already closed, so
            // we have nowhere prominent to surface this. Log + drop.
            // A toast/sheet would be over-engineering for an action
            // the user can simply retry.
            print("DiffPaneView: markdown export failed — \(error)")
        }
    }

    /// Default filename baked from the two runIDs. Pure function so
    /// tests pin the format directly.
    static func defaultExportFilename(baselineID: String, comparisonID: String) -> String {
        "diff-\(shortID(baselineID))-vs-\(shortID(comparisonID)).md"
    }

    /// `RunDiff.markdownTable()` produces the body; this wrapper adds a
    /// small header with the two runIDs and fingerprint so the exported
    /// file is self-describing when pasted into a PR. Pure function;
    /// tested by `DiffMarkdownExportTests`.
    static func markdownExport(for diff: RunDiff) -> String {
        let baseline = diff.a.runMetadata
        let comparison = diff.b.runMetadata
        var lines: [String] = []
        lines.append("# VectorSuiteBench diff")
        lines.append("")
        lines.append("- **Baseline**: `\(baseline.runID)`  (\(baseline.hardware.fingerprint))")
        lines.append("- **Comparison**: `\(comparison.runID)`  (\(comparison.hardware.fingerprint))")
        lines.append("")
        lines.append(diff.markdownTable())
        return lines.joined(separator: "\n") + "\n"
    }

    /// Compact a runID to its leading `yyyy-MM-dd` + sha7 chunk if the
    /// store's filename convention applies, else the first 24 chars.
    /// Used only for the export filename default — purely cosmetic.
    private static func shortID(_ runID: String) -> String {
        // Run IDs follow `YYYY-MM-DDTHH-mm-ssZ__sha__preset`; the
        // double-underscore split gets us "YYYY-MM-DDTHH-mm-ssZ" then
        // "sha". Trim each to keep the filename readable.
        let parts = runID.split(separator: "_", omittingEmptySubsequences: true)
        if let datePart = parts.first {
            let date = String(datePart.prefix(10))
            if parts.count >= 2 {
                let sha = String(parts[1].prefix(7))
                return "\(date)-\(sha)"
            }
            return String(date)
        }
        return String(runID.prefix(24))
    }
}
