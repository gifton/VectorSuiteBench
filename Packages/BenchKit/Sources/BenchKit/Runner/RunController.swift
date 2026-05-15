import Foundation

/// Orchestrates a single run end-to-end:
///   1. probes environment (hardware, build, git, FPCR),
///   2. self-benches `NullWorkload` to derive the harness floor,
///   3. opens a `RunStore` run, writes each `CaseResult`, finalizes the run,
///   4. honors total wall budget + cancellation across the whole queue.
///
/// **Existential dispatch.** The registry is `[any RunnableWorkload]`. Per
/// case, `runVia(runner:asyncRunner:cancellation:)` is the protocol witness
/// that routes to `Runner.run(_:)` or `AsyncRunner.run(_:)` with the
/// concrete `Self` — no `switch on protocol kind`, no `Any` casts.
///
/// **FPCR.** `enableFlushToZero()` is called at run start; the previous
/// value is captured and restored on exit so a unit-test run doesn't leak
/// FZ/DN state into subsequent in-process work.
public struct RunController: Sendable {
    public let registry: [any RunnableWorkload]
    public let store: RunStore
    public let preset: RunPreset
    public let runID: String
    public let cancellation: CancellationToken?
    public let gitWorkingDirectory: URL?
    public let allowDebugBuildsForTesting: Bool

    public init(
        registry: [any RunnableWorkload],
        store: RunStore,
        preset: RunPreset,
        runID: String? = nil,
        cancellation: CancellationToken? = nil,
        gitWorkingDirectory: URL? = nil,
        allowDebugBuildsForTesting: Bool = false
    ) {
        self.registry = registry
        self.store = store
        self.preset = preset
        self.cancellation = cancellation
        self.gitWorkingDirectory = gitWorkingDirectory
        self.allowDebugBuildsForTesting = allowDebugBuildsForTesting
        self.runID = runID ?? Self.generatedRunID(preset: preset)
    }

    /// Drive the entire run. On success returns the finalized `RunDocument`
    /// (also persisted via the store). `total` budget overruns and
    /// cancellation produce a *valid* partial document — completed cases plus
    /// `.truncated` on the in-flight case (if any).
    @discardableResult
    public func run() async throws -> RunDocument {
        try ReleaseGuard.assertReleaseConfiguration(
            allowDebugForTesting: allowDebugBuildsForTesting
        )

        // 1. Environment probes.
        let hardware = HardwareInventory.probe()
        let build = BuildProvenance.probe()
        let git = GitProvenance.probe(workingDirectory: gitWorkingDirectory)
        let previousFPCR = FPCRState.enableFlushToZero()
        defer { FPCRState.restore(previousFPCR) }
        let fpcrAtStart = FPCRState.current()

        // Preset-derived budget + sample count.
        let budget = preset.defaultBudget
        let sampleCount = Self.sampleCount(for: preset)

        // 2. Build runners (shared across the queue).
        let clock = BenchClock()
        let timerOverheadNanos = TimerCalibration.measureOverheadNanos(clock: clock)
        let runner = Runner(
            runID: runID,
            budget: budget,
            sampleCount: sampleCount,
            timerOverheadNanos: timerOverheadNanos
        )
        let asyncRunner = AsyncRunner(
            runID: runID,
            budget: budget,
            sampleCount: sampleCount,
            timerOverheadNanos: timerOverheadNanos
        )

        // 3. NullWorkload self-bench — runs through the same Runner with a
        //    dedicated SampleCount so we always get an Amortized number even
        //    on the .smoke preset (which has amortizedSamples = 0). The
        //    Amortized median per-op is the harness floor.
        let harnessOverheadNanos = await measureHarnessFloor(
            timerOverheadNanos: timerOverheadNanos,
            budget: budget
        )

        // 4. Compose RunMetadata.
        let metadata = RunMetadata(
            runID: runID,
            timestamp: Date(),
            preset: preset,
            git: git,
            build: build,
            hardware: hardware,
            linkedLibraryVersions: linkedLibraryVersions(),
            fpcrAtStart: fpcrAtStart,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            timerOverheadNanos: timerOverheadNanos,
            harnessOverheadNanos: harnessOverheadNanos,
            seedTableVersion: SeedTable.version
        )

        try store.beginRun(metadata: metadata)

        // 5. Drive the queue. Total-budget overrun stops the queue regardless
        //    of `abortPolicy` (the policy governs per-case sample truncation;
        //    once total wall is gone there's nothing left to truncate to).
        let queueStartTicks = clock.now()
        let totalBudgetNanos = nanos(from: budget.total)
        for workload in registry {
            if cancellation?.isCancelled == true { break }
            if totalBudgetNanos > 0,
               clock.nanos(clock.now() &- queueStartTicks) >= totalBudgetNanos {
                break
            }
            let result = await workload.runVia(
                runner: runner,
                asyncRunner: asyncRunner,
                cancellation: cancellation
            )
            try store.writeCase(result)
        }

        // 6. Finalize: assemble RunDocument + update index.json.
        return try store.finalizeRun(runID: runID)
    }

    // MARK: - Helpers

    /// Generate a default runID in the canonical
    /// `<ISO-timestamp>__<git-sha>__<preset>` shape. Git probe happens twice
    /// when the caller doesn't pre-supply a runID, but it's cheap (~ms) and
    /// the alternative — building runID inside `run()` and recomputing — is
    /// uglier.
    private static func generatedRunID(preset: RunPreset) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Replace `:` so the timestamp is filename-safe.
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let sha = GitProvenance.probe().sha
        let shortSha = String(sha.prefix(7))
        return "\(stamp)__\(shortSha)__\(preset.label)"
    }

    private static func sampleCount(for preset: RunPreset) -> SampleCount {
        switch preset {
        case .smoke:    return .smoke
        case .standard: return .standard
        case .full:     return .full
        case .custom(_, let sampleCount, _): return sampleCount
        }
    }

    /// Linked library versions — best-effort probe. Phase 2.0 ships an empty
    /// dict; later phases can introspect `Bundle.allFrameworks` or read
    /// per-package version files. Kept as a hook so the RunMetadata schema
    /// is stable even before we wire it up.
    private func linkedLibraryVersions() -> [String: String] {
        ["BenchKit": "0.2.0"]
    }

    private func nanos(from duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(max(components.seconds, 0)) &* 1_000_000_000
            &+ UInt64(max(components.attoseconds, 0) / 1_000_000_000)
    }

    /// Run `NullWorkload` through Runner with an explicit Amortized budget so
    /// we always derive a floor — even under the `.smoke` preset, which
    /// otherwise disables Amortized mode. Failures (verification, etc.)
    /// surface as `nil` so RunMetadata stays Codable-clean.
    private func measureHarnessFloor(
        timerOverheadNanos: Double,
        budget: WallClockBudget
    ) async -> Double? {
        // Cap the self-bench budget so a bad clock or thermal stall can't
        // strand the run before any real work has begun.
        let selfBenchBudget = WallClockBudget(
            total: .seconds(5),
            perCase: .seconds(5),
            abortPolicy: .truncateSamples
        )
        let selfBenchRunner = Runner(
            runID: "\(runID)__self-bench",
            budget: selfBenchBudget,
            sampleCount: SampleCount(singleShotMax: 100, amortizedSamples: 32),
            timerOverheadNanos: timerOverheadNanos
        )
        let result = await selfBenchRunner.run(NullWorkload())
        // `nanosPerOp` is the loop median / K. That's the harness floor:
        // clock-read + BlackHole + Runner overhead per op.
        return result.amortized?.nanosPerOp
    }
}
