import Foundation
import BenchKit
import Observation

/// Polls a run's `cases/` directory to surface progress to the UI while a
/// `RunController` is mid-flight. Created when a run starts (Item 4c
/// invokes `RunController.run()`); discarded when the run finalizes.
///
/// **What we can observe from disk.** RunStore writes case JSON atomically
/// AFTER each case completes — the in-flight case is invisible to a
/// disk-scan. So `completedCount` is the count of finalized cases on disk;
/// `currentCase` is intentionally a separate setter that the orchestrator
/// (Item 4c) populates from in-process signals (the runner hands us the
/// `WorkloadID` it's about to start). Without the orchestrator wiring,
/// `currentCase` stays `nil` even while the disk-scan reports progress.
///
/// **Polling cadence.** Default 500 ms — finer than `RunStoreCoordinator`
/// (1 s) because the in-flight UI cares about responsiveness, and the
/// `cases/` scan is cheap (sub-millisecond for any reasonable case count).
@MainActor
@Observable
final class RunProgress {
    let runID: String
    let totalCount: Int
    let store: RunStore

    private(set) var completedCount: Int = 0
    private(set) var currentCase: WorkloadID? = nil
    private(set) var isRunning: Bool = false

    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration

    init(
        runID: String,
        totalCount: Int,
        store: RunStore,
        pollInterval: Duration = .milliseconds(500)
    ) {
        self.runID = runID
        self.totalCount = totalCount
        self.store = store
        self.pollInterval = pollInterval
    }

    /// Fraction in `[0, 1]`. Returns 0 when `totalCount == 0` to avoid
    /// a divide-by-zero from a corrupt caller; UIs treating 0 as
    /// "nothing started" still read correctly.
    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    /// Begin polling the cases dir. Idempotent.
    func start() {
        guard pollTask == nil else { return }
        isRunning = true
        let interval = pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.scan()
            }
        }
    }

    /// Stop polling. Idempotent. The `currentCase` setter remains
    /// available so a final "wrap-up" signal from the orchestrator can
    /// still clear it.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
    }

    /// Re-scan the cases directory immediately. Public so callers that
    /// know a case just finished (synchronous signal from the runner)
    /// can refresh without waiting for the next poll tick.
    func scan() {
        let dir = store.casesDirectory(for: runID)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return
        }
        let count = entries.lazy.filter { $0.hasSuffix(".json") }.count
        completedCount = count
    }

    /// Set the in-flight case. Item 4c wires this up from the runner's
    /// pre-invoke hook; until then, callers can leave it `nil`.
    func setCurrentCase(_ id: WorkloadID?) {
        currentCase = id
    }
}
