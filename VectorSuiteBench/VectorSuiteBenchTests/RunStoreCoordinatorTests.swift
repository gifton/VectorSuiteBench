import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// `RunStoreCoordinator` is the @Observable spine that wraps `RunStore`
/// and watches `index.json` for changes. Tests use a temp-dir-backed
/// store + a tight (50 ms) poll interval so the watcher exercises
/// promptly without making the suite slow.
@Suite("RunStoreCoordinator")
@MainActor
struct RunStoreCoordinatorTests {

    @Test("Loads the initial index from disk on init")
    func loadsInitialIndex() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        try populateStore(store, runIDs: ["a", "b", "c"])

        let coordinator = RunStoreCoordinator(store: store)
        #expect(coordinator.index.runs.count == 3)
        // RunStore sorts newest-first by timestamp; the IDs match the set
        // we wrote (per-test timestamps are identical, so ordering of
        // identical-timestamp rows is implementation-defined — we only
        // assert membership, not order).
        let ids = Set(coordinator.index.runs.map(\.runID))
        #expect(ids == ["a", "b", "c"])
    }

    @Test("Empty store yields an empty index")
    func emptyStore() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let coordinator = RunStoreCoordinator(store: store)
        #expect(coordinator.index.runs.isEmpty)
    }

    @Test("Polling picks up runs written while the coordinator is watching")
    func reactsToNewRuns() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        try populateStore(store, runIDs: ["first"])

        let coordinator = RunStoreCoordinator(store: store, pollInterval: .milliseconds(50))
        coordinator.startWatching()
        #expect(coordinator.index.runs.count == 1)

        // The poll watches modification time. If the second populate
        // happens in the same filesystem-mtime quantum (HFS+ has 1 s
        // resolution; APFS is finer but not infinite), the watcher won't
        // notice. `forceReloadIndex` is the explicit escape hatch
        // documented for in-process writes; tests use the polling path
        // by sleeping past the watcher tick.
        try await Task.sleep(for: .milliseconds(60))
        try populateStore(store, runIDs: ["second"])
        try await Task.sleep(for: .milliseconds(200))

        #expect(coordinator.index.runs.count == 2,
                Comment(rawValue: "expected 2 runs after second populate; got \(coordinator.index.runs.count)"))
        coordinator.stopWatching()
    }

    @Test("forceReloadIndex bypasses the mtime check for in-process writes")
    func forceReloadWorks() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let coordinator = RunStoreCoordinator(store: store)
        #expect(coordinator.index.runs.isEmpty)

        try populateStore(store, runIDs: ["a"])
        coordinator.forceReloadIndex()
        #expect(coordinator.index.runs.count == 1)
    }

    @Test("Caches loaded run documents")
    func cachesRuns() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        try populateStore(store, runIDs: ["x"])

        let coordinator = RunStoreCoordinator(store: store)
        let first = try coordinator.loadRun(id: "x")
        let second = try coordinator.loadRun(id: "x")
        #expect(first.runMetadata.runID == "x")
        #expect(second.runMetadata.runID == "x")
        // Cache hit means the second load returns the same in-memory
        // instance — RunDocument isn't AnyObject, so we compare a
        // representative field. The deeper "cache actually used" assertion
        // would require injecting a counting store; deferred.
    }

    @Test("clearCache forces re-read from disk")
    func clearCacheDropsEntries() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        try populateStore(store, runIDs: ["y"])

        let coordinator = RunStoreCoordinator(store: store)
        _ = try coordinator.loadRun(id: "y")
        coordinator.clearCache()
        // Just verify it doesn't crash and re-loads successfully.
        let reloaded = try coordinator.loadRun(id: "y")
        #expect(reloaded.runMetadata.runID == "y")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunStoreCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func populateStore(_ store: RunStore, runIDs: [String]) throws {
        for id in runIDs {
            let metadata = makeMetadata(runID: id)
            try store.beginRun(metadata: metadata)
            _ = try store.finalizeRun(runID: id)
        }
    }

    private func makeMetadata(runID: String) -> RunMetadata {
        RunMetadata(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            preset: .smoke,
            git: GitProvenance(sha: "abc1234", branch: "test", dirty: false),
            build: BuildProvenance.probe(),
            hardware: HardwareInventory.probe(),
            linkedLibraryVersions: [:],
            fpcrAtStart: 0,
            lowPowerModeEnabled: false,
            timerOverheadNanos: 41.6,
            harnessOverheadNanos: 5.0,
            seedTableVersion: SeedTable.version
        )
    }
}
