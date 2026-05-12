import Foundation

/// Derives GB/s and GFLOP/s from the workload's declared `bytesMoved` and
/// `flops` plus the Amortized median per-op time. **Never derived from
/// single-shot samples** — at the Apple Silicon ~41.6 ns timebase resolution,
/// per-sample arithmetic on single-shot data can produce nonsense at the
/// noise floor.
public enum BandwidthEstimator {
    /// Returns GB/s. Returns 0 if any input is non-positive.
    public static func gbPerSec(bytesMoved: Int, nanosPerOp: Double) -> Double {
        guard bytesMoved > 0, nanosPerOp > 0 else { return 0 }
        // bytes / ns == GB / s (because 1 ns / B == 1 s / GB).
        return Double(bytesMoved) / nanosPerOp
    }

    /// Returns GFLOP/s. Returns 0 if any input is non-positive.
    public static func gflops(flops: Int, nanosPerOp: Double) -> Double {
        guard flops > 0, nanosPerOp > 0 else { return 0 }
        return Double(flops) / nanosPerOp
    }
}
