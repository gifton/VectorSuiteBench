import Foundation

/// One-time calibration of `mach_absolute_time`'s self-measured overhead.
/// The returned value is the **median nanoseconds per back-to-back clock
/// read** — recorded in `RunMetadata` as context metadata.
///
/// **Critical**: this number is NEVER subtracted from per-sample single-shot
/// values. At the ~41.6 ns Apple Silicon timebase resolution, subtracting a
/// similarly-sized overhead from a fast op produces zero or negative
/// latency. Overhead correction applies only at the Amortized aggregate level
/// (where total loop time ≥100 µs makes overhead a sub-1 % effect), and is
/// presented as a chart annotation, not folded into raw samples.
public enum TimerCalibration {
    public static func measureOverheadNanos(clock: BenchClock = BenchClock(), samples: Int = 10_000) -> Double {
        precondition(samples >= 100, "calibration needs ≥100 samples")
        var deltas = [UInt64](repeating: 0, count: samples)
        // Warm the icache before timing.
        for _ in 0..<256 {
            _ = clock.now()
        }
        for i in 0..<samples {
            let a = clock.now()
            let b = clock.now()
            deltas[i] = b &- a
        }
        deltas.sort()
        let medianTicks = deltas[samples / 2]
        return Double(clock.nanos(medianTicks))
    }
}
