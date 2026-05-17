import Foundation
import BenchKit
import Observation

/// Observable model for the first-launch calibration flow (design doc §07
/// "Empty state · first launch"). Owns the state machine (idle → running →
/// complete / failed) and the append-only `transcript` that drives the
/// terminal-style status feed.
///
/// **Why this orchestrates the stages itself** instead of calling
/// `PeakMeasurement.ensureCached(...)`. The design doc says "engineers
/// want to see what step they're on, not a generic indeterminate bar"
/// — so we need progress emission mid-flight. `ensureCached` runs both
/// stages end-to-end with no callback hook; calling the stages
/// (`measureCompute()` / `measureBandwidth()`) and finishing with
/// `writeCached(_:in:)` lets us emit a transcript line between each.
///
/// **Testability.** The measurement workflow is an injected closure
/// (`Measure`). Production uses the default (real microkernels);
/// tests pass a stub that returns instantly with known values, so
/// the orchestration logic — state transitions, transcript ordering,
/// error handling — can be exercised without spending 30 s per test.
///
/// **Cancellation.** `cancel()` cancels the in-flight Task. The
/// in-Task cancellation checks land between stages, not inside the
/// microkernels (those run uninterruptibly for ≤30 s total — adding
/// per-loop cancellation checks would distort the timing). A cancel
/// during the bandwidth stage waits for that stage to finish, then
/// transitions to `.failed("Cancelled.")`. Acceptable for a one-time
/// setup flow.
@MainActor
@Observable
final class CalibrationStatus {

    /// State machine. `failed` carries a human-readable message rather
    /// than the underlying `Error` because (a) `Error` isn't `Equatable`
    /// for SwiftUI diffing and (b) the message is what the UI renders.
    ///
    /// `Equatable` is implemented manually because `PeakRecord` (carried
    /// by `.complete`) isn't Equatable in BenchKit. Records are compared
    /// by the fields that uniquely identify a measurement run —
    /// fingerprint + when + the two peak values — which is enough for
    /// SwiftUI's "did the state change?" check.
    enum Phase: Sendable {
        case idle
        case running
        case complete(PeakRecord)
        case failed(String)
    }

    /// One line in the calibration transcript. `id` is a UUID so SwiftUI's
    /// `ForEach` keys stably even when two adjacent lines carry identical
    /// text (rare but possible — e.g. "Step finished." repeated).
    struct TranscriptLine: Identifiable, Hashable, Sendable {
        let id: UUID
        let text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    /// The work the orchestrator delegates the actual measurement to.
    /// Receives a callback (`emit`) that the implementation calls to
    /// append a transcript line between stages. Returns the final
    /// `PeakRecord` to be written; the model writes it.
    ///
    /// **Not @MainActor.** The closure runs off the main thread so the
    /// 30-second microkernel work doesn't freeze the UI. Calls to `emit`
    /// (which IS @MainActor) cross actor boundaries — each is an
    /// `await emit(...)` from the closure body's perspective.
    typealias Measure = @Sendable (
        _ hardware: HardwareInventory,
        _ store: RunStore,
        _ emit: @MainActor @Sendable (String) -> Void
    ) async throws -> PeakRecord

    private(set) var phase: Phase = .idle
    private(set) var transcript: [TranscriptLine] = []

    private let measure: Measure
    private var task: Task<Void, Never>?

    /// Default initializer uses the real measurement workflow
    /// (`PeakMeasurement.measureCompute` + `.measureBandwidth` + `.writeCached`).
    init(measure: @escaping Measure = CalibrationStatus.defaultMeasure) {
        self.measure = measure
    }
}

// MARK: - Equatable

extension CalibrationStatus.Phase: Equatable {
    static func == (lhs: CalibrationStatus.Phase, rhs: CalibrationStatus.Phase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.running, .running):
            return true
        case (.complete(let a), .complete(let b)):
            return a.hardwareFingerprint == b.hardwareFingerprint
                && a.measuredAt == b.measuredAt
                && a.peakComputeGFLOPS == b.peakComputeGFLOPS
                && a.peakBandwidthGBPerSec == b.peakBandwidthGBPerSec
                && a.method == b.method
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

extension CalibrationStatus {

    /// Begin calibration. Idempotent — calling while running returns the
    /// existing Task. The returned Task is awaitable so tests (and any
    /// future caller that wants to synchronize) can `await task.value`.
    @discardableResult
    func start(hardware: HardwareInventory, store: RunStore) -> Task<Void, Never> {
        if let task { return task }
        phase = .running
        transcript = []
        let measureFn = measure
        let newTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(hardware: hardware, store: store, measure: measureFn)
        }
        task = newTask
        return newTask
    }

    /// Cancel the in-flight Task. Idempotent. Transitions phase to
    /// `.failed("Cancelled.")` once the Task observes the cancellation.
    func cancel() {
        task?.cancel()
    }

    /// Reset to `.idle` so the user can retry after a `.failed` state.
    /// Refuses while `.running` so a click-storm can't strand state mid-run.
    func reset() {
        switch phase {
        case .idle, .complete, .failed:
            phase = .idle
            transcript = []
            task = nil
        case .running:
            return    // refuse — caller must `cancel()` first
        }
    }

    // MARK: - Private orchestration

    private func run(
        hardware: HardwareInventory,
        store: RunStore,
        measure: Measure
    ) async {
        defer { task = nil }
        do {
            let record = try await measure(hardware, store) { [weak self] line in
                self?.transcript.append(TranscriptLine(text: line))
            }
            if Task.isCancelled {
                transcript.append(TranscriptLine(text: "Cancelled."))
                phase = .failed("Cancelled.")
                return
            }
            phase = .complete(record)
        } catch is CancellationError {
            transcript.append(TranscriptLine(text: "Cancelled."))
            phase = .failed("Cancelled.")
        } catch {
            transcript.append(TranscriptLine(text: "Error: \(error.localizedDescription)"))
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Default measurement workflow

    /// Production measurement: cache check → compute peak → bandwidth peak
    /// → write. Each stage emits one transcript line on entry and one on
    /// completion (with the measured value). Re-used by the in-app UI;
    /// tests pass their own stub.
    ///
    /// **`nonisolated`** — the stored closure value is Sendable; reading
    /// the property from a non-MainActor default-argument context (the
    /// init signature) needs no isolation hop. The closure body itself
    /// runs off the main thread (see `Measure` doc).
    nonisolated static let defaultMeasure: Measure = { hardware, store, emit in
        await emit("Checking peaks cache for \(hardware.fingerprint)…")
        if let cached = PeakMeasurement.loadCached(for: hardware.fingerprint, in: store) {
            await emit("Cache hit — using stored peaks (compute \(cached.method.compute), bandwidth \(cached.method.bandwidth)).")
            await emit("Calibration complete.")
            return cached
        }
        await emit("No cached peaks — measuring this machine from scratch.")

        await emit("Measuring single-P-core FMA throughput…")
        let compute = PeakMeasurement.measureCompute()
        await emit(String(
            format: "Peak compute: %.1f GFLOPS (%llu iterations in %llu ms).",
            compute.gflops, compute.iterations, compute.elapsedNanos / 1_000_000
        ))

        try Task.checkCancellation()

        await emit("Measuring memory bandwidth (STREAM-triad, multi-thread)…")
        let bandwidth = await PeakMeasurement.measureBandwidth()
        await emit(String(
            format: "Peak bandwidth: %.1f GB/s (%d threads × %d MiB arrays).",
            bandwidth.gbPerSec,
            bandwidth.threadCount,
            bandwidth.elementCount * MemoryLayout<Float>.size / (1024 * 1024)
        ))

        try Task.checkCancellation()

        let record = PeakRecord(
            schemaVersion: .current,
            hardwareFingerprint: hardware.fingerprint,
            measuredAt: Date(),
            peakComputeGFLOPS: compute.gflops,
            peakBandwidthGBPerSec: bandwidth.gbPerSec,
            method: PeakMethod(
                compute: PeakMeasurement.computeMethodVersion,
                bandwidth: PeakMeasurement.bandwidthMethodVersion
            )
        )
        await emit("Writing peaks to \(store.peakURL(for: hardware.fingerprint).lastPathComponent)…")
        try PeakMeasurement.writeCached(record, in: store)
        await emit("Calibration complete.")
        return record
    }
}
