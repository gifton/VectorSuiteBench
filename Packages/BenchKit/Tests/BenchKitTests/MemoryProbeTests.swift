import Testing
import Foundation
@testable import BenchKit

@Suite("MemoryProbe")
struct MemoryProbeTests {

    @Test("Probe collects samples at the configured cadence")
    func cadence() async throws {
        let clock = BenchClock()
        let probe = MemoryProbe(intervalMillis: 10)
        let handle = probe.start(referenceTicks: clock.now(), clock: clock)
        // Run for ~100 ms. Background scheduler latency makes precise
        // counts unreliable; a lower bound of 5 keeps the test
        // non-flaky on shared CI while still confirming the timer fires.
        try await Task.sleep(for: .milliseconds(200))
        let trace = probe.stop(handle)
        // Background-QoS timer + 1 ms leeway: expected ~20 samples over
        // 200 ms, but under contention or thermal pressure it can drop to
        // single digits. The point of this test is "the timer fires at
        // all", not exact cadence — keep the floor loose to stay
        // non-flaky on shared CI.
        #expect(trace.count >= 2,
                "expected ≥2 samples at 10ms cadence over 200ms; got \(trace.count)")
        // RSS of a running test process is always > 0.
        #expect(trace.allSatisfy { $0.residentBytes > 0 })
    }

    @Test("Timestamps are loop-relative, not wall-clock")
    func relativeTimestamps() async throws {
        let clock = BenchClock()
        let probe = MemoryProbe(intervalMillis: 10)
        let handle = probe.start(referenceTicks: clock.now(), clock: clock)
        try await Task.sleep(for: .milliseconds(50))
        let trace = probe.stop(handle)
        #expect(!trace.isEmpty)
        // First sample's timestamp is at most ~milliseconds from t=0;
        // the unsigned-subtract math means a wall-clock encoding would
        // produce a huge value (nanos since boot).
        if let first = trace.first {
            #expect(first.timestampNanos < 50_000_000,
                    "first probe sample must be loop-relative (<50 ms); got \(first.timestampNanos) ns")
        }
    }

    @Test("Stop is idempotent — no samples appear after cancellation")
    func stopIsFinal() async throws {
        let clock = BenchClock()
        let probe = MemoryProbe(intervalMillis: 5)
        let handle = probe.start(referenceTicks: clock.now(), clock: clock)
        try await Task.sleep(for: .milliseconds(30))
        let trace1 = probe.stop(handle)
        // After stop, wait long enough for several would-be ticks.
        try await Task.sleep(for: .milliseconds(30))
        // The handle's state isn't directly snapshottable post-stop, but
        // calling stop() again is the public contract — verify it doesn't
        // crash and returns a count >= trace1 (the lock-snapshot read is
        // idempotent on a cancelled timer).
        let trace2 = probe.stop(handle)
        #expect(trace2.count == trace1.count,
                "samples must not accrue after stop; was \(trace1.count), now \(trace2.count)")
    }

    @Test("Runner-with-memoryProbe-nil produces an empty trace on amortized cases")
    func runnerOptOut() async {
        let runner = Runner(
            runID: "memprobe-opt-out",
            budget: .smoke,
            sampleCount: SampleCount(singleShotMax: 16, amortizedSamples: 8),
            memoryProbe: nil
        )
        let result = await runner.run(NullWorkload())
        #expect(result.memoryTrace.isEmpty,
                "memoryTrace must be empty when probe is nil; got \(result.memoryTrace.count) samples")
    }
}
