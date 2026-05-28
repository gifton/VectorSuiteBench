import Foundation
import BenchKit
import VSBCore

/// Owns the in-flight benchmark run. Bridges between the `RunConfig`
/// surface in the New Run modal and BenchKit's `RunController`.
///
/// **State machine** (per locked decision §4c — minimum-viable scope):
/// - `.idle`: no run active. Toolbar shows `+ New Run`; LiveStateChip
///   green.
/// - `.running`: a Task is currently executing `RunController.run()`.
///   Toolbar swaps to `◼ Cancel`; LiveStateChip blue.
/// - `.failed`: most recent run threw (e.g. Debug-build `ReleaseGuard`
///   trip). Toolbar shows `+ New Run` again (user can retry);
///   LiveStateChip red with help text carrying the error.
///
/// **Streaming row treatment in the table is deliberately out of scope
/// for 4c** — the design seam (`VerificationDisplayState.inflight`)
/// stays reserved in the table; a future item will wire `RunProgress`
/// to it. For 4c, completed runs surface in the sidebar via
/// `RunStoreCoordinator`'s normal index-polling path.
///
/// **Concurrency**: only one run at a time. `start(config:)` is a no-op
/// when already running.
@MainActor
@Observable
final class RunInvocation {

    /// The three states the toolbar / LiveStateChip read from.
    enum State: Sendable, Equatable {
        case idle
        case running(runID: String)
        case failed(reason: String)
    }

    private(set) var state: State = .idle

    private let store: RunStore
    private var task: Task<Void, Never>?
    private var token: CancellationToken?

    init(store: RunStore) {
        self.store = store
    }

    // MARK: - Live state derivation

    /// Translate `state` into the `LiveState` enum the
    /// `LiveStateChip` consumes. Same mapping the toolbar uses to pick
    /// between New Run / Cancel.
    var liveState: LiveState {
        switch state {
        case .idle:    return .idle
        case .running: return .running
        case .failed:  return .failed
        }
    }

    /// `true` while a run is in flight. Used by the toolbar to swap
    /// the `+ New Run` button for `◼ Cancel`.
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Free-text reason when `state == .failed`; `nil` otherwise.
    /// Surfaced as the LiveStateChip's `.help(_:)` tooltip and (in
    /// future error UI) any inline error rendering.
    var failureReason: String? {
        if case .failed(let r) = state { return r }
        return nil
    }

    // MARK: - Start / Cancel

    /// Spawn a benchmark run from the given `RunConfig`. Returns
    /// immediately; the actual work happens in a detached Task.
    /// State observability drives the toolbar chip + sidebar refresh.
    ///
    /// **`allowDebugBuildsForTesting`** is a test-only seam. Production
    /// callers leave it `false` — the spec mandates Debug refusal per
    /// `ReleaseGuard.assertReleaseConfiguration()`.
    ///
    /// **`cancellationOverride`** is also a test seam: when supplied,
    /// uses the caller's token instead of constructing a fresh one.
    /// Lets the cancellation test pre-cancel before invoking
    /// (mirrors the deterministic-cancellation path in
    /// `RunControllerIntegrationTests`).
    func start(
        config: RunConfig,
        allowDebugBuildsForTesting: Bool = false,
        cancellationOverride: CancellationToken? = nil
    ) {
        guard !isRunning else { return }

        // Preset filter narrows the full registry per spec §3 (e.g., Smoke
        // pins dim 512 + VectorCore-optimized + Accelerate + naive). User
        // axes then narrow further. In practice the preset chip flips to
        // .custom as soon as the user touches an axis, so the preset filter
        // is restrictive only on the canned presets where the auto-fill
        // axes exactly match the preset's allow-list. Building the BenchKit
        // preset happens AFTER user-axes filtering so `.custom.ids` (the
        // manifest payload documenting what ran) reflects the actual case
        // set, not the full registry.
        let presetFiltered = presetFilteredWorkloads(VSBCoreRegistry.workloads, for: config)
        let registry = filteredRegistry(presetFiltered, for: config)
        if registry.isEmpty {
            state = .failed(reason: "No workloads match the current configuration. Adjust ops / impls / sizes and try again.")
            return
        }

        let token = cancellationOverride ?? CancellationToken()
        self.token = token
        let preset = makeBenchPreset(from: config, registry: registry)
        let controller = RunController(
            registry: registry,
            store: store,
            preset: preset,
            cancellation: token,
            allowDebugBuildsForTesting: allowDebugBuildsForTesting,
            // Item 5 covers first-launch peak measurement; the modal
            // doesn't re-measure peaks (a fresh fingerprint reaches
            // the calibration flow elsewhere).
            measurePeaks: false
        )

        state = .running(runID: controller.runID)

        task = Task { [weak self] in
            // The `Task { ... }` captures MainActor isolation from the
            // enclosing `start(...)` method, so `self?.finish(...)`
            // calls don't need `await` — same-actor hop.
            do {
                _ = try await controller.run()
                self?.finish(.idle)
            } catch let releaseError as ReleaseGuard.Error {
                self?.finish(.failed(reason: releaseError.description))
            } catch {
                self?.finish(.failed(reason: error.localizedDescription))
            }
        }
    }

    /// Cooperatively cancel the in-flight run. The running task
    /// observes the token between cases and produces a valid partial
    /// `RunDocument`; state flips to `.idle` when the task wraps up.
    func cancel() {
        token?.cancel()
    }

    /// Await the in-flight task. Returns immediately when idle.
    /// Test seam — production callers observe `state` instead.
    func waitForCompletion() async {
        await task?.value
    }

    // MARK: - Private

    private func finish(_ newState: State) {
        task = nil
        token = nil
        state = newState
    }

    /// Apply the preset's filter rules per BenchKit `RunPreset.filter(_:)`.
    /// `.custom` is identity (the user has hand-picked axes; preset
    /// machinery doesn't second-guess them); other cases delegate to the
    /// corresponding BenchKit preset's filter.
    private func presetFilteredWorkloads(
        _ workloads: [any RunnableWorkload],
        for config: RunConfig
    ) -> [any RunnableWorkload] {
        switch config.preset {
        case .smoke:         return BenchKit.RunPreset.smoke.filter(workloads)
        case .standard:      return BenchKit.RunPreset.standard.filter(workloads)
        case .full, .custom: return workloads
        }
    }

    /// Filter a pre-narrowed workload list by the user's RunConfig axes.
    /// Mirrors `vsb-run`'s CLI filter logic but takes the typed
    /// `RunConfig` axes (Sets) instead of stringly-typed argv tokens.
    ///
    /// **Shape matching**: vector(n), pairwise(_, n), matrix(_, n) all
    /// match against `config.sizes` by inner dim.
    private func filteredRegistry(
        _ workloads: [any RunnableWorkload],
        for config: RunConfig
    ) -> [any RunnableWorkload] {
        workloads.filter { workload in
            let id = workload.identifier
            guard config.ops.contains(id.op) else { return false }
            guard config.impls.contains(id.impl) else { return false }
            switch id.shape {
            case .vector(let n):           return config.sizes.contains(n)
            case .pairwise(_, let n):      return config.sizes.contains(n)
            case .matrix(_, let n):        return config.sizes.contains(n)
            }
        }
    }

    /// Map `RunConfig`'s preset selection to a BenchKit `RunPreset`.
    /// Honors `config.preset` directly: when the user picked one of the
    /// canned presets (`.smoke` / `.standard` / `.full`) and hasn't
    /// touched anything since (any subsequent change would have flipped
    /// the chip to `.custom`), we pass the matching BenchKit preset so
    /// `RunController.generatedRunID(preset:)` produces a sidebar
    /// label that matches user intent. Only the `.custom` path bakes
    /// the user's budget + sample-count axes into a fresh
    /// `RunPreset.custom(...)` payload.
    private func makeBenchPreset(
        from config: RunConfig,
        registry: [any RunnableWorkload]
    ) -> BenchKit.RunPreset {
        switch config.preset {
        case .smoke:    return .smoke
        case .standard: return .standard
        case .full:     return .full
        case .custom:
            let budget = BenchKit.WallClockBudget(
                total: .seconds(config.totalBudget.seconds),
                perCase: .milliseconds(Int(config.perCaseBudget.seconds * 1000)),
                abortPolicy: benchAbortPolicy(config.abortPolicy)
            )
            // Both upper bounds get the user's sample count; the runner
            // auto-tunes the actual N per case based on observed cost.
            let sampleCount = BenchKit.SampleCount(
                singleShotMax: config.sampleCount.count,
                amortizedSamples: config.modes.asModes.contains(.amortized)
                    ? config.sampleCount.count
                    : 0
            )
            // `ids` is documentation-only on the BenchKit side —
            // RunController iterates `registry` directly. Passing the
            // filtered IDs keeps the run manifest honest about what
            // was configured.
            let ids = registry.map(\.identifier)
            return .custom(budget: budget, sampleCount: sampleCount, ids: ids)
        }
    }

    private func benchAbortPolicy(_ policy: AbortPolicy) -> BenchKit.WallClockBudget.AbortPolicy {
        switch policy {
        case .skipRemaining:   return .skipRemaining
        case .truncateSamples: return .truncateSamples
        }
    }
}
