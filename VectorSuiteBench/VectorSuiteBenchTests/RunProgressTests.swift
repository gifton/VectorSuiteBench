import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// `RunProgress` polls a run's `cases/` directory to count completed cases
/// while a `RunController` is mid-flight. Tests use a synthetic on-disk
/// run dir + a tight (50 ms) poll so the watcher exercises promptly.
@Suite("RunProgress")
@MainActor
struct RunProgressTests {

    @Test("scan() counts JSON files in the run's cases directory")
    func scanCounts() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let casesDir = store.casesDirectory(for: "scan-run")
        try FileManager.default.createDirectory(at: casesDir, withIntermediateDirectories: true)

        let progress = RunProgress(runID: "scan-run", totalCount: 5, store: store)
        progress.scan()
        #expect(progress.completedCount == 0)

        for i in 0..<3 {
            let url = casesDir.appendingPathComponent("case-\(i).json")
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        }
        progress.scan()
        #expect(progress.completedCount == 3)
    }

    @Test("scan() ignores non-JSON files")
    func ignoresNonJSON() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let casesDir = store.casesDirectory(for: "filter-run")
        try FileManager.default.createDirectory(at: casesDir, withIntermediateDirectories: true)

        try "ok".write(
            to: casesDir.appendingPathComponent("good.json"),
            atomically: true, encoding: .utf8
        )
        try "tmp".write(
            to: casesDir.appendingPathComponent("partial.tmp"),
            atomically: true, encoding: .utf8
        )
        try "log".write(
            to: casesDir.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8
        )

        let progress = RunProgress(runID: "filter-run", totalCount: 5, store: store)
        progress.scan()
        #expect(progress.completedCount == 1)
    }

    @Test("Polling picks up new case files as they appear")
    func pollingDetectsNewFiles() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let casesDir = store.casesDirectory(for: "poll-run")
        try FileManager.default.createDirectory(at: casesDir, withIntermediateDirectories: true)

        let progress = RunProgress(
            runID: "poll-run", totalCount: 5, store: store, pollInterval: .milliseconds(50)
        )
        progress.start()
        #expect(progress.isRunning == true)
        try await Task.sleep(for: .milliseconds(75))
        #expect(progress.completedCount == 0)

        try "{}".write(
            to: casesDir.appendingPathComponent("a.json"),
            atomically: true, encoding: .utf8
        )
        try await Task.sleep(for: .milliseconds(150))
        #expect(progress.completedCount == 1)

        progress.stop()
        #expect(progress.isRunning == false)
    }

    @Test("fraction returns 0 when totalCount is 0 (no divide-by-zero)")
    func fractionGuardsZeroTotal() {
        let tmp = try! makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let progress = RunProgress(runID: "zero-run", totalCount: 0, store: store)
        #expect(progress.fraction == 0)
    }

    @Test("fraction tracks completedCount / totalCount")
    func fractionTracksProgress() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let casesDir = store.casesDirectory(for: "frac-run")
        try FileManager.default.createDirectory(at: casesDir, withIntermediateDirectories: true)

        let progress = RunProgress(runID: "frac-run", totalCount: 4, store: store)
        for i in 0..<2 {
            try "{}".write(
                to: casesDir.appendingPathComponent("\(i).json"),
                atomically: true, encoding: .utf8
            )
        }
        progress.scan()
        #expect(progress.fraction == 0.5)
    }

    @Test("setCurrentCase updates the observable property")
    func setCurrentCaseUpdates() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let progress = RunProgress(runID: "cur-run", totalCount: 5, store: store)
        #expect(progress.currentCase == nil)

        let params = try CanonicalParams([:], impl: .naive, op: .dot, shape: .vector(n: 64))
        let id = WorkloadID(
            op: .dot, impl: .naive, implClass: .standard,
            dtype: .f32, shape: .vector(n: 64), params: params
        )
        progress.setCurrentCase(id)
        #expect(progress.currentCase == id)

        progress.setCurrentCase(nil)
        #expect(progress.currentCase == nil)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunProgressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
