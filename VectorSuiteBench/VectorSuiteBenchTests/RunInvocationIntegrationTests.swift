import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit
@testable import VSBCore

/// Integration tests for the New Run modal's `RunInvocation`. Mirrors
/// the existing `RunControllerIntegrationTests` in VSBCore but exercises
/// the **UI invocation path**: configure a `RunConfig`, call
/// `invocation.start(config:)`, await completion via the test seam,
/// verify the produced `RunDocument` is well-formed on disk and the
/// invocation's state transitions correctly.
///
/// Uses `allowDebugBuildsForTesting: true` (same as the VSBCore test)
/// because the harness's `ReleaseGuard` refuses Debug builds in
/// production — but tests need to run under Debug.
@MainActor
@Suite("RunInvocation integration")
struct RunInvocationIntegrationTests {

    // MARK: - Happy path

    @Test("Start path: configure → start → await → valid RunDocument on disk")
    func startProducesValidDocument() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let invocation = RunInvocation(store: store)

        let config = makeMinimalConfig()  // dot · naive · n=64 · SHOT only

        invocation.start(config: config, allowDebugBuildsForTesting: true)
        // start() spawns the Task and returns synchronously; state
        // should already be .running by the time we observe it.
        if case .running = invocation.state {
            // expected
        } else {
            Issue.record(Comment(rawValue: "expected .running state immediately after start; got \(invocation.state)"))
        }
        #expect(invocation.isRunning)
        #expect(invocation.liveState == .running)

        await invocation.waitForCompletion()
        #expect(invocation.state == .idle, Comment(rawValue: "after completion state must return to .idle; got \(invocation.state)"))
        #expect(!invocation.isRunning)

        // Document on disk via the store: index.json shows the run.
        let index = try store.loadIndex()
        #expect(index.runs.count == 1)
        let runID = try #require(index.runs.first?.runID)
        #expect(FileManager.default.fileExists(atPath: store.manifestURL(for: runID).path))

        // Case JSONs present — at least one (the naive dot at N=64).
        let casesDir = store.casesDirectory(for: runID)
        let caseFiles = try FileManager.default.contentsOfDirectory(atPath: casesDir.path)
            .filter { $0.hasSuffix(".json") }
        #expect(caseFiles.count >= 1, Comment(rawValue: "expected ≥1 case file; got \(caseFiles.count)"))
    }

    // MARK: - Cancellation

    @Test("Pre-cancelled token → state returns to .idle with a valid partial document")
    func preCancelledRunStillProducesValidDocument() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let invocation = RunInvocation(store: store)

        let config = makeMinimalConfig()
        let token = CancellationToken()
        token.cancel()

        invocation.start(
            config: config,
            allowDebugBuildsForTesting: true,
            cancellationOverride: token
        )
        await invocation.waitForCompletion()
        #expect(invocation.state == .idle, Comment(rawValue: "cancellation produces a valid run, not a failure — state returns to .idle"))

        // Manifest still written (cancelled-run contract per BenchKit
        // spec §8: "a cancelled run is a valid run on disk").
        let index = try store.loadIndex()
        #expect(index.runs.count == 1)
    }

    // MARK: - Empty-selection guard

    @Test("Empty registry (zero ops selected) → state becomes .failed with reason")
    func emptySelectionFailsWithReason() {
        let tmp = (try? makeTempDir()) ?? FileManager.default.temporaryDirectory
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let invocation = RunInvocation(store: store)

        let config = RunConfig()
        // Strip all ops — the filter will yield zero workloads.
        for op in [OpKind.dot, .l2dist, .cosine] {
            if config.ops.contains(op) { config.toggleOp(op) }
        }
        #expect(config.ops.isEmpty)

        invocation.start(config: config, allowDebugBuildsForTesting: true)

        // start() returns immediately and never spawns a Task when the
        // filtered registry is empty — state should be .failed already.
        if case .failed(let reason) = invocation.state {
            #expect(reason.contains("No workloads match"))
        } else {
            Issue.record(Comment(rawValue: "expected .failed state; got \(invocation.state)"))
        }
        #expect(invocation.failureReason != nil)
    }

    // MARK: - Concurrent start is a no-op

    @Test("Calling start while already running is a no-op (no concurrent runs)")
    func concurrentStartIsNoOp() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RunStore(rootURL: tmp)
        let invocation = RunInvocation(store: store)
        let config = makeMinimalConfig()

        invocation.start(config: config, allowDebugBuildsForTesting: true)
        let firstRunID: String? = {
            if case .running(let id) = invocation.state { return id }
            return nil
        }()
        #expect(firstRunID != nil)

        // Try to start another run — should not spawn a new task or
        // change runID.
        invocation.start(config: config, allowDebugBuildsForTesting: true)
        if case .running(let id) = invocation.state {
            #expect(id == firstRunID, Comment(rawValue: "second start must not replace the in-flight runID"))
        } else {
            Issue.record(Comment(rawValue: "expected still .running; got \(invocation.state)"))
        }

        // Drain the in-flight task so the test doesn't leave background
        // work running.
        await invocation.waitForCompletion()
    }

    // MARK: - Fixtures

    /// Build a `RunConfig` filtered down to a single naive-dot case at
    /// N=64 — the smallest workload in the VSBCore registry, used by
    /// `RunControllerIntegrationTests` in VSBCore for the same reason
    /// (smallest wall time + a known-good baseline).
    private func makeMinimalConfig() -> RunConfig {
        let config = RunConfig()
        // Smoke defaults: ops {dot, l2dist, cosine} / impls
        // {vectorCore, accelerate, naive} / sizes {512} / SHOT only.
        // Reduce to dot only.
        if config.ops.contains(.l2dist) { config.toggleOp(.l2dist) }
        if config.ops.contains(.cosine) { config.toggleOp(.cosine) }
        // Reduce to naive only.
        if config.impls.contains(.vectorCore) { config.toggleImpl(.vectorCore) }
        if config.impls.contains(.accelerate) { config.toggleImpl(.accelerate) }
        // Swap size 512 → 64.
        if config.sizes.contains(512) { config.toggleSize(512) }
        if !config.sizes.contains(64) { config.toggleSize(64) }
        return config
    }

    nonisolated private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunInvocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
