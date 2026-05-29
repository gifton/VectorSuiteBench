import Testing
import Foundation
import BenchKit
@testable import VectorSuiteBench

/// `DiffPaneView.markdownExport(for:)` is the wrapper that turns a
/// `RunDiff` into the file body the user pastes into a PR description.
/// It composes `RunDiff.markdownTable()` (already tested in BenchKit's
/// own suite) with a small "what runs am I looking at?" header so the
/// exported file is self-describing.
///
/// Tests focus on the wrapper, not the table internals (those are
/// BenchKit's job):
/// - header carries both runIDs + fingerprints in a stable shape
/// - body table is appended verbatim from `RunDiff.markdownTable()`
/// - default export filename derives a date+sha7 stub for each side
@MainActor
@Suite("DiffPaneView.markdownExport")
struct DiffMarkdownExportTests {

    @Test("Exported Markdown carries a self-describing header with both runIDs and fingerprints")
    func headerCarriesRunContext() throws {
        let baseline = makeDocument(runID: "2026-05-26T22-13-00Z__abc1234__standard")
        let comparison = makeDocument(runID: "2026-05-28T22-13-00Z__def5678__standard")
        // Same hardware inventory on both sides → same fingerprint, so
        // RunDiff.compare(a:b:) won't refuse. Assertions cross-check
        // against the computed fingerprint rather than a hardcoded
        // string — HardwareInventory.fingerprint is a deterministic
        // hash of its fields, not user-supplied.
        let diff = try RunDiff.compare(a: baseline, b: comparison)
        let md = DiffPaneView.markdownExport(for: diff)
        let fp = baseline.runMetadata.hardware.fingerprint

        #expect(md.contains("# VectorSuiteBench diff"))
        #expect(md.contains("Baseline"))
        #expect(md.contains("Comparison"))
        #expect(md.contains("2026-05-26T22-13-00Z__abc1234__standard"),
                "baseline runID must appear verbatim in header so the exported file is self-describing")
        #expect(md.contains("2026-05-28T22-13-00Z__def5678__standard"),
                "comparison runID must appear verbatim in header")
        #expect(md.contains("(\(fp))"),
                Comment(rawValue: "fingerprint '\(fp)' must appear next to each runID so the reader can confirm same-hardware diff"))
    }

    @Test("Exported Markdown appends RunDiff.markdownTable() verbatim")
    func bodyTableMatchesRunDiff() throws {
        let baseline = makeDocument(runID: "old")
        let comparison = makeDocument(runID: "new")
        let diff = try RunDiff.compare(a: baseline, b: comparison)

        let md = DiffPaneView.markdownExport(for: diff)
        let body = diff.markdownTable()
        // The wrapper appends the table verbatim — we don't reformat
        // the BenchKit-owned table here, so a regression in either
        // place shows up as a substring mismatch.
        #expect(md.contains(body),
                "wrapper must concat RunDiff.markdownTable() verbatim — reformatting belongs to BenchKit")
    }

    @Test("Default export filename derives date+sha7 from each runID")
    func defaultFilenameStub() {
        let name = DiffPaneView.defaultExportFilename(
            baselineID: "2026-05-26T22-13-00Z__abc1234__standard",
            comparisonID: "2026-05-28T22-13-00Z__def5678__standard"
        )
        // `diff-{baseDateSha}-vs-{compDateSha}.md` — readable in
        // Finder, stable across re-exports of the same pair.
        #expect(name == "diff-2026-05-26-abc1234-vs-2026-05-28-def5678.md",
                Comment(rawValue: "expected canonical date+sha7 stubbing; got \(name)"))
    }

    // MARK: - Fixtures

    private func makeDocument(runID: String) -> RunDocument {
        let metadata = RunMetadata(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            preset: .smoke,
            git: GitProvenance(sha: "abc1234", branch: "main", dirty: false),
            build: BuildProvenance.probe(),
            hardware: HardwareInventory(
                chip: "Apple M3 Max",
                pCoreCount: 12, eCoreCount: 4,
                gpuCoreCount: 30, memoryGB: 36,
                osVersion: "26.2", xcodeBuild: "26B12",
                swiftVersion: "6.0+"
            ),
            linkedLibraryVersions: [:],
            fpcrAtStart: 0,
            lowPowerModeEnabled: false,
            timerOverheadNanos: 41.6,
            harnessOverheadNanos: 5.0,
            seedTableVersion: SeedTable.version
        )
        return RunDocument(runMetadata: metadata, cases: [])
    }
}
