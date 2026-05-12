import Foundation
import Darwin.Mach

/// Monotonic clock backed by `mach_absolute_time` with one-time timebase
/// conversion. The returned `now()` is a tick count; `nanos(_:)` converts a
/// delta of ticks to nanoseconds.
///
/// **Resolution floor on Apple Silicon:** ~41.6 ns (24 MHz timebase). Ops
/// shorter than ~50 ns single-shot are not honestly measurable in single-shot
/// mode — see Runner for Amortized fallback.
public struct BenchClock: Sendable {
    public let timebase: mach_timebase_info_data_t

    public init() {
        var info = mach_timebase_info_data_t()
        let result = mach_timebase_info(&info)
        precondition(result == KERN_SUCCESS, "mach_timebase_info failed: \(result)")
        self.timebase = info
    }

    @inlinable
    @inline(__always)
    public func now() -> UInt64 {
        mach_absolute_time()
    }

    /// Convert a `mach_absolute_time` delta (ticks) into nanoseconds.
    @inlinable
    @inline(__always)
    public func nanos(_ deltaTicks: UInt64) -> UInt64 {
        // (delta * numer) / denom — use 128-bit math via overflow-guarded steps
        // to avoid overflow for long deltas. On Apple Silicon numer == denom == 1
        // typically, but we don't assume.
        let product = deltaTicks.multipliedFullWidth(by: UInt64(timebase.numer))
        // product.high : product.low is the 128-bit result
        // divide by denom
        let denom = UInt64(timebase.denom)
        if product.high == 0 {
            return product.low / denom
        }
        // For deltas long enough to overflow 64 bits after multiplication,
        // fall back to Double arithmetic. Loses ~1 ULP at the extreme; fine
        // for wall-time-scale numbers.
        let asDouble = Double(deltaTicks) * Double(timebase.numer) / Double(denom)
        return UInt64(asDouble)
    }
}
