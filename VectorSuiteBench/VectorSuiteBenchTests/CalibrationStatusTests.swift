import Testing
import Foundation
@testable import VectorSuiteBench
@testable import BenchKit

/// State-machine + transcript tests for the first-launch calibration
/// model. All tests use a stubbed `Measure` closure so they execute in
/// milliseconds rather than spending 30 s per test on the real
/// microkernels. The actual numerical correctness of `measureCompute` /
/// `measureBandwidth` is covered by `PeakMeasurementTests` in BenchKit.
@Suite("CalibrationStatus")
@MainActor
struct CalibrationStatusTests {

    @Test("Starts in .idle with empty transcript")
    func initialState() {
        let status = CalibrationStatus()
        #expect(status.phase == .idle)
        #expect(status.transcript.isEmpty)
    }

    @Test("Successful measurement transitions idle → running → complete and captures transcript")
    func happyPath() async {
        let record = makeRecord()
        let status = CalibrationStatus(measure: { _, _, emit in
            emit("step one")
            emit("step two")
            return record
        })
        let task = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        // After start() returns synchronously, phase is .running (the
        // Task hasn't necessarily made progress yet).
        #expect(status.phase == .running)
        await task.value
        #expect(status.phase == .complete(record))
        #expect(status.transcript.map(\.text) == ["step one", "step two"])
    }

    @Test("Failing measurement transitions to .failed with the error message")
    func failurePath() async {
        struct StubError: LocalizedError {
            var errorDescription: String? { "stub failure" }
        }
        let status = CalibrationStatus(measure: { _, _, emit in
            emit("starting")
            throw StubError()
        })
        let task = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        await task.value
        if case .failed(let message) = status.phase {
            #expect(message == "stub failure")
        } else {
            Issue.record(Comment(rawValue: "expected .failed; got \(status.phase)"))
        }
        // The error message gets appended as the last transcript line.
        #expect(status.transcript.contains { $0.text.contains("stub failure") })
    }

    @Test("CancellationError lands as .failed(\"Cancelled.\")")
    func cancellationPath() async {
        let status = CalibrationStatus(measure: { _, _, _ in
            throw CancellationError()
        })
        let task = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        await task.value
        #expect(status.phase == .failed("Cancelled."))
        #expect(status.transcript.last?.text == "Cancelled.")
    }

    @Test("start() while running is idempotent — returns the existing Task")
    func startIsIdempotent() async {
        let started = expectation()
        let status = CalibrationStatus(measure: { _, _, emit in
            emit("starting")
            started.fulfill()
            try await Task.sleep(for: .milliseconds(50))
            return makeRecord()
        })
        let t1 = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        await started.wait()
        let t2 = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        #expect(t1 == t2, Comment(rawValue: "second start() must return the same Task"))
        await t1.value
    }

    @Test("reset() clears transcript and returns to .idle after .complete")
    func resetAfterComplete() async {
        let status = CalibrationStatus(measure: { _, _, emit in
            emit("done")
            return makeRecord()
        })
        let task = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        await task.value
        #expect(!status.transcript.isEmpty)
        status.reset()
        #expect(status.phase == .idle)
        #expect(status.transcript.isEmpty)
    }

    @Test("reset() is a no-op while .running")
    func resetRefusedWhileRunning() async {
        let started = expectation()
        let status = CalibrationStatus(measure: { _, _, emit in
            emit("running")
            started.fulfill()
            try await Task.sleep(for: .milliseconds(80))
            return makeRecord()
        })
        let task = status.start(hardware: HardwareInventory.probe(), store: makeStore())
        await started.wait()
        let transcriptCount = status.transcript.count
        status.reset()    // should be ignored
        #expect(status.phase == .running)
        #expect(status.transcript.count == transcriptCount)
        await task.value
    }

    @Test("defaultMeasure cache-hit path short-circuits without re-measuring")
    func defaultMeasureCacheHit() async throws {
        // Pre-populate the store with a valid cached record so
        // `defaultMeasure` takes the cache-hit branch. Without the
        // pre-population the test would run the real microkernels
        // (~30 s) — far too slow for a unit test.
        let store = try makeStoreOnDisk()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let hardware = HardwareInventory.probe()
        let preCached = PeakRecord(
            schemaVersion: .current,
            hardwareFingerprint: hardware.fingerprint,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            peakComputeGFLOPS: 1.0,
            peakBandwidthGBPerSec: 1.0,
            method: PeakMethod(
                compute: PeakMeasurement.computeMethodVersion,
                bandwidth: PeakMeasurement.bandwidthMethodVersion
            )
        )
        try PeakMeasurement.writeCached(preCached, in: store)

        let status = CalibrationStatus()    // uses defaultMeasure
        let task = status.start(hardware: hardware, store: store)
        await task.value
        if case .complete(let record) = status.phase {
            #expect(record.peakComputeGFLOPS == 1.0)
            #expect(record.peakBandwidthGBPerSec == 1.0)
        } else {
            Issue.record(Comment(rawValue: "expected .complete on cache hit; got \(status.phase)"))
        }
        #expect(status.transcript.contains { $0.text.contains("Cache hit") },
                Comment(rawValue: "cache-hit branch must announce the hit in the transcript"))
    }

    // MARK: - Helpers

    private func makeStore() -> RunStore {
        RunStore(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("CalibrationStatusTests-\(UUID().uuidString)"))
    }

    private func makeStoreOnDisk() throws -> RunStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalibrationStatusTests-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RunStore(rootURL: dir)
    }

    private func makeRecord(
        compute: Double = 100,
        bandwidth: Double = 50
    ) -> PeakRecord {
        PeakRecord(
            schemaVersion: .current,
            hardwareFingerprint: "test-fingerprint",
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            peakComputeGFLOPS: compute,
            peakBandwidthGBPerSec: bandwidth,
            method: PeakMethod(compute: "stub", bandwidth: "stub")
        )
    }

    /// Tiny continuation-backed expectation. Swift Testing has no
    /// XCTestExpectation-equivalent; this is the smallest thing that
    /// lets one task signal another that "I've started".
    private func expectation() -> Expectation {
        Expectation()
    }
}

/// Continuation-backed one-shot signal. `fulfill()` is idempotent.
/// `wait()` resumes when the first `fulfill()` lands.
@MainActor
final class Expectation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fulfilled = false

    func fulfill() {
        if fulfilled { return }
        fulfilled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fulfilled { return }
        await withCheckedContinuation { cont in
            if fulfilled {
                cont.resume()
            } else {
                continuation = cont
            }
        }
    }
}
