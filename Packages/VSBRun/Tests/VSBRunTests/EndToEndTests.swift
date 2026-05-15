import Testing
import Foundation
import BenchKit

/// End-to-end smoke tests for `vsb-run`. Spawn the CLI binary via
/// `Process.run`, verify exit codes, then load the produced `RunDocument`
/// off disk via `RunStore` and validate shape.
///
/// **Binary location**: SwiftPM puts the executable at
/// `<package-root>/.build/<config>/vsb-run`. We walk up from `#filePath`
/// (this test file) to find the package root, then check both `debug` and
/// `release` paths so the test works under either build mode.
@Suite("vsb-run end-to-end")
struct EndToEndTests {

    @Test("Smoke preset filtered to naive-dot produces a valid RunDocument")
    func smokeRunHappyPath() async throws {
        let binary = try cliBinaryURL()
        let outDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--preset", "smoke",
            "--filter", "dot",
            "--filter", "naive",
            "--output", outDir.path,
            "--skip-peaks",
            "--allow-debug-builds",
            "--quiet",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
        #expect(
            process.terminationStatus == 0,
            Comment(rawValue: "vsb-run exit \(process.terminationStatus); stderr: \(stderrStr)")
        )

        // Load the produced RunDocument and check shape.
        let store = RunStore(rootURL: outDir)
        let index = try store.loadIndex()
        #expect(!index.runs.isEmpty, "index.json should contain ≥1 run summary")
        let summary = try #require(index.runs.first)
        let doc = try store.loadRun(runID: summary.runID)

        // 5 cases (naive × 5 sizes 64/256/512/1536/4096); all should verify.
        #expect(doc.cases.count == 5, "expected 5 naive-dot cases, got \(doc.cases.count)")
        for c in doc.cases {
            switch c.verification {
            case .verified, .unverifiable:
                continue
            case .failed(let maxUlp, let window, _):
                Issue.record(Comment(rawValue: "\(c.id.canonicalString) failed: ulp=\(maxUlp) window=\(window)"))
            }
        }

        // Manifest + samples.csv on disk.
        let manifestURL = store.manifestURL(for: summary.runID)
        let csvURL = store.samplesCSVURL(for: summary.runID)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: csvURL.path))

        // CSV has the versioned header + at least one data row per case.
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("# schemaVersion: \(SchemaVersion.current.description)"))
        let dataLines = csv.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(dataLines.count >= 5, "expected ≥5 CSV data rows (one per case in smoke mode)")
    }

    @Test("Unknown filter produces empty registry and exits 2")
    func unknownFilterExits2() async throws {
        let binary = try cliBinaryURL()
        let outDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--preset", "smoke",
            "--filter", "this-op-does-not-exist",
            "--output", outDir.path,
            "--skip-peaks",
            "--allow-debug-builds",
            "--quiet",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // We use exit code 2 for "filter matched zero cases".
        #expect(process.terminationStatus == 2,
                Comment(rawValue: "expected exit 2 for empty registry; got \(process.terminationStatus)"))
    }

    @Test("Dry-run prints the plan and exits cleanly")
    func dryRun() async throws {
        let binary = try cliBinaryURL()
        let outDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outDir) }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--preset", "smoke",
            "--filter", "dot",
            "--filter", "naive",
            "--output", outDir.path,
            "--dry-run",
            "--allow-debug-builds",
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(out.contains("dry-run"))
        #expect(out.contains("dot|naive"))
        // Dry-run must NOT create any files in the output directory.
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        #expect(listing.isEmpty, "dry-run must not touch the output dir; saw \(listing)")
    }

    // MARK: - Helpers

    /// Locate the `vsb-run` binary built by SwiftPM. Walks up from this
    /// test file's path to the package root, then checks both
    /// `.build/debug` and `.build/release`.
    private func cliBinaryURL() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()       // VSBRunTests/
            .deletingLastPathComponent()       // Tests/
            .deletingLastPathComponent()       // VSBRun/

        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/vsb-run"),
            packageRoot.appendingPathComponent(".build/release/vsb-run"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/vsb-run"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/release/vsb-run"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw FixtureError.binaryNotFound(searched: candidates.map(\.path))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VSBRunE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum FixtureError: Error, CustomStringConvertible {
        case binaryNotFound(searched: [String])
        var description: String {
            switch self {
            case .binaryNotFound(let paths):
                return "vsb-run binary not found in any of: \(paths.joined(separator: "\n  "))"
            }
        }
    }
}
