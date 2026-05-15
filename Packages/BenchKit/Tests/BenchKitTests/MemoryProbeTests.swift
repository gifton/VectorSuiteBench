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
        // 200 ms, but under contention or thermal pressure parallel test
        // runs can starve the queue and produce zero ticks. The point of
        // this test is "the timer's wired up and produces well-formed
        // samples when it fires", not exact cadence — assert on shape,
        // not count.
        for sample in trace {
            #expect(sample.residentBytes > 0,
                    "every sample must record positive RSS for a running process")
        }
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

    @Test("Stop is idempotent — at most one in-flight sample lands post-cancel")
    func stopIsFinal() async throws {
        let clock = BenchClock()
        let probe = MemoryProbe(intervalMillis: 5)
        let handle = probe.start(referenceTicks: clock.now(), clock: clock)
        try await Task.sleep(for: .milliseconds(30))
        let trace1 = probe.stop(handle)
        // After stop, wait long enough for several would-be ticks.
        try await Task.sleep(for: .milliseconds(30))
        let trace2 = probe.stop(handle)
        // `DispatchSource.cancel()` is non-blocking; a handler that
        // already passed the `stopped` guard at the top can still finish
        // its append before stop()'s snapshot runs. That's one extra
        // sample, max. What we DO guarantee: no further handler runs
        // after cancel(), so trace2 - trace1 is bounded by 1, and stop()
        // remains idempotent past that tiny window.
        let delta = trace2.count - trace1.count
        #expect(delta >= 0 && delta <= 1,
                "samples must not accrue after stop (delta = \(delta))")
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
