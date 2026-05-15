import Foundation
import Darwin.Mach
import os

/// Continuous resident-set probe that samples `mach_task_basic_info` at a
/// fixed cadence on a background queue. Used **only during Amortized
/// sampling** — single-shot sampling stays snapshot-only because a 100 Hz
/// background reader would inject exactly the kind of OS jitter we're
/// trying to characterize.
///
/// Why this is safe during Amortized but not single-shot:
/// - Single-shot: per-sample wall is < 1 µs for most ops. A 10-ms-cadence
///   reader competes for the same SoC and the kernel's brief task-info lock
///   shows up as tail latency in the histogram.
/// - Amortized: each K-iteration loop runs ≥ 100 µs by design. A probe
///   firing at most once per ten loops contributes sub-1 % overhead and
///   does not perturb the median.
///
/// Usage:
/// ```
/// let probe = MemoryProbe()
/// let handle = probe.start(referenceTicks: clock.now(), clock: clock)
/// // ... run the timed loop ...
/// let trace = probe.stop(handle)
/// ```
public final class MemoryProbe: @unchecked Sendable {
    public let intervalMillis: Int

    public init(intervalMillis: Int = 10) {
        precondition(intervalMillis > 0, "probe interval must be positive")
        self.intervalMillis = intervalMillis
    }

    /// Begin sampling. `referenceTicks` is the run's clock zero so the
    /// recorded `timestampNanos` are loop-relative, not wall-clock.
    public func start(referenceTicks: UInt64, clock: BenchClock) -> Handle {
        let state = SampleState()
        let queue = DispatchQueue(
            label: "vsb.MemoryProbe",
            qos: .background
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(intervalMillis),
            leeway: .milliseconds(1)
        )
        // `DispatchSource.cancel()` is non-blocking; a handler invocation
        // queued before cancel can still fire. The `stopped` flag is the
        // race guard: `stop()` sets it before calling `cancel()`, so any
        // late firing is a no-op.
        timer.setEventHandler {
            guard !state.isStopped else { return }
            let now = clock.now()
            let rss = MemoryProbe.readResidentSize()
            let sample = MemorySample(
                timestampNanos: clock.nanos(now &- referenceTicks),
                residentBytes: rss
            )
            state.append(sample)
        }
        timer.resume()
        return Handle(timer: timer, state: state)
    }

    /// End sampling and return the accumulated trace. Sets the state's
    /// `stopped` flag *before* cancelling the timer so any in-flight
    /// handler invocation observes it and short-circuits — `DispatchSource
    /// .cancel()` is non-blocking, so without this flag a late firing
    /// would race past our snapshot read.
    public func stop(_ handle: Handle) -> [MemorySample] {
        handle.state.markStopped()
        handle.timer.cancel()
        return handle.state.snapshot()
    }

    // MARK: - Internals

    /// Read RSS via `task_info` / `MACH_TASK_BASIC_INFO`. Returns 0 on
    /// kernel failure — caller treats 0 as "unknown" without raising.
    private static func readResidentSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    public struct Handle {
        fileprivate let timer: DispatchSourceTimer
        fileprivate let state: SampleState
    }

    /// Lock-guarded sample list. Append happens on the probe's background
    /// queue; snapshot happens on the caller. `OSAllocatedUnfairLock` is
    /// the right primitive — sub-microsecond contention, no Swift-runtime
    /// allocator pressure under load.
    fileprivate final class SampleState: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<[MemorySample]>(initialState: [])
        private let stoppedLock = OSAllocatedUnfairLock<Bool>(initialState: false)

        func append(_ sample: MemorySample) {
            lock.withLock { $0.append(sample) }
        }

        func snapshot() -> [MemorySample] {
            lock.withLock { $0 }
        }

        var isStopped: Bool {
            stoppedLock.withLock { $0 }
        }

        func markStopped() {
            stoppedLock.withLock { $0 = true }
        }
    }
}
